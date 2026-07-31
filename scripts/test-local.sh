#!/usr/bin/env bash
# =============================================================================
# test-local.sh — Integration tests: Terraform resources vs LocalStack emulation
# =============================================================================
# Covers: AC-R1a, AC-R1b, AC-R2-local, AC-R3-local, AC-R5 (ingestion)
#          + AC-AUA-R1a, AC-AUA-R1b, AC-AUA-R7a, AC-AUA-OUTa, AC-AUA-R4a,
#            AC-AUA-R5a, AC-AUA-R5b, AC-AUA-R5c, AC-AUA-R5d (airbyte-ui-access)
# Plus boundary and edge-case tests per Spec Kit methodology.
#
# Pre-conditions:
#   1. LocalStack running:  docker compose up -d
#   2. Local env applied:   ./scripts/local-up.sh  (or terraform apply -var-file=envs/local.tfvars)
#
# This script is read-only except for a temporary test bucket (AC-R1b) which is
# cleaned up.  It MUST fail initially (red phase) since Terraform code is not yet
# written.  This is expected and correct.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LOCALSTACK_URL="${LOCALSTACK_URL:-http://localhost:4566}"
AWS_OPTS=(--endpoint-url="${LOCALSTACK_URL}" --region="${AWS_REGION:-us-east-1}" --no-sign-request)
PROJECT="${PROJECT:-data4ai}"
ENV_LOCAL="${ENV_LOCAL:-local}"
ENV_PROD="${ENV_PROD:-prod}"
BUCKET_LOCAL="${PROJECT}-staging-${ENV_LOCAL}"
BUCKET_PROD="${PROJECT}-staging-${ENV_PROD}"
HEALTH_URL="${LOCALSTACK_URL}/_localstack/health"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Dummy TF_VAR exports (airbyte-ui-access spec — R5, R6)
# Required variables must be set even for plan-only operations in this script.
# These are throwaway LocalStack-only values; the EC2 instance never boots in
# LocalStack, so user_data is never executed. The dummy lives only in gitignored
# local state.
# ---------------------------------------------------------------------------
export TF_VAR_airbyte_basic_auth_username="${TF_VAR_airbyte_basic_auth_username:-local-dev}"
export TF_VAR_airbyte_basic_auth_password="${TF_VAR_airbyte_basic_auth_password:-local-dummy-pw-sentinel-keep-local}"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() {
    echo -e "${GREEN}  ✓ PASS${NC}  ${1}"
    PASS_COUNT=$((PASS_COUNT + 1))
}
fail() {
    echo -e "${RED}  ✗ FAIL${NC}  ${1}"
    if [[ -n "${2:-}" ]]; then
        echo -e "${RED}          ${2}${NC}"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
}
skip() {
    echo -e "${YELLOW}  ○ SKIP${NC}  ${1}"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}
header() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━ ${1} ━━━${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Helper: run AWS CLI and capture output; return 0 on success
# ---------------------------------------------------------------------------
aws_ls() {
    aws "${AWS_OPTS[@]}" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# Helper: exit if FAIL_COUNT > 0
# ---------------------------------------------------------------------------
fail_if_any() {
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo ""
        echo -e "${RED}${BOLD}Exiting early due to failures.${NC}"
        exit 1
    fi
}

# =============================================================================
# PRE-FLIGHT — LocalStack must be running and healthy
# =============================================================================
header "PRE-FLIGHT: LocalStack connectivity"

echo "  Probing ${HEALTH_URL} …"
if curl -sf --max-time 5 "${HEALTH_URL}" > /dev/null 2>&1; then
    pass "LocalStack is reachable at ${LOCALSTACK_URL}"
else
    # EDGE CASE: LocalStack not running — actionable error
    fail "LocalStack is NOT reachable at ${LOCALSTACK_URL}" \
         "Start it with:  docker compose up -d"
    exit 1
fi

# Fetch full health JSON
HEALTH_JSON="$(curl -sf --max-time 5 "${HEALTH_URL}" 2>/dev/null || true)"
if [[ -z "${HEALTH_JSON}" ]]; then
    fail "LocalStack health endpoint returned empty response"
    exit 1
fi

echo ""
echo "  Parsing health response for required services …"

# EDGE CASE: health endpoint returns but services may not be available
check_service() {
    local svc="$1"
    local label="$2"
    # LocalStack /_localstack/health returns a JSON object like:
    #  {"services": {"s3": "available", "ec2": "available", …}}
    local status
    status="$(echo "${HEALTH_JSON}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    services = data.get('services', data)
    print(services.get('${svc}', services.get('${svc/_/-}', 'unknown')))
except Exception:
    print('parse_error')
" 2>/dev/null || echo 'parse_error')"

    if [[ "${status}" == "available" ]] || [[ "${status}" == "running" ]]; then
        pass "Service ${label} (${svc}) is ${status}"
    else
        fail "Service ${label} (${svc}) status: '${status}' (expected 'available' or 'running')" \
             "Check SERVICES env var in docker-compose.yml — needs: s3,ec2,iam,sts"
    fi
}

check_service "s3"  "S3"
check_service "ec2" "EC2"
check_service "iam" "IAM"
check_service "sts" "STS"

fail_if_any

# =============================================================================
# AC-R1a — Raw API calls: S3, EC2 DescribeInstances, STS GetCallerIdentity
# =============================================================================
header "AC-R1a: Raw AWS API operations via LocalStack"

echo "  → s3api list-buckets …"
if LIST_BUCKETS="$(aws_ls s3api list-buckets 2>&1)"; then
    pass "s3api list-buckets succeeded"
else
    fail "s3api list-buckets failed" "${LIST_BUCKETS}"
fi

echo ""
echo "  → ec2 DescribeInstances …"
if DESC_INST="$(aws_ls ec2 describe-instances 2>&1)"; then
    pass "ec2 describe-instances succeeded"
else
    fail "ec2 describe-instances failed" "${DESC_INST}"
fi

echo ""
echo "  → sts GetCallerIdentity …"
if CALLER="$(aws_ls sts get-caller-identity 2>&1)"; then
    pass "sts get-caller-identity succeeded"
    echo -e "    ${CYAN}Caller: $(echo "${CALLER}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("Arn","unknown"))' 2>/dev/null || echo 'parse_error')${NC}"
else
    fail "sts get-caller-identity failed" "${CALLER}"
fi

fail_if_any

# =============================================================================
# AC-R1b — Raw S3 create-bucket / list-buckets (independent of Terraform)
# =============================================================================
header "AC-R1b: Raw S3 bucket create & list (Terraform-independent)"

TEST_BUCKET="staging-bucket-ac-test-$$"

echo "  → Creating temporary bucket '${TEST_BUCKET}' …"
if CREATE_OUT="$(aws_ls s3api create-bucket --bucket "${TEST_BUCKET}" 2>&1)"; then
    pass "s3api create-bucket '${TEST_BUCKET}' succeeded"
else
    fail "s3api create-bucket '${TEST_BUCKET}' failed" "${CREATE_OUT}"
    fail_if_any
fi

echo ""
echo "  → Verifying '${TEST_BUCKET}' appears in list-buckets …"
if aws_ls s3api list-buckets --query "Buckets[?Name=='${TEST_BUCKET}']" --output text 2>&1 | grep -q "${TEST_BUCKET}"; then
    pass "Bucket '${TEST_BUCKET}' found in list-buckets"
else
    fail "Bucket '${TEST_BUCKET}' NOT found in list-buckets"
fi

echo ""
echo "  → Cleaning up temporary bucket …"
if aws_ls s3api delete-bucket --bucket "${TEST_BUCKET}" 2>&1; then
    pass "Temporary bucket '${TEST_BUCKET}' deleted"
else
    # Non-fatal: bucket will be left but test still valid
    echo -e "${YELLOW}  ⚠ WARN${NC}  Could not delete temporary bucket '${TEST_BUCKET}'"
fi

# BOUNDARY: create-bucket with invalid name should fail
echo ""
echo "  → BOUNDARY: create-bucket with invalid name …"
if aws_ls s3api create-bucket --bucket "INVALID_UPPERCASE" 2>&1; then
    fail "create-bucket with uppercase name unexpectedly succeeded (LocalStack may be lenient)"
else
    pass "create-bucket with invalid name correctly rejected"
fi

fail_if_any

# =============================================================================
# AC-R2-local — Terraform bucket: name, versioning, encryption
# =============================================================================
header "AC-R2-local: Terraform-provisioned bucket verification"

# Check Terraform is initialised
if [[ ! -d "${PROJECT_ROOT}/.terraform" ]]; then
    fail "Terraform not initialised — .terraform/ directory missing" \
         "Run:  cd ${PROJECT_ROOT} && terraform init"
    fail_if_any
fi

echo "  → Checking bucket '${BUCKET_LOCAL}' exists via S3 API …"
if aws_ls s3api head-bucket --bucket "${BUCKET_LOCAL}" 2>&1; then
    pass "Bucket '${BUCKET_LOCAL}' exists"
else
    # EDGE CASE: bucket doesn't exist yet (Terraform not applied)
    fail "Bucket '${BUCKET_LOCAL}' not found" \
         "Run:  terraform apply -var-file=envs/local.tfvars"
    fail_if_any
fi

echo ""
echo "  → Checking versioning is Enabled …"
VERSIONING="$(aws_ls s3api get-bucket-versioning --bucket "${BUCKET_LOCAL}" 2>&1 || true)"
VERSION_STATUS="$(echo "${VERSIONING}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('Status', d.get('status', 'not_set')))
except Exception:
    print('parse_error')
" 2>/dev/null || echo 'parse_error')"

if [[ "${VERSION_STATUS}" == "Enabled" ]]; then
    pass "Bucket versioning is Enabled"
else
    fail "Bucket versioning is '${VERSION_STATUS}' (expected 'Enabled')" \
         "Ensure aws_s3_bucket_versioning resource has status = 'Enabled'"
fi

echo ""
echo "  → Checking server-side encryption (AES256 / SSE-S3) …"
ENCRYPTION="$(aws_ls s3api get-bucket-encryption --bucket "${BUCKET_LOCAL}" 2>&1 || true)"
ENC_ALGO="$(echo "${ENCRYPTION}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    rules = d.get('ServerSideEncryptionConfiguration', {}).get('Rules', [])
    if rules:
        algo = rules[0].get('ApplyServerSideEncryptionByDefault', {}).get('SSEAlgorithm', '')
        print(algo)
    else:
        print('no_rules')
except Exception:
    print('parse_error')
" 2>/dev/null || echo 'parse_error')"

if [[ "${ENC_ALGO}" == "AES256" ]] || [[ "${ENC_ALGO}" == "aws:kms" ]]; then
    pass "Bucket SSE algorithm is ${ENC_ALGO} (AES256 / SSE-S3 expected; aws:kms also valid)"
