# terraform/alb.tf
# Internet-facing Application Load Balancer, two Target Groups (one per service),
# HTTP listener on port 80, and path-based forwarding rules.

# ─── Application Load Balancer ────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false # Internet-facing
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id # Span both public subnets / AZs

  enable_deletion_protection = false # Set to true for production; keep false for easy teardown

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# ─── Target Group: Service1 (port 5000) ───────────────────────────────────────
resource "aws_lb_target_group" "service1" {
  name        = "${var.project_name}-tg1"
  port        = var.service1_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health"      # Flask /health returns {"status":"healthy"} HTTP 200
    port                = "traffic-port" # Use the target group port (5000)
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  # Allow extra time for containers to start before ALB deregisters the target
  deregistration_delay = 30

  tags = {
    Name    = "${var.project_name}-service1-tg"
    Service = "service1"
  }
}

# ─── Target Group: Service2 (port 5001) ───────────────────────────────────────
resource "aws_lb_target_group" "service2" {
  name        = "${var.project_name}-tg2"
  port        = var.service2_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health"      # Flask /health returns {"status":"healthy"} HTTP 200
    port                = "traffic-port" # Use the target group port (5001)
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name    = "${var.project_name}-service2-tg"
    Service = "service2"
  }
}

# ─── HTTP Listener on port 80 ─────────────────────────────────────────────────
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # Default action: return a clear 404 for unmatched paths
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\": \"route not found. Use /service1 or /service2\"}"
      status_code  = "404"
    }
  }
}

# ─── Listener Rule: /service1* → Target Group 1 ───────────────────────────────
# Matches both the exact path /service1 and any sub-path /service1/...
resource "aws_lb_listener_rule" "service1" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100 # Lower number = evaluated first

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service1.arn
  }

  condition {
    path_pattern {
      values = ["/service1", "/service1/*"]
    }
  }

  tags = {
    Name = "${var.project_name}-rule-service1"
  }
}

# ─── Listener Rule: /service2* → Target Group 2 ───────────────────────────────
resource "aws_lb_listener_rule" "service2" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service2.arn
  }

  condition {
    path_pattern {
      values = ["/service2", "/service2/*"]
    }
  }

  tags = {
    Name = "${var.project_name}-rule-service2"
  }
}
