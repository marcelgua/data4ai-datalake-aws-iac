# =============================================================================
# envs/local.tfvars — local development against LocalStack
# =============================================================================
# Usage: terraform apply -var-file=envs/local.tfvars
# (scripts/local-up.sh wraps LocalStack startup + init + apply)
# =============================================================================

project     = "data4ai"
environment = "local"
aws_region  = "us-east-1"

# EC2 is mocked by LocalStack — instance type is recorded but nothing real boots.
instance_type = "t3.large"

# No real SSH access locally; kept open for the mocked security group.
allowed_ssh_cidr = "0.0.0.0/0"

# LocalStack cannot service AMI lookups: the root module injects the dummy
# AMI "ami-12345678" for this environment, so ami_id stays unset here.
