# Plan: airbyte-ui-access

## Architecture

### Directory Structure (delta vs ingestion plan)

```
data4ai-datalake-aws-iac/
├── main.tf                         # + data.aws_caller_identity, aws_iam_policy.ssm_access; module args updated
├── variables.tf                    # - allowed_ssh_cidr; + airbyte_basic_auth_username (required), + airbyte_basic_auth_password (sensitive)
├── outputs.tf                      # - airbyte_url, - airbyte_public_ip; + ssm_access_policy_arn
├── envs/
│   ├── local.tfvars                # - allowed_ssh_cidr
│   └── prod.tfvars                 # - allowed_ssh_cidr (breaking change)
├── modules/airbyte_ec2/
│   ├── main.tf                     # SG: both ingress blocks deleted (egress unchanged); templatefile() gains auth args
│   ├── variables.tf                # - allowed_ssh_cidr; + auth vars (no default; username non-empty)
│   ├── outputs.tf                  # - public_ip (no remaining consumers)
│   └── templates/user_data.sh.tftpl# + BASIC_AUTH_* append to .env; + empty-password warning
├── scripts/
│   ├── local-up.sh                 # + exports dummy TF_VAR_airbyte_basic_auth_* (local-only, inert)
│   ├── local-down.sh               # + same dummy exports (destroy needs required vars too)
│   ├── test-local.sh               # + dummy TF_VARs; + structural assertions (SG, outputs, IAM policy, user_data, redaction)
│   ├── ssm-connect.sh              # NEW: ui (port-forward 8000) / shell (interactive) subcommands
│   └── verify-ssm-access.sh        # NEW: prod-only read-only posture checks
└── specs/airbyte-ui-access/{spec,plan}.md
```

### Component Layout (textual diagram)

```
                        ┌──────────────────────────────────────────────┐
                        │               Operator host                  │
                        │  scripts/ssm-connect.sh  ui | shell          │
                        │   1. validate subcommand (usage first)       │
                        │   2. preflight: aws CLI, session-manager-    │
                        │      plugin, sts get-caller-identity         │
                        │   3. resolve instance ID: terraform output   │
                        │      → fallback: Name-tag describe-instances │
                        └───────┬──────────────────────────────────────┘
                                │ aws ssm start-session (HTTPS 443)
                                │  • ui:    --document-name AWS-StartPortForwardingSession
                                │           --parameters portNumber=8000,localPortNumber=$LOCAL_PORT
                                │  • shell: default doc SSM-SessionManagerRunShell
                                ▼
              ┌───────────────────────────────────┐
              │ AWS SSM service (control plane)   │   IAM check:
              │                                   │   aws_iam_policy.ssm_access on caller
              └───────────────▲───────────────────┘
                              │ outbound-only data channel (agent-initiated, 443)
              ┌───────────────┴───────────────────┐
              │ EC2: SSM Agent → ssmmessages      │
              │  SG: ZERO ingress, 1 egress (all) │
              │  public IP retained (egress/IGW)  │
              │  airbyte-proxy :8000 (basic auth  │
              │   from rendered .env override)    │
              └───────────────────────────────────┘
   Browser → http://localhost:$LOCAL_PORT ──(tunnel)──► instance:8000
```

### Data Flow