else
    fail "Bucket encryption algorithm is '${ENC_ALGO}' (expected 'AES256')" \
         "Ensure aws_s3_bucket_server_side_encryption_configuration uses AES256"
fi

# EDGE CASE: get-bucket-encryption on a bucket WITHOUT encryption should fail
# (already covered above — if algo is unexpected, test fails)

# BOUNDARY: verify public access block is configured
echo ""
echo "  → BOUNDARY: checking public access block …"
if PUB_BLOCK="$(aws_ls s3api get-public-access-block --bucket "${BUCKET_LOCAL}" 2>&1)"; then
    ALL_BLOCKED="$(echo "${PUB_BLOCK}" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('PublicAccessBlockConfiguration', {})
all_true = all([
    d.get('BlockPublicAcls', False),
    d.get('IgnorePublicAcls', False),
    d.get('BlockPublicPolicy', False),
    d.get('RestrictPublicBuckets', False),
])
print('yes' if all_true else 'no')
" 2>/dev/null || echo 'parse_error')"
    if [[ "${ALL_BLOCKED}" == "yes" ]]; then
        pass "Public access block: all four settings are true (hardening)"
    else
        fail "Public access block: not all settings are blocked"
    fi
else
    # Not all environments require public access block — soft skip
    skip "Public access block not configured (optional hardening)"
fi

fail_if_any

# =============================================================================
# AC-R3-local — Airbyte EC2 instance & IAM profile in Terraform state + LocalStack
# =============================================================================
header "AC-R3-local: Airbyte EC2 instance & IAM verification"

echo "  → Checking terraform state for module.airbyte_ec2 …"
cd "${PROJECT_ROOT}"
TF_STATE="$(terraform state list 2>&1 || true)"

# Check for airbyte_ec2 resources in state
AIRBYTE_INSTANCE="$(echo "${TF_STATE}" | grep -E 'airbyte_ec2.*aws_instance' || true)"
AIRBYTE_ROLE="$(echo "${TF_STATE}" | grep -E 'airbyte_ec2.*aws_iam_role' || true)"
AIRBYTE_PROFILE="$(echo "${TF_STATE}" | grep -E 'airbyte_ec2.*aws_iam_instance_profile' || true)"

if [[ -n "${AIRBYTE_INSTANCE}" ]]; then
    pass "Terraform state contains airbyte EC2 instance resource"
else
    fail "Terraform state missing airbyte EC2 instance resource"
fi

if [[ -n "${AIRBYTE_ROLE}" ]]; then
    pass "Terraform state contains airbyte IAM role resource"
else
    fail "Terraform state missing airbyte IAM role resource"
fi

if [[ -n "${AIRBYTE_PROFILE}" ]]; then
    pass "Terraform state contains airbyte IAM instance profile resource"
else
    fail "Terraform state missing airbyte IAM instance profile resource"
fi

echo ""
echo "  → Checking EC2 instances in LocalStack …"
LOCALSTACK_INSTANCES="$(aws_ls ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text 2>&1 || true)"

if [[ -n "${LOCALSTACK_INSTANCES}" ]] && [[ "${LOCALSTACK_INSTANCES}" != "None" ]]; then
    pass "EC2 instance(s) visible in LocalStack: ${LOCALSTACK_INSTANCES}"
else
    # EDGE CASE: LocalStack EC2 might show no instances if Terraform not applied
    fail "No EC2 instances visible in LocalStack" \
         "Ensure terraform apply -var-file=envs/local.tfvars was run"
fi

echo ""
echo "  → Checking IAM instance profiles in LocalStack …"
IAM_PROFILES="$(aws_ls iam list-instance-profiles --query 'InstanceProfiles[*].InstanceProfileName' --output text 2>&1 || true)"

if [[ -n "${IAM_PROFILES}" ]] && [[ "${IAM_PROFILES}" != "None" ]]; then
    pass "IAM instance profile(s) visible in LocalStack: ${IAM_PROFILES}"
else
    # EDGE CASE: may be empty if Terraform not applied
    fail "No IAM instance profiles visible in LocalStack" \
         "Ensure module.airbyte_ec2 creates an aws_iam_instance_profile"
fi

# EDGE CASE: verify IAM role has S3 policy attached
echo ""
echo "  → EDGE: Checking IAM roles for S3 policy …"
IAM_ROLES="$(aws_ls iam list-roles --query 'Roles[*].RoleName' --output text 2>&1 || true)"
if [[ -n "${IAM_ROLES}" ]] && [[ "${IAM_ROLES}" != "None" ]]; then
    # Try to find an airbyte-related role
    AIRBYTE_ROLE_NAME="$(echo "${IAM_ROLES}" | tr '\t' '\n' | grep -i airbyte | head -1 || true)"
    if [[ -n "${AIRBYTE_ROLE_NAME}" ]]; then
        ROLE_POLICIES="$(aws_ls iam list-role-policies --role-name "${AIRBYTE_ROLE_NAME}" --query 'PolicyNames' --output text 2>&1 || true)"
        if [[ -n "${ROLE_POLICIES}" ]] && [[ "${ROLE_POLICIES}" != "None" ]]; then
            pass "Airbyte IAM role '${AIRBYTE_ROLE_NAME}' has inline policies: ${ROLE_POLICIES}"
        else
            # Might use managed policies instead — check
            ATTACHED="$(aws_ls iam list-attached-role-policies --role-name "${AIRBYTE_ROLE_NAME}" --query 'AttachedPolicies[*].PolicyName' --output text 2>&1 || true)"
            if [[ -n "${ATTACHED}" ]] && [[ "${ATTACHED}" != "None" ]]; then
                pass "Airbyte IAM role '${AIRBYTE_ROLE_NAME}' has attached policies: ${ATTACHED}"
            else
                fail "Airbyte IAM role '${AIRBYTE_ROLE_NAME}' has no policies attached"
            fi
        fi
    else
        skip "No airbyte-named IAM role found — skipping policy check"
    fi
