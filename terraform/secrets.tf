// terraform/secrets.tf
// Secure configuration surface for the two services.
//
// Why:
//   - Avoid baking configuration or credentials into AMIs, images, or user-data.
//   - Separate non-sensitive config (SSM Parameter Store, versioned, cheap) from
//     sensitive secrets (Secrets Manager, KMS-encrypted, rotatable).
//   - EC2 instances read these at boot via the instance IAM role — no static
//     credentials on disk.
//
// Usage pattern on the instance (see user_data.tpl):
//   aws ssm get-parameter --name /<proj>/<env>/app/log_level ...
//   aws secretsmanager get-secret-value --secret-id /<proj>/<env>/app/config ...
//   -> exported as env vars into docker compose.
//
// IMPORTANT: The values below are non-sensitive placeholders. Real secret
// material is injected out-of-band (console, CLI, or a pipeline step using
// `ignore_changes = [secret_string]`).

locals {
  config_prefix = "/${var.project_name}/${var.environment}"
}

// ─── Non-sensitive runtime config (SSM Parameter Store) ──────────────────────
resource "aws_ssm_parameter" "log_level" {
  name        = "${local.config_prefix}/app/log_level"
  description = "Log level for service1 and service2 (DEBUG, INFO, WARN, ERROR)."
  type        = "String"
  value       = "INFO"

  tags = {
    Name = "${var.project_name}-log-level"
  }
}

resource "aws_ssm_parameter" "feature_flags" {
  name        = "${local.config_prefix}/app/feature_flags"
  description = "Comma-separated feature flag list consumed by the services."
  type        = "String"
  value       = "tenant_context,structured_logs"

  tags = {
    Name = "${var.project_name}-feature-flags"
  }
}

// ─── Sensitive app secret (Secrets Manager) ──────────────────────────────────
// Real values (API keys, downstream service credentials, signing secrets) are
// populated by the pipeline or operator. Terraform only owns the container.
resource "aws_secretsmanager_secret" "app_config" {
  name        = "${local.config_prefix}/app/config"
  description = "Runtime secrets for service1 and service2 (JSON object)."
  kms_key_id  = "alias/aws/secretsmanager"

  tags = {
    Name = "${var.project_name}-app-secret"
  }
}

resource "aws_secretsmanager_secret_version" "app_config_initial" {
  secret_id = aws_secretsmanager_secret.app_config.id

  // Placeholder JSON — overwrite out-of-band. Terraform then ignores drift so
  // rotations do not trigger resource replacement.
  secret_string = jsonencode({
    DOWNSTREAM_API_KEY = "REPLACE_ME"
    SIGNING_SECRET     = "REPLACE_ME"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

// ─── Scoped read policy for the EC2 instance role ────────────────────────────
// Defined here (not in iam.tf) so the secret ARNs can be referenced directly.
data "aws_iam_policy_document" "app_config_read" {
  statement {
    sid    = "ReadRuntimeSSMParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.config_prefix}/app/*"
    ]
  }

  statement {
    sid    = "ReadAppSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.app_config.arn]
  }

  // Allow the instance to decrypt the AWS-managed Secrets Manager key. Scoped
  // by the ViaService condition so the role cannot decrypt unrelated data.
  statement {
    sid    = "UseSecretsManagerKMS"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "app_config_read" {
  name        = "${var.project_name}-app-config-read"
  description = "Allow EC2 instances to read runtime SSM params and the app secret."
  policy      = data.aws_iam_policy_document.app_config_read.json
}

resource "aws_iam_role_policy_attachment" "ec2_app_config" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = aws_iam_policy.app_config_read.arn
}
