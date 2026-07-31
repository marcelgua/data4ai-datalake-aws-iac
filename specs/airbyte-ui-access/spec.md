# Secure Airbyte UI Access Specification

## Purpose
This capability eliminates public network exposure of the self-managed Airbyte EC2 instance by replacing IP-allowlist-based ingress with AWS Systems Manager Session Manager for both UI access and shell access. It addresses the operational risk of a dynamic home IP rotting the `allowed_ssh_cidr` allowlist, the security risk of Airbyte's default HTTP Basic Auth credentials, and the broader risk of exposing a data-plane service on the public internet. The capability serves the two-person data engineering team who need reliable, secure access to the Airbyte UI and shell without depending on a stable IP address or managing long-lived SSH keys. It establishes IAM-based access control as the single gating mechanism and deliberately leaves room for a future internet-facing ALB + OIDC path.

## Spec Delta / Amendments to ingestion spec

This spec **amends** the following requirements and implementation details from `specs/ingestion/`:

| Ingestion Ref | Amendment |
|---|---|
| **R4** (Network and Access Integration) | The security group for the Airbyte EC2 instance no longer permits inbound traffic on ports 8000 (Airbyte UI) or 22 (SSH) from any CIDR. Network access to the Airbyte UI and shell is provided exclusively via AWS SSM Session Manager. Egress (`0.0.0.0/0` all protocols) is unchanged. |
| **AGENTS.md** gotcha: "Same CIDR for SSH (22) and Airbyte UI (8000)" | This gotcha is **obsolete**. `var.allowed_ssh_cidr` is removed entirely. No single CIDR controls ingress because there are no ingress rules. |
| **AGENTS.md** gotcha: `var.key_name` / SSH key | The EC2 key pair is **retained as an inert break-glass artifact** (no SG rule exposes port 22). The key pair may remain attached to the instance but must not be used as a primary access path. |
| **R1–R3, R5–R7** of ingestion spec | No amendment. The S3 bucket posture, versioning, encryption, environment toggle, Hive partitioning, and AVRO format requirements are untouched. |
| `outputs.tf` `airbyte_url` and `airbyte_public_ip` | Both removed — the URL `http://<public_ip>:8000` implies public access that no longer exists, and the public IP is no longer a useful identifier once direct access is disabled. The module-level `public_ip` output is also removed (its only consumers were these two root outputs). The instance still receives a public IP at the infrastructure level (required for egress via the IGW — SSM Agent reachability depends on it), but it is no longer advertised as an output. Replaced by SSM-based access instructions. |
| `envs/prod.tfvars` `allowed_ssh_cidr` | Removed. This is a **breaking change** to the root and module variable interfaces. |

## Requirements

### R1: Zero Public Ingress on Airbyte Security Group
The security group attached to the Airbyte EC2 instance SHALL have **no inbound rules** for any port. Egress SHALL remain unchanged (`0.0.0.0/0`, all protocols) so that the instance can reach package repositories, Docker Hub, the Airbyte platform release assets on GitHub, and external data sources.

#### Scenario: Security group has no ingress rules in production
- GIVEN the Terraform configuration is applied with `environment = "prod"`
- WHEN the Airbyte security group is inspected via the EC2 API
- THEN the security group SHALL have zero inbound (ingress) rules
- AND the security group SHALL have exactly one outbound (egress) rule allowing all traffic to `0.0.0.0/0`

#### Scenario: Security group has no ingress rules in local environment
- GIVEN the Terraform configuration is applied with `environment = "local"`
- WHEN the Airbyte security group is inspected via LocalStack's EC2 API
- THEN the mocked security group SHALL structurally reflect zero ingress rules
- AND the mocked security group SHALL structurally reflect the unchanged egress rule

#### Scenario: Instance retains a public IP but no port is reachable
- GIVEN the Airbyte EC2 instance is running in production
- WHEN an external host attempts to connect to the instance's public IP on port 8000 or 22
- THEN the connection SHALL be refused or time out (no SG rule permits it)
- AND the instance SHALL still be able to initiate outbound connections (Docker pulls, S3 writes, source reads)

