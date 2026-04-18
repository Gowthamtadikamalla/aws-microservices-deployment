// terraform/environments/dev.tfvars
// Development environment overrides. Smallest footprint, no TLS/WAF by
// default so costs stay near zero. Intended for short-lived validation.

aws_region  = "ap-south-1"
environment = "dev"

asg_min_size         = 1
asg_desired_capacity = 1
asg_max_size         = 2

scale_out_cpu_threshold = 60

enable_public_tls = false
enable_waf        = false
alert_email       = ""

log_retention_days = 7
