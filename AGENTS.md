# AGENTS.md — data4ai-datalake-aws-iac

Terraform IaC for a data lake ingestion tier: versioned/encrypted S3 bucket + self-managed Airbyte on EC2.

## Commands

```bash
./scripts/local-up.sh        # docker compose up + terraform init + apply (local)
./scripts/test-local.sh      # 25 integration assertions against LocalStack
./scripts/local-down.sh      # terraform destroy (local) + docker compose down -v
./scripts/verify-airbyte-s3.sh <url> <s3-endpoint> <bucket>  # Airbyte->S3 smoke test
./scripts/verify-ssm-access.sh <profile> # Prod SSM and Basic Auth verification
./scripts/ssm-connect.sh <ui|shell>      # Connect to Airbyte via SSM

# Static checks
terraform fmt -check -recursive
terraform validate -var-file=envs/local.tfvars
terraform validate -var-file=envs/prod.tfvars

# Production
terraform plan  -var-file=envs/prod.tfvars
terraform apply -var-file=envs/prod.tfvars
```

No `make`, no `package.json`, no CI pipelines are configured. Prefer the scripts — they enforce safety checks (e.g., `local-up.sh` verifies `environment = "local"` in the tfvars before proceeding).

## Architecture

- **Terraform ≥ 1.5, < 2.0** — `hashicorp/aws ~> 5.0` pinned to `5.100.0` (lockfile committed).
- **Two child modules** in `modules/`: `s3_bucket/` and `airbyte_ec2/`.
- **Environments are purely tfvars-driven** (`envs/local.tfvars` vs `envs/prod.tfvars`). No Terraform workspaces for environment separation. `var.environment` is validated to `"local"` or `"prod"` and drives the entire provider config (`providers.tf`).
- **State is local and gitignored** — `terraform.tfstate` for local, `terraform.tfstate.d/prod/` workspace for prod. S3 backend + DynamoDB locking is planned but not yet implemented.

## Testing

- All tests are **bash scripts** (no Terratest or Go). They talk to LocalStack directly via `aws --endpoint-url=http://localhost:4566 --no-sign-request`.
- `test-local.sh` covers R1, R2, R3, R5. It is read-only except for a temporary test bucket it creates and destroys.
- `verify-airbyte-s3.sh` covers R4, R6, R7 (Airbyte health, S3 destination connectivity, Hive partition format, AVRO magic bytes). Requires a running Airbyte instance and an accessible S3 endpoint.

## Gotchas

- **LocalStack cannot service `aws_ami` data lookups.** `main.tf` injects a dummy AMI (`ami-760aaa0f`) when `environment == "local"`, and the module gates the `data.aws_ami` lookup behind `count = var.ami_id == "" ? 1 : 0`. Never remove this gating.
- **`s3_use_path_style = true` is required for LocalStack S3** and must never be set in prod.
- **`$${VAR}` escaping** in `modules/airbyte_ec2/templates/user_data.sh.tftpl` — bash variables inside `templatefile()` need the double-dollar to pass through Terraform interpolation.
- **EC2 `user_data` is async** — `terraform apply` succeeds regardless of bootstrap outcome. The test script polls for `/var/lib/airbyte-ready` marker.
- **Zero Ingress** — The security group has no ingress rules. SSH and UI access are handled entirely through SSM Session Manager.
- **Airbyte config lives on the EC2 Docker volumes**, not in Terraform state. Tearing down the EC2 instance discards Airbyte configuration.
- **Airbyte `user_data` downloads from GitHub raw** — the EC2 needs outbound internet access (SG allows all egress).

## Specs

Requirements and architecture plan live in `specs/ingestion/` (spec.md + plan.md). 7 requirements (R1–R7) with traceable test coverage.

There is also a second capability, Airbyte UI Access, located in `specs/airbyte-ui-access/` covering zero-ingress SSM access and Basic Auth hardening (R1-R8).
