# Plan: ingestion

## Architecture

### Directory Structure

```
data4ai-datalake-aws-iac/
├── docker-compose.yml              # LocalStack for local development
├── providers.tf                    # AWS provider w/ local vs prod endpoint mapping
├── versions.tf                     # Terraform + provider version pins
├── main.tf                         # Root module composition (locals, module calls)
├── variables.tf                    # Root input variables (project, environment, ...)
├── outputs.tf                      # Root outputs (bucket name, instance id, ...)
├── envs/
│   ├── local.tfvars                # environment = "local"
│   └── prod.tfvars                 # environment = "prod"
├── modules/
│   ├── s3_bucket/                  # Staging bucket + versioning + encryption
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── airbyte_ec2/                # EC2 + IAM + SG + user_data (docker-compose Airbyte)
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── templates/
│           └── user_data.sh.tftpl  # Installs Docker, pulls Airbyte, compose up
├── scripts/
│   ├── local-up.sh                 # Start LocalStack + terraform apply (local)
│   ├── test-local.sh               # Assert bucket/versioning/encryption vs LocalStack
│   ├── verify-airbyte-s3.sh        # Airbyte → LocalStack S3 connection check, partitioning, and format check
│   └── local-down.sh               # terraform destroy + docker compose down
├── .gitignore                      # *.tfstate*, .terraform/, .env
└── specs/ingestion/{spec,plan}.md
```

### Component Layout (textual diagram)

```
                        ┌──────────────────────────────────────────────┐
                        │                 Developer host               │
                        │                                              │
   terraform apply ────►│  Root Terraform module                       │
   -var-file=envs/X     │   ├── module.s3_bucket                       │
                        │   └── module.airbyte_ec2                     │
                        └───────┬───────────────────┬──────────────────┘
                                │ AWS API           │ AWS API
              ┌─────────────────┴───────┐   ┌───────┴──────────────────┐
              │  local: LocalStack      │   │  prod: real AWS          │
              │  (docker-compose,       │   │                          │
              │   http://localhost:4566)│   │                          │
              │   • aws_s3_bucket  ✓    │   │  • aws_s3_bucket         │
              │   • aws_instance   (mocked)│ │  • aws_instance (EC2)    │
              │   • aws_iam_*      (mocked)│ │  • aws_iam_role/policy   │
              │   • aws_security_group    │ │  • aws_security_group    │
              └─────────▲───────────────┘   └─────────▲────────────────┘
                        │ S3 API (endpoint override)  │ user_data boot
              ┌─────────┴───────────────┐   ┌─────────┴────────────────┐
              │ Airbyte (docker-compose │   │ EC2 user_data:           │
              │  on host, local dev)    │   │  docker + compose up     │
              │  S3 dest endpoint:      │   │  Airbyte self-managed    │
              │  host.docker.internal:  │   │  → writes to             │
              │  4566                   │   │  data4ai-staging-prod    │
              └─────────────────────────┘   └──────────────────────────┘
```

### Data Flow

1. **Provisioning**: `terraform apply -var-file=envs/<env>.tfvars` → root module resolves
   `is_local = var.environment == "local"` → provider endpoints/credentials switch →
   `module.s3_bucket` creates `data4ai-staging-<env>` → outputs feed `module.airbyte_ec2`
   (bucket name → IAM policy ARN scope + user_data env).
2. **Ingestion (prod)**: EC2 boots → user_data installs Docker, fetches pinned Airbyte
   docker-compose release, `docker compose up -d` → engineer configures S3 destination in
   Airbyte UI → Airbyte writes compressed AVRO files to `s3://data4ai-staging-prod/` using the
   instance-profile credentials.
3. **Ingestion (local)**: engineer runs LocalStack + Airbyte via docker-compose on the host
   → Airbyte S3 destination configured with custom endpoint `http://host.docker.internal:4566`,
   dummy credentials `test/test`, bucket `data4ai-staging-local` → writes land in LocalStack S3.
4. **S3 Path Partitioning**: The Airbyte S3 destination connector is configured with a path format
   partitioned by table name and hive-partitioned by ingestion timestamp:
   `${NAMESPACE}/${STREAM_NAME}/year=${YEAR}/month=${MONTH}/day=${DAY}/hour=${HOUR}/`
5. **Data Format**: The output format configured for the S3 destination connector is set to `AVRO` with compression (e.g. Deflate or Snappy).

## Component Breakdown

- **Root module** (`main.tf`, `variables.tf`, `outputs.tf`): owns `var.project`
  (default `"data4ai"`), `var.environment` (validated: `local` | `prod`), `var.aws_region`,
  `var.instance_type` (default `t3.large`, 8 GB — Airbyte minimum), `var.allowed_ssh_cidr`.
  Computes `local.is_local`, `local.bucket_name = "${var.project}-staging-${var.environment}"`.
  Depends on: both modules. Interface: tfvars in, outputs out.
