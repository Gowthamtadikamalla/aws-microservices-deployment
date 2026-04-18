# Disaster Recovery

Captures what can go wrong, what must survive, and how we recover. Kept
honest about the current state: the application is stateless, so most "DR"
in this repo today is really about rebuilding the platform layer.

## Objectives

| Scenario | RPO | RTO |
|----------|-----|-----|
| Single EC2 instance failure | 0 | < 5 min (ASG self-heals) |
| Single AZ failure | 0 | < 5 min (both AZs already serve traffic) |
| ALB failure or misconfig | 0 | < 30 min (redeploy from Terraform) |
| Full region loss | 0 for stateless services; secrets RPO = time since last rotation export | < 2 hours once a target region is chosen |
| Accidental `terraform destroy` in prod | depends on state backup age | < 1 hour using remote state versioning + Git |
| Compromise of deploy role | N/A | < 1 hour to rotate (see `docs/security-model.md`) |

## Stateful vs stateless inventory

| Component | Stateful? | Notes |
|-----------|-----------|-------|
| Flask services (`service1`, `service2`) | No | Pure request/response, no on-disk persistence. |
| EC2 instances | No | Bootstrapped from user-data + ECR on each launch. |
| ECR images | Yes (artifact) | Can be rebuilt from Git for any tagged commit. |
| Terraform state | Yes (critical) | S3 bucket with versioning + KMS; backed up per below. |
| Secrets Manager values | Yes | Source of truth is the password manager of record; Terraform only owns the container. |
| SSM parameters | Yes (low value) | Defaults are in `terraform/secrets.tf`; current values can be exported. |
| CloudWatch Logs | No (observability only) | Retention controlled by `var.log_retention_days`. |

If/when a database is introduced (RDS, DynamoDB), it becomes the dominant
stateful item and must be listed at the top of this table with its own RPO.

## What we back up

1. **Terraform state**: S3 backend has versioning enabled; deleted objects
   are recoverable for 180 days (lifecycle policy in `terraform/backup.tf`).
   A weekly out-of-band `aws s3 cp` snapshot is uploaded to the dedicated
   backup bucket in a different path prefix.
2. **Secrets Manager values**: operator exports the JSON blob after every
   rotation into the password manager of record. Terraform does not touch
   `secret_string` after creation.
3. **ECR images**: retention lifecycle keeps the 5 most recent; anything
   older can be rebuilt from the corresponding Git tag.

## Recovery runbooks

### R1. Single instance / AZ failure

No action required. The ASG replaces failed instances and the ALB routes
traffic only to healthy targets in the surviving AZ.

### R2. Accidental Terraform destroy

1. Restore the previous `terraform.tfstate` object version from the S3 state
   bucket.
2. Run `terraform init` and `terraform plan` in a clean checkout; verify the
   plan shows only the missing resources being re-created.
3. Run `terraform apply` with the appropriate tfvars.
4. Trigger the CD pipeline's `build-and-push` job if images also need to be
   re-pushed.

### R3. Regional evacuation

1. Choose a target region that already has:
   - Ubuntu 24.04 AMI (`data.aws_ami.ubuntu_24_04` resolves automatically).
   - A Route 53 zone (shared, zones are global).
2. Create new ECR repos in the target region by running Terraform with a new
   backend key and `aws_region` override.
3. Re-push the last known-good images to the new ECR with the pipeline.
4. Apply the stack with the new region value.
5. Update the Route 53 alias to point at the new ALB DNS name.

### R4. Secret compromise

See `docs/incident-runbook.md`, section 4.

## Game-day cadence

Each runbook above is exercised in the staging environment on a regular
cadence so failure modes are rehearsed before they hit production:

- R1 (instance failure): validated continuously by the ASG self-healing
  behaviour; an instance is terminated manually at least once per release.
- R2 (accidental destroy): exercised against a throwaway copy of the stack
  by rolling back to a prior `terraform.tfstate` version.
- R3 (regional evacuation) and R4 (secret compromise): documented, with a
  scheduled drill planned quarterly in staging.
