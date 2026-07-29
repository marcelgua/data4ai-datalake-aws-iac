# =============================================================================
# modules/airbyte_ec2 — outputs
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID of the Airbyte host."
  value       = aws_instance.airbyte.id
}

output "public_ip" {
  description = "Public IP address of the Airbyte host."
  value       = aws_instance.airbyte.public_ip
}

output "security_group_id" {
  description = "Security group attached to the Airbyte host."
  value       = aws_security_group.airbyte.id
}

output "iam_role_name" {
  description = "IAM role used by the Airbyte instance profile."
  value       = aws_iam_role.airbyte.name
}
