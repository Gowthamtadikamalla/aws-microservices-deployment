// terraform/environments/prod.tfvars
// Production settings. Larger minimum capacity, longer log retention, TLS
// and WAF enforced. Alert email should route to the on-call rotation.

aws_region  = "ap-south-1"
environment = "prod"

asg_min_size         = 2
asg_desired_capacity = 3
asg_max_size         = 6

scale_out_cpu_threshold = 40

enable_public_tls = true
public_domain     = "example.com"   // REPLACE: Route 53 zone you own
public_subdomain  = "api"
enable_waf        = true

alert_email        = "oncall@example.com"  // REPLACE
log_retention_days = 90
