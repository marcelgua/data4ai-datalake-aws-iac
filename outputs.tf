# =============================================================================
# outputs.tf — Root module outputs
# =============================================================================

output "environment" {
  description = "Environment this state was applied against."
  value       = var.environment
}

output "planned_bucket_name" {
  description = <<-EOT
    Staging bucket name resolved from project + environment for the CURRENT
    var-file (equals the provisioned bucket name). Computed purely from
    inputs, so it renders in `terraform plan` output for any environment —
    including prod plan-only reviews without live AWS credentials.
  EOT
  value       = local.bucket_name
}

output "bucket_name" {
  description = "Name of the staging S3 bucket."
  value       = module.s3_bucket.bucket_name
}

output "bucket_arn" {
  description = "ARN of the staging S3 bucket."
  value       = module.s3_bucket.bucket_arn
}

output "airbyte_instance_id" {
  description = "EC2 instance ID of the self-managed Airbyte host."
  value       = module.airbyte_ec2.instance_id
}

output "airbyte_public_ip" {
  description = "Public IP of the Airbyte host."
  value       = module.airbyte_ec2.public_ip
}

output "airbyte_url" {
  description = "URL of the Airbyte UI/API."
  value       = "http://${module.airbyte_ec2.public_ip}:8000"
}
