# Incident Runbook

First response guide for common failure modes in this stack. Keep it short,
imperative, and copy-paste friendly.

All commands assume `AWS_REGION=ap-south-1` and that the operator has assumed
the read-only incident-response role.

## 0. Triage checklist (60 seconds)

- Open the SNS alert email and note the alarm name + dimensions.
- Check ALB health in the AWS console: `Load Balancers > <project>-alb > Targets`.
- Check ASG activity: `Auto Scaling Groups > <project>-asg > Activity`.
- Tail recent logs:

```
aws logs tail /<project>/<env>/services --since 15m --follow
```

## 1. Alarm: `<project>-<env>-alb-5xx`

**What it means**: targets are returning 5xx to the ALB at a rate above the
threshold. User-visible errors.

Steps:
1. Filter logs for 5xx:

```
aws logs filter-log-events \
  --log-group-name /<project>/<env>/services \
  --filter-pattern '{ $.status >= 500 }' \
  --start-time $(($(date +%s%3N) - 900000))
```

2. Group by `tenant_id` and `path` to see if it is a single tenant or endpoint.
3. Correlate with the latest image digest:

```
aws ecr describe-images --repository-name service1 --query 'sort_by(imageDetails,&imagePushedAt)[-1]'
```

4. Rollback if the alarm followed a recent deploy:
   - Re-tag the previous image digest as `:latest` in ECR.
   - Terminate one ASG instance; the replacement pulls the rolled-back image.
5. Open a ticket capturing the first bad request's `request_id` and a log line.

## 2. Alarm: `<project>-<env>-tg[12]-unhealthy`

**What it means**: one or more targets fail the `/health` check.

Steps:
1. Identify the failing target instance id from the ALB console.
2. SSH into it (or `aws ssm start-session`) and inspect containers:

```
sudo docker ps
sudo docker logs <container_id> --tail 200
```

3. Common causes:
   - Out of memory (`docker stats`, `dmesg | tail`).
   - Container crashed after a bad config -> check `/opt/microservices/app.env`.
   - Disk full (`df -h`).
4. If the instance is unrecoverable, set its ASG lifecycle state to
   `Terminating` via the console; the ASG launches a fresh one.

## 3. Alarm: `<project>-<env>-asg-cpu-sustained-high`

**What it means**: CPU stayed above 70% for 15 minutes. Scale-out should have
fired. If it did not, we are capacity-bound.

Steps:
1. Confirm ASG size in the console: has `DesiredCapacity` increased?
2. If stuck at `max_size`, raise `asg_max_size` in the env tfvars and apply.
3. If capacity rose but CPU is still pinned: look for a runaway request
   pattern (log-group `status = 200` count per minute, grouped by `tenant_id`).
4. Consider WAF rate-limit tightening as a temporary shield.

## 4. Suspected security event

1. Snapshot the root volume of the affected instance:

```
aws ec2 create-snapshot --volume-id <vol> --description "ir-$(date +%F)"
```

2. Isolate the instance by moving it into a quarantine SG with no ingress
   and egress limited to the log shipper endpoint.
3. Rotate any credential that could have leaked:
   - Update the value in Secrets Manager.
   - Terminate all ASG instances so the new value is picked up.
4. Capture evidence:

```
aws logs filter-log-events --log-group-name /<project>/<env>/services \
  --filter-pattern '{ $.tenant_id = "<suspected-tenant>" }'
```

5. File a postmortem within 48 hours.

## 5. Deploy gone bad

1. Pull the last known-good image digest:

```
aws ecr describe-images --repository-name service1 \
  --query 'sort_by(imageDetails[?contains(imageTags,`stable`)],&imagePushedAt)[-1]'
```

2. Re-tag as `:latest`:

```
MANIFEST=$(aws ecr batch-get-image --repository-name service1 \
  --image-ids imageDigest=<digest> --query 'images[0].imageManifest' --output text)

aws ecr put-image --repository-name service1 --image-tag latest --image-manifest "$MANIFEST"
```

3. Trigger a rolling replacement:

```
aws autoscaling start-instance-refresh --auto-scaling-group-name <project>-asg
```

## Escalation

- Primary: SNS topic `<project>-<env>-alerts` (email).
- Secondary: any subscriber added to that topic (PagerDuty, Opsgenie, Slack
  webhook). Adding a new subscriber is a `terraform apply` away.
