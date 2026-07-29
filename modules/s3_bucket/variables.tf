# =============================================================================
# modules/s3_bucket — input variables
# =============================================================================

variable "bucket_name" {
  description = "Name of the staging S3 bucket (must be globally unique on real AWS)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters, numbers, dots and dashes)."
  }
}

variable "environment" {
  description = "Deployment environment (local | prod)."
  type        = string

  validation {
    condition     = contains(["local", "prod"], var.environment)
    error_message = "environment must be one of: local, prod."
  }
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}
