# airbyte-ui-access — Test Coverage Matrix

## Traceability: Spec Scenarios → Test Assertions

| Spec Scenario | Test Assertion ID | Layer | Environment | Red-Phase Expectation |
|---|---|---|---|---|
| **R1**: SG has no ingress rules in production | `verify-ssm-access.sh` CHECK 3 | Structural (prod) | Real AWS (`verify-ssm-access.sh`) | FAIL — SG currently has 2 ingress rules (8000 + 22) |
| **R1**: SG has no ingress rules in local environment | AC-AUA-R1a | Structural (local) | LocalStack (`test-local.sh`) | FAIL — SG has `ingress { }` blocks in state + `IpPermissions` non-empty via EC2 API |
| **R1**: Instance retains a public IP but no port is reachable | prod-manual | Behavioural (prod) | Real AWS (manual `nc -zw3 <ip> 8000`) | FAIL — port 8000 currently reachable |
| **R1**: Break-glass key pair retained but inert | AC-AUA-R1a (SG check) + design review | Structural (local) | LocalStack + code review | PASS on key_name presence; FAIL on SG ingress (22 still open today) |
| **R2**: Successful port-forward session to Airbyte UI | prod-manual | Behavioural (prod) | Real AWS (`ssm-connect.sh ui`) | FAIL — SSM not configured, script not written |
| **R2**: Instance not found or not running | prod-manual | Behavioural (prod) | Real AWS (ssm-connect.sh error handling) | n/a (script not yet written) |
| **R2**: session-manager-plugin not installed | prod-manual | Behavioural (prod) | Real AWS (ssm-connect.sh preflight) | n/a (script not yet written) |
| **R2**: AWS credentials missing or expired | prod-manual | Behavioural (prod) | Real AWS (ssm-connect.sh preflight) | n/a (script not yet written) |
| **R2**: Terraform state not available for instance ID | prod-manual | Behavioural (prod) | Real AWS (ssm-connect.sh fallback to Name-tag) | n/a (script not yet written) |
| **R3**: Successful SSM shell session | prod-manual | Behavioural (prod) | Real AWS (`ssm-connect.sh shell`) | FAIL — SSM not configured |
| **R3**: Shell access through same script entrypoint | prod-manual | Behavioural (prod) | Real AWS (ssm-connect.sh usage/`ui`+`shell`) | n/a (script not yet written) |
| **R3**: SSH on port 22 permanently unavailable | AC-AUA-R1a + verify-ssm-access.sh CHECK 3 | Structural (local + prod) | LocalStack (`test-local.sh`) + Real AWS | FAIL — SG allows port 22 ingress today |
| **R4**: Policy grants StartSession/TerminateSession scoped to Airbyte instance only | AC-AUA-R4a | Structural (local) | LocalStack IAM (`test-local.sh` IAM API → python3 parse) | FAIL — no `aws_iam_policy.ssm_access` resource yet |
| **R4**: Policy ARN available as Terraform output | AC-AUA-OUTa (`ssm_access_policy_arn` leg) | Structural (local) | LocalStack (`test-local.sh`) | FAIL — `terraform output ssm_access_policy_arn` returns error (output absent) |
| **R4**: Policy is not created in local environment | N/A (per plan Decision 3: always created) | — | — | — |
| **R4**: No SSM permissions needed for instance role itself | design review | Design (review) | Code review | PASS — instance role has `AmazonSSMManagedInstanceCore` (pre-existing) |
| **R5**: Credentials supplied via TF_VAR_ env vars | AC-AUA-R5a (user_data render), AC-AUA-R5b (plan redaction) | Structural (local) | LocalStack (`test-local.sh`) | FAIL — user_data has no `BASIC_AUTH_*` lines; plan redaction test fails (variable undeclared) |
| **R5**: Password never appears in version control | AC-AUA-R7a (tfvars grep) + prod-manual | Structural (local) | LocalStack (`test-local.sh`) | PASS — current tfvars contain `allowed_ssh_cidr` (target of AC-AUA-R7a) but not `airbyte_basic_auth_password` |
| **R5**: Default password is rejected | prod-manual | Behavioural (prod) | Real AWS (SSM shell → `grep BASIC_AUTH /opt/airbyte/.env`) | FAIL — default password currently in use (no override rendered) |
| **R5**: Instance replacement on password change | AC-AUA-R5c | Structural (local) | LocalStack (`test-local.sh`) | FAIL — variable undeclared → plan error; no "must be replaced" signal |
| **R5**: Airbyte basic auth username is required | AC-AUA-R5d (negative validation) | Structural (local) | LocalStack (`test-local.sh`) | FAIL — variable undeclared → plan error ≠ validation error; post-implementation must show "required/non-empty" message |
| **R6**: local-up.sh applies successfully with zero-ingress SG | existing test-local.sh (all 25 assertions) + new AC-AUA-* | Integration (local) | LocalStack (full `local-up.sh` + `test-local.sh` flow) | Existing: PASS. New: FAIL (red phase) |
| **R6**: test-local.sh gains structural SG assertions | AC-AUA-R1a, AC-AUA-R1b, AC-AUA-R7a, AC-AUA-OUTa, AC-AUA-R4a, AC-AUA-R5a–R5d | Structural (local) | LocalStack (`test-local.sh`) | ALL FAIL (red phase) |
| **R6**: local-down.sh tears down without changes | dev flow (manual) | Integration (local) | manual `local-down.sh` | No change expected; same behaviour |
| **R6**: Prod-only verification script for SSM access | `verify-ssm-access.sh` (all checks) | Structural (prod) | Real AWS | FAIL — SG has ingress, SSM may not be online, policy not deployed |
| **R7**: `allowed_ssh_cidr` variable absent from root and module interfaces | AC-AUA-R7a (plan grep + tfvars grep) | Structural (local) | LocalStack (`test-local.sh`) | FAIL — plan references `allowed_ssh_cidr`; both tfvars contain it |
| **R7**: Existing tfvars files are updated | AC-AUA-R7a (tfvars grep sub-tests) | Structural (local) | LocalStack (`test-local.sh`) | FAIL — both local.tfvars and prod.tfvars still contain `allowed_ssh_cidr` |
| **R7**: Breaking change is documented for consumers | doc review | Design (review) | Commit message + `specs/ingestion/plan.md` amendment | n/a (not testable by script) |
| **R7**: No ingress rules replace the removed CIDR-based rules | AC-AUA-R1a (structural) | Structural (local) | LocalStack (`test-local.sh`) | FAIL — SG still has 2 inline `ingress {}` blocks |
| **R8**: ALB-sourced ingress rule can be added externally | design review (`security_group_id` output) | Design (review) | Code review | PASS — `security_group_id` output already exists; will be retained |
| **R8**: No design decisions block HTTPS termination | design review | Design (review) | Code review | PASS — Airbyte listens on :8000; ALB TLS termination is external |
| **R8**: `allowed_ssh_cidr`-style per-IP variables are not reintroduced | design review + AC-AUA-R7a | Design (review) + Structural (local) | Code review + LocalStack | Prevented by R7 implementation |

