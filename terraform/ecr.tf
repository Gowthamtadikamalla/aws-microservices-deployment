# terraform/ecr.tf
# Amazon ECR repositories for service1 and service2.
# MUTABLE tags allow re-pushing :latest for iterative development.
# Lifecycle policies cap storage to the 5 most recent images.

resource "aws_ecr_repository" "service1" {
  name                 = "service1"
  image_tag_mutability = "MUTABLE"  # Allows overwriting :latest on each push

  image_scanning_configuration {
    scan_on_push = true  # Free basic CVE scanning on every push
  }

  tags = {
    Name = "${var.project_name}-service1-ecr"
  }
}

resource "aws_ecr_lifecycle_policy" "service1" {
  repository = aws_ecr_repository.service1.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain only the 5 most recent images to control storage costs"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_repository" "service2" {
  name                 = "service2"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-service2-ecr"
  }
}

resource "aws_ecr_lifecycle_policy" "service2" {
  repository = aws_ecr_repository.service2.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain only the 5 most recent images to control storage costs"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
