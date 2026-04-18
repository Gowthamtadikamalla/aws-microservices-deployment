# terraform/asg.tf
# Launch Template with full cloud-init user-data bootstrap,
# Auto Scaling Group attached to both ALB target groups,
# and CPU-based scale-out / scale-in policies.

locals {
  # ECR registry hostname resolved from current account + region
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

# ─── User Data Bootstrap Script ───────────────────────────────────────────────
# Runs as root via cloud-init on first boot.
# Steps:
#   1. Install Docker CE (official repo — more up-to-date than apt docker.io)
#   2. Install AWS CLI v2
#   3. Authenticate to ECR using the instance IAM role (no credentials needed)
#   4. Write /opt/microservices/docker-compose.yml with concrete ECR image URIs
#   5. Pull images and start services
#   6. Schedule ECR token refresh every 6 hours (tokens expire in 12 h)
locals {
  user_data = base64encode(templatefile("${path.module}/user_data.tpl", {
    aws_region        = var.aws_region
    ecr_registry      = local.ecr_registry
    service1_image    = "${local.ecr_registry}/service1:latest"
    service2_image    = "${local.ecr_registry}/service2:latest"
    log_group_name    = aws_cloudwatch_log_group.services.name
    ssm_log_level     = aws_ssm_parameter.log_level.name
    ssm_feature_flags = aws_ssm_parameter.feature_flags.name
    app_secret_arn    = aws_secretsmanager_secret.app_config.arn
    project_name      = var.project_name
    environment       = var.environment
  }))
}

# ─── Launch Template ──────────────────────────────────────────────────────────
resource "aws_launch_template" "main" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = data.aws_ami.ubuntu_24_04.id  # Auto-fetched latest Ubuntu 24.04 for the region
  instance_type = var.ec2_instance_type
  key_name      = var.ec2_key_name

  user_data = local.user_data

  # Attach IAM instance profile so the instance can call ECR APIs
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_ecr_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true   # Needed to reach ECR without NAT Gateway
    security_groups             = [aws_security_group.ec2.id]
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20          # GB — sufficient for OS + Docker images
      volume_type           = "gp3"       # Better performance/cost than gp2
      delete_on_termination = true
      encrypted             = true        # Encrypt at rest
    }
  }

  # Standard monitoring (5-minute intervals) — free tier eligible.
  # Detailed monitoring ($0.014/instance/day) is NOT needed since we use period=300 in CloudWatch alarms.
  monitoring {
    enabled = false
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-asg-instance"
      Project = var.project_name
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name    = "${var.project_name}-asg-volume"
      Project = var.project_name
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Auto Scaling Group ───────────────────────────────────────────────────────
resource "aws_autoscaling_group" "main" {
  name                = "${var.project_name}-asg"
  min_size            = var.asg_min_size
  desired_capacity    = var.asg_desired_capacity
  max_size            = var.asg_max_size
  vpc_zone_identifier = aws_subnet.public[*].id

  # Each instance registers with BOTH target groups (it runs both services)
  target_group_arns = [
    aws_lb_target_group.service1.arn,
    aws_lb_target_group.service2.arn
  ]

  # Use ELB health checks — ALB health checks determine whether an instance is healthy,
  # replacing EC2 status checks (which only detect OS-level failures)
  health_check_type         = "ELB"
  health_check_grace_period = 180  # Seconds to wait after launch before checking (allow containers to start)

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  # Terminate oldest launch template instances first during scale-in
  termination_policies = ["OldestLaunchTemplate", "Default"]

  # Rolling instance refresh — used when the launch template is updated
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50  # Keep at least 1 instance healthy during refresh
    }
  }

  # Wait until instances pass ELB health checks before marking terraform apply as complete
  wait_for_capacity_timeout = "10m"

  tag {
    key                 = "Name"
    value               = "${var.project_name}-asg-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Scale-Out Policy: CPU > 40% for 5 consecutive minutes ───────────────────
# Using SimpleScaling with standard (5-min) CloudWatch metrics — free tier eligible.
# period=300 (5 min) × evaluation_periods=1 = triggers after 5 minutes of high CPU.
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.project_name}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.main.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1       # Add 1 instance per alarm trigger
  cooldown               = 300     # 5-minute cooldown before the next scale-out can happen
  policy_type            = "SimpleScaling"
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1           # 1 × 5-minute period = triggers after 5 minutes
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300         # 5-minute periods — free tier (standard monitoring)
  statistic           = "Average"
  threshold           = var.scale_out_cpu_threshold  # 40%
  alarm_description   = "Trigger scale-out when average CPU > ${var.scale_out_cpu_threshold}% for 5 minutes (free tier: standard monitoring)"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]

  tags = {
    Name = "${var.project_name}-cpu-high-alarm"
  }
}

# ─── Scale-In Policy: CPU < 20% for 10 consecutive minutes ───────────────────
# Prevents runaway costs after a traffic spike subsides.
resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${var.project_name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.main.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1      # Remove 1 instance per alarm trigger
  cooldown               = 300
  policy_type            = "SimpleScaling"
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.project_name}-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2           # 2 × 5-minute periods = 10 minutes of low CPU
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300         # 5-minute periods — free tier
  statistic           = "Average"
  threshold           = 20          # Scale in when CPU drops below 20%
  alarm_description   = "Trigger scale-in when average CPU < 20% for 10 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]

  tags = {
    Name = "${var.project_name}-cpu-low-alarm"
  }
}
