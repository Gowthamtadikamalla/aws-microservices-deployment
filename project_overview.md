# Project Overview

A walkthrough of the whole stack in plain language: what it is, why it is built the way it is, and how a request flows from the internet down to a container and back. Use this as the narrative companion to the technical docs in `docs/` and the Terraform in `terraform/`.

---

## 1. What the project does

- Runs two small Flask microservices — `service1` and `service2` — as Docker containers on AWS.
- Exposes them to the internet through a single domain and a single Application Load Balancer, with path-based routing:
  - `GET /service1` -> service1 container (port 5000).
  - `GET /service2` -> service2 container (port 5001).
- Autoscales the underlying compute based on CPU, across two availability zones.
- Is provisioned end-to-end with Terraform and deployed through GitHub Actions.
- Ships logs, metrics, and alerts to CloudWatch and SNS, with a runbook for common failure modes.

Each service is deliberately simple so the infrastructure is the star of the show: TLS termination, WAF, least-privilege IAM, secrets management, observability, CI/CD, environment separation, backup, and tenancy hooks.

---

## 2. Components at a glance

| Layer | Resource | Purpose |
|-------|----------|---------|
| Edge | Route 53 + ACM + ALB (HTTPS 443 + HTTP 80 redirect) + WAFv2 | Stable DNS name, TLS termination, L7 filtering, per-IP rate limit. |
| Network | VPC, two public subnets across two AZs, IGW, route table | Multi-AZ footprint; ALB and ASG instances live here. |
| Compute | Launch Template + Auto Scaling Group of Ubuntu 24.04 t3.micro EC2 | Self-healing fleet that runs both containers per instance. |
| Containers | Docker + docker-compose (written by user-data) pulling from ECR | Reproducible runtime; `awslogs` driver ships stdout to CloudWatch. |
| Registry | Amazon ECR (`service1`, `service2`) with scan-on-push + lifecycle | Private image registry with CVE scans and retention. |
| Identity | EC2 IAM role with scoped policies: ECR pull, SSM read, Secrets Manager read, CloudWatch Logs write | No static credentials on disk; every action is attributable. |
| Config | SSM Parameter Store (non-sensitive) + Secrets Manager (sensitive) | Runtime config fetched on boot and injected into containers. |
| Observability | CloudWatch log group + alarms (ALB 5xx, unhealthy targets, sustained CPU) + SNS topic | Structured logs, user-visible failure alerts. |
| Backup | Versioned, encrypted, public-access-blocked S3 bucket | Holds out-of-band state snapshots. |
| CI/CD | GitHub Actions (`ci.yml`, `cd.yml`) with OIDC, tfsec, plan-in-PR, apply-on-merge | Safe, peer-reviewable deploys to dev, staging, and prod. |

---

## 3. Directory layout

```
.
├── README.md                 # Architecture, deploy, operate
├── project_overview.md       # This document
├── verify_endpoints.sh       # End-to-end verification script
├── servers/                  # Flask services and Docker setup
│   ├── docker-compose.yml        # Local development (build from source)
│   ├── docker-compose.prod.yml   # EC2 deployment (pull from ECR)
│   └── service{1,2}/
│       ├── service{1,2}.py
│       ├── requirements.txt
│       └── Dockerfile
├── terraform/                # Infrastructure as code
│   ├── main.tf               # Provider, AMI, account/AZ lookups
│   ├── variables.tf          # Input variables
│   ├── outputs.tf            # ALB DNS, ECR URL, security group IDs, etc.
│   ├── vpc.tf                # VPC, subnets, IGW, routes
│   ├── security_groups.tf    # ALB SG + EC2 SG
│   ├── ecr.tf                # ECR repositories + scan-on-push + lifecycle
│   ├── iam.tf                # EC2 instance role + instance profile
│   ├── alb.tf                # ALB, target groups, HTTP listener + path rules
│   ├── asg.tf                # Launch Template + ASG + CPU scaling policies
│   ├── user_data.tpl         # EC2 bootstrap script
│   ├── secrets.tf            # SSM parameters + Secrets Manager + read policy
│   ├── dns_tls.tf            # Route 53 + ACM + HTTPS listener + redirect
│   ├── waf.tf                # WAFv2 web ACL + ALB association
│   ├── observability.tf      # Log group, SNS topic, alarms, logs-write policy
│   ├── backup.tf             # Encrypted versioned backup bucket
│   ├── backend.tf.example    # Remote state backend template
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
    ├── ci.yml
    └── cd.yml
```

