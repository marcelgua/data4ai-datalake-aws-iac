# =============================================================================
# modules/airbyte_ec2 — self-managed Airbyte host
# =============================================================================
# EC2 instance (docker-compose Airbyte via user_data) + security group +
# IAM instance profile with a policy scoped to the staging bucket only.
#
# The AMI data source is DISABLED when an explicit AMI ID is provided — this
# is what allows the local environment to run against LocalStack (which cannot
# service AMI lookups) using a dummy AMI.
# =============================================================================

locals {
  resolved_ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux_2023[0].id
}

# -----------------------------------------------------------------------------
# AMI lookup (prod path; skipped entirely when var.ami_id is set, e.g. local)
# -----------------------------------------------------------------------------
data "aws_ami" "amazon_linux_2023" {
  count = var.ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# -----------------------------------------------------------------------------
# Security group: ZERO inbound rules (SSM Session Manager only) / open egress.
# UI and shell access go through SSM port-forwarding — no SG rule exposes any
# port (airbyte-ui-access R1). Zero inline inbound blocks also keeps a future
# ALB-sourced aws_vpc_security_group_ingress_rule at root safe (R8).
# -----------------------------------------------------------------------------
resource "aws_security_group" "airbyte" {
  name        = "${var.name_prefix}-sg"
  description = "Airbyte host: no public inbound — SSM Session Manager only"

  egress {
    description = "Allow all outbound (package repos, Docker Hub, S3, sources)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-sg"
  })
}

# -----------------------------------------------------------------------------
# IAM role + scoped inline policy (write access to the staging bucket only)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "airbyte" {
  name               = "${var.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "airbyte_s3_access" {
  statement {
    sid       = "ListStagingBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
  }

  statement {
    sid    = "ReadWriteStagingObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${var.bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "airbyte_s3_access" {
  name   = "${var.name_prefix}-s3-access"
  role   = aws_iam_role.airbyte.id
  policy = data.aws_iam_policy_document.airbyte_s3_access.json
}

resource "aws_iam_role_policy_attachment" "airbyte_ssm" {
  role       = aws_iam_role.airbyte.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "airbyte" {
  name = "${var.name_prefix}-profile"
  role = aws_iam_role.airbyte.name

  tags = var.tags
}

# -----------------------------------------------------------------------------
# EC2 instance — boots straight into the Airbyte docker-compose stack
# -----------------------------------------------------------------------------
resource "aws_instance" "airbyte" {
  ami                    = local.resolved_ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.airbyte.name
  vpc_security_group_ids = [aws_security_group.airbyte.id]

  # user_data changes (e.g. basic-auth credential rotation) MUST destroy and
  # recreate the instance (airbyte-ui-access R5). Provider default (false)
  # would update user_data in place via stop/start.
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    bucket_name            = var.bucket_name
    aws_region             = var.aws_region
    environment            = var.environment
    s3_endpoint            = var.s3_endpoint
    airbyte_version        = var.airbyte_version
    docker_compose_version = var.docker_compose_version
    basic_auth_username    = var.airbyte_basic_auth_username
    basic_auth_password    = var.airbyte_basic_auth_password
  })

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ec2"
  })
}
