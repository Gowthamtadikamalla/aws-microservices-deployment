# Security Model

Describes the trust boundaries, controls, and open risks for this deployment.
The goal is to make every security-relevant decision explicit so it can be
challenged and improved.

## Trust boundaries

1. **Public internet -> ALB**
   - Only ports 80 and 443 are reachable via the ALB security group.
   - Port 80 is a redirect when TLS is enabled (`enable_public_tls = true`).
2. **ALB -> EC2**
   - EC2 security group only accepts 5000/5001 from the ALB SG (by source SG,
     not CIDR). Containers are never reachable from the internet directly.
3. **Operator -> EC2**
   - SSH restricted to `var.my_ip_cidr` (`/32`). The hardening roadmap below
     tracks the move to AWS Systems Manager Session Manager.
4. **EC2 -> AWS services**
   - The instance role can: pull two specific ECR repos, read a specific SSM
     prefix, read a specific Secrets Manager secret, and write to one
     CloudWatch log group.
5. **Pipeline -> AWS**
   - GitHub Actions authenticates via OIDC to assume a dedicated role in the
     target account. No long-lived access keys are stored in GitHub.

## Layered controls

| Layer | Control | File |
|-------|---------|------|
| Edge | WAFv2 managed rule groups (Common, KnownBadInputs) + per-IP rate limit | `terraform/waf.tf` |
| TLS | ACM cert + HTTPS listener with TLS 1.2+ policy + HTTP->HTTPS redirect | `terraform/dns_tls.tf` |
| Network | Public subnets for ALB; EC2 SG locked to ALB SG; SSH limited to operator IP | `terraform/security_groups.tf`, `terraform/vpc.tf` |
| IAM | Per-purpose scoped policies (ECR pull, SSM/Secrets read, logs write) attached to a single EC2 role | `terraform/iam.tf`, `terraform/secrets.tf`, `terraform/observability.tf` |
| Secrets | Sensitive values in Secrets Manager with KMS; non-sensitive config in SSM | `terraform/secrets.tf` |
| Storage | EBS encrypted at rest; backup bucket versioned, encrypted, public-access-blocked | `terraform/asg.tf`, `terraform/backup.tf` |
| Registry | ECR `scan_on_push` enabled; images expire after 5 revisions | `terraform/ecr.tf` |
| CI | Ruff lint + pytest + docker build on every PR; tfsec scan of all Terraform | `.github/workflows/ci.yml` |

## Data classification

| Data | Sensitivity | Location |
|------|-------------|----------|
| Service source + Dockerfiles | Public (on GitHub) | `servers/` |
| Terraform configuration | Internal | `terraform/` |
| Terraform state | Confidential (contains ARNs, secret IDs) | S3 bucket (KMS-encrypted, versioned) |
| SSM parameters | Internal | AWS SSM |
| App secrets (`/project/env/app/config`) | Secret | AWS Secrets Manager (KMS-encrypted) |
| CloudWatch logs | Internal (may contain tenant_id, never secrets) | CloudWatch Logs |

## Secret handling

- Real secret values are **never committed** to Git. The `aws_secretsmanager_secret_version`
  resource writes a placeholder, then `lifecycle.ignore_changes = [secret_string]`
  ensures operator rotations do not trigger Terraform drift.
- Instances fetch secrets at boot via the instance role and write them to
  `/opt/microservices/app.env` with mode `600`. The file is then consumed by
  `docker-compose` as an `env_file`.
- Rotation playbook: update the secret in Secrets Manager, terminate the
  oldest ASG instance; the ASG replaces it and the new instance boots with
  the rotated value. Zero redeploy required.

## Accepted risks and hardening roadmap

The controls above cover the baseline. The following items are tracked
deliberately so the security posture keeps improving with the platform:

| Area | Roadmap |
|------|---------|
| Operator access | Replace SSH with AWS SSM Session Manager and remove port 22 ingress. |
| Instance placement | Move EC2 to private subnets with VPC endpoints for ECR / SSM / Secrets / CloudWatch Logs, keeping only the ALB in public subnets. |
| Instance metadata | Enforce IMDSv2 via `metadata_options { http_tokens = "required" }` on the launch template. |
| CI security scan | Promote `tfsec` from soft-fail to hard-fail once any pre-existing findings are triaged. |
| Image provenance | Sign ECR images with AWS Signer or `cosign` and verify signatures at pull time. |
| Secret rotation | Enable Secrets Manager scheduled rotation for credentials that support it. |