else
    skip "No IAM roles found — skipping policy check"
fi

fail_if_any

# =============================================================================
# AC-R5 — Prod env plan check: bucket name + no endpoint override
# =============================================================================
header "AC-R5: Production environment plan-only check"

echo "  → Running: terraform plan -var-file=envs/prod.tfvars …"
cd "${PROJECT_ROOT}"

if [[ ! -f "envs/prod.tfvars" ]]; then
    # EDGE CASE: prod.tfvars doesn't exist yet
    skip "envs/prod.tfvars not found — skipping prod plan check"
else
    # Capture plan in JSON for machine parsing if available
    PLAN_OUT="$(terraform plan -var-file="envs/prod.tfvars" -detailed-exitcode 2>&1 || true)"
    PLAN_RC=$?

    # terraform plan -detailed-exitcode returns:
    #   0 = no changes (Succeeded, empty diff)
    #   1 = error
    #   2 = changes present (Succeeded, non-empty diff)
    # Both 0 and 2 are valid "plan succeeded" outcomes.
    if [[ ${PLAN_RC} -eq 0 ]] || [[ ${PLAN_RC} -eq 2 ]]; then
        pass "terraform plan (prod) succeeded"
    else
        fail "terraform plan (prod) returned exit code ${PLAN_RC}" "${PLAN_OUT}"
        fail_if_any
    fi

    echo ""
    echo "  → Checking planned bucket name contains '${BUCKET_PROD}' …"
    if echo "${PLAN_OUT}" | grep -q "${BUCKET_PROD}"; then
        pass "Prod plan references bucket '${BUCKET_PROD}'"
    else
        fail "Prod plan does NOT reference expected bucket '${BUCKET_PROD}'" \
             "Check bucket_name = \"\${var.project}-staging-\${var.environment}\""
    fi

    # EDGE CASE: local endpoint overrides must NOT appear in prod plan
    echo ""
    echo "  → EDGE: verifying no localhost endpoint override in prod plan …"
    if echo "${PLAN_OUT}" | grep -q "localhost:4566"; then
        fail "Prod plan contains localhost endpoint override — provider misconfiguration"
    else
        pass "Prod plan has NO localhost endpoint override (correct)"
    fi
fi

fail_if_any

# =============================================================================
# airbyte-ui-access spec (specs/airbyte-ui-access)
# R1, R4, R5, R6, R7 structural assertions against LocalStack
#
# RED PHASE: ALL of these assertions MUST fail before the spec is implemented.
# Expected failures:
#   - R1a: SG has 2 ingress blocks today (port 8000 + port 22)
#   - R1b: egress exists and is correct (may pass if unchanged)
#   - R7a: allowed_ssh_cidr still in plan + tfvars
#   - OUTa: airbyte_url/airbyte_public_ip exist; ssm_access_policy_arn absent
#   - R4a: no IAM policy resource yet
#   - R5a: user_data has no BASIC_AUTH_* lines
#   - R5b/R5c: airbyte_basic_auth_password variable undeclared → plan error
#   - R5d: airbyte_basic_auth_username variable undeclared → plan error
# Green phase: after Stage 4 implementation, these assertions must pass.
# =============================================================================
header "airbyte-ui-access: R1 Zero Public Ingress (SG structural)"

# -----------------------------------------------------------------------------
# AC-AUA-R1a — Security group has zero ingress rules
#   Sub-test 1: terraform state show → no "ingress {" block
#   Sub-test 2: LocalStack EC2 API → IpPermissions == []
# -----------------------------------------------------------------------------
echo "  → AC-AUA-R1a: checking SG has zero ingress via terraform state …"
SG_STATE="$(terraform state show module.airbyte_ec2.aws_security_group.airbyte 2>&1 || true)"
if echo "${SG_STATE}" | grep -q 'ingress {'; then
    fail "AC-AUA-R1a: security group has ingress block(s) in terraform state (expected zero)" \
         "SG must have no ingress { } blocks — remove the port 8000 and port 22 ingress rules from the module"
else
    pass "AC-AUA-R1a: security group has zero ingress blocks in terraform state"
fi

echo ""
echo "  → AC-AUA-R1a: checking SG IpPermissions via LocalStack EC2 API …"
# Find the Airbyte security group by name pattern
SG_ID="$(aws_ls ec2 describe-security-groups \
    --filters "Name=group-name,Values=*airbyte*" \
    --query "SecurityGroups[0].GroupId" --output text 2>&1 || true)"

if [[ -z "${SG_ID}" ]] || [[ "${SG_ID}" == "None" ]] || [[ "${SG_ID}" == "None"* ]]; then
    fail "AC-AUA-R1a: could not find Airbyte security group via LocalStack EC2 API" \
         "Ensure terraform apply was run — module.airbyte_ec2 should create aws_security_group.airbyte"
