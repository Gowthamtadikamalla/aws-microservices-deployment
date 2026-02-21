# terraform/outputs.tf
# Key values printed after `terraform apply` for use in subsequent steps.

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer. Pass as ALB_DNS to verify_endpoints.sh."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB (useful for Route 53 alias records)."
  value       = aws_lb.main.zone_id
}

output "ecr_service1_repository_url" {
  description = "Full ECR repository URL for service1 (use to tag and push images)."
  value       = aws_ecr_repository.service1.repository_url
}

output "ecr_service2_repository_url" {
  description = "Full ECR repository URL for service2 (use to tag and push images)."
  value       = aws_ecr_repository.service2.repository_url
}

output "ecr_registry" {
  description = "ECR registry hostname (<account_id>.dkr.ecr.<region>.amazonaws.com). Set as ECR_REGISTRY."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "asg_name" {
  description = "Name of the Auto Scaling Group."
  value       = aws_autoscaling_group.main.name
}

output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets."
  value       = aws_subnet.public[*].id
}

output "ec2_security_group_id" {
  description = "ID of the EC2 security group."
  value       = aws_security_group.ec2.id
}

output "alb_security_group_id" {
  description = "ID of the ALB security group."
  value       = aws_security_group.alb.id
}

output "ec2_instance_profile_name" {
  description = "IAM Instance Profile attached to EC2 instances (allows ECR pull)."
  value       = aws_iam_instance_profile.ec2_ecr_profile.name
}

output "quick_test_commands" {
  description = "Copy-paste commands to quickly verify the deployment."
  value       = <<-EOT
    # Test service1 via ALB
    curl http://${aws_lb.main.dns_name}/service1

    # Test service2 via ALB
    curl http://${aws_lb.main.dns_name}/service2

    # Run full verification script
    ALB_DNS=${aws_lb.main.dns_name} AWS_REGION=${var.aws_region} ./verify_endpoints.sh
  EOT
}
