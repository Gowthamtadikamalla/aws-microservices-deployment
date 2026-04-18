# Microservices Deployment on AWS

A production-style deployment of two containerized Flask services on AWS. Images are built and pushed to Amazon ECR, run as Docker containers on EC2 instances managed by an Auto Scaling Group, and exposed through an internet-facing Application Load Balancer with path-based routing. The entire stack is provisioned with Terraform and includes TLS termination, a managed Web Application Firewall, centralised logging, alarms, runtime configuration from SSM and Secrets Manager, GitHub Actions CI/CD, and environment-separated state.

---

## Architecture

```
                         Internet
                             |
                   +---------------------+
                   |    Route 53         |
                   |  api.<env>.<domain> |
                   +----------+----------+
                              |
                     +--------+--------+
                     |    AWS WAFv2    |   managed rules + per-IP rate limit
                     +--------+--------+
                              |
             +----------------+----------------+
             |  Application Load Balancer      |
             |  :80  HTTP -> HTTPS redirect    |
             |  :443 TLS 1.2+  (ACM cert)      |
             +---------+-------------+---------+
                       |             |
                /service1*      /service2*
                       |             |
            +----------+----+  +-----+----------+
            | Target Group 1|  | Target Group 2 |
            | :5000         |  | :5001          |
            +-------+-------+  +-------+--------+
                    \                  /
                     \                /
               +------+--------------+------+
               |   Auto Scaling Group       |
               |   min=2  desired=2-3  max=4-6
               |   (sized per environment;  |
               |   see environments/*.tfvars)|
               |   Ubuntu 24.04 / gp3 / AZ-1 |
               |   Ubuntu 24.04 / gp3 / AZ-2 |
               +--------------+-------------+
                              |
                      user-data bootstrap
                              |
    +------------+  +-------------+  +--------------+  +---------------+
    |  Amazon    |  |  SSM        |  |  Secrets     |  |  CloudWatch   |
    |  ECR       |  |  Parameter  |  |  Manager     |  |  Logs + Alarms|
    |  (images)  |  |  Store      |  |  (app creds) |  |  + SNS alerts |
    +------------+  +-------------+  +--------------+  +---------------+
```

**Region:** `ap-south-1` (Mumbai)

Every EC2 instance runs both services simultaneously. The Launch Template user-data installs Docker and the AWS CLI, authenticates to ECR, pulls the runtime configuration from SSM Parameter Store and Secrets Manager, writes a `docker-compose.yml`, and starts both containers. Container stdout is shipped to a dedicated CloudWatch log group via the awslogs Docker driver.

---

## Services

| Service  | Port | Endpoints                               |
|----------|------|-----------------------------------------|
| service1 | 5000 | `/`, `/service1`, `/health`, `/metrics` |
| service2 | 5001 | `/`, `/service2`, `/health`, `/metrics` |

Both are Python Flask apps. They emit structured JSON logs, honour `X-Tenant-ID` and `X-Request-ID` request headers, and expose Prometheus metrics via `prometheus-flask-exporter`. Health checks return `{"status": "healthy"}` with HTTP 200.

---

## Repo Structure

```
.
├── README.md
├── project_overview.md
├── verify_endpoints.sh            # Health + ALB + ECR verification script
├── servers/
│   ├── docker-compose.yml         # Local development (builds from source)
│   ├── docker-compose.prod.yml    # EC2 deployment (pulls images from ECR)
│   ├── service1/
│   │   ├── service1.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   └── service2/
│       ├── service2.py
│       ├── requirements.txt
│       └── Dockerfile
├── terraform/
│   ├── main.tf                    # Provider, AMI data source, account/AZ lookups
│   ├── variables.tf               # Input variables
│   ├── outputs.tf                 # ALB DNS, ECR URLs, etc.
│   ├── vpc.tf                     # VPC, public subnets, IGW, routes
│   ├── security_groups.tf         # ALB SG + EC2 SG
│   ├── ecr.tf                     # ECR repositories with scan-on-push + lifecycle
│   ├── iam.tf                     # EC2 IAM role + scoped policies
│   ├── alb.tf                     # ALB, target groups, listener rules
│   ├── asg.tf                     # Launch Template, ASG, scaling policies
│   ├── user_data.tpl              # EC2 bootstrap script
│   ├── secrets.tf                 # SSM parameters + Secrets Manager + read policy
│   ├── dns_tls.tf                 # Route 53 + ACM + HTTPS listener + redirect
│   ├── waf.tf                     # WAFv2 web ACL + ALB association
│   ├── observability.tf           # Log group, SNS topic, alarms
│   ├── backup.tf                  # Versioned encrypted backup bucket
│   ├── backend.tf.example         # Remote state backend template (S3 + DynamoDB)
│   └── environments/
│       ├── dev.tfvars
│       ├── staging.tfvars
│       └── prod.tfvars
├── docs/
│   ├── architecture.md
│   ├── security-model.md
│   ├── incident-runbook.md
│   ├── disaster-recovery.md
│   └── multi-tenant-design.md
└── .github/workflows/
    ├── ci.yml                     # Lint, test, docker build, tf fmt/validate, tfsec
    └── cd.yml                     # ECR push + plan-in-PR / apply-on-merge via OIDC
```