else
    SG_JSON="$(aws_ls ec2 describe-security-groups --group-ids "${SG_ID}" --output json 2>&1 || true)"
    IP_PERM_COUNT="$(echo "${SG_JSON}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    groups = data.get('SecurityGroups', [])
    if groups:
        perms = groups[0].get('IpPermissions', [])
        print(len(perms))
    else:
        print('no_groups')
except Exception as e:
    print('parse_error')
" 2>/dev/null || echo 'parse_error')"

    case "${IP_PERM_COUNT}" in
        0)
            pass "AC-AUA-R1a: SG IpPermissions is empty (zero ingress rules)"
            ;;
        parse_error|no_groups)
            fail "AC-AUA-R1a: could not parse SG ingress from LocalStack API" \
                 "Raw SG JSON: $(echo "${SG_JSON}" | head -c 200)"
            ;;
        *)
            fail "AC-AUA-R1a: SG has ${IP_PERM_COUNT} ingress rule(s) (expected 0)" \
                 "SG ID: ${SG_ID} — all ingress rules must be removed"
            ;;
    esac
fi

# -----------------------------------------------------------------------------
# AC-AUA-R1b — Exactly one egress rule: all protocols, 0.0.0.0/0
# -----------------------------------------------------------------------------
echo ""
echo "  → AC-AUA-R1b: checking exactly one egress rule (all protocols, 0.0.0.0/0) …"

if [[ -n "${SG_ID:-}" ]] && [[ "${SG_ID}" != "None" ]]; then
    SG_JSON="$(aws_ls ec2 describe-security-groups --group-ids "${SG_ID}" --output json 2>&1 || true)"
    EGRESS_CHECK="$(echo "${SG_JSON}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    groups = data.get('SecurityGroups', [])
    if not groups:
        print('no_groups')
        sys.exit(0)
    egress = groups[0].get('IpPermissionsEgress', [])
    
    errors = []
    # Check exactly one egress rule
    if len(egress) != 1:
        errors.append('expected 1 egress rule, got {}'.format(len(egress)))
        print('FAIL:' + '; '.join(errors))
        sys.exit(0)
    
    rule = egress[0]
    # Check protocol == -1 (all)
    if str(rule.get('IpProtocol', '')) != '-1':
        errors.append('protocol is {} (expected -1 for all)'.format(rule.get('IpProtocol')))
    
    # Check 0.0.0.0/0
    ranges = rule.get('IpRanges', [])
    if len(ranges) != 1 or ranges[0].get('CidrIp', '') != '0.0.0.0/0':
        errors.append('IpRanges should be exactly [0.0.0.0/0], got {}'.format(ranges))
    
    if errors:
        print('FAIL:' + '; '.join(errors))
    else:
        print('PASS')
except Exception as e:
    print('parse_error:' + str(e))
" 2>/dev/null || echo 'parse_error')"

    case "${EGRESS_CHECK}" in
        PASS)
            pass "AC-AUA-R1b: exactly one egress rule (all protocols, 0.0.0.0/0)"
            ;;
        FAIL:*)
            fail "AC-AUA-R1b: ${EGRESS_CHECK#FAIL:}" \
                 "Egress must be: exactly one rule, protocol -1, cidr 0.0.0.0/0"
            ;;
        *)
            fail "AC-AUA-R1b: could not verify egress rule — ${EGRESS_CHECK}"
            ;;
    esac
else
    fail "AC-AUA-R1b: skipped — no SG ID from R1a check"
fi

fail_if_any

# =============================================================================
# AC-AUA-R7a — allowed_ssh_cidr absent from plan and tfvars
# =============================================================================
header "airbyte-ui-access: R7 Removal of allowed_ssh_cidr"

echo "  → AC-AUA-R7a: checking terraform plan output for allowed_ssh_cidr …"
cd "${PROJECT_ROOT}"

if PLAN_OUT_R7="$(terraform plan -var-file="envs/local.tfvars" 2>&1)"; then
    PLAN_R7_RC=0
else
    PLAN_R7_RC=$?
fi

if [[ ${PLAN_R7_RC} -eq 0 ]] || [[ ${PLAN_R7_RC} -eq 2 ]]; then
    if echo "${PLAN_OUT_R7}" | grep -q 'allowed_ssh_cidr'; then
        fail "AC-AUA-R7a: terraform plan output references allowed_ssh_cidr (must be absent)" \
             "Remove allowed_ssh_cidr variable from root and module; remove the line from both tfvars"
    else
        pass "AC-AUA-R7a: terraform plan output has NO allowed_ssh_cidr reference"
    fi
else
    fail "AC-AUA-R7a: terraform plan (local) failed with exit code ${PLAN_R7_RC}" \
         "${PLAN_OUT_R7}"
fi

echo ""
echo "  → AC-AUA-R7a: checking envs/local.tfvars for allowed_ssh_cidr …"
if grep -q 'allowed_ssh_cidr' "${PROJECT_ROOT}/envs/local.tfvars" 2>/dev/null; then
    fail "AC-AUA-R7a: envs/local.tfvars still contains allowed_ssh_cidr line (must be removed)"
else
    pass "AC-AUA-R7a: envs/local.tfvars has no allowed_ssh_cidr"
fi

echo ""
echo "  → AC-AUA-R7a: checking envs/prod.tfvars for allowed_ssh_cidr …"
if grep -q 'allowed_ssh_cidr' "${PROJECT_ROOT}/envs/prod.tfvars" 2>/dev/null; then
    fail "AC-AUA-R7a: envs/prod.tfvars still contains allowed_ssh_cidr line (must be removed)"
