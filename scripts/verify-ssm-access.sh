#!/usr/bin/env bash
# =============================================================================
# verify-ssm-access.sh — Prod-only read-only SSM posture verification
# =============================================================================
# Covers: R1 (zero SG ingress), R2/R3 (SSM Agent online), R4 (policy output)
#         per specs/airbyte-ui-access (R1, R2, R3, R6 prod scenarios)
#
# Usage:
#   ./scripts/verify-ssm-access.sh [instance-id]
#
# Env:
#   PROJECT=data4ai  ENVIRONMENT=prod  AWS_REGION=us-east-1
#
# Checks (read-only, non-interactive — NEVER starts a session):
#   PRE-FLIGHT   aws CLI present; sts get-caller-identity
#   INSTANCE     EC2 instance is in 'running' state
#   SSM AGENT    ssm describe-instance-information → PingStatus == Online
#   SG INGRESS   attached security group IpPermissions == []
#   SG EGRESS    exactly one all-protocols 0.0.0.0/0 egress rule
#
# Exit: 0 iff FAIL_COUNT == 0 (matches verify-airbyte-s3.sh conventions).
#
# RED PHASE: This script MUST fail — the SG still has ingress rules, the IAM
#            policy is not yet deployed, and instance may not be configured for
#            SSM. Expected failures pre-implementation. This is correct.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration & defaults
# ---------------------------------------------------------------------------
PROJECT="${PROJECT:-data4ai}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_ID="${1:-}"           # optional positional argument

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Colour helpers (same palette as verify-airbyte-s3.sh)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

fail_if_any() {
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo ""
        echo -e "${RED}${BOLD}Exiting early due to failures.${NC}"
        exit 1
    fi
}

# =============================================================================
# PRE-FLIGHT — aws CLI and credentials
# =============================================================================
header "PRE-FLIGHT: AWS CLI and credentials"

echo "  → Checking aws CLI …"
if command -v aws >/dev/null 2>&1; then
    AWS_VERSION="$(aws --version 2>&1 || echo 'unknown')"
    pass "aws CLI found: ${AWS_VERSION}"
else
    fail "aws CLI not found in PATH" \
         "Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

echo ""
echo "  → Verifying AWS credentials (sts get-caller-identity) …"
if CALLER="$(aws sts get-caller-identity --region "${AWS_REGION}" --output json 2>&1)"; then
    CALLER_ARN="$(echo "${CALLER}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('Arn', 'unknown'))
" 2>/dev/null || echo 'parse_error')"
    pass "AWS credentials valid — caller: ${CALLER_ARN}"
else
    fail "AWS credentials check failed — cannot call sts get-caller-identity" \
         "Ensure AWS credentials are configured (env vars, SSO, or instance profile). Error: ${CALLER:-}"
    exit 1
fi

fail_if_any

# =============================================================================
# INSTANCE ID RESOLUTION
# =============================================================================
header "INSTANCE: Resolving Airbyte EC2 instance ID"

RESOLVED_ID=""

# Method 1: explicit argument
if [[ -n "${INSTANCE_ID}" ]]; then
    echo "  → Using provided instance ID: ${INSTANCE_ID}"
    RESOLVED_ID="${INSTANCE_ID}"
fi

# Method 2: terraform output
if [[ -z "${RESOLVED_ID}" ]]; then
    echo "  → Trying terraform output -raw airbyte_instance_id …"
    cd "${PROJECT_ROOT}" 2>/dev/null || true
    if command -v terraform >/dev/null 2>&1 && \
       [[ -d "${PROJECT_ROOT}/.terraform" ]] 2>/dev/null; then
        if TF_OUT="$(terraform output -raw airbyte_instance_id 2>/dev/null)"; then
            if [[ -n "${TF_OUT}" ]]; then
                RESOLVED_ID="${TF_OUT}"
                echo "    Resolved via terraform output: ${RESOLVED_ID}"
            fi
        fi
    fi
fi