---

## Prerequisites

- AWS CLI v2 with an IAM principal that can manage EC2, ECR, ELB, ASG, IAM, CloudWatch, Route 53, ACM, WAF, SSM, Secrets Manager, and S3.
- Terraform >= 1.6.0.
- Docker with `buildx` support.
- A Route 53 public hosted zone when `enable_public_tls = true`.

---

## Deployment

### 1. Create EC2 key pair

```bash
aws ec2 create-key-pair \
  --key-name microservices-key \
  --region ap-south-1 \
  --query 'KeyMaterial' --output text > ~/.ssh/microservices-key.pem

chmod 400 ~/.ssh/microservices-key.pem
```

### 2. Get your public IP

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)
```

### 3. Create ECR repositories and push images

```bash
cd terraform
terraform init

terraform apply \
  -target=aws_ecr_repository.service1 \
  -target=aws_ecr_repository.service2 \
  -var-file="environments/dev.tfvars" \
  -var="ec2_key_name=microservices-key" \
  -var="my_ip_cidr=${MY_IP}/32"

ECR_REGISTRY=$(terraform output -raw ecr_registry)

aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin $ECR_REGISTRY

cd ../servers

docker buildx build --platform linux/amd64 \
  -t $ECR_REGISTRY/service1:latest --push ./service1

docker buildx build --platform linux/amd64 \
  -t $ECR_REGISTRY/service2:latest --push ./service2
```

### 4. Apply the full stack

```bash
cd ../terraform

terraform apply \
  -var-file="environments/dev.tfvars" \
  -var="ec2_key_name=microservices-key" \
  -var="my_ip_cidr=${MY_IP}/32"
```

This creates the VPC, subnets, security groups, IAM role, ALB, target groups, Launch Template, Auto Scaling Group, SSM parameters, Secrets Manager secret, WAF web ACL (when enabled), ACM certificate and Route 53 records (when TLS is enabled), CloudWatch log group, and alarms. Instances boot, fetch runtime config, and start the containers automatically.

Allow 3 to 4 minutes for the ASG to register healthy targets with the ALB.

### 5. Quick test

```bash
ALB_DNS=$(terraform output -raw alb_dns_name)

curl http://$ALB_DNS/service1
# {"message":"Hello from Service 1","tenant_id":"unknown","request_id":"..."}