---

## 4. How each component works

### 4.1 The services (`servers/`)

Both services are small Python Flask apps with:

- JSON responses on `/` and `/serviceN` that include `message`, `user_info`, `tenant_id`, and `request_id`.
- A tenant-agnostic `/health` returning `{"status": "healthy"}`.
- A Prometheus metrics endpoint at `/metrics` via `prometheus-flask-exporter`.
- Structured JSON logging. Every non-health request emits one log line with `timestamp`, `level`, `service`, `environment`, `tenant_id`, `request_id`, `path`, `method`, `status`.
- `X-Tenant-ID` and `X-Request-ID` headers are read in a `@before_request` hook and attached to both the response and the log record.
- Runtime config (log level, feature flags, and any downstream secrets) is read from environment variables, which the EC2 bootstrap populates from SSM and Secrets Manager.

### 4.2 Networking (`terraform/vpc.tf`)

- A dedicated VPC (`10.0.0.0/16`).
- Two public subnets (`10.0.1.0/24`, `10.0.2.0/24`) in different AZs so the ALB and ASG can meet the two-AZ requirement.
- Internet Gateway and a single public route table with `0.0.0.0/0 -> IGW`.
- Every public subnet is associated with that route table and has `map_public_ip_on_launch = true` so instances launched by the ASG can reach ECR, SSM, and Secrets Manager without a NAT gateway.

### 4.3 Security groups (`terraform/security_groups.tf`)

- **ALB SG**: inbound 80 from anywhere; all outbound.
- **EC2 SG**: 5000 and 5001 only from the ALB SG (by group, not CIDR), SSH 22 only from the operator CIDR, all outbound.
- Net effect: the services are unreachable from the public internet except through the ALB.

### 4.4 Container images (`terraform/ecr.tf`)

- Two private ECR repositories: `service1` and `service2`.
- `scan_on_push = true` runs a free AWS CVE scan on every push.
- Lifecycle policy keeps the five most recent images to control storage cost.

### 4.5 Instance identity (`terraform/iam.tf` + scoped add-ons in `secrets.tf`, `observability.tf`)

One EC2 role with four narrowly-scoped policies attached:

1. ECR pull limited to the `service1` and `service2` repo ARNs (plus the AWS-required global `ecr:GetAuthorizationToken`).
2. SSM `GetParameter(s)` limited to the `/${project}/${env}/app/*` prefix.
3. Secrets Manager `GetSecretValue` and `DescribeSecret` on exactly one secret ARN, plus scoped KMS `Decrypt`.
4. CloudWatch Logs `CreateLogStream` and `PutLogEvents` on exactly one log group.

An IAM instance profile attaches the role to every Launch Template instance.

### 4.6 ALB and routing (`terraform/alb.tf`)

- Internet-facing ALB spanning both public subnets.
- Two target groups (port 5000 and port 5001) with `/health` health checks.
- HTTP listener on port 80 with a default fixed-response `404` and two forward rules:
  - Priority 100: path `/service1` or `/service1/*` -> target group 1.
  - Priority 200: path `/service2` or `/service2/*` -> target group 2.
- When TLS is enabled the HTTP listener gains a priority-1 redirect to HTTPS.

### 4.7 TLS, DNS, and WAF (`terraform/dns_tls.tf`, `terraform/waf.tf`)

