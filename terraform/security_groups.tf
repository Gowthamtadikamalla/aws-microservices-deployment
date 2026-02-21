# terraform/security_groups.tf
# ALB SG: accepts HTTP (port 80) from the public internet.
# EC2 SG: accepts SSH from operator IP only; service ports from ALB SG only (never public).

# ─── ALB Security Group ───────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow inbound HTTP port 80 from public internet to the ALB."
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (ALB to EC2 target groups and health checks)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

# ─── EC2 Security Group ───────────────────────────────────────────────────────
resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "EC2 instances: SSH from operator IP only; service ports from ALB SG only."
  vpc_id      = aws_vpc.main.id

  # SSH access restricted to operator's IP (least privilege)
  ingress {
    description = "SSH from operator IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Service1 traffic allowed only from the ALB — not from the public internet
  ingress {
    description     = "service1 port 5000 from ALB only"
    from_port       = var.service1_port
    to_port         = var.service1_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Service2 traffic allowed only from the ALB
  ingress {
    description     = "service2 port 5001 from ALB only"
    from_port       = var.service2_port
    to_port         = var.service2_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (needed for ECR image pulls, apt-get, and health check replies)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ec2-sg"
  }
}
