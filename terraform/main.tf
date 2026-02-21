# terraform/main.tf
# Provider configuration and Terraform version constraints.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Optional: uncomment to use S3 remote state backend
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "microservices-deployment/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Caller identity - used in IAM policies and ECR registry URL construction
data "aws_caller_identity" "current" {}

# Available AZs in the selected region
data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Ubuntu 24.04 LTS AMI — automatically fetches the current version for the region.
# Owned by Canonical (099720109477). HVM + gp3 SSD + amd64 (required for EC2).
data "aws_ami" "ubuntu_24_04" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