# Method 3: Name-tag describe-instances fallback
if [[ -z "${RESOLVED_ID}" ]]; then
    echo "  → Falling back to Name-tag describe-instances …"
    TAG_NAME="${PROJECT}-${ENVIRONMENT}-airbyte-ec2"
    TAG_RESULT="$(aws ec2 describe-instances \
        --region "${AWS_REGION}" \
        --filters "Name=tag:Name,Values=${TAG_NAME}" \
                  "Name=instance-state-name,Values=pending,running" \
        --query "Reservations[0].Instances[0].InstanceId" \
        --output text 2>&1 || true)"

    if [[ -n "${TAG_RESULT}" ]] && [[ "${TAG_RESULT}" != "None" ]]; then
        RESOLVED_ID="${TAG_RESULT}"
        echo "    Resolved via Name tag '${TAG_NAME}': ${RESOLVED_ID}"
    fi
fi

if [[ -z "${RESOLVED_ID}" ]]; then
    fail "Could not resolve Airbyte EC2 instance ID" \
         "Provide an instance-id argument, run terraform apply, or ensure Name tag matches '${PROJECT}-${ENVIRONMENT}-airbyte-ec2'"
    exit 1
fi

pass "Instance ID resolved: ${RESOLVED_ID}"

fail_if_any

# =============================================================================
# CHECK 1 — Instance is running
# =============================================================================
header "CHECK 1: Instance state == running"

echo "  → Describing instance ${RESOLVED_ID} …"
INSTANCE_STATE="$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${RESOLVED_ID}" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text 2>&1 || true)"

if [[ "${INSTANCE_STATE}" == "running" ]]; then
    pass "Instance ${RESOLVED_ID} is running"
elif [[ -z "${INSTANCE_STATE}" ]] || [[ "${INSTANCE_STATE}" == "None" ]]; then
    fail "Instance ${RESOLVED_ID} not found or describe-instances returned empty" \
         "Verify the instance ID is correct and belongs to region ${AWS_REGION}"
else
    fail "Instance ${RESOLVED_ID} state is '${INSTANCE_STATE}' (expected 'running')" \
         "If stopped, start the instance. If terminated, run terraform apply."
fi

fail_if_any

# =============================================================================
# CHECK 2 — SSM Agent is online
# =============================================================================
header "CHECK 2: SSM Agent PingStatus == Online"

echo "  → Calling ssm describe-instance-information for ${RESOLVED_ID} …"
SSM_INFO="$(aws ssm describe-instance-information \
    --region "${AWS_REGION}" \
    --filters "Key=InstanceIds,Values=${RESOLVED_ID}" \
    --output json 2>&1 || true)"

PING_STATUS="$(echo "${SSM_INFO}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get('InstanceInformationList', [])
    if items:
        print(items[0].get('PingStatus', 'unknown'))
    else:
        print('not_found')
except Exception:
    print('parse_error')
" 2>/dev/null || echo 'parse_error')"

if [[ "${PING_STATUS}" == "Online" ]]; then
    pass "SSM Agent PingStatus: Online"
elif [[ "${PING_STATUS}" == "not_found" ]]; then
    fail "SSM Agent not found — instance ${RESOLVED_ID} not registered with SSM" \
         "Remediation: 1) verify instance has AmazonSSMManagedInstanceCore policy attached to its IAM role, 2) check outbound 443 to ssm/ssmmessages/ec2messages endpoints, 3) check SSM Agent is running: sudo systemctl status amazon-ssm-agent"
elif [[ "${PING_STATUS}" == "parse_error" ]]; then
    fail "Could not parse SSM describe-instance-information response" \
         "Raw output: $(echo "${SSM_INFO}" | head -c 300)"
elif [[ "${PING_STATUS}" == "ConnectionLost" ]]; then
    fail "SSM Agent PingStatus: ConnectionLost — agent was online but is now unreachable" \
         "Check network connectivity (egress 443 to ssm/ssmmessages/ec2messages), instance state, and agent logs"
else
    fail "SSM Agent PingStatus: ${PING_STATUS} (expected 'Online')" \
         "Agent may be starting up — wait and retry. If persists, check agent logs on the instance."
fi

fail_if_any

# =============================================================================
# CHECK 3 — Security group: zero ingress, one all-traffic egress
# =============================================================================
header "CHECK 3: Security group posture (R1 zero public ingress)"

