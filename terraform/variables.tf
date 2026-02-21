# terraform/variables.tf
# All configurable input variables with sensible defaults.

variable "aws_region" {
  description = "AWS region for all resources. Default: ap-south-1 (Mumbai) — nearest for India."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name prefix used in resource naming and tags."
  type        = string
  default     = "microservices-demo"
}

variable "environment" {
  description = "Deployment environment label used in tags."
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the two public subnets (one per AZ). ALB requires at least 2 AZs."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "ec2_instance_type" {
  description = "EC2 instance type for the Launch Template / ASG. t3.micro is free-tier eligible in ap-south-1."
  type        = string
  default     = "t3.micro"
}

variable "ec2_key_name" {
  description = "Name of the existing EC2 key pair for SSH access. Must exist in the target region."
  type        = string
  # No default — must be supplied: -var='ec2_key_name=my-key'
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR notation, used to restrict SSH inbound rule. Example: 203.0.113.10/32"
  type        = string
  # No default — must be supplied: -var='my_ip_cidr=x.x.x.x/32'
  # Get your IP with: curl -s https://checkip.amazonaws.com
}

variable "ami_id" {
  description = <<-EOT
    Ubuntu 24.04 LTS AMI ID for the target region.
    The default is valid for ap-south-1 but may change over time.
    Get the latest with:
      aws ec2 describe-images --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
                  "Name=state,Values=available" \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
        --output text --region ap-south-1
  EOT
  type    = string
  default = "ami-0f58b397bc5c1f2e8" # Ubuntu 24.04 LTS — ap-south-1 (verify before use)
}

variable "service1_port" {
  description = "Host and container port for service1."
  type        = number
  default     = 5000
}

variable "service2_port" {
  description = "Host and container port for service2."
  type        = number
  default     = 5001
}

variable "asg_min_size" {
  description = "Minimum number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Desired number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 4
}

variable "scale_out_cpu_threshold" {
  description = "CPU utilisation (%) that triggers a scale-out event."
  type        = number
  default     = 40
}

variable "scale_out_evaluation_minutes" {
  description = "Number of consecutive 1-minute periods CPU must exceed the threshold before scaling out."
  type        = number
  default     = 5
}