## Assertion ID Inventory

| Assertion ID | Script | Checks | Status |
|---|---|---|---|
| AC-AUA-R1a | `test-local.sh` | SG zero ingress: terraform state no `ingress {` + LocalStack EC2 `IpPermissions == []` | RED (expected) |
| AC-AUA-R1b | `test-local.sh` | SG exactly one egress: protocol `-1`, cidr `0.0.0.0/0` | RED (may partially pass) |
| AC-AUA-R7a | `test-local.sh` | Plan output no `allowed_ssh_cidr`; `envs/local.tfvars` no line; `envs/prod.tfvars` no line | RED (expected) |
| AC-AUA-OUTa | `test-local.sh` | `airbyte_url` absent; `airbyte_public_ip` absent; `ssm_access_policy_arn` present with `:policy/` | RED (expected) |
| AC-AUA-R4a | `test-local.sh` | IAM policy: 3 StartSession resources, own-session scoping, DescribeInstances on `*` | RED (expected) |
| AC-AUA-R5a | `test-local.sh` | user_data contains `BASIC_AUTH_USERNAME=` and `BASIC_AUTH_PASSWORD=` | RED (expected) |
| AC-AUA-R5b | `test-local.sh` | plan with sentinel password → output must NOT contain sentinel | RED (expected) |
| AC-AUA-R5c | `test-local.sh` | same plan reports `aws_instance.airbyte` "must be replaced" | RED (expected) |
| AC-AUA-R5d | `test-local.sh` | negative validation: empty username → plan fails with "required/non-empty" error | RED (expected) |
| `verify-ssm-access.sh` | `verify-ssm-access.sh` | Instance running + SSM Online + SG zero ingress + one egress | RED (expected) |

## Pre-existing Assertions (Ingestion Spec — must PASS in red phase)

| Assertion ID | Checks |
|---|---|
| AC-R1a | Raw API ops (s3 list, ec2 describe, sts get-caller) |
| AC-R1b | Raw S3 create/list/delete bucket; boundary invalid name |
| AC-R2-local | Terraform bucket: name, versioning (Enabled), encryption (AES256), public access block |
| AC-R3-local | Terraform state: airbyte EC2 instance, IAM role, instance profile; LocalStack: EC2, IAM profiles, role policies |
| AC-R5 | Prod plan: bucket name, no localhost endpoint override |
| BOUNDARY + EDGE | Various boundary/edge tests throughout |

All 25 pre-existing assertions (exact count may vary slightly with LocalStack state) MUST continue to PASS when this test script runs in red phase.

## Notes

- **Red-phase signalling**: ALL 9 new AC-AUA-* assertions (plus the 3 sub-assertions within them) are expected to FAIL. This is the correct TDD red phase — the tests describe what the system MUST do, but the implementation (Stage 4) has not yet been written.
- **`verify-ssm-access.sh`**: Entirely red. Requires live AWS with the Airbyte instance running and the new IAM policy deployed.
- **SSM not emulated**: LocalStack does not support SSM. All `test-local.sh` assertions are **structural** (terraform state, IAM policy JSON, SG shape, plan output, user_data render). Behavioural SSM tests are prod-manual only.
- **`${}` escaping**: The IAM policy check in AC-AUA-R4a looks for the literal string `${aws:username}` in the JSON (Terraform `$${aws:username}` renders to `${aws:username}` in the policy document). The python3 parser handles both forms.
- **user_data base64**: AC-AUA-R5a decodes the `user_data` attribute from terraform state using python3's `base64.b64decode`. Fallback to plain `terraform state show` text grep if JSON path fails.
- **Expected-failure idiom**: Assertions for absent outputs (AC-AUA-OUTa) and negative validation (AC-AUA-R5d) use `if command; then fail; else pass; fi` inside `set -euo pipefail` — the `if` safely suppresses `set -e` for the condition.
- **Shared plan invocation**: AC-AUA-R5b and AC-AUA-R5c run a single `terraform plan` with the sentinel password and check both redaction AND replacement from the same output, avoiding duplicate plan invocations.