- **module.s3_bucket**: resources `aws_s3_bucket.staging`,
  `aws_s3_bucket_versioning.staging` (`Enabled`), `aws_s3_bucket_server_side_encryption_
  configuration.staging` (`AES256`), `aws_s3_bucket_public_access_block.staging` (all blocked —
  hardening, no spec conflict). Inputs: `bucket_name`, `environment`. Outputs: `bucket_name`,
  `bucket_arn`. No dependencies.
- **module.airbyte_ec2**: resources `aws_instance.airbyte` (user_data from
  `templatefile()`), `aws_iam_role` + `aws_iam_role_policy` (scoped: `s3:ListBucket` on bucket,
  `s3:GetObject/PutObject/DeleteObject` on `bucket/*`), `aws_iam_instance_profile`,
  `aws_security_group` (ingress 8000 Airbyte UI, 22 from allowed CIDR; egress 0.0.0.0/0).
  `data "aws_ami"` for Amazon Linux 2023, **gated with `count = local.is_local ? 0 : 1`** —
  LocalStack can't service AMI lookups; local uses `var.ami_id_override = "ami-12345678"`.
  Depends on: module.s3_bucket (bucket name/ARN). Outputs: `instance_id`, `public_ip`.
- **LocalStack compose service** (`docker-compose.yml`): `localstack/localstack:3.5` (pinned),
  port `4566`, `SERVICES=s3,ec2,iam,sts`, volume `/var/run/docker.sock`, named volume for state.
  Healthcheck on `/_localstack/health`.
