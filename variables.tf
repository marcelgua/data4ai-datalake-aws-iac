# =============================================================================
# variables.tf — Root input variables
# =============================================================================
# Environment selection happens exclusively through these variables
# (see envs/*.tfvars); the core infrastructure code never changes per env.
# =============================================================================

variable "project" {
  description = "Project slug used as a name prefix for all resources (S3-compatible)."
  type        = string
  default     = "data4ai"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.project))
    error_message = "project must be lowercase alphanumeric with optional dashes (S3 bucket name compatible)."
  }
}

variable "environment" {
  description = "Deployment environment. 'local' targets LocalStack, 'prod' targets real AWS."
  type        = string

  validation {
    condition     = contains(["local", "prod"], var.environment)
    error_message = "environment must be one of: local, prod."
  }
}

variable "aws_region" {
  description = "AWS region for all resources (also used against LocalStack)."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the self-managed Airbyte host (Airbyte needs >= 8 GB RAM)."
  type        = string
  default     = "t3.large"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to reach the Airbyte EC2 instance over SSH (port 22)."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.allowed_ssh_cidr, 0))
    error_message = "allowed_ssh_cidr must be a valid IPv4 CIDR block (e.g. \"203.0.113.10/32\")."
  }
}

variable "ami_id" {
  description = <<-EOT
    Explicit AMI ID for the Airbyte EC2 instance. When empty, the latest
    Amazon Linux 2023 AMI is looked up (prod only — the AMI data source is
    disabled for the local environment, which always uses a dummy AMI because
    LocalStack cannot service AMI lookups).
  EOT
  type        = string
  default     = ""
}

variable "airbyte_version" {
  description = "Pinned Airbyte platform version deployed on the EC2 host via docker compose."
  type        = string
  default     = "0.63.5"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.airbyte_version))
    error_message = "airbyte_version must be a semantic version string (e.g. \"0.63.5\")."
  }
}

variable "docker_compose_version" {
  description = "Pinned Docker Compose plugin version installed on the Airbyte EC2 host."
  type        = string
  default     = "2.29.2"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.docker_compose_version))
    error_message = "docker_compose_version must be a semantic version string (e.g. \"2.29.2\")."
  }
}