1. **user_data rendering path (R5)**: operator sets `TF_VAR_airbyte_basic_auth_username` /
   `TF_VAR_airbyte_basic_auth_password` → root `variables.tf` (username validated non-empty at
   plan time) → `module.airbyte_ec2` inputs → `templatefile(user_data.sh.tftpl, {…,
   basic_auth_username, basic_auth_password})` → `aws_instance.airbyte.user_data` (sensitivity
   propagates → redacted in plan) → EC2 boot → cloud-init (logged to `/var/log/user-data.log`)
   → fetches pinned Airbyte `.env` → appends `BASIC_AUTH_USERNAME` / `BASIC_AUTH_PASSWORD`
   (compose-go dotenv: last occurrence in `--env-file` wins → overrides shipped
   `airbyte`/`password` defaults) → `docker compose --env-file .env up -d` → `airbyte-proxy`
   enforces the credentials on :8000. Empty password → prominent warning in user-data log,
   bootstrap continues (warn-don't-fail per R5).
2. **SSM session establishment path (R2/R3)**: operator runs `ssm-connect.sh ui|shell` →
   subcommand validated (usage + non-zero on invalid, before any dependency checks) → preflight
   (`aws` CLI, `session-manager-plugin`, `sts get-caller-identity`) → instance ID resolved
   (terraform output → Name-tag fallback) → instance state verified `running` →
   `aws ssm start-session` → SSM control plane checks caller IAM policy (`aws_iam_policy.ssm_access`
   attached out-of-band to the operator principal) → SSM Agent (already polling `ssmmessages`
   outbound on 443 — no SG ingress involved) opens the data channel → `session-manager-plugin`
   relays: `localhost:$LOCAL_PORT ↔ instance:8000` (ui) or interactive TTY as `ssm-user` (shell).

## Component Breakdown

- **Root `variables.tf`**: remove `allowed_ssh_cidr` (R7). Add `airbyte_basic_auth_username`
  (`string`, **no default**, validation `length(...) > 0` — "the Airbyte default is never used")
  and `airbyte_basic_auth_password` (`string`, `sensitive = true`, `default = ""`; empty triggers
  the R5 bootstrap warning, not a validation failure). No other variables change.
- **Root `main.tf`**: drop `allowed_ssh_cidr` from `module.airbyte_ec2`; pass the two auth
  variables; add `data.aws_caller_identity.current`, `data.aws_iam_policy_document.ssm_access`,
  `resource "aws_iam_policy" "ssm_access"` (R4; placed at root per spec Open Decision 1).
  `data.aws_caller_identity` works against LocalStack STS (test account) and adds no new
  plan-time credential requirement in prod (the AMI data source already requires real creds
  for prod plans).
- **Root `outputs.tf`**: remove `airbyte_url` and `airbyte_public_ip` (imply public access that
  no longer exists). Add `ssm_access_policy_arn` with a description stating it must be attached
  to IAM users/groups needing Airbyte access, and that in local it renders a LocalStack mock ARN
  (placeholder). Keep `airbyte_instance_id` (consumed by `ssm-connect.sh`).
- **`modules/airbyte_ec2/variables.tf`**: remove `allowed_ssh_cidr`; add both auth variables with
  no defaults (root always passes explicitly); non-empty validation on username only (module
  password must accept `""` to preserve warn-don't-fail semantics).
- **`modules/airbyte_ec2/main.tf`**: delete both `ingress {}` blocks from
  `aws_security_group.airbyte`; keep the single `egress {}` unchanged; update the SG description
  ("no public ingress — SSM Session Manager only"). Extend the `templatefile()` argument map with
  `basic_auth_username` / `basic_auth_password`. AMI lookup gating (`count = var.ami_id == "" ? 1 : 0`)
  and the LocalStack dummy-AMI injection are untouched (AGENTS.md gotcha).
- **`modules/airbyte_ec2/outputs.tf`**: remove `public_ip`. Keep `instance_id`,
  `security_group_id` (R8 forward-compat), `iam_role_name`.
- **`user_data.sh.tftpl`**: after the staging-context `cat >> .env` block, append a second heredoc
  writing `BASIC_AUTH_USERNAME=${basic_auth_username}` and `BASIC_AUTH_PASSWORD=${basic_auth_password}`
  (single-`${}` — these are Terraform template inputs; `$${VAR}` escaping remains reserved for
  bash-runtime variables). Wrap a `%{ if basic_auth_password == "" }…%{ endif }` template
  conditional around a prominent `echo WARNING` line so the warning exists only when the password
  is empty (renders nothing otherwise).
- **`envs/local.tfvars` / `envs/prod.tfvars`**: delete the `allowed_ssh_cidr` lines (and the
  prod comment referencing it). No replacement IP-allowlist variable is introduced (R7).
- **`scripts/local-up.sh` / `scripts/local-down.sh`**: export
  `TF_VAR_airbyte_basic_auth_username="${TF_VAR_airbyte_basic_auth_username:-local-dev}"` and a
  non-empty sentinel `TF_VAR_airbyte_basic_auth_password` before `terraform apply`/`destroy`
  (both commands evaluate required variables). Inert locally — LocalStack never boots the
  instance, so user_data never runs; the dummy lives only in gitignored local state.
- **`scripts/test-local.sh`**: export the same dummy TF_VARs at the top (the existing AC-R5
  prod-plan leg and all new plan invocations fail with "No value for required variable"
  otherwise). Add the structural assertions listed in Testing Strategy.
- **`scripts/ssm-connect.sh` (new)**: single entrypoint, `ui`/`shell` subcommands (spec Open
  Decision 3). See API / Interface Design.
- **`scripts/verify-ssm-access.sh` (new)**: prod-only, read-only, same bash conventions as
  `verify-airbyte-s3.sh` (`set -euo pipefail`, colour helpers, PASS/FAIL/SKIP counters,
  `fail_if_any`, summary, exit code). Checks: instance `running`; SSM Agent `Online` via
  `ssm describe-instance-information`; attached SG has zero `IpPermissions` and exactly one
  all-traffic `0.0.0.0/0` egress rule. Never starts a session.
- **Docs**: `README.md` — replace SSH/public-URL instructions with SSM access (plugin install
  link, policy attach step, `ssm-connect.sh` usage, TF_VAR instructions, replacement warning).
  `AGENTS.md` — strike the "Same CIDR for SSH (22) and Airbyte UI (8000)" gotcha; add gotcha
  "user_data changes (incl. basic-auth variables) force EC2 destroy/recreate — Airbyte config on
  docker volumes is lost". `specs/ingestion/plan.md` — targeted module-contract amendment (R7).

## Design Decisions & Resolutions

1. **Required username vs. unattended local flow** — scripts export throwaway
   `TF_VAR_airbyte_basic_auth_*` dummies; credentials never enter committed tfvars (R5);
   values are inert because LocalStack never executes user_data. Chosen over a `local.tfvars`
   default (would commit a credential-shaped value) and over making the variable optional
   (human-resolved: required).
2. **Sensitive password vs. Terraform state (SPEC-PHYSICS GAP — human sign-off required)** —
   Terraform stores rendered `user_data` in state regardless of `sensitive = true`; sensitivity
   only redacts plan/CLI output (it propagates through `templatefile()`, so the whole
   `user_data` attribute shows as `(sensitive value)`). The literal R5 wording ("SHALL NOT
   appear in the Terraform state file in cleartext") is unsatisfiable while the password is in
   user_data and state is an unencrypted local file. **Accepted resolution**: plan/CLI redaction
   (testable) + state is local and gitignored (repo convention) + the future S3-backend
   migration (ingestion plan follow-up) MUST include bucket encryption and restrictive ACLs —
   explicitly noted in README/AGENTS risk text. Alternatives considered and rejected for scope:
   SSM Parameter Store/Secrets Manager fetch at boot (adds IAM surface and a new failure mode to
   user_data; reasonable future hardening).
3. **IAM policy in local env** — created **always**, not gated on `!local.is_local`. Spec R4's
   local scenario explicitly permits "created but expected to be non-functional against
   LocalStack's SSM emulation". LocalStack (SERVICES includes iam, sts) supports
   `aws_iam_policy` and `data.aws_caller_identity`; the choice maximizes structural test
   coverage (policy JSON assertions in `test-local.sh`) at zero cost to `local-up.sh`.
4. **Instance ID resolution in scripts** — primary `terraform output -raw airbyte_instance_id`
   (scripts `cd` to the repo root first); fallback
   `aws ec2 describe-instances --filters Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-airbyte-ec2 Name=instance-state-name,Values=pending,running`.
   Tag value verified against code: root `name_prefix = "${var.project}-${var.environment}-airbyte"`
   (module input), instance tag `Name = "${var.name_prefix}-ec2"` → `data4ai-prod-airbyte-ec2`.
5. **user_data change forces instance replacement** — first prod apply: (a) SG ingress rules
   revoked in place, (b) `aws_iam_policy` created, (c) **EC2 destroyed and recreated** because of
   the user_data diff (removing SG ingress alone would NOT recreate the instance — the template
   change does). AMI drift (`most_recent = true` lookup) can compound the replacement; pinning
   `ami_id` in `envs/prod.tfvars` beforehand is recommended. Full operator checklist in
   Implementation Approach.
6. **`ssm-connect.sh` local port** — `LOCAL_PORT` env override (default 8000) so the tunnel
   never collides with anything on the operator's machine; subcommand validation happens before
   all dependency preflights (spec R3's usage scenario has no IAM/plugin preconditions).

## Data Models & Persistence

- **No new persisted data models.** Terraform state remains local + gitignored (repo convention);
  the only state-sensitivity consideration is Decision 2 above.
- **Module contract (amended)**:

  | Module | Inputs | Outputs |
  |---|---|---|
  | `s3_bucket` | `bucket_name: string`, `environment: string` | `bucket_name`, `bucket_arn` |
  | `airbyte_ec2` | `name_prefix`, `environment`, `aws_region`, `instance_type`, `ami_id`, `key_name`, `bucket_name`, `bucket_arn`, `s3_endpoint`, `airbyte_version`, `docker_compose_version`, `airbyte_basic_auth_username`, `airbyte_basic_auth_password` (sensitive), `tags` | `instance_id`, `security_group_id`, `iam_role_name` |

- **R8 forward-compat enabler**: after this change the SG has **zero inline ingress blocks**.
  That is exactly what makes a future root-level `aws_vpc_security_group_ingress_rule`
  (referencing `module.airbyte_ec2.security_group_id`, sourced from an ALB SG) safe — mixing
  inline ingress blocks with external rule resources on the same SG causes rule fighting;
  zero-inline-ingress does not. `security_group_id` output is retained for this purpose.
- **Airbyte config persistence**: unchanged — docker named volumes on the EC2 root EBS volume;
  discarded on instance replacement (see rollout checklist).

## API / Interface Design

### Root variables (HCL sketch)

```hcl
variable "airbyte_basic_auth_username" {
  description = "REQUIRED. Basic auth username for the Airbyte UI proxy. Supply via TF_VAR_airbyte_basic_auth_username or -var; never commit to tfvars."
  type        = string
  validation {
    condition     = length(var.airbyte_basic_auth_username) > 0
    error_message = "airbyte_basic_auth_username is required and must be non-empty; the Airbyte default ('airbyte') is never used."
  }
}

variable "airbyte_basic_auth_password" {
  description = "Basic auth password for the Airbyte UI proxy (sensitive). Empty = bootstrap logs a prominent warning and Airbyte keeps its shipped default. Avoid '$', quotes, backslash and ' #' sequences (compose dotenv interpolation rules)."
  type        = string
  sensitive   = true
  default     = ""
}
```

### IAM policy (R4) — verified ARN forms

```hcl
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
    # Center (federated), swap aws:username → aws:userid here and below.
    resources = ["arn:aws:ssm:*:*:session/$${aws:username}-*"]
  }
  statement {
    sid       = "AllowOpenDataChannelOwnSessions"   # required for port-forward data channel
    effect    = "Allow"
    actions   = ["ssmmessages:OpenDataChannel"]
    resources = ["arn:aws:ssm:*:*:session/$${aws:username}-*"]
  }
  statement {
    sid       = "AllowDescribeInstances"            # helper-script instance discovery
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
```

Notes: instance role (`AmazonSSMManagedInstanceCore` attachment in the module) is NOT modified
(R4 scenario). No KMS `GenerateDataKey` statement (session-data KMS encryption not configured).
`ssm:SessionDocumentAccessCheck` condition deliberately omitted — both documents are listed
explicitly as resources, matching AWS's own quickstart shape.

### `scripts/ssm-connect.sh` contract

```
Usage: scripts/ssm-connect.sh <ui|shell>
Env:   PROJECT=data4ai  ENVIRONMENT=prod  AWS_REGION=us-east-1  LOCAL_PORT=8000
Exit:  0 session closed cleanly · 1 resolution/state error · 2 usage/preflight error
Flow:  usage-check → command -v aws → command -v session-manager-plugin
       (missing → install URL https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
       → aws sts get-caller-identity (propagate AWS auth error to stderr, exit non-zero)
       → terraform output -raw airbyte_instance_id ‖ Name-tag describe-instances fallback
       → assert state == running (else: print ID + state + "run terraform apply", exit 1)
ui:    aws ssm start-session --target <id> --document-name AWS-StartPortForwardingSession \
         --parameters "{\"portNumber\":[\"8000\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
       + banner "Airbyte UI → http://localhost:${LOCAL_PORT} (Ctrl-C to close tunnel)"
shell: aws ssm start-session --target <id>            # default SSM-SessionManagerRunShell
```

### `scripts/verify-ssm-access.sh` contract

```
Usage: scripts/verify-ssm-access.sh [instance-id]   # id optional (same resolution as ssm-connect)
Env:   PROJECT/ENVIRONMENT/AWS_REGION as above
Checks (read-only, non-interactive):
  PRE-FLIGHT   aws CLI present; sts get-caller-identity
  R1/R6        instance state == running
  R2/R3        ssm describe-instance-information → PingStatus == Online
  R1           attached SG IpPermissions == [] AND IpPermissionsEgress == exactly one
               all-protocols 0.0.0.0/0 rule
Exit: 0 iff FAIL_COUNT == 0 (same summary block as verify-airbyte-s3.sh)
```

## Error Handling Strategy

| Category | Handling |
|---|---|
| `ssm-connect.sh`: invalid/missing subcommand | usage listing `ui`/`shell`, exit 2 — checked FIRST (spec R3 scenario has no preconditions) |
| `ssm-connect.sh`: session-manager-plugin missing | detect via `command -v` before connecting; exit 2 + install instructions incl. the AWS plugin download URL (R2 scenario) |
| `ssm-connect.sh`: AWS credentials missing/expired | `sts get-caller-identity` preflight surfaces the auth error; message propagated to stderr, exit non-zero (R2 scenario) |
| `ssm-connect.sh`: terraform state unavailable | fall back to Name-tag `describe-instances`; both fail → error naming working dir + `terraform apply`, exit 1 (R2 scenario) |
| `ssm-connect.sh`: instance stopped/terminated | print instance ID + current state + suggest `terraform apply`, exit 1 (R2 scenario) |
| `ssm-connect.sh`: local port already in use | plugin's bind error surfaced to stderr; operator re-runs with `LOCAL_PORT=<free>` (Decision 6) |
| `verify-ssm-access.sh`: agent offline | FAIL with remediation: check egress 443 to ssm/ssmmessages/ec2messages, instance profile `AmazonSSMManagedInstanceCore`, agent logs |
| `verify-ssm-access.sh`: SG ingress > 0 | FAIL listing offending rules (rule-level detail via `describe-security-groups`) |
| Terraform: empty/unset username | `validation` block fails plan with descriptive error (R5); unset → "No value for required variable" |
| Terraform: empty password | NOT an error — user_data logs a prominent warning to `/var/log/user-data.log`, bootstrap continues (R5 warn-don't-fail) |
| IAM policy render | `$${aws:username}` HCL-escaping preserved (else the policy variable is eaten by Terraform interpolation) |
| user_data bootstrap failure | unchanged: `set -euo pipefail`, `/var/log/user-data.log`, apply succeeds regardless — post-boot verification via `verify-ssm-access.sh` |
| Script hygiene | all bash `set -euo pipefail`; destructive scripts keep the `environment = "local"` safety grep |

**Logging**: user_data log on EC2 (read via SSM shell — SSH is gone); SSM session output on the
operator's terminal; Terraform CLI output; LocalStack container logs for local runs.

## Testing Strategy

### Unit / static level
- `terraform fmt -check -recursive`; `terraform validate` with both tfvars (R7: passes with no
  `allowed_ssh_cidr` defined — `validate` does not require values for required variables).
- Negative validation test: `terraform plan -var-file=envs/local.tfvars -var 'airbyte_basic_auth_username='`
  must fail with the non-empty validation message (R5 username scenario).

### LocalStack-structural (`test-local.sh` additions; dummy TF_VARs exported at script top)
1. **AC-AUA-R1a**: resolve the SG from `terraform state show module.airbyte_ec2.aws_security_group.airbyte`
   → assert zero `ingress` blocks (state grep) AND, via LocalStack EC2 API
   (`aws ec2 describe-security-groups`), `IpPermissions == []`.
2. **AC-AUA-R1b**: exactly one egress rule, all protocols, `0.0.0.0/0` (R1 "exactly one" scenario).
3. **AC-AUA-R7a**: `terraform plan -var-file=envs/local.tfvars` output contains no
   `allowed_ssh_cidr`; both `envs/*.tfvars` files contain no `allowed_ssh_cidr` line.
4. **AC-AUA-OUTa**: `terraform output airbyte_url` and `terraform output airbyte_public_ip` exit
   non-zero (absent); `terraform output -raw ssm_access_policy_arn` succeeds and contains `:policy/`.
5. **AC-AUA-R4a**: policy JSON via LocalStack IAM (`iam list-policies --scope Local` →
   `get-policy` → `get-policy-version`), parsed with python3 (repo convention): StartSession
   statement has 3 resources — instance ARN (contains `:instance/i-`),
   `SSM-SessionManagerRunShell` ARN **with** account segment, `AWS-StartPortForwardingSession`
   ARN with `::document/`; that statement has no `"*"` and no `:instance/*` resource;
   TerminateSession scoped to `arn:aws:ssm:*:*:session/${aws:username}-*`; `ec2:DescribeInstances`
   on `*` present.
6. **AC-AUA-R5a**: `terraform state show module.airbyte_ec2.aws_instance.airbyte` user_data
   contains `BASIC_AUTH_USERNAME=` and `BASIC_AUTH_PASSWORD=` (structural render check; the
   visible value is the local dummy — not a real secret).
7. **AC-AUA-R5b (redaction)**: `terraform plan -var-file=envs/local.tfvars -var 'airbyte_basic_auth_password=REDACTION_SENTINEL_x'`
   → plan output must NOT contain the sentinel (sensitivity propagates through `templatefile()`).
8. **AC-AUA-R5c (replacement)**: the same plan reports `aws_instance.airbyte` "must be replaced"
   (local proof of the R5 instance-replacement scenario; plan-only — state untouched).
9. All pre-existing assertions (ingestion R1, R2, R3, R5 incl. AC-R5 prod-plan leg — now running
   with dummy TF_VARs) must keep passing; `local-up.sh`/`local-down.sh` flows unchanged (R6).

### Prod-only (manual / read-only)
- `verify-ssm-access.sh` full pass (R1, R2/R3 posture leg). Optional manual probe: `nc -zw3
  <public-ip> 8000` from an external host times out (IP via console/describe-instances — no
  longer an output).
- Manual R2: `ssm-connect.sh ui` → browser `http://localhost:8000` → login with new credentials.
- Manual R3: `ssm-connect.sh shell` → prompt as `ssm-user`; `sudo -iu ec2-user` works.
- Manual R4: attach `ssm_access_policy_arn` to operator principals; optional
  `aws iam simulate-principal-policy` for StartSession on the instance ARN.
- Manual R5: via SSM shell, `sudo grep BASIC_AUTH /opt/airbyte/.env` → non-default values.
- R8: design review only (output exists; zero-inline-ingress enabler documented).

### Expected red-phase failures (before implementation)
SG zero-ingress (2 blocks today) · `allowed_ssh_cidr`-absent (still in plan + tfvars) · outputs
absent (both exist) · `ssm_access_policy_arn` (no such output) · IAM policy JSON (no policy) ·
user_data BASIC_AUTH render · redaction sentinel (user_data not yet sensitive) ·
replacement-on-password-change (variable undeclared → no replacement planned) · username
validation negative test (no validation error text). Mid-phase: adding the required variable
before updating scripts breaks `local-up.sh` — variables and script TF_VAR exports land together.

### Test data / fixtures
Dummy local credentials (`local-dev` + non-empty sentinel password, never committed);
`REDACTION_SENTINEL_$$` per-run password for the redaction test; instance Name tag
`data4ai-local-airbyte-ec2` / `data4ai-prod-airbyte-ec2` derived from existing conventions.

## Implementation Approach

1. **Stage 3 tests first**: extend `test-local.sh` (red), write `verify-ssm-access.sh` and
   `ssm-connect.sh` skeletons.
2. **Interfaces**: root + module variables (remove `allowed_ssh_cidr`, add auth vars) **in the
   same commit as** the tfvars edits and the script TF_VAR exports (keeps local flow green).
3. **Module**: SG ingress removal; template + `templatefile()` args; module outputs.
4. **Root**: `main.tf` wiring, `data.aws_caller_identity`, IAM policy, outputs.
5. **Scripts**: complete `ssm-connect.sh` / `verify-ssm-access.sh`.
6. **Docs**: README, AGENTS.md, `specs/ingestion/plan.md` amendment; commit message calls out
   the breaking change explicitly (repo has no CHANGELOG — R7 scenario allows commit message).
7. **Green**: `test-local.sh` all pass; prod `terraform plan` review.
8. **Prod rollout** (below).

### Production rollout & apply consequences

First prod apply of this change set plans: (a) `aws_security_group.airbyte` modified **in
place** — both ingress rules revoked (SG-only change would NOT touch the instance); (b)
`aws_iam_policy.ssm_access` created; (c) `aws_instance.airbyte` **DESTROYED AND RECREATED** —
the `templatefile()` diff changes `user_data` (force-replacement attribute). AMI drift
(`most_recent` lookup) may add a second replacement trigger. Airbyte configuration on the
docker volumes (connectors, destinations, connections) is **lost**.

Pre-apply operator checklist:
1. Export/document Airbyte connections manually (UI + API GETs) or accept reconfiguration.
2. `export TF_VAR_airbyte_basic_auth_username=… TF_VAR_airbyte_basic_auth_password=…`
   (shell env or untracked credentials file — never tfvars).
3. Recommended: pin `ami_id` in `envs/prod.tfvars` to the currently running AMI so the diff
   shows only this change set.
4. `terraform plan -var-file=envs/prod.tfvars` — verify: 2 ingress removals, 1 policy create,
   instance **replacement**.
5. `terraform apply`; poll bootstrap via SSM (`/var/lib/airbyte-ready`,
   `/var/log/user-data.log`).
6. Attach the policy: `aws iam attach-user-policy --policy-arn $(terraform output -raw ssm_access_policy_arn) --user-name <operator>` (manual per Out-of-Scope #7).
7. `./scripts/verify-ssm-access.sh` → pass.
8. `./scripts/ssm-connect.sh ui` → log in with new credentials → reconfigure the S3 destination
   (ingestion R6/R7: Hive path format + AVRO) → re-verify destination check through the tunnel.

### Risks & mitigations
- **State cleartext password** — accepted risk (Decision 2); S3-backend follow-up must add
  encryption + ACL hardening.
- **Config loss on replacement** — checklist above; schedule apply with a reconfiguration window.
- **Airbyte version drift** — BASIC_AUTH_* names verified for 0.63.5; re-verify against
  `raw.githubusercontent.com/airbytehq/airbyte-platform/v<version>/.env` on any version bump.
- **Password charset** — compose dotenv interpolates unquoted values; guidance (avoid `$`,
  quotes, `\`, ` #`) lives in the variable description + README.
- **Federated principals later** — documented swap `aws:username` → `aws:userid` in the policy.

## Traceability

| Requirement | Plan Section | Notes |
|---|---|---|
| R1 (zero public ingress) | Component Breakdown (module SG); API/Interface (SG shape); Testing AC-AUA-R1a/b; verify-ssm-access.sh | egress unchanged; break-glass `key_name` retained, inert (no port-22 rule) |
| R2 (SSM port-forward UI) | Architecture → SSM path; API → ssm-connect.sh contract; Error Handling (per scenario); Testing (prod manual) | instance-ID resolution per Decision 4 |
| R3 (SSM shell replaces SSH) | API → ssm-connect.sh `shell`; Error Handling (usage-first ordering); Testing (prod manual) | default doc `SSM-SessionManagerRunShell`; no ingress on 22 |
| R4 (least-privilege IAM policy) | API/Interface (policy HCL, verified ARNs); Testing AC-AUA-R4a + output check; Decision 3 (local) | user-facing policy; instance role untouched; `ssm_access_policy_arn` output |
| R5 (basic auth hardening) | Data Flow → user_data path; Component Breakdown (variables/template); Decisions 1–2; Testing AC-AUA-R5a/b/c + negative validation | username required/validated; password sensitive w/ warn-if-empty; state-cleartext gap flagged |
| R6 (local parity) | Component Breakdown (script TF_VAR exports); Testing (all LocalStack assertions + unchanged flows) | structural-only assertions; no SSM emulation assumed |
| R7 (`allowed_ssh_cidr` removal) | Component Breakdown (root/module/tfvars); Testing AC-AUA-R7a; Implementation step 6 (breaking-change commit message) | includes `specs/ingestion/plan.md` contract amendment |
| R8 (ALB+OIDC forward compat) | Data Models (security_group_id retained; zero-inline-ingress enabler) | design constraint; no runtime behavior; no CIDR-style variable reintroduced |

## Appendix: Verified external facts

1. **IAM ARN forms** (docs.aws.amazon.com): instance `arn:aws:ec2:<region>:<account>:instance/<id>`;
   account-owned `SSM-SessionManagerRunShell` → `arn:aws:ssm:<region>:<account>:document/SSM-SessionManagerRunShell`
   (Quickstart end-user samples); AWS-owned `AWS-*` documents → empty account segment
   (`arn:aws:ssm:*:*:document/AWS-StartSSHSession` in "Step 8: Allow and control permissions for
   SSH connections"). Own-session scoping: `arn:aws:ssm:*:*:session/${aws:username}-*` (Additional
   sample policies, Example 4 Method 1 — IAM users) / `${aws:userid}` (federated-compatible);
   `ssmmessages:OpenDataChannel` on the same session ARN appears in all current AWS samples.
   Session ARN format `arn:aws:ssm:<region>:<account>:session/<user>-<id>` ("Step 3: Control
   session access").
2. **Compose dotenv last-wins**: compose-spec/compose-go `dotenv/parser.go` — sequential
   `out[key] = value` map assignment; a later duplicate key in the SAME file overrides the
   earlier one. Docker docs additionally: later `--env-file` files override earlier ones.
3. **Airbyte v0.63.5** (current default in `variables.tf`): `.env` ships
   `BASIC_AUTH_USERNAME=airbyte` / `BASIC_AUTH_PASSWORD=password` ("Set to empty values… to
   disable basic auth"); `docker-compose.yaml` `airbyte-proxy` publishes `"8000:8000"` and
   interpolates both vars into its environment — so the appended `.env` override reaches the
   proxy that enforces auth. (raw.githubusercontent.com/airbytehq/airbyte-platform/v0.63.5/.env
   and …/docker-compose.yaml)
4. **SSM Agent is outbound-only** ("Step 1: Complete Session Manager prerequisites"): nodes must
   allow HTTPS/443 outbound to the `ssm`, `ssmmessages`, and `ec2messages` endpoints (or use
   PrivateLink); no SG ingress is required for Session Manager. `ssm-user` is created by the
   agent; port forwarding requires agent ≥ 3.0.222.0 (Amazon Linux 2023 ships 3.x). The instance
   retains a public IP for IGW egress — that is an infrastructure necessity, not an access path.

## Self-Review

- Status: PASS (conditional — one spec-physics gap in R5 requires human acceptance: the password
  remains cleartext in local Terraform state despite `sensitive = true`; see Design Decision 2
  and Traceability R5)
- All requirements (R1–R8) addressed: yes
- All ACs accounted for in testing strategy: yes (LocalStack-structural vs prod-only split per
  spec Testability Notes; red-phase expectations enumerated)
- No contradictions with spec: one known deviation (R5 state cleartext — physically
  unsatisfiable, flagged); two interpretation calls flagged (R4 local output renders a mock ARN
  "placeholder"; module password has no non-empty validation to preserve warn-don't-fail)
- Traceability complete: yes (R1–R8 all mapped; no orphan sections — R8's forward-compat content
  lives only in Data Models/Traceability by design)