#### Scenario: Break-glass key pair is retained but inert
- GIVEN `var.key_name` is set to a valid EC2 key pair name
- WHEN the EC2 instance is launched
- THEN the key pair SHALL be associated with the instance
- AND no security group rule SHALL expose port 22 to any CIDR
- AND the key pair SHALL serve only as a documented break-glass recovery artifact (e.g., in case SSM Agent fails to start)

---

### R2: Session Manager Port-Forwarding for Airbyte UI Access
The system SHALL provide a helper script that uses AWS SSM Session Manager to forward a local port to the Airbyte UI (tcp/8000) on the EC2 instance, enabling browser access without any public ingress.

#### Scenario: Successful port-forward session to Airbyte UI
- GIVEN the Airbyte EC2 instance is running and the SSM Agent is online
- AND the caller has the required IAM permissions (see R4)
- AND the AWS CLI and `session-manager-plugin` are installed on the caller's host
- WHEN the helper script is invoked with the `ui` subcommand
- THEN the script SHALL resolve the EC2 instance ID from the Terraform state or outputs
- AND the script SHALL start an SSM port-forwarding session mapping `localhost:8000` to the instance's port 8000
- AND the Airbyte UI SHALL be accessible at `http://localhost:8000` for the duration of the session

#### Scenario: Instance not found or not running
- GIVEN the Terraform state exists but the Airbyte EC2 instance has been terminated or stopped
- WHEN the helper script is invoked with the `ui` subcommand
- THEN the script SHALL exit with a non-zero code
- AND the script SHALL print an actionable error message indicating the instance ID, its current state (if determinable), and a suggestion to run `terraform apply`

#### Scenario: session-manager-plugin not installed
- GIVEN the `session-manager-plugin` binary is not in the caller's PATH
- WHEN the helper script is invoked with any subcommand
- THEN the script SHALL detect the missing plugin before attempting to connect
- AND the script SHALL exit with a non-zero code and print installation instructions
- AND the script SHALL include the URL for the plugin download page

#### Scenario: AWS credentials missing or expired
- GIVEN the caller's AWS credentials are not available (no env vars, no SSO token, no instance profile)
- WHEN the helper script is invoked with any subcommand
- THEN the SSM `start-session` call SHALL fail with an AWS auth error
- AND the script SHALL propagate the error message to stderr and exit non-zero

#### Scenario: Terraform state not available for instance ID resolution
- GIVEN the Terraform state file does not exist or cannot be read (e.g., different working directory)
- WHEN the helper script is invoked
- THEN the script SHALL attempt to resolve the instance ID via `terraform output -raw airbyte_instance_id`
- AND if that fails, the script SHALL fall back to searching for the instance by its known `Name` tag
- AND if both methods fail, the script SHALL exit with an error instructing the user to run `terraform apply` or set the correct working directory

---

### R3: Session Manager Shell Access Replacing SSH
The system SHALL provide shell access to the Airbyte EC2 instance via SSM Session Manager, fully replacing SSH-based shell access for all operational tasks. The helper script from R2 SHALL support a `shell` subcommand that starts an interactive SSM session.

#### Scenario: Successful SSM shell session
- GIVEN the Airbyte EC2 instance is running and the SSM Agent is online
- AND the caller has the required IAM permissions (see R4)
- WHEN the helper script is invoked with the `shell` subcommand
- THEN the script SHALL start an interactive SSM session on the instance
- AND the caller SHALL be presented with a shell prompt as the `ssm-user` (or `ec2-user` via `sudo`)
- AND the session SHALL use the `SSM-SessionManagerRunShell` SSM document by default

#### Scenario: Shell access through the same script entrypoint
- GIVEN the helper script supports both `ui` and `shell` subcommands
- WHEN the script is invoked without arguments or with an invalid subcommand
- THEN the script SHALL print a usage message listing `ui` and `shell` as valid subcommands
- AND the script SHALL exit with a non-zero code

