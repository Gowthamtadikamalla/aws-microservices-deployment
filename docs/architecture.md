# Architecture

This document describes the full architecture of the microservices deployment. It complements the high-level diagram in `README.md` with the reasoning behind each layer.

## Design principles

- **Stateless services.** Any EC2 instance can be replaced at any time without data loss. All state lives in AWS-managed services.
- **Least-privilege IAM.** Every permission granted to the EC2 role is scoped to specific ARNs. The only `*` resource is `ecr:GetAuthorizationToken`, which AWS requires globally.
- **Multi-AZ.** Both the ALB and the ASG span two public subnets in different availability zones.
- **Configuration out of code.** Non-sensitive config lives in SSM Parameter Store; sensitive values live in Secrets Manager. Neither is committed to Git.
- **Observability first.** Logs, metrics, and alarms are part of the stack — not an afterthought.
- **Reproducible.** Every resource is defined in Terraform and can be rebuilt per environment via `environments/*.tfvars`.

## High-level diagram

```
                       Internet
                           |
                 +---------------------+
                 |   Route 53 (A/ALIAS)|
                 |  api.<env>.<domain> |
                 +----------+----------+
                            |
                   +--------+--------+
                   |    AWS WAFv2    |   managed rules + rate limit
                   +--------+--------+
                            |
           +----------------+----------------+
           |  Application Load Balancer      |
           |  :80 (redirect)  :443 (TLS 1.2+)|
           +---------+-------------+---------+
                     |             |
              /service1*      /service2*
                     |             |
          +----------+----+  +-----+----------+
          | Target Group 1|  | Target Group 2 |
          | :5000         |  | :5001          |
          +-------+-------+  +-------+--------+
                  \                 /
                   \               /
             +------+---------------+------+
             |   Auto Scaling Group        |
             |   min=2  desired=2-3  max=4-6
             |   (sized per environment)   |
             |   Ubuntu 24.04 / gp3 / AZ-1 |
             |   Ubuntu 24.04 / gp3 / AZ-2 |
             +--------------+--------------+
                            |
                    user-data bootstrap
                            |
   +------------+  +-------------+  +--------------+  +---------------+
   |  Amazon    |  |  SSM        |  |  Secrets     |  |  CloudWatch   |
   |  ECR       |  |  Parameter  |  |  Manager     |  |  Logs + Alarms|
   |  (images)  |  |  Store      |  |  (app creds) |  |  + SNS alerts |
   +------------+  +-------------+  +--------------+  +---------------+
```

## Request lifecycle

1. Client issues a request to `https://api.<env>.<domain>/service1`.
2. Route 53 resolves the alias to the ALB's regional endpoint.
3. AWS WAFv2 evaluates the managed rule groups and the per-IP rate limit; blocked requests never reach the ALB targets.
4. The ALB terminates TLS on the HTTPS listener with an ACM certificate; the HTTP listener redirects anything on port 80 to 443.
5. Path rule `/service1*` forwards to target group 1 (port 5000); `/service2*` forwards to target group 2 (port 5001).
6. The ALB picks a healthy EC2 target registered by the Auto Scaling Group.
7. The container receives the request, reads `X-Tenant-ID` and `X-Request-ID`, processes it, and emits a structured JSON access log line.
8. The Docker `awslogs` driver streams the line to `/<project>/<env>/services` in CloudWatch Logs.

## EC2 bootstrap

The Launch Template `user_data` runs once per instance on first boot:

1. `apt-get update && upgrade` for the base image.
2. Install Docker CE and the Docker Compose plugin from the official Docker apt repository.
3. Install AWS CLI v2.
4. `aws ecr get-login-password | docker login` using the instance role's credentials.
5. Fetch `log_level` and `feature_flags` from SSM Parameter Store.
6. Fetch the JSON secret blob from Secrets Manager and render it as key-value lines.
7. Write `/opt/microservices/app.env` (mode 600) and a `docker-compose.yml` that pulls the ECR images, mounts the env file, and configures the `awslogs` logging driver.
8. `docker compose pull && docker compose up -d`.
9. Install a cron job that refreshes the ECR auth token every 6 hours (token TTL is 12).

## Runtime boundaries

- **Public**: Route 53, ACM, WAF, ALB (ports 80 and 443 only via the ALB security group).
- **Private**: EC2 service ports 5000 and 5001 accept traffic only from the ALB security group.
- **Operator**: SSH (port 22) restricted to the operator CIDR (`var.my_ip_cidr`).
- **Account-internal**: ECR, SSM, Secrets Manager, and CloudWatch are reached by the EC2 instance role over AWS-private endpoints.

## Scaling behaviour

- **Baseline**: The ASG keeps `desired_capacity` instances running across both availability zones.
- **Scale out**: Average ASG CPU above `var.scale_out_cpu_threshold` for five minutes adds one instance (up to `asg_max_size`).
- **Scale in**: Average ASG CPU below 20% for ten minutes removes one instance (down to `asg_min_size`).
- **Self-heal**: `health_check_type = "ELB"` means the ASG terminates any instance the ALB reports unhealthy and launches a replacement.
- **Instance refresh**: A rolling strategy with `min_healthy_percentage = 50` rotates instances when the Launch Template changes (new AMI, new user-data).

## Environments

| Env     | Capacity (min/desired/max) | TLS     | WAF     | Log retention |
|---------|-----------------------------|---------|---------|---------------|
| dev     | 1 / 1 / 2                   | off     | off     | 7 days        |
| staging | 2 / 2 / 4                   | on      | on      | 30 days       |
| prod    | 2 / 3 / 6                   | on      | on      | 90 days       |

Each environment is applied with a dedicated `tfvars` file and a dedicated remote state file (`microservices-deployment/<env>/terraform.tfstate`).