echo "  → Finding security group attached to instance ${RESOLVED_ID} …"
SG_ID="$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${RESOLVED_ID}" \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
    --output text 2>&1 || true)"

if [[ -z "${SG_ID}" ]] || [[ "${SG_ID}" == "None" ]]; then
    fail "No security group found attached to instance ${RESOLVED_ID}" \
         "The instance must have at least one security group."
else
    echo "    Security group ID: ${SG_ID}"
    SG_JSON="$(aws ec2 describe-security-groups \
        --region "${AWS_REGION}" \
        --group-ids "${SG_ID}" \
        --output json 2>&1 || true)"

    SG_CHECK="$(echo "${SG_JSON}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    groups = data.get('SecurityGroups', [])
    if not groups:
        print('FAIL:no security groups in response')
        sys.exit(0)
    
    sg = groups[0]
    ingress = sg.get('IpPermissions', [])
    egress  = sg.get('IpPermissionsEgress', [])
    
    errors = []
    
    # --- Ingress check ---
    if len(ingress) > 0:
        # Build a brief description of offending rules
        rules_desc = []
        for rule in ingress:
            from_port = rule.get('FromPort', '*')
            to_port   = rule.get('ToPort', '*')
            proto     = rule.get('IpProtocol', '?')
            cidrs     = [r.get('CidrIp', '?') for r in rule.get('IpRanges', [])]
            sg_refs   = [r.get('GroupId', '?') for r in rule.get('UserIdGroupPairs', [])]
            rules_desc.append('proto={} ports={}-{} cidrs={} sg_refs={}'.format(
                proto, from_port, to_port, cidrs, sg_refs))
        errors.append('SG has {} ingress rule(s): {}'.format(len(ingress), ' | '.join(rules_desc)))
    
    # --- Egress check ---
    if len(egress) != 1:
        errors.append('expected exactly 1 egress rule, got {}'.format(len(egress)))
    else:
        rule = egress[0]
        proto = str(rule.get('IpProtocol', ''))
        ranges = rule.get('IpRanges', [])
        cidrs = [r.get('CidrIp', '') for r in ranges]
        
        if proto != '-1':
            errors.append('egress protocol is {} (expected -1 for all)'.format(proto))
        if '0.0.0.0/0' not in cidrs or len(cidrs) != 1:
            errors.append('egress IpRanges is {} (expected exactly [0.0.0.0/0])'.format(cidrs))
    
    if errors:
        print('FAIL:' + ' | '.join(errors))
    else:
        print('PASS:zero ingress, exactly one all-traffic egress')
except Exception as e:
    import traceback
    print('parse_error:' + str(e))
" 2>/dev/null || echo 'parse_error')"

    case "${SG_CHECK}" in
        PASS:*)
            pass "SG posture: ${SG_CHECK#PASS:}"
            ;;
        FAIL:*)
            fail "SG posture FAILED" \
                 "${SG_CHECK#FAIL:}"
            ;;
        *)
            fail "SG posture: could not parse describe-security-groups" \
                 "Raw output (truncated): $(echo "${SG_JSON}" | head -c 300)"
            ;;
    esac
fi

fail_if_any

# =============================================================================
# SUMMARY
# =============================================================================
header "VERIFY-SSM-ACCESS SUMMARY"

TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
echo ""
echo -e "  ${BOLD}Total assertions:${NC} ${TOTAL}"
echo -e "  ${GREEN}${BOLD}Passed:${NC} ${PASS_COUNT}"
echo -e "  ${RED}${BOLD}Failed:${NC} ${FAIL_COUNT}"
echo -e "  ${YELLOW}${BOLD}Skipped:${NC} ${SKIP_COUNT}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo -e "${RED}${BOLD}❌ SOME CHECKS FAILED${NC}"
    echo ""
    echo -e "  This is ${YELLOW}expected${NC} during the red phase —"
    echo "  the Terraform code for airbyte-ui-access has not been applied yet."
    echo "  Once the spec is implemented and terraform apply has completed, re-run this script."
    exit 1
else
    echo -e "${GREEN}${BOLD}✅ ALL CHECKS PASSED${NC}"
    exit 0
fi
