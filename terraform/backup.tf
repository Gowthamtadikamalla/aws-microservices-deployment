// terraform/backup.tf
// Backup bucket for the one artifact that must survive a region/account loss:
// Terraform state snapshots taken out-of-band.
//
// The services themselves are stateless — they hold no data, and a full
// redeploy from Git + ECR fully reconstructs them. The only stateful items in
// scope today are:
//
//   1. Terraform state (S3 bucket defined by backend.tf)       -> backed up
//   2. ECR images                                              -> backed by
//      Git history; any tagged commit can be rebuilt and pushed.
//   3. Secrets Manager secret values                           -> rotated
//      by the operator; recovered from the password manager of record.
//
// If the services later gain a database (RDS/DynamoDB), an AWS Backup plan
// should be added here to cover it — see docs/disaster-recovery.md.

variable "enable_backup_bucket" {
  description = "Create the dedicated backup S3 bucket."
  type        = bool
  default     = true
}

resource "aws_s3_bucket" "backups" {
  count         = var.enable_backup_bucket ? 1 : 0
  bucket        = "${var.project_name}-${var.environment}-backups-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = {
    Name    = "${var.project_name}-${var.environment}-backups"
    Purpose = "terraform-state-and-config-snapshots"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  count  = var.enable_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  count  = var.enable_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  count                   = var.enable_backup_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.backups[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  count  = var.enable_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 180
    }
  }
}

output "backup_bucket_name" {
  description = "Name of the backup S3 bucket (empty when disabled)."
  value       = var.enable_backup_bucket ? aws_s3_bucket.backups[0].bucket : ""
}
