# =============================================================================
# main.tf — Root module composition
# =============================================================================
# Data flow: envs/<env>.tfvars -> locals -> module.s3_bucket -> outputs feed
# module.airbyte_ec2 (bucket name scopes the IAM policy and the user_data env).
# =============================================================================

locals {
  bucket_name = "${var.project}-staging-${var.environment}"
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Staging S3 bucket (versioned, AES256 encrypted, public access blocked)
# -----------------------------------------------------------------------------
module "s3_bucket" {
  source = "./modules/s3_bucket"

  bucket_name = local.bucket_name
  environment = var.environment
  tags        = local.common_tags
}

# -----------------------------------------------------------------------------
# Self-managed Airbyte on EC2 (docker-compose via user_data)
# -----------------------------------------------------------------------------
module "airbyte_ec2" {
  source = "./modules/airbyte_ec2"

  name_prefix   = "${local.name_prefix}-airbyte"
  environment   = var.environment
  aws_region    = var.aws_region
  instance_type = var.instance_type
  # Local: dummy AMI from LocalStack's built-in image catalog. The AWS
  # provider v5 validates the AMI via DescribeImages at apply time and
  # LocalStack only knows its pre-loaded catalog — ami-760aaa0f is the
  # catalog's Amazon Linux (x86_64, hvm, ebs) image. Nothing actually boots
  # in LocalStack, so the image contents are irrelevant.
  ami_id                 = local.is_local ? "ami-760aaa0f" : var.ami_id
  allowed_ssh_cidr       = var.allowed_ssh_cidr
  bucket_name            = module.s3_bucket.bucket_name
  bucket_arn             = module.s3_bucket.bucket_arn
  s3_endpoint            = local.is_local ? "http://localhost:4566" : ""
  key_name               = var.key_name
  airbyte_version        = var.airbyte_version
  docker_compose_version = var.docker_compose_version
  tags                   = local.common_tags

  depends_on = [module.s3_bucket]
}