- Route 53 record `api.<env>.<domain>` as an `ALIAS` to the ALB.
- ACM certificate for that FQDN validated via DNS records in the same zone.
- HTTPS listener on 443 with TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06` and matching forward rules for `/service1*` and `/service2*`.
- HTTP-to-HTTPS redirect on port 80.
- WAFv2 web ACL associated to the ALB with:
  - `AWSManagedRulesCommonRuleSet`
  - `AWSManagedRulesKnownBadInputsRuleSet`
  - A per-source-IP rate-based rule.

Both `enable_public_tls` and `enable_waf` are variables so dev environments can run without a domain or WAF.

### 4.8 Compute and auto scaling (`terraform/asg.tf`, `terraform/user_data.tpl`)

- Launch Template uses the latest Ubuntu 24.04 AMI for the region, `t3.micro`, encrypted gp3 root volume, the EC2 SG, and the EC2 instance profile.
- User-data (`user_data.tpl`) runs on first boot:
  1. OS update.
  2. Install Docker CE + Docker Compose plugin.
  3. Install AWS CLI v2.
  4. ECR login via the instance role.
  5. Fetch runtime config: SSM parameters (`log_level`, `feature_flags`) and the Secrets Manager JSON blob, write them to `/opt/microservices/app.env` with mode `600`, plus project/environment/region metadata.
  6. Write `/opt/microservices/docker-compose.yml` that pulls both ECR images, mounts `app.env` as `env_file`, and configures the `awslogs` Docker log driver.
  7. `docker compose pull && docker compose up -d`.
  8. Cron job refreshes the ECR auth token every 6 hours.
- Auto Scaling Group:
  - `min / desired / max` per environment (e.g. 1/1/2 dev, 2/3/6 prod).
  - Registers every instance with both ALB target groups, so each instance runs both services.
  - `health_check_type = "ELB"` so ALB failures trigger instance replacement.
  - Scale-out policy: one instance when average CPU stays above the configured threshold for 5 minutes. Scale-in: one instance when CPU is below 20% for 10 minutes.
  - Rolling `instance_refresh` with `min_healthy_percentage = 50` for AMI / user-data updates.

### 4.9 Runtime configuration and secrets (`terraform/secrets.tf`)

- Non-sensitive config lives in SSM Parameter Store (`/${project}/${env}/app/log_level`, `/.../feature_flags`).
- Sensitive config lives in a Secrets Manager secret (`/${project}/${env}/app/config`) encrypted with the AWS-managed Secrets Manager KMS key.
- The Terraform resource writes a placeholder JSON body and then ignores `secret_string` drift so operator rotations do not trigger Terraform replacement.
- The EC2 role has a scoped policy granting read access to only these SSM paths, this secret ARN, and the KMS key via the `secretsmanager` service condition.

### 4.10 Observability (`terraform/observability.tf`)

- A dedicated log group `/${project}/${env}/services` with per-environment retention (7, 30, or 90 days).
- An SNS topic `${project}-${env}-alerts` with an optional email subscription.
- Three alarms, each wired to the SNS topic:
  1. ALB target 5xx count above 10 per minute for 2 minutes.
  2. Per-target-group unhealthy host count above zero for 3 minutes.
  3. ASG average CPU above 70% for 15 minutes.
- Additional subscribers (PagerDuty, Slack webhook) plug into the same topic.

### 4.11 Environment separation (`terraform/environments/*.tfvars`, `terraform/backend.tf.example`)

- `dev.tfvars`: minimal footprint, TLS and WAF off, short log retention.
- `staging.tfvars`: mirrors production capacity and security controls for realistic validation.
- `prod.tfvars`: larger minimum capacity, longer log retention, alert email on the on-call rotation.
- Remote Terraform state is keyed per environment (`microservices-deployment/<env>/terraform.tfstate`) in S3 + DynamoDB, templated by `backend.tf.example`.

### 4.12 Backup and disaster recovery (`terraform/backup.tf`, `docs/disaster-recovery.md`)

- The services are stateless; the platform itself is the recoverable artifact.
- The backup bucket is versioned, KMS-encrypted, public-access-blocked, with a lifecycle that moves old versions to STANDARD_IA after 30 days and expires them after 180.
- RPO/RTO, stateful inventory, and per-scenario runbooks are captured in `docs/disaster-recovery.md`.

### 4.13 CI/CD (`.github/workflows/ci.yml`, `.github/workflows/cd.yml`)

- `ci.yml` on every push and PR:
  - `ruff check` + `pytest` per service.
  - Docker `buildx` build for `linux/amd64` (no push).
  - `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`.
  - `tfsec` security scan.
- `cd.yml` on merge and manual dispatch:
  - OIDC-based AWS role assumption.
  - Build and push both images to ECR (`:sha` and `:latest`).
  - `terraform plan` on PRs; `terraform apply` on merges.
  - GitHub Environments gate staging and prod with required reviewers.

### 4.14 Verification (`verify_endpoints.sh`)

- Confirms both ECR repos exist and contain images.
- Asserts `GET /service1` and `GET /service2` return HTTP 200 with the expected `message` field.
- Optionally exercises `/health` and `/metrics` directly on instance IPs to bypass the ALB.
- Exits 0 on full success and 1 on any failure; used both locally and as a smoke test after deploys.

---

## 5. End-to-end request flow

1. A client calls `https://api.<env>.<domain>/service1` with an optional `X-Tenant-ID` header.
2. Route 53 resolves the A/ALIAS record to the ALB endpoint.
3. WAFv2 applies managed rule groups and the per-IP rate limit; blocked requests never reach the ALB targets.
4. The ALB terminates TLS on port 443 using the ACM certificate.
5. The listener rule `path-pattern = /service1*` forwards to target group 1 on port 5000.
6. The ALB picks a healthy EC2 target registered by the Auto Scaling Group in one of the two AZs.
7. The `service1` container receives the request, reads `X-Tenant-ID` and `X-Request-ID`, handles it, and returns JSON.
8. A single structured JSON log line is emitted on stdout and streamed by the Docker `awslogs` driver to `/${project}/${env}/services` in CloudWatch Logs.
9. Prometheus counters on `/metrics` tick; CloudWatch continues to evaluate ALB, target group, and ASG metrics.
10. If any of the alarms trip, SNS fans out the notification to the alert subscribers.

---

## 6. Deployment and operation flow

1. Open a pull request. CI runs lint, tests, Docker build, `terraform fmt/validate`, and `tfsec`. The CD workflow attaches a `terraform plan` artifact.
2. A reviewer approves and merges.
3. CD assumes the target environment's deploy role via OIDC, builds and pushes both images to ECR (`:sha` + `:latest`), and runs `terraform apply` with the environment-specific `tfvars` file.
4. The ASG's rolling instance refresh brings up fresh EC2 instances. Each one boots, pulls the new image, and replaces an old instance.
5. The ALB routes traffic only to healthy targets; users see no downtime.
6. `verify_endpoints.sh` is run as a smoke test.
7. CloudWatch logs, metrics, and alarms take it from there. On-call receives any SNS notifications; responses are captured in `docs/incident-runbook.md`.

---

## 7. Where to read more

- `README.md` — architecture diagram, prerequisites, deploy steps, screenshots, cleanup.
- `docs/architecture.md` — design principles, request lifecycle, scaling, runtime boundaries.
- `docs/security-model.md` — trust boundaries, control matrix, hardening roadmap.
- `docs/incident-runbook.md` — first-response for each alarm and common incidents.
- `docs/disaster-recovery.md` — RPO/RTO, stateful inventory, recovery runbooks.
- `docs/multi-tenant-design.md` — tenancy hooks in this stack and the path forward.