#### Scenario: SSH on port 22 is permanently unavailable
- GIVEN the security group has no ingress rule for port 22
- WHEN any external host attempts to connect via SSH to the instance
- THEN the connection SHALL be refused at the network level (no SG rule permits it)
- AND there SHALL be no alternative SSH path available (SSM is the sole remote shell mechanism)

---

### R4: IAM Least-Privilege Policy for Human Access
The system SHALL define a Terraform-managed IAM policy that grants the minimum permissions necessary for a human operator to start and manage SSM sessions on the Airbyte EC2 instance. The policy SHALL be scoped to the specific instance and the required SSM documents, and its ARN SHALL be exposed as a Terraform output for attachment to IAM users or groups.

#### Scenario: Policy grants StartSession and TerminateSession on the Airbyte instance only
- GIVEN the Terraform configuration is applied in production
- WHEN the IAM policy is inspected
- THEN the policy SHALL allow `ssm:StartSession` on the Airbyte instance ARN and on the SSM documents `SSM-SessionManagerRunShell` and `AWS-StartPortForwardingSession`
- AND the policy SHALL allow `ssm:TerminateSession` scoped to sessions owned by the caller (via `ssm:resourceTag/aws:ssmmessages:session-id` or equivalent condition)
- AND the policy SHALL NOT grant `ssm:StartSession` on arbitrary instances outside the Airbyte instance ARN
- AND the policy SHALL allow `ec2:DescribeInstances` (resource `*`) so users can discover the instance state

#### Scenario: Policy ARN is available as a Terraform output
- GIVEN `terraform apply` has completed in production
- WHEN `terraform output ssm_access_policy_arn` is executed
- THEN the output SHALL return the ARN of the IAM policy created by this requirement
- AND the output description SHALL document that this policy must be attached to IAM users or groups who need Airbyte access

