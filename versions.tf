# =============================================================================
# versions.tf — Terraform CLI and provider version pins
# =============================================================================
terraform {
  # Pin the Terraform CLI major line. Installed/verified with 1.15.x.
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to the v5 major line: fully supported by LocalStack 3.5
      # (endpoint overrides, s3_use_path_style, skip_* flags).
      version = "~> 5.0"
    }
  }
}
