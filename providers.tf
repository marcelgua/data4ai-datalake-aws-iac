# =============================================================================
# providers.tf — Environment-aware AWS provider configuration
# =============================================================================
# local: all service endpoints point at LocalStack (http://localhost:4566)
#        with dummy static credentials and every offline skip flag enabled.
# prod:  no overrides — the standard AWS credential chain is used
#        (env vars / shared config / SSO / instance profile).
# =============================================================================

locals {
  is_local = var.environment == "local"
}

provider "aws" {
  region = var.aws_region

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
      s3  = "http://localhost:4566"
      ec2 = "http://localhost:4566"
      iam = "http://localhost:4566"
      sts = "http://localhost:4566"
    }
  }

  access_key                  = local.is_local ? "test" : null
  secret_key                  = local.is_local ? "test" : null
  skip_credentials_validation = local.is_local
  skip_metadata_api_check     = local.is_local
  skip_requesting_account_id  = local.is_local
  s3_use_path_style           = local.is_local # required by LocalStack S3

  default_tags {
    tags = local.common_tags
  }
}
