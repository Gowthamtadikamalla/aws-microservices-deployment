// terraform/observability.tf
// CloudWatch log group, alarms, and SNS topic for operator alerts.
//
// Why:
//   - Centralise container stdout in a single CloudWatch log group so every
//     request line (including tenant_id and request_id) is queryable without
//     SSHing to instances.
//   - High-signal alarms for the three failure modes that surface a user
//     visible outage: ALB 5xx spikes, unhealthy target groups, and sustained
//     high CPU on the ASG.
//   - An SNS topic with a placeholder email subscription is the single fanout
//     point; PagerDuty / Slack / extra mailboxes are all additional subscribers.
//
// All alarm actions publish to the same SNS topic so on-call sees a single
// feed. Escalation (PagerDuty, Opsgenie) can subscribe to the same topic.

variable "alert_email" {
  description = "Email address subscribed to the alert SNS topic. Leave empty to skip subscription."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days for the services log group."
  type        = number
  default     = 30
}

// ─── Log group used by Docker awslogs driver ─────────────────────────────────
resource "aws_cloudwatch_log_group" "services" {
  name              = "/${var.project_name}/${var.environment}/services"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project_name}-services-logs"
  }
}

// IAM permission for EC2 instances to ship container logs via the awslogs
// driver. Scoped to this log group and its streams only.
data "aws_iam_policy_document" "logs_write" {
  statement {
    sid    = "WriteContainerLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.services.arn,
      "${aws_cloudwatch_log_group.services.arn}:*",
    ]
  }
}

resource "aws_iam_policy" "logs_write" {
  name        = "${var.project_name}-logs-write"
  description = "Allow EC2 instances to write container logs to the services log group."
  policy      = data.aws_iam_policy_document.logs_write.json
}

resource "aws_iam_role_policy_attachment" "ec2_logs" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = aws_iam_policy.logs_write.arn
}

// ─── SNS alert topic ─────────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-${var.environment}-alerts"

  tags = {
    Name = "${var.project_name}-alerts"
  }
}

resource "aws_sns_topic_subscription" "alert_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

// ─── ALB 5xx alarm ───────────────────────────────────────────────────────────
// Fires when the ALB itself returns 5xx (target groups returning 500-range).
// Indicates application failure or bad deploys, not infrastructure issues.
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-5xx"
  alarm_description   = "Target 5xx rate on the ALB exceeded threshold."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

// ─── Unhealthy target alarm (per target group) ───────────────────────────────
// Fires when any target group has at least one unhealthy host for 3 minutes.
resource "aws_cloudwatch_metric_alarm" "tg_unhealthy_service1" {
  alarm_name          = "${var.project_name}-${var.environment}-tg1-unhealthy"
  alarm_description   = "service1 target group has unhealthy hosts."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.service1.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "tg_unhealthy_service2" {
  alarm_name          = "${var.project_name}-${var.environment}-tg2-unhealthy"
  alarm_description   = "service2 target group has unhealthy hosts."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.service2.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

// ─── Wire existing CPU alarms into SNS ───────────────────────────────────────
// The CPU alarms in asg.tf already drive scaling policies. We also want them
// to notify on-call so we can see whether load is scaling cleanly.
resource "aws_cloudwatch_metric_alarm" "asg_cpu_notify" {
  alarm_name          = "${var.project_name}-${var.environment}-asg-cpu-sustained-high"
  alarm_description   = "ASG sustained high CPU — scale-out should be happening."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
