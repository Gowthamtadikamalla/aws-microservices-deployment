// terraform/environments/staging.tfvars
// Staging mirrors the production footprint and security controls so prod
// surprises are caught before a real release.

aws_region  = "ap-south-1"
environment = "staging"

asg_min_size         = 2
asg_desired_capacity = 2
asg_max_size         = 4

scale_out_cpu_threshold = 50

enable_public_tls = true
public_domain     = "example.com" // REPLACE: Route 53 zone you own
public_subdomain  = "staging.api"
enable_waf        = true

alert_email        = "alerts-staging@example.com" // REPLACE
log_retention_days = 30
