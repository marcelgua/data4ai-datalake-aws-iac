#!/usr/bin/env bash
# =============================================================================
# test-local.sh — Integration tests: Terraform resources vs LocalStack emulation
# =============================================================================
# Covers: AC-R1a, AC-R1b, AC-R2-local, AC-R3-local, AC-R5
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
