# =============================================================================
# envs/prod.tfvars — production on real AWS
# =============================================================================
# Usage: terraform apply -var-file=envs/prod.tfvars
# Requires real AWS credentials via the standard chain
# (env vars / shared config / SSO). No LocalStack endpoint overrides apply.
# =============================================================================

project     = "data4ai"
environment = "prod"
aws_region  = "us-east-1"

# Airbyte needs >= 8 GB RAM.
instance_type = "t3.large"

# EC2 key pair (break-glass only — no security group rule exposes port 22;
# day-to-day shell/UI access goes through SSM Session Manager).
key_name = "data4ai-airbyte-key"

# Empty = look up the latest Amazon Linux 2023 AMI at apply time.
# Pin an AMI ID here for fully reproducible prod deploys, e.g.:
# ami_id = "ami-0123456789abcdef0"
