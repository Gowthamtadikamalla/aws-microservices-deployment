# terraform/iam.tf
# Least-privilege IAM role for EC2 instances.
# Grants only what is needed: authenticate to ECR and pull the two service images.

# ─── Trust Policy ─────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ─── IAM Role ─────────────────────────────────────────────────────────────────
resource "aws_iam_role" "ec2_ecr_role" {
  name               = "${var.project_name}-ec2-ecr-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  description        = "Allows EC2 instances to authenticate and pull images from ECR."

  tags = {
    Name = "${var.project_name}-ec2-ecr-role"
  }
}

# ─── Least-Privilege ECR Policy ───────────────────────────────────────────────
# GetAuthorizationToken must be on resource "*" (AWS requirement — cannot be scoped to a repo).
# All other actions are scoped to only the two specific ECR repositories.
data "aws_iam_policy_document" "ecr_pull" {
  statement {
    sid    = "ECRAuthToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPullImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeRepositories",
      "ecr:ListImages"
    ]
    resources = [
      aws_ecr_repository.service1.arn,
      aws_ecr_repository.service2.arn
    ]
  }
}

resource "aws_iam_policy" "ecr_pull" {
  name        = "${var.project_name}-ecr-pull-policy"
  description = "Least-privilege ECR pull access for service1 and service2 repositories."
  policy      = data.aws_iam_policy_document.ecr_pull.json

  tags = {
    Name = "${var.project_name}-ecr-pull-policy"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ecr" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = aws_iam_policy.ecr_pull.arn
}

# ─── Instance Profile ─────────────────────────────────────────────────────────
# An instance profile is the container that links an IAM role to an EC2 instance.
resource "aws_iam_instance_profile" "ec2_ecr_profile" {
  name = "${var.project_name}-ec2-ecr-profile"
  role = aws_iam_role.ec2_ecr_role.name

  tags = {
    Name = "${var.project_name}-ec2-ecr-profile"
  }
}
