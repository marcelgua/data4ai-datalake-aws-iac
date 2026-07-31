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
  bucket_name            = module.s3_bucket.bucket_name
  bucket_arn             = module.s3_bucket.bucket_arn
  s3_endpoint            = local.is_local ? "http://localhost:4566" : ""
  key_name               = var.key_name
  airbyte_version        = var.airbyte_version
  docker_compose_version = var.docker_compose_version

  # Basic auth hardening (airbyte-ui-access R5). Supplied via TF_VAR_*
  # environment variables at apply time — never committed to tfvars.
  airbyte_basic_auth_username = var.airbyte_basic_auth_username
  airbyte_basic_auth_password = var.airbyte_basic_auth_password

  tags = local.common_tags

  depends_on = [module.s3_bucket]
}

# -----------------------------------------------------------------------------
# Human-facing SSM access policy (airbyte-ui-access R4)
# Attach to IAM users/groups that operate Airbyte. The instance role
# (AmazonSSMManagedInstanceCore in the module) is intentionally untouched.
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ssm_access" {
  statement {
    sid     = "AllowStartSessionAirbyte"
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      # instance ARN (account-id segment present):
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${module.airbyte_ec2.instance_id}",
      # account-owned document (created by Session Manager in the account):
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/SSM-SessionManagerRunShell",
      # AWS-owned document (EMPTY account segment, per AWS docs):
      "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession",
    ]
  }

  statement {
    sid     = "AllowManageOwnSessions"
    effect  = "Allow"
    actions = ["ssm:TerminateSession", "ssm:ResumeSession"]
    # GOTCHA: $${...} escapes HCL interpolation so the IAM policy variable
    # ${aws:username} survives into the rendered JSON (same class of escaping
    # as $${VAR} in the user_data template). Matches AWS Example 4 Method 1
    # (IAM-user principals). If operators later authenticate via IAM Identity
    # Center (federated), swap aws:username -> aws:userid here and below.
    resources = ["arn:aws:ssm:*:*:session/$${aws:username}-*"]
  }

  statement {
    sid       = "AllowOpenDataChannelOwnSessions" # required for port-forward data channel
    effect    = "Allow"
    actions   = ["ssmmessages:OpenDataChannel"]
    resources = ["arn:aws:ssm:*:*:session/$${aws:username}-*"]
  }

  statement {
    sid       = "AllowDescribeInstances" # helper-script instance discovery
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ssm_access" {
  name        = "${local.name_prefix}-ssm-access"
  description = "Human access: SSM Session Manager (shell + UI port-forward) to the Airbyte EC2 instance. Attach to IAM users/groups that operate Airbyte."
  policy      = data.aws_iam_policy_document.ssm_access.json
  tags        = local.common_tags
}