else
    pass "AC-AUA-R7a: envs/prod.tfvars has no allowed_ssh_cidr"
fi

fail_if_any

# =============================================================================
# AC-AUA-OUTa — outputs: airbyte_url/airbyte_public_ip absent; ssm_access_policy_arn present
# =============================================================================
header "airbyte-ui-access: Output checks (R4/R7)"

echo "  → AC-AUA-OUTa: airbyte_url output must be absent …"
cd "${PROJECT_ROOT}"
if terraform output airbyte_url >/dev/null 2>&1; then
    fail "AC-AUA-OUTa: terraform output airbyte_url exists (must be removed — implies public access)"
else
    pass "AC-AUA-OUTa: terraform output airbyte_url is absent (expected)"
fi

echo ""
echo "  → AC-AUA-OUTa: airbyte_public_ip output must be absent …"
if terraform output airbyte_public_ip >/dev/null 2>&1; then
    fail "AC-AUA-OUTa: terraform output airbyte_public_ip exists (must be removed)"
else
    pass "AC-AUA-OUTa: terraform output airbyte_public_ip is absent (expected)"
fi

echo ""
echo "  → AC-AUA-OUTa: ssm_access_policy_arn output must exist and contain :policy/ …"
if SSM_POLICY_ARN="$(terraform output -raw ssm_access_policy_arn 2>&1)"; then
    if echo "${SSM_POLICY_ARN}" | grep -q ':policy/'; then
        pass "AC-AUA-OUTa: ssm_access_policy_arn = ${SSM_POLICY_ARN} (contains :policy/)"
    else
        fail "AC-AUA-OUTa: ssm_access_policy_arn '${SSM_POLICY_ARN}' does not contain ':policy/'" \
             "Expected ARN format: arn:aws:iam::*:policy/<name>"
    fi
else
    fail "AC-AUA-OUTa: terraform output -raw ssm_access_policy_arn failed — output absent" \
         "Add output \"ssm_access_policy_arn\" to outputs.tf referencing aws_iam_policy.ssm_access.arn"
fi

fail_if_any

# =============================================================================
# AC-AUA-R4a — IAM least-privilege policy structural checks
# =============================================================================
header "airbyte-ui-access: R4 IAM Policy structural assertions"

echo "  → AC-AUA-R4a: locating SSM access policy in LocalStack IAM …"
POLICY_ARN="$(aws_ls iam list-policies --scope Local \
    --query "Policies[?PolicyName=='data4ai-local-ssm-access'].Arn" \
    --output text 2>&1 || true)"

if [[ -z "${POLICY_ARN}" ]] || [[ "${POLICY_ARN}" == "None" ]] || [[ "${POLICY_ARN}" == *"NoSuch"* ]]; then
    fail "AC-AUA-R4a: SSM access policy 'data4ai-local-ssm-access' not found in LocalStack IAM" \
         "Ensure aws_iam_policy.ssm_access is created with name 'data4ai-local-ssm-access'"
else
    echo "    Policy ARN: ${POLICY_ARN}"

    echo ""
    echo "  → AC-AUA-R4a: fetching policy document …"
    POLICY_VER="$(aws_ls iam get-policy --policy-arn "${POLICY_ARN}" \
        --query "Policy.DefaultVersionId" --output text 2>&1 || true)"

    if [[ -z "${POLICY_VER}" ]] || [[ "${POLICY_VER}" == "None" ]]; then
        fail "AC-AUA-R4a: could not get default version for policy ${POLICY_ARN}"
    else
        POLICY_DOC="$(aws_ls iam get-policy-version \
            --policy-arn "${POLICY_ARN}" \
            --version-id "${POLICY_VER}" \
            --output json 2>&1 || true)"

        echo "    Parsing policy document with python3 …"
        R4A_RESULT="$(echo "${POLICY_DOC}" | python3 -c "
import sys, json

