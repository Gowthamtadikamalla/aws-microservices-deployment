// terraform/waf.tf
// AWS WAFv2 Web ACL attached to the ALB.
//
// Why:
//   - Public ALBs need at least a baseline of Layer-7 protection against
//     common attacks (SQLi, XSS, known-bad inputs) and bot/abuse traffic.
//   - Managed rule groups do the heavy lifting with no rule-writing required.
//   - A rate-limit rule gives cheap protection against brute force / noisy
//     scrapers before they reach the services.
//
// Controlled by var.enable_waf. Kept optional because WAF has per-rule-group
// hourly cost and an empty free-tier account might not want it on by default.

variable "enable_waf" {
  description = "Create a WAFv2 Web ACL and associate it with the ALB."
  type        = bool
  default     = true
}

variable "waf_rate_limit_per_5m" {
  description = "Per-source-IP request cap over a rolling 5 minute window."
  type        = number
  default     = 2000
}

resource "aws_wafv2_web_acl" "alb" {
  count       = var.enable_waf ? 1 : 0
  name        = "${var.project_name}-alb-waf"
  description = "Baseline Web ACL for the public ALB."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  // ─── AWS managed common rule set ───────────────────────────────────────────
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  // ─── AWS managed known-bad-inputs rule set ─────────────────────────────────
  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  // ─── Per-IP rate limit ─────────────────────────────────────────────────────
  rule {
    name     = "PerIPRateLimit"
    priority = 30

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5m
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.project_name}-alb-waf"
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.alb[0].arn
}
