# =============================================================================
# modules/s3_bucket — outputs
# =============================================================================

output "bucket_name" {
  description = "Name of the staging bucket."
  value       = aws_s3_bucket.staging.bucket
}

output "bucket_arn" {
  description = "ARN of the staging bucket."
  value       = aws_s3_bucket.staging.arn
}