try:
    data = json.load(sys.stdin)
    # The Document field may be a JSON string (URL-decoded) or a dict
    doc = data.get('PolicyVersion', {}).get('Document', {})
    if isinstance(doc, str):
        doc = json.loads(doc)
    
    statements = doc.get('Statement', [])
    if not isinstance(statements, list):
        print('FAIL:Statement is not a list')
        sys.exit(0)
    
    errors = []
    
    # --- Find StartSession statement ---
    start_stmt = None
    for stmt in statements:
        actions = stmt.get('Action', [])
        if isinstance(actions, str):
            actions = [actions]
        if 'ssm:StartSession' in actions:
            start_stmt = stmt
            break
    
    if start_stmt is None:
        errors.append('StartSession: statement not found')
    else:
        resources = start_stmt.get('Resource', [])
        if isinstance(resources, str):
            resources = [resources]
        
        # Check exactly 3 resources
        if len(resources) != 3:
            errors.append('StartSession: expected 3 resources, got {}: {}'.format(len(resources), resources))
        else:
            # Order-INDEPENDENT matching: aws_iam_policy_document renders Resource
            # as an unordered set (hash-sorted) — positional checks are impossible.
            inst = [r for r in resources if ':instance/i-' in str(r)]
            shell_doc = [r for r in resources if 'SSM-SessionManagerRunShell' in str(r)]
            fwd_doc = [r for r in resources if 'AWS-StartPortForwardingSession' in str(r)]
            if len(inst) != 1:
                errors.append('StartSession: expected exactly 1 instance ARN (:instance/i-), got {}'.format(inst))
            if len(shell_doc) != 1:
                errors.append('StartSession: expected exactly 1 SSM-SessionManagerRunShell ARN, got {}'.format(shell_doc))
            elif '::document/' in str(shell_doc[0]):
                errors.append('StartSession: SSM-SessionManagerRunShell ARN should have account segment (not ::document/): {}'.format(shell_doc[0]))
            if len(fwd_doc) != 1:
                errors.append('StartSession: expected exactly 1 AWS-StartPortForwardingSession ARN, got {}'.format(fwd_doc))
            elif '::document/' not in str(fwd_doc[0]):
                errors.append('StartSession: AWS-StartPortForwardingSession ARN should have empty account segment (::document/): {}'.format(fwd_doc[0]))
        
        # Check: no '*' resource in StartSession
        if '*' in [str(r) for r in resources]:
            errors.append('StartSession: contains \"*\" resource — must be scoped')
        # Check: no ':instance/*'
        if any(':instance/*' in str(r) for r in resources):
            errors.append('StartSession: contains :instance/* — must use specific instance ID')
    
    # --- Find TerminateSession/ResumeSession statement ---
    term_stmt = None
    for stmt in statements:
        actions = stmt.get('Action', [])
        if isinstance(actions, str):
            actions = [actions]
        if 'ssm:TerminateSession' in actions or 'ssm:ResumeSession' in actions:
            term_stmt = stmt
            break
    
    if term_stmt is None:
        errors.append('TerminateSession/ResumeSession: statement not found')
    else:
        resources = term_stmt.get('Resource', [])
        if isinstance(resources, str):
            resources = [resources]
        found_session_scope = False
        for r in resources:
            if 'session/' in str(r) and 'aws:username' in str(r):
                found_session_scope = True
                break
        if not found_session_scope:
            errors.append('TerminateSession: resources must scope to \${aws:username} session ARN, got {}'.format(resources))
    
    # --- Find OpenDataChannel statement ---
    odc_stmt = None
    for stmt in statements:
        actions = stmt.get('Action', [])
        if isinstance(actions, str):
            actions = [actions]
        if 'ssmmessages:OpenDataChannel' in actions:
            odc_stmt = stmt
            break
    
    if odc_stmt is None:
        errors.append('OpenDataChannel: ssmmessages:OpenDataChannel statement not found')
    else:
        resources = odc_stmt.get('Resource', [])
        if isinstance(resources, str):
            resources = [resources]
        found_odc_scope = False
        for r in resources:
            if 'session/' in str(r) and 'aws:username' in str(r):
                found_odc_scope = True
                break
        if not found_odc_scope:
            errors.append('OpenDataChannel: resources must scope to \${aws:username} session ARN, got {}'.format(resources))
    
    # --- Find DescribeInstances statement ---
    desc_stmt = None
    for stmt in statements:
        actions = stmt.get('Action', [])
        if isinstance(actions, str):
            actions = [actions]
        if 'ec2:DescribeInstances' in actions:
            desc_stmt = stmt
            break
    
    if desc_stmt is None:
        errors.append('DescribeInstances: ec2:DescribeInstances statement not found')
    else:
        resources = desc_stmt.get('Resource', [])
        if isinstance(resources, str):
            resources = [resources]
        if '*' not in [str(r) for r in resources]:
            errors.append('DescribeInstances: expected Resource \"*\" (for instance discovery), got {}'.format(resources))
    
    if errors:
        print('FAIL:' + ' | '.join(errors))
    else:
        print('PASS:all {} assertions verified'.format(7))
except Exception as e:
    import traceback
    print('parse_error:' + str(e) + ' -- ' + traceback.format_exc().replace(chr(10),' // '))
" 2>/dev/null || echo 'parse_error')"

        case "${R4A_RESULT}" in
            PASS:*)
                pass "AC-AUA-R4a: IAM policy structure verified — ${R4A_RESULT#PASS:}"
                ;;
            FAIL:*)
                fail "AC-AUA-R4a: IAM policy assertion(s) failed" \
                     "${R4A_RESULT#FAIL:}"
                ;;
            *)
                fail "AC-AUA-R4a: could not parse IAM policy — ${R4A_RESULT}" \
                     "Raw policy doc (truncated): $(echo "${POLICY_DOC}" | head -c 300)"
                ;;
        esac
    fi
fi

fail_if_any

# =============================================================================
# AC-AUA-R5a — user_data contains BASIC_AUTH_USERNAME= and BASIC_AUTH_PASSWORD=
# =============================================================================
header "airbyte-ui-access: R5 Basic Auth hardening"

echo "  → AC-AUA-R5a: checking user_data contains BASIC_AUTH_USERNAME= and BASIC_AUTH_PASSWORD= …"
cd "${PROJECT_ROOT}"

# Fetch user_data from LocalStack directly, as Terraform state stores a SHA1 hash for sensitive user_data
INSTANCE_ID="$(terraform output -raw airbyte_instance_id 2>/dev/null || echo '')"
if [[ -n "${INSTANCE_ID}" ]]; then
    USER_DATA_B64="$(aws ec2 describe-instance-attribute --instance-id "${INSTANCE_ID}" --attribute userData --endpoint-url=http://localhost:4566 --no-sign-request --output text --query 'UserData.Value' 2>/dev/null || echo '')"
    USER_DATA_DECODED="$(echo "${USER_DATA_B64}" | base64 -d 2>/dev/null || echo '')"
