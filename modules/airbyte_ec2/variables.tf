# =============================================================================
# modules/airbyte_ec2 — input variables
# =============================================================================

variable "name_prefix" {
  description = "Prefix applied to every resource name in this module (contains 'airbyte')."
  type        = string
}

variable "environment" {
  description = "Deployment environment (local | prod)."
  type        = string

  validation {
    condition     = contains(["local", "prod"], var.environment)
    error_message = "environment must be one of: local, prod."
  }
}

variable "aws_region" {
  description = "AWS region (passed to user_data for the Airbyte S3 destination context)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the Airbyte host (>= 8 GB RAM recommended)."
  type        = string
  default     = "t3.large"
}

variable "ami_id" {
  description = "Explicit AMI ID. When empty, the latest Amazon Linux 2023 AMI is looked up."
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH (port 22) into the instance."
  type        = string
}

variable "bucket_name" {
  description = "Name of the staging S3 bucket Airbyte writes to."
  type        = string
}

variable "bucket_arn" {
  description = "ARN of the staging S3 bucket (scopes the IAM instance policy)."
  type        = string
}

variable "s3_endpoint" {
  description = "Custom S3 endpoint for the Airbyte destination (LocalStack). Empty = real AWS S3."
  type        = string
  default     = ""
}

variable "airbyte_version" {
  description = "Pinned Airbyte platform version to deploy via docker compose."
  type        = string
}

variable "docker_compose_version" {
  description = "Pinned Docker Compose plugin version installed on the host."
  type        = string
}

variable "tags" {
  description = "Tags applied to all taggable resources in this module."
  type        = map(string)
  default     = {}
}