- **scripts/**: bash glue with `set -euo pipefail`. Interfaces documented in Testing Strategy.

## Data Models & Persistence

- **Terraform state**: local backend for both environments initially (state files gitignored).
  Prod follow-up (out of scope, noted as risk): migrate to S3 backend + DynamoDB locking once
  a bootstrap bucket exists. Kept simple deliberately — single-developer local-first workflow.
- **S3 bucket schema**: one bucket per environment, `<project>-staging-<environment>`;
  versioning on; SSE-S3 (AES256); public access blocked.
- **S3 Partitioning and File Format Structure**:
  The Airbyte staging destination uses:
  - Custom S3 path: `<table_name>/year=YYYY/month=MM/day=DD/hour=HH/`
  - File Format: AVRO (`.avro` suffix)
  - Example file: `users/year=2026/month=07/day=29/hour=14/<filename>.avro`
- **Airbyte persistence**: Airbyte's own config Postgres lives inside its docker-compose
  deployment (named volume), not managed by Terraform. On EC2 it persists on the root EBS
  volume; teardown of the instance discards Airbyte config (acceptable for a staging tier —
  documented in README).
- **Relationships/constraints**: IAM policy ARN must reference the exact bucket ARN → module
  wiring via outputs; environment variable must match `^(local|prod)$` via `validation` block.

## API / Interface Design

### `providers.tf` — environment-aware endpoint mapping

```hcl
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
  s3_use_path_style           = local.is_local   # required by LocalStack S3
}
```

Prod requires no overrides — standard credential chain (env vars / shared config / SSO).

### Module contracts

| Module | Inputs | Outputs |
|---|---|---|
| `s3_bucket` | `bucket_name: string`, `environment: string` | `bucket_name`, `bucket_arn` |
| `airbyte_ec2` | `bucket_name`, `bucket_arn`, `instance_type`, `ami_id`, `environment` | `instance_id` |

_Amended per `specs/airbyte-ui-access/spec.md` (R7 + spec delta): `allowed_ssh_cidr` input and `public_ip` output removed — breaking change to the module interface._

### `user_data.sh.tftpl` contract

Inputs: `${bucket_name}`, `${airbyte_version}` (pinned, e.g. `0.63.x`). Behavior:
`dnf install docker` → enable/start docker → install compose plugin → fetch Airbyte's pinned
`docker-compose.yaml` + `.env` from the `airbytehq/airbyte` release → `docker compose up -d` →
write marker file `/var/lib/airbyte-ready` for test polling. Failures logged to
`/var/log/user-data.log` and non-zero exit via `set -euo pipefail`.

### Script interfaces

- `scripts/local-up.sh` — starts LocalStack (waits on healthcheck, 60 s timeout), runs
  `terraform init && terraform apply -var-file=envs/local.tfvars -auto-approve`.
- `scripts/test-local.sh` — read-only assertions (exit 1 on first failure).
- `scripts/verify-airbyte-s3.sh <airbyte-url> <s3-endpoint>` — Airbyte destination check.
- `scripts/local-down.sh` — `terraform destroy` (local) + `docker compose down -v`.

## Error Handling Strategy

| Category | Handling |
|---|---|
| LocalStack not running | `local-up.sh` healthcheck loop with timeout + actionable message; `test-local.sh` pre-flight `curl localhost:4566/_localstack/health` |
| Invalid environment value | Terraform `validation` block on `var.environment` — fails at plan time |
| AMI lookup vs LocalStack | data source disabled in local (`count = 0`), static dummy AMI — avoids opaque provider errors |
| AWS credential errors (prod) | no `skip_*` flags in prod → provider fails fast at plan with the standard auth error |
| Bucket name collision | deterministic `<project>-staging-<environment>` name; apply failure surfaces clearly |
| user_data bootstrap failure | `set -euo pipefail`; output to `/var/log/user-data.log`; `terraform apply` still succeeds → verified by post-boot check, not by apply |
| Airbyte↔S3 failure | `verify-airbyte-s3.sh` reports Airbyte API check status and LocalStack bucket listing; non-zero exit on failure |
| Script hygiene | all bash uses `set -euo pipefail`; every destructive script confirms target env is `local` |

**Logging**: Terraform CLI output (captured to `logs/` optionally); LocalStack container logs
via `docker compose logs localstack`; Airbyte logs via its compose stack; user_data log on EC2.

## Testing Strategy

### Unit / static level
- `terraform fmt -check -recursive`, `terraform validate` per env (`-var-file` both tfvars).
- Optional: `tflint`, `checkov` (soft gate initially).
- Variable validation exercised by applying an invalid `environment` and expecting plan failure.

### Integration: Terraform vs LocalStack (R1, R2, R3-local)
`scripts/test-local.sh` asserts, using `aws --endpoint-url=http://localhost:4566`:
1. **AC-R1a**: LocalStack health shows S3 + EC2 available; raw `ec2 DescribeInstances` and
   `sts GetCallerIdentity` calls succeed.
2. **AC-R1b**: raw `s3api create-bucket staging-bucket` succeeds and appears in `list-buckets`
   (cleanup after). Proves emulation independent of Terraform.
3. **AC-R2-local**: `terraform apply` (local.tfvars) exits 0; bucket `data4ai-staging-local`
   exists; `get-bucket-versioning` = `Enabled`; `get-bucket-encryption` = `AES256`.
4. **AC-R3-local**: `terraform state show module.airbyte_ec2.aws_instance.airbyte` exists;
   instance visible via LocalStack EC2 API; IAM role/policy/profile present.
5. **AC-R5**: repeat apply with `envs/prod.tfvars` in **plan-only** mode → planned bucket name
   is `data4ai-staging-prod` and no endpoint override appears in plan (no code change needed).

### Integration: Airbyte ↔ S3 connection, Partitioning, and AVRO Format (R4, R6, R7)
- Start Airbyte on host (pinned docker-compose release) alongside LocalStack.
- `verify-airbyte-s3.sh`:
  1. Wait for Airbyte API health.
  2. Create/lookup S3 destination via Airbyte API pointing to LocalStack.
  3. Configure destination to write custom S3 path formatting and format = `AVRO`.
  4. Call the destination **check** operation and assert `status == "succeeded"`.
  5. Run test sync/upload, verify S3 objects exist matching `*/year=*/month=*/day=*/hour=*/*.avro`.
  6. Assert files start with the AVRO magic header bytes (`Obj\x01` or equivalent AVRO header).

### Prod smoke (R2-prod, R3-prod, manual, pre-merge)
- `terraform plan -var-file=envs/prod.tfvars` review; verify settings & output formats.

## Implementation Approach

1. **Scaffold**: `versions.tf`, `variables.tf`, `providers.tf`, `.gitignore` → `fmt/validate`.
2. **module.s3_bucket`** + root wiring.
3. **docker-compose.yml` (LocalStack)** + `local-up.sh` / `local-down.sh`.
4. **module.airbyte_ec2**: security group, roles, user_data.
5. **Scripts & tests**: `test-local.sh`, then `verify-airbyte-s3.sh` + host Airbyte compose.
6. **Docs**: README quickstart.

## Traceability

| Requirement | Plan Section | Notes |
|---|---|---|
| R1 (LocalStack emulation) | Architecture → LocalStack compose; Testing → AC-R1a/R1b | S3/EC2/IAM/STS mocked APIs |
| R2 (Env-aware S3 provisioning) | Architecture → modules; API → providers.tf; Testing → AC-R2-local | `<project>-staging-<environment>` name |
| R3 (Airbyte via Terraform) | Component Breakdown → module.airbyte_ec2; Testing → AC-R3-local | EC2 + docker-compose |
| R4 (Network & access integration) | Component Breakdown; Testing → Integration: Airbyte ↔ S3 | IAM policy, `verify-airbyte-s3.sh` |
| R5 (Environment toggle) | Architecture → `envs/*.tfvars`; Testing → AC-R5 | Variable validation, endpoint toggle |
| R6 (Partitioned S3 Target Paths) | Data Models → S3 Partitioning Structure; Testing → Integration: Airbyte ↔ S3 | `*/year=*/month=*/day=*/hour=*/` format |
| R7 (AVRO Output Format) | Data Models → S3 Partitioning and File Format; Testing → Integration: Airbyte ↔ S3 | AVRO `.avro` format and header validation |

## Self-Review

Review performed against spec R1–R7 and every scenario:
- Status: PASS
- All requirements (R1–R7) addressed: yes
- All ACs accounted for in testing strategy: yes
- No contradictions with spec: yes
- Traceability complete: yes