curl http://$ALB_DNS/service2
# {"message":"Hello from Service 2","tenant_id":"unknown","request_id":"..."}
```

---

## Verification script

```bash
ALB_DNS=<alb-dns-name> AWS_REGION=ap-south-1 ./verify_endpoints.sh
```

To also exercise the health and metrics endpoints directly on the instances:

```bash
ALB_DNS=<alb-dns-name> \
INSTANCE1_IP=<ec2-public-ip-1> \
INSTANCE2_IP=<ec2-public-ip-2> \
AWS_REGION=ap-south-1 \
./verify_endpoints.sh
```

The script exits with code 0 when every check passes:

- ECR `service1` and `service2` repositories exist and contain at least one image.
- `GET /service1` and `GET /service2` via the ALB return HTTP 200 with the expected `message` field.
- Direct `/health` on each instance returns HTTP 200 with `"healthy"`.
- Direct `/metrics` on each instance returns HTTP 200 and Prometheus text format.

---

## Security

- **Public edge**: WAFv2 web ACL on the ALB with AWS managed Common and KnownBadInputs rule groups plus a per-IP rate limit; HTTPS listener with TLS 1.2+ and an HTTP-to-HTTPS redirect.
- **Private service ports**: EC2 security group only accepts 5000 and 5001 from the ALB security group. Containers are never directly reachable from the internet.
- **Operator access**: SSH (port 22) restricted to the operator CIDR.
- **IAM**: Per-purpose scoped policies (ECR pull, SSM/Secrets read, logs write) attached to a single EC2 role. `ecr:GetAuthorizationToken` is on `*` because AWS requires it; every other permission is scoped to specific ARNs.
- **Secrets**: Non-sensitive runtime config in SSM Parameter Store; sensitive values in Secrets Manager with KMS. Instances fetch them at boot and write them to `/opt/microservices/app.env` (mode 600).
- **Storage**: EBS volumes encrypted at rest (gp3). Backup bucket versioned, KMS-encrypted, public-access-blocked. ECR scans images on push and lifecycles to five revisions.
- **CI**: `ruff` lint, pytest, Docker build, `terraform fmt/validate`, and `tfsec` in GitHub Actions on every PR. Deploy role assumed via OIDC — no long-lived AWS keys in GitHub.

Full trust boundaries and open risks: `docs/security-model.md`.

---

## Auto Scaling Group

| Setting              | Value                                   |
|----------------------|-----------------------------------------|
| Min / Desired / Max  | 2 / 2-3 / 4-6 (varies by environment; see `terraform/environments/*.tfvars`) |
| Instance type        | t3.micro (free-tier eligible)           |
| Scale-out trigger    | CPU > 40% for 5 minutes                 |
| Scale-in trigger     | CPU < 20% for 10 minutes                |
| Health check type    | ELB (ALB health checks)                 |
| Monitoring           | Standard 5-min CloudWatch metrics       |

The Launch Template user-data script handles the full bootstrap on every new instance:

1. Installs Docker CE from the official Docker apt repository.
2. Installs AWS CLI v2.
3. Authenticates to ECR using the instance IAM role.
4. Fetches runtime config from SSM Parameter Store and Secrets Manager.
5. Writes `/opt/microservices/docker-compose.yml` with the concrete ECR image URIs and the `awslogs` logging driver.
6. Runs `docker compose up -d`.
7. Schedules a cron job to refresh the ECR auth token every 6 hours.

---

## Observability

- **Logs**: Container stdout is shipped to CloudWatch log group `/<project>/<env>/services` via the Docker `awslogs` driver. Lines are structured JSON with `timestamp`, `level`, `service`, `environment`, `tenant_id`, `request_id`, `path`, `method`, `status`.
- **Metrics**: Prometheus metrics exposed on `/metrics` for each service. Standard 5-minute CloudWatch metrics for EC2, ALB, and ASG.
- **Alarms** (notifying the SNS alert topic):
  - ALB target 5xx rate above threshold.
  - Per-target-group unhealthy host count above zero.
  - Sustained high CPU on the ASG.
- **Alert delivery**: SNS topic `<project>-<env>-alerts` with email subscription from `var.alert_email`. Any additional subscriber (PagerDuty, Slack webhook) plugs into the same topic.

First response for common alarms: `docs/incident-runbook.md`.

---

## Environments

Environment-specific settings live in `terraform/environments/{dev,staging,prod}.tfvars`:

```bash
terraform apply -var-file="environments/dev.tfvars"       \
  -var="ec2_key_name=microservices-key"                    \
  -var="my_ip_cidr=${MY_IP}/32"
```

Remote state (S3 + DynamoDB lock) is configured from `terraform/backend.tf.example`. Separate state files per environment keep blast radius contained and allow plans to run in parallel.

---

## CI/CD

GitHub Actions workflows under `.github/workflows/`:

- `ci.yml`: ruff + pytest on both services, Docker buildx (no push), `terraform fmt`, `terraform init -backend=false`, `terraform validate`, and `tfsec` scanning.
- `cd.yml`: OIDC-based AWS role assumption, ECR push (`:sha` and `:latest`), `terraform plan` on pull requests, and `terraform apply` on merges to `main`. Staging and production are gated by GitHub Environment reviewers.

---

## Screenshots

### ECR repositories

![ECR repositories](Deliverables_Screenshots/ECR.png)
![ECR service1 images](Deliverables_Screenshots/ECR_S1.png)
![ECR service2 images](Deliverables_Screenshots/ECR_S2.png)

### EC2 instances and `docker ps`

![EC2 instances](Deliverables_Screenshots/EC2.png)
![docker ps instance 1](Deliverables_Screenshots/Instance_1.png)
![docker ps instance 2](Deliverables_Screenshots/Instance_2.png)

### ALB responses and verification

![ALB curl responses](Deliverables_Screenshots/ALB.png)
![Verification script output](Deliverables_Screenshots/Checks.png)

### ASG scale-out event

![ASG scale-out event](Deliverables_Screenshots/ASG_event_evidence.png)

---

## Cleanup

```bash
cd terraform
terraform destroy \
  -var-file="environments/dev.tfvars" \
  -var="ec2_key_name=microservices-key" \
  -var="my_ip_cidr=$(curl -s https://checkip.amazonaws.com)/32"
```
