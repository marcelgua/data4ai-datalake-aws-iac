# data4ai-datalake-aws-iac

Infrastructure-as-Code (Terraform) for the data4ai data lake ingestion tier:
a versioned, AES256-encrypted staging S3 bucket and a self-managed Airbyte
instance on EC2 — runnable locally against LocalStack or in production on AWS.

## Layout

```
docker-compose.yml            LocalStack (S3, EC2, IAM, STS) for local dev
providers.tf                  AWS provider with local/prod endpoint mapping
versions.tf                   Terraform + AWS provider version pins
main.tf / variables.tf / outputs.tf   Root module composition
envs/local.tfvars             environment = "local"  (LocalStack)
envs/prod.tfvars              environment = "prod"   (real AWS)
modules/s3_bucket/            Staging bucket + versioning + SSE + access block
modules/airbyte_ec2/          EC2 + SG + IAM instance profile + user_data
scripts/local-up.sh           Start LocalStack, terraform init + apply (local)
scripts/test-local.sh         Integration tests vs LocalStack (read-only)
scripts/verify-airbyte-s3.sh  Airbyte -> S3 connection/partition/AVRO checks
scripts/local-down.sh         terraform destroy (local) + compose down -v
```

## Prerequisites

- Docker (with Compose v2)
- Terraform >= 1.5
- AWS CLI v2 and `curl` (for the test scripts)
- For prod: valid AWS credentials via the standard chain

## Quickstart (local)

```bash
./scripts/local-up.sh       # LocalStack up + terraform apply (envs/local.tfvars)
./scripts/test-local.sh     # 25 assertions: R1, R2-local, R3-local, R5
./scripts/local-down.sh     # tear everything down
```

The staging bucket is `data4ai-staging-local` (pattern
`<project>-staging-<environment>`), versioned, SSE-S3 (AES256), public access
fully blocked. The mocked EC2 host carries an instance profile scoped to
`s3:ListBucket` on the bucket and `s3:Get/Put/DeleteObject` on `bucket/*`.

## Production

```bash
terraform init
terraform plan  -var-file=envs/prod.tfvars    # review
terraform apply -var-file=envs/prod.tfvars
```

Notes:

- No endpoint overrides or skip flags apply in prod — the provider uses the
  standard credential chain and fails fast on invalid credentials.
- `ami_id` empty = latest Amazon Linux 2023 lookup; pin it in
  `envs/prod.tfvars` for reproducible deploys. For `local`, a dummy AMI from
  LocalStack's built-in catalog (`ami-760aaa0f`) is injected automatically
  because LocalStack cannot service AMI lookups.
- EC2 user_data installs Docker + Compose (pinned) and brings up the pinned
  Airbyte platform release (`airbyte_version`, default `0.63.5`) via
  `docker compose up -d`; bootstrap logs go to `/var/log/user-data.log` and a
  ready marker is written to `/var/lib/airbyte-ready`.
- Configure the Airbyte S3 destination with path format
  `${NAMESPACE}/${STREAM_NAME}/year=${YEAR}/month=${MONTH}/day=${DAY}/hour=${HOUR}/`
  and format `Avro` (deflate/snappy) per specs/ingestion/spec.md (R6, R7).
- Terraform state is local (gitignored). Migrating prod to an S3 backend with
  DynamoDB locking is a deliberate follow-up.

## Environment toggle

Environments are selected purely by tfvars (`envs/local.tfvars` vs
`envs/prod.tfvars`); `var.environment` is validated (`local` | `prod`) and
drives the provider endpoint mapping, credentials, and bucket naming. No
core infrastructure code changes between environments.