#### Scenario: Policy is not created in local environment
- GIVEN `environment = "local"`
- WHEN `terraform apply` is executed
- THEN the SSM access policy resource SHALL be conditionally created (gated on `!local.is_local`, or created but expected to be non-functional against LocalStack's SSM emulation)
- AND the `ssm_access_policy_arn` output SHALL render as an empty string or a placeholder

#### Scenario: No SSM permissions are needed for the instance role itself
- GIVEN the instance already has `AmazonSSMManagedInstanceCore` attached (pre-existing)
- WHEN the new IAM policy from this requirement is created
- THEN the new policy SHALL be a **user-facing** policy (attached to human IAM principals)
- AND the pre-existing instance role SHALL NOT be modified by this requirement

---

### R5: Airbyte Basic Auth Hardening
The system SHALL override Airbyte's default HTTP Basic Auth **username and password** with values supplied via Terraform variables that are never committed to version control. The password variable SHALL be **sensitive**; the username variable SHALL be **required** (no default) and validated non-empty. Both values SHALL be written into the Airbyte `.env` file by the EC2 `user_data` script during bootstrap.

#### Scenario: Credentials are supplied via TF_VAR_ environment variables
- GIVEN a sensitive Terraform variable `var.airbyte_basic_auth_password` is defined with `sensitive = true`
- AND a required Terraform variable `var.airbyte_basic_auth_username` is defined with no default and a non-empty validation
- AND the values are supplied via `TF_VAR_airbyte_basic_auth_password` and `TF_VAR_airbyte_basic_auth_username` at apply time
- WHEN `terraform apply` is executed
- THEN both values SHALL be injected into the `user_data` template rendering
- AND the rendered `user_data` SHALL append `BASIC_AUTH_PASSWORD=<value>` and `BASIC_AUTH_USERNAME=<value>` (or the equivalent Airbyte env vars) to the instance's `.env` file
- AND the password value SHALL NOT appear in `terraform plan` output or in the Terraform state file in cleartext (it SHALL be marked sensitive)
- AND if `var.airbyte_basic_auth_username` is unset or empty, `terraform validate`/`plan` SHALL fail with a descriptive error

#### Scenario: Password never appears in version control
- GIVEN the `prod.tfvars` file is committed to git
- WHEN the file is inspected
- THEN the file SHALL NOT contain `airbyte_basic_auth_password` or `airbyte_basic_auth_username`
- AND the `.gitignore` SHALL already exclude `.env` and `*.pem` files (pre-existing; no change needed)
- AND the `TF_VAR_airbyte_basic_auth_password` and `TF_VAR_airbyte_basic_auth_username` values SHALL only exist in the operator's shell environment or an untracked credentials file

#### Scenario: Default password is rejected
- GIVEN the Airbyte platform's default password is `password` (the well-known default for the pinned version)
- WHEN the instance bootstraps
- THEN the rendered user_data SHALL override `BASIC_AUTH_PASSWORD` (or equivalent) with the value from `var.airbyte_basic_auth_password`
- AND if `var.airbyte_basic_auth_password` is empty or unset, the `user_data` script SHALL log a warning to `/var/log/user-data.log` indicating the default password is in use
- AND the script SHALL NOT fail hard (to avoid preventing bootstrap), but the warning SHALL be prominent

#### Scenario: Instance replacement on password change
- GIVEN the Airbyte EC2 instance is running and `var.airbyte_basic_auth_password` or `var.airbyte_basic_auth_username` is changed
- WHEN `terraform apply` is executed
- THEN Terraform SHALL detect that `user_data` has changed and SHALL plan to **destroy and recreate** the EC2 instance
- AND the operator SHALL be warned (via spec documentation, not Terraform output) that changing the password discards Airbyte configuration (connectors, destinations, connections) stored on the instance's Docker volumes

#### Scenario: Airbyte basic auth username is required
- GIVEN the Airbyte `.env` file supports a `BASIC_AUTH_USERNAME` variable (version-dependent)
- WHEN `terraform plan` or `apply` is executed
- THEN `var.airbyte_basic_auth_username` SHALL be required (no default value)
- AND the variable SHALL fail validation if set to an empty string
- AND the rendered `user_data` SHALL always write an explicit `BASIC_AUTH_USERNAME` to the `.env` file
- AND the Airbyte default username (`airbyte`) SHALL NOT be relied upon under any circumstances

---

### R6: Local Environment Parity
The existing local development scripts (`scripts/local-up.sh`, `scripts/test-local.sh`, `scripts/local-down.sh`) SHALL continue to function without modification to their core workflow. Since SSM is not emulated by LocalStack, local tests SHALL assert **structural** properties of the security posture rather than functional SSM behavior.

#### Scenario: local-up.sh applies successfully with zero-ingress security group
- GIVEN `environment = "local"` and LocalStack is running
- WHEN `./scripts/local-up.sh` is executed
- THEN `terraform apply` SHALL exit 0
- AND the Airbyte EC2 module SHALL create a security group resource in LocalStack
- AND the security group SHALL structurally have no ingress rules (verifiable via `terraform state show` or the LocalStack EC2 API)

#### Scenario: test-local.sh gains structural security-group assertions
- GIVEN `./scripts/local-up.sh` has completed successfully
- WHEN `./scripts/test-local.sh` is executed
- THEN the test script SHALL include new assertions that verify:
  - The security group attached to the Airbyte instance has zero inbound (ingress) rules
  - The `allowed_ssh_cidr` variable name does NOT appear in `terraform plan` output
  - The `airbyte_url` and `airbyte_public_ip` outputs are absent
- AND all pre-existing assertions (R1, R2, R3, R5 from the ingestion spec) SHALL continue to pass

#### Scenario: local-down.sh tears down without changes
- GIVEN `./scripts/local-up.sh` has completed
- WHEN `./scripts/local-down.sh` is executed
- THEN `terraform destroy` SHALL exit 0
- AND `docker compose down -v` SHALL exit 0
- AND no new resources or dependencies SHALL prevent clean teardown

#### Scenario: Prod-only verification script for SSM access
- GIVEN the Airbyte EC2 instance is running in production
- AND the operator has the required IAM permissions
- WHEN a new script `scripts/verify-ssm-access.sh` (or equivalent name) is executed against real AWS
- THEN the script SHALL perform read-only checks:
  - The EC2 instance is in the `running` state
  - The SSM Agent is online (via `ssm describe-instance-information`)
  - The security group has zero ingress rules
- AND the script SHALL NOT start an interactive session (it is non-interactive and read-only)
- AND the script SHALL follow the same bash conventions as `scripts/verify-airbyte-s3.sh` (`set -euo pipefail`, colour output, pass/fail/skip counters, summary)

---

### R7: Removal of `allowed_ssh_cidr` Variable
The `allowed_ssh_cidr` variable SHALL be removed from both the root module (`variables.tf`) and the `airbyte_ec2` child module (`modules/airbyte_ec2/variables.tf`). Its sole consumer — the two ingress rules in the security group resource — SHALL be deleted. This is a **breaking change** to the module interface.

#### Scenario: Variable is absent from root and module interfaces
- GIVEN the refactored Terraform code
- WHEN `terraform plan` is executed with any tfvars file
- THEN the plan SHALL NOT reference `var.allowed_ssh_cidr`
- AND `terraform validate` SHALL pass without the variable being set in tfvars

#### Scenario: Existing tfvars files are updated
- GIVEN `envs/prod.tfvars` previously contained `allowed_ssh_cidr = "177.39.123.94/32"`
- WHEN the refactored code is applied
- THEN the tfvars file SHALL have that line removed
- AND no replacement variable SHALL be introduced that serves the same purpose of IP-allowlisting

#### Scenario: Breaking change is documented for consumers
- GIVEN the module interface contract defined in `specs/ingestion/plan.md` (table: `airbyte_ec2` inputs include `allowed_ssh_cidr`)
- WHEN this spec is implemented
- THEN the plan.md SHALL be updated to remove `allowed_ssh_cidr` from the module contract table
- AND the CHANGELOG or commit message SHALL call out the breaking change explicitly

#### Scenario: No ingress rules replace the removed CIDR-based rules
- GIVEN the `aws_security_group.airbyte` resource is refactored
- WHEN the resource definition is inspected
- THEN the resource SHALL contain **only** the egress block
- AND there SHALL be zero `ingress {}` blocks
- AND there SHALL be no dynamic ingress block that conditionally adds back a CIDR-based rule

---

### R8: Forward Compatibility for ALB + OIDC Access
The security group and module structure SHALL NOT foreclose the future addition of an internet-facing Application Load Balancer with HTTPS and OIDC authentication. The module SHALL continue to output its `security_group_id`, enabling the root module to attach additional ingress rules sourced from an ALB security group without modifying the child module.

#### Scenario: ALB-sourced ingress rule can be added externally
- GIVEN the Airbyte module outputs `security_group_id`
- AND an ALB security group exists in the same VPC
- WHEN a future `aws_vpc_security_group_ingress_rule` (or `aws_security_group_rule`) resource is added to the root module
- THEN the new rule SHALL be able to reference `module.airbyte_ec2.security_group_id` without modifying the child module
- AND the rule SHALL allow ingress on port 8000 sourced from the ALB's security group

#### Scenario: No design decisions block HTTPS termination
- GIVEN the current architecture terminates Airbyte UI traffic at localhost:8000 (via SSM port-forwarding)
- WHEN an ALB is introduced in the future
- THEN the Airbyte service inside the EC2 instance SHALL NOT need modification (it already listens on port 8000)
- AND the ALB SHALL be able to terminate TLS and forward HTTP to the instance on port 8000
- AND the Airbyte basic auth credentials (R5) SHALL remain as an additional layer of defense behind OIDC

#### Scenario: `allowed_ssh_cidr`-style per-IP variables are not reintroduced
- GIVEN the ALB feature is implemented in the future
- WHEN the ingress rule for port 8000 is added
- THEN the rule SHALL use a security group reference (ALB SG), NOT a hardcoded CIDR block
- AND the design SHALL NOT reintroduce a variable like `allowed_ssh_cidr` for this purpose

---

## Out of Scope

The following are explicitly **not** addressed by this specification and are deferred to future work:

1. **Internet-facing ALB + HTTPS + OIDC authentication.** This is the planned mid-term upgrade path once a domain name is acquired. The spec ensures forward compatibility (R8) but does not design or implement the ALB.
2. **TLS termination on the Airbyte EC2 instance itself.** Airbyte Community edition does not provide native TLS; TLS will be terminated at the ALB when that feature is added.
3. **AWS WAF integration.** Any web application firewall rules for the future ALB are out of scope.
4. **S3 backend for Terraform state + DynamoDB locking.** Already noted as a follow-up in the ingestion plan; unchanged by this spec.
5. **SSO inside Airbyte.** This is an Enterprise (paid) Airbyte feature. The Community edition's HTTP Basic Auth is the only authentication mechanism available; this spec hardens it (R5) but does not replace it.
6. **Airbyte version upgrade or migration to `abctl`.** The pinned version and Docker Compose deployment method are preserved; a migration to `abctl` / Kubernetes is a separate decision.
7. **Managing IAM users/groups in Terraform.** The spec defines the IAM policy (R4) but stops at outputting its ARN; attaching the policy to IAM principals is a manual operational step (or belongs in a separate IAM-management repository).
8. **Automatic Airbyte configuration backup.** The spec documents (R5 scenario) that user_data changes force instance replacement, which discards Airbyte config. A backup/restore mechanism for Airbyte's Docker volumes is out of scope.

## Testability Notes

| Requirement | LocalStack (bash) | Prod-only (manual / read-only script) | Notes |
|---|---|---|---|
| **R1** (zero ingress) | ✅ `test-local.sh` verifies SG has 0 ingress rules via LocalStack EC2 API or `terraform state show` | ✅ `verify-ssm-access.sh` verifies same against real AWS | Structural assertion; no SSM emulation needed |
| **R2** (port-forward UX) | ❌ SSM not emulated by LocalStack | ✅ Manual test: run `ssm-connect.sh ui`, open browser at `localhost:8000` | Script error-handling paths testable in local with mocks |
| **R3** (shell UX) | ❌ SSM not emulated | ✅ Manual test: run `ssm-connect.sh shell`, verify prompt | Same script; shared error handling from R2 |
| **R4** (IAM policy) | ⚠️ Policy created structurally in LocalStack; policy content verifiable via `terraform state show` | ✅ Policy ARN output; `iam simulate-principal-policy` can validate permissions | IAM policy evaluation in LocalStack is limited |
| **R5** (basic auth) | ⚠️ `user_data` renders structurally (template output inspectable via `terraform state`); password marked `sensitive` — terraform plan redacts it | ✅ Manual: fetch `.env` from instance via SSM, verify password is not default | SSM reachability is a prerequisite for prod verification of R5 |
| **R6** (local parity) | ✅ Full `local-up.sh` + `test-local.sh` flow must pass | N/A | Core dev workflow unchanged |
| **R7** (variable removal) | ✅ `terraform validate -var-file=envs/local.tfvars` passes without `allowed_ssh_cidr` | ✅ `terraform validate -var-file=envs/prod.tfvars` passes without `allowed_ssh_cidr` | Caught at plan time |
| **R8** (forward compat) | ⚠️ N/A (no ALB in local) | ⚠️ Verified by design review: `security_group_id` output exists and is usable as a reference | Not a runtime behavior; a design constraint |

### New files expected (referenced by this spec)

| File | Purpose |
|---|---|
| `scripts/ssm-connect.sh` | Helper script: `ui` (port-forward 8000) and `shell` (interactive session) subcommands |
| `scripts/verify-ssm-access.sh` | Prod-only read-only script: instance running, SSM agent online, SG has zero ingress |

### Existing files requiring modification

| File | Change |
|---|---|
| `variables.tf` (root) | Remove `allowed_ssh_cidr`. Add `airbyte_basic_auth_password` (sensitive, default `""`). Add `airbyte_basic_auth_username` (**required**, no default, non-empty validation). |
| `modules/airbyte_ec2/variables.tf` | Remove `allowed_ssh_cidr`. Add `airbyte_basic_auth_password` and `airbyte_basic_auth_username` (required, non-empty). |
| `main.tf` (root) | Remove `allowed_ssh_cidr` argument from `module.airbyte_ec2` block. Pass new `airbyte_basic_auth_password` and `airbyte_basic_auth_username` variables. Add `aws_iam_policy` resource for human SSM access (R4). |
| `modules/airbyte_ec2/main.tf` | Remove both `ingress {}` blocks from `aws_security_group.airbyte`. Keep `egress {}` unchanged. Update `templatefile()` call to pass basic auth variables. |
| `modules/airbyte_ec2/templates/user_data.sh.tftpl` | Append `BASIC_AUTH_PASSWORD` and `BASIC_AUTH_USERNAME` to `.env` after the staging context block. Add a warning log if password is empty/default. |
| `outputs.tf` (root) | Remove `airbyte_url` and `airbyte_public_ip`. Add `ssm_access_policy_arn`. |
| `modules/airbyte_ec2/outputs.tf` | Remove the `public_ip` output (no remaining consumers). Keep `instance_id`, `security_group_id`, `iam_role_name`. |
| `envs/prod.tfvars` | Remove `allowed_ssh_cidr` line. |
| `envs/local.tfvars` | Remove `allowed_ssh_cidr` line. |
| `scripts/test-local.sh` | Add assertions: SG ingress count = 0; `allowed_ssh_cidr` absent from plan; `airbyte_url` output absent or non-public. |
| `specs/ingestion/plan.md` | Update module contract table: remove `allowed_ssh_cidr` from `airbyte_ec2` inputs. |
| `AGENTS.md` | Remove or strike through the gotcha "Same CIDR for SSH (22) and Airbyte UI (8000)." Add gotcha about user_data changes forcing instance replacement. |
| `README.md` | Replace SSH/Airbyte URL access instructions with SSM-based access instructions. |

## Open Decisions

The following judgment calls are embedded in the spec and are presented for human review:

1. **IAM policy location.** The spec places the human-facing SSM IAM policy (`aws_iam_policy`) in the **root module** (not the `airbyte_ec2` child module), because it references both the instance ID and the account ID (`data.aws_caller_identity`). This is a lightweight approach that avoids polluting the child module with cross-cutting user-access concerns. **Alternative considered:** a standalone documented policy JSON in `docs/` that users apply manually. **Chosen:** Terraform-managed policy + output ARN, because the repo convention is to manage all AWS resources through Terraform.

2. **Fate of `key_name`.** The spec retains `var.key_name` as a break-glass artifact. The key is attached to the EC2 instance but no SG rule exposes port 22. If the SSM Agent fails, the operator would need to temporarily add an SG ingress rule (outside Terraform, as a break-glass operation) to SSH in. **Alternative considered:** removing `key_name` entirely for a cleaner posture. **Chosen:** retained, because SSM Agent failure on a self-managed EC2 with no other access path is an unrecoverable state without it.

3. **Helper script shape.** The spec consolidates UI port-forwarding and shell access into a single script (`scripts/ssm-connect.sh`) with `ui` and `shell` subcommands. **Alternative considered:** two separate scripts (`ssm-ui.sh` and `ssm-shell.sh`). **Chosen:** single script, because the setup logic (instance ID resolution, AWS CLI checks, plugin checks) is identical; subcommands keep the UX simple without duplicating code.

4. **Basic auth username configurability.** ~~Optional~~ → **RESOLVED (human decision): the username is a required variable** — no default, non-empty validation, always written explicitly to `.env`. The Airbyte default username (`airbyte`) is never relied upon.

5. **`airbyte_public_ip` output.** ~~Retained~~ → **RESOLVED (human decision): dropped** from the root outputs, along with the module-level `public_ip` output (no remaining consumers). The instance still receives a public IP at the infrastructure level (needed for egress/IGW — SSM Agent depends on it — and for the future ALB target), but it is no longer advertised as an output.