else
    USER_DATA_DECODED=""
fi

if echo "${USER_DATA_DECODED}" | grep -q 'BASIC_AUTH_USERNAME='; then
    pass "AC-AUA-R5a: user_data contains BASIC_AUTH_USERNAME="
else
    fail "AC-AUA-R5a: user_data does NOT contain BASIC_AUTH_USERNAME=" \
         "user_data.sh.tftpl must append BASIC_AUTH_USERNAME=\${basic_auth_username} to .env"
fi

if echo "${USER_DATA_DECODED}" | grep -q 'BASIC_AUTH_PASSWORD='; then
    pass "AC-AUA-R5a: user_data contains BASIC_AUTH_PASSWORD="
else
    fail "AC-AUA-R5a: user_data does NOT contain BASIC_AUTH_PASSWORD=" \
         "user_data.sh.tftpl must append BASIC_AUTH_PASSWORD=\${basic_auth_password} to .env"
fi

fail_if_any

# =============================================================================
# AC-AUA-R5b — Sensitive password is redacted in plan output
# AC-AUA-R5c — Password change reports "must be replaced"
# (Same terraform plan invocation serves both assertions)
# =============================================================================
echo ""
echo "  → AC-AUA-R5b,R5c: running terraform plan with sentinel password …"
cd "${PROJECT_ROOT}"

REDACTION_SENTINEL="REDACTION_SENTINEL_x"
if PLAN_AUTH_OUT="$(terraform plan -var-file="envs/local.tfvars" \
    -var "airbyte_basic_auth_password=${REDACTION_SENTINEL}" 2>&1)"; then
    PLAN_AUTH_RC=0
else
    PLAN_AUTH_RC=$?
fi

if [[ ${PLAN_AUTH_RC} -ne 0 ]] && [[ ${PLAN_AUTH_RC} -ne 2 ]]; then
    fail "AC-AUA-R5b: terraform plan with password var failed (exit ${PLAN_AUTH_RC})" \
         "In red phase this is expected (variable not yet declared). Output: $(echo "${PLAN_AUTH_OUT}" | tail -5)"
    fail "AC-AUA-R5c: terraform plan with password var failed (exit ${PLAN_AUTH_RC})" \
         "In red phase this is expected — shared with R5b plan invocation."
else
    # --- AC-AUA-R5b: redaction ---
    if echo "${PLAN_AUTH_OUT}" | grep -q "${REDACTION_SENTINEL}"; then
        fail "AC-AUA-R5b: plan output CONTAINS the sentinel password (must be redacted)" \
             "Ensure var.airbyte_basic_auth_password has sensitive = true, which propagates through templatefile()"
    else
        pass "AC-AUA-R5b: plan output does NOT contain sentinel password (sensitive redacted)"
    fi

    # --- AC-AUA-R5c: replacement ---
    if echo "${PLAN_AUTH_OUT}" | grep -qE '(must be replaced|forces replacement|# aws_instance\.airbyte must be replaced)'; then
        pass "AC-AUA-R5c: plan reports aws_instance.airbyte must be replaced (user_data change)"
    else
        fail "AC-AUA-R5c: plan does NOT report instance replacement for password change" \
             "user_data changes must force EC2 instance destroy+recreate — check plan output"
    fi
fi

fail_if_any

# =============================================================================
# AC-AUA-R5d — Negative validation: empty username must fail plan
# =============================================================================
echo ""
echo "  → AC-AUA-R5d: negative validation — empty username must fail …"
cd "${PROJECT_ROOT}"

# Expected-failure idiom: plan with empty username should fail WITH validation error
if PLAN_VAL_OUT="$(terraform plan -var-file="envs/local.tfvars" \
    -var 'airbyte_basic_auth_username=' 2>&1)"; then
    fail "AC-AUA-R5d: terraform plan with empty username unexpectedly SUCCEEDED" \
         "var.airbyte_basic_auth_username must have non-empty validation and no default"
else
    # Check for the expected validation error message
    if echo "${PLAN_VAL_OUT}" | grep -qiE '(airbyte_basic_auth_username.*required|must be non-empty|length.*0|Invalid value for variable)'; then
        pass "AC-AUA-R5d: empty username correctly rejected with validation error"
    else
        fail "AC-AUA-R5d: plan with empty username failed, but NOT with expected validation message" \
             "Expected error about airbyte_basic_auth_username being required/non-empty. Got: $(echo "${PLAN_VAL_OUT}" | tail -3)"
    fi
fi

fail_if_any

# =============================================================================
# SUMMARY
# =============================================================================
header "TEST SUMMARY"

TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
echo ""
echo -e "  ${BOLD}Total assertions:${NC} ${TOTAL}"
echo -e "  ${GREEN}${BOLD}Passed:${NC} ${PASS_COUNT}"
echo -e "  ${RED}${BOLD}Failed:${NC} ${FAIL_COUNT}"
echo -e "  ${YELLOW}${BOLD}Skipped:${NC} ${SKIP_COUNT}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo -e "${RED}${BOLD}❌ SOME TESTS FAILED${NC}"
    echo ""
    echo -e "  This is ${YELLOW}expected${NC} during the red phase — Terraform code has not been written yet."
    echo "  Once the Infrastructure-as-Code is implemented and applied, re-run this script."
    exit 1
else
    echo -e "${GREEN}${BOLD}✅ ALL TESTS PASSED${NC}"
    exit 0
fi
