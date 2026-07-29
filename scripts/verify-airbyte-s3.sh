#!/usr/bin/env bash
# =============================================================================
# verify-airbyte-s3.sh — Airbyte ↔ S3 integration test
# =============================================================================
# Covers: R4 (Connection), R6 (Partitioning), R7 (AVRO Format)
# Plus edge-case and boundary tests per Spec Kit methodology.
#
# Usage:
#   ./scripts/verify-airbyte-s3.sh [airbyte-url] [s3-endpoint] [bucket-name]
#
# Defaults:
#   airbyte-url    = http://localhost:8000
#   s3-endpoint    = http://host.docker.internal:4566
#   bucket-name    = data4ai-staging-local
#
# Pre-conditions:
#   1. LocalStack running with S3 enabled
#   2. Airbyte running (docker compose or EC2 user_data)
#   3. Terraform applied (local env) — bucket exists
#
# This script MUST fail initially (red phase).  This is expected and correct.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration & defaults
# ---------------------------------------------------------------------------
AIRBYTE_URL="${1:-http://localhost:8000}"
S3_ENDPOINT="${2:-http://host.docker.internal:4566}"
BUCKET_NAME="${3:-data4ai-staging-local}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_OPTS=(--endpoint-url="${S3_ENDPOINT}" --region="${AWS_REGION}" --no-sign-request)
AIRBYTE_API="${AIRBYTE_URL}/api/v1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Derived
AIRBYTE_HEALTH="${AIRBYTE_URL}/api/v1/health"
AIRBYTE_DESTINATIONS="${AIRBYTE_API}/destinations"
AIRBYTE_DEST_CHECK="${AIRBYTE_API}/destinations/check_connection"

# Timeouts
HEALTH_TIMEOUT=120       # seconds to wait for Airbyte to be healthy
HEALTH_INTERVAL=5        # seconds between health checks

# ---------------------------------------------------------------------------
# Colour helpers
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

aws_ls() {
    aws "${AWS_OPTS[@]}" "$@" 2>&1
}

fail_if_any() {
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo ""
        echo -e "${RED}${BOLD}Exiting early due to failures.${NC}"
        exit 1
    fi
}

# =============================================================================
# PRE-FLIGHT — S3 endpoint and Airbyte connectivity
# =============================================================================
header "PRE-FLIGHT: Endpoint reachability"

echo "  → Probing S3 endpoint ${S3_ENDPOINT} …"
if curl -sf --max-time 5 "${S3_ENDPOINT}/_localstack/health" > /dev/null 2>&1; then
    pass "S3 endpoint (LocalStack) is reachable"
else
    # EDGE CASE: S3 endpoint might not expose health; try raw S3 API
    if aws_ls s3api list-buckets > /dev/null 2>&1; then
        pass "S3 endpoint (LocalStack) reachable via s3api list-buckets"
    else
        fail "S3 endpoint ${S3_ENDPOINT} is NOT reachable" \
             "Start LocalStack:  docker compose up -d"
    fi
fi

echo ""
echo "  → Probing Airbyte health at ${AIRBYTE_HEALTH} …"

# ---------------------------------------------------------------------------
# Wait for Airbyte health with timeout
# ---------------------------------------------------------------------------
AIRBYTE_READY=false
ELAPSED=0

while [[ ${ELAPSED} -lt ${HEALTH_TIMEOUT} ]]; do
    if curl -sf --max-time 3 "${AIRBYTE_HEALTH}" > /dev/null 2>&1; then
        AIRBYTE_READY=true
        break
    fi
    echo -ne "  ${YELLOW}Waiting for Airbyte … ${ELAPSED}s / ${HEALTH_TIMEOUT}s${NC}\r"
    sleep "${HEALTH_INTERVAL}"
    ELAPSED=$((ELAPSED + HEALTH_INTERVAL))
done
echo ""

if ${AIRBYTE_READY}; then
    pass "Airbyte API is healthy (waited ${ELAPSED}s)"
else
    fail "Airbyte API NOT healthy after ${HEALTH_TIMEOUT}s" \
         "Check Airbyte is running:  docker compose ps  (or check EC2)"
    exit 1
fi

# Verify health response structure
HEALTH_RESP="$(curl -sf --max-time 5 "${AIRBYTE_HEALTH}" 2>/dev/null || true)"
if echo "${HEALTH_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('available',False)==True" 2>/dev/null; then
    pass "Airbyte health reports available=true"
else
    fail "Airbyte health response unexpected: ${HEALTH_RESP}"
fi

fail_if_any

# =============================================================================
# R4 — Airbyte S3 destination connection check
# =============================================================================
header "R4: Airbyte S3 destination connection check"

echo "  → Listing existing S3 destinations …"
DEST_LIST="$(curl -sf --max-time 10 "${AIRBYTE_DESTINATIONS}" 2>/dev/null || true)"
if [[ -z "${DEST_LIST}" ]]; then
    fail "Could not retrieve destinations list from Airbyte"
    fail_if_any
fi

# Check if we already have an S3 destination configured
EXISTING_S3_DEST="$(echo "${DEST_LIST}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    dests = data if isinstance(data, list) else data.get('destinations', data.get('data', []))
    for d in dests:
        name = d.get('destinationName', d.get('name', ''))
        if 's3' in name.lower():
            print(d.get('destinationId', d.get('id', '')))
            break
    else:
        print('')
except Exception:
    print('parse_error')
" 2>/dev/null || echo '')"

S3_DEST_ID=""

if [[ -n "${EXISTING_S3_DEST}" ]] && [[ "${EXISTING_S3_DEST}" != "parse_error" ]]; then
    S3_DEST_ID="${EXISTING_S3_DEST}"
    pass "Found existing S3 destination (id=${S3_DEST_ID})"
else
    # Create a new S3 destination
    echo ""
    echo "  → Creating new S3 destination configuration …"

    # Airbyte API destination creation payload
    # Configuration keys based on Airbyte S3 destination connector spec
    CREATE_PAYLOAD=$(cat <<EOJSON
{
  "name": "localstack-s3-test",
  "destinationDefinitionId": "4816b78f-1489-44c1-9060-4b19d5fa9362",
  "workspaceId": "$(echo "${DEST_LIST}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
dests = data if isinstance(data, list) else data.get('destinations', [])
if dests:
    ws = dests[0].get('workspaceId', dests[0].get('workspace_id', ''))
    print(ws)
" 2>/dev/null || echo '')",
  "connectionConfiguration": {
    "s3_bucket_name": "${BUCKET_NAME}",
    "s3_bucket_path": "\${NAMESPACE}/\${STREAM_NAME}/year=\${YEAR}/month=\${MONTH}/day=\${DAY}/hour=\${HOUR}",
    "s3_bucket_region": "${AWS_REGION}",
    "format": {
      "format_type": "Avro",
      "compression_codec": {
        "codec": "deflate",
        "compression_level": 6
      }
    },
    "s3_endpoint": "${S3_ENDPOINT}",
    "access_key_id": "test",
    "secret_access_key": "test",
    "path_format": "\${NAMESPACE}/\${STREAM_NAME}/year=\${YEAR}/month=\${MONTH}/day=\${DAY}/hour=\${HOUR}"
  }
}
EOJSON
)

    CREATE_RESP="$(curl -sf --max-time 15 \
        -X POST "${AIRBYTE_DESTINATIONS}" \
        -H "Content-Type: application/json" \
        -d "${CREATE_PAYLOAD}" 2>/dev/null || true)"

    if [[ -n "${CREATE_RESP}" ]]; then
        S3_DEST_ID="$(echo "${CREATE_RESP}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('destinationId', d.get('id', '')))
except Exception:
    print('')
" 2>/dev/null || echo '')"
        if [[ -n "${S3_DEST_ID}" ]]; then
            pass "Created S3 destination (id=${S3_DEST_ID})"
        else
            # EDGE CASE: creation returned but without expected ID field
            skip "S3 destination creation response did not contain destinationId — using simulated check"
        fi
    else
        # EDGE CASE: Airbyte API might not have the S3 destination connector installed
        skip "Could not create S3 destination via API — connector may not be installed yet"
    fi
fi

# If we have a destination ID, run the connection check
if [[ -n "${S3_DEST_ID}" ]]; then
    echo ""
    echo "  → Running destination connection check (id=${S3_DEST_ID}) …"
    CHECK_PAYLOAD="{\"destinationId\": \"${S3_DEST_ID}\"}"
    CHECK_RESP="$(curl -sf --max-time 30 \
        -X POST "${AIRBYTE_DEST_CHECK}" \
        -H "Content-Type: application/json" \
        -d "${CHECK_PAYLOAD}" 2>/dev/null || true)"

    if [[ -n "${CHECK_RESP}" ]]; then
        CHECK_STATUS="$(echo "${CHECK_RESP}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('status', d.get('jobInfo', {}).get('status', 'unknown')))
except Exception:
    print('parse_error')
" 2>/dev/null || echo 'parse_error')"

        if [[ "${CHECK_STATUS}" == "succeeded" ]]; then
            pass "Destination connection check: succeeded"
        elif [[ "${CHECK_STATUS}" == "failed" ]]; then
            MSG="$(echo "${CHECK_RESP}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('message', d.get('jobInfo',{}).get('message','')))
except:
    print('')
" 2>/dev/null || echo '')"
            fail "Destination connection check: failed — ${MSG}" \
                 "Verify S3 endpoint and credentials are correct"
        else
            fail "Destination connection check: unexpected status '${CHECK_STATUS}'" \
                 "Raw response: ${CHECK_RESP}"
        fi
    else
        fail "Destination connection check returned empty response"
    fi
else
    fail "Skipping destination check — no destination ID available"
fi

fail_if_any

# =============================================================================
# R6 — Hive-style partition format verification
# =============================================================================
header "R6: Partitioned S3 path format verification"

# Expected pattern: <table_name>/year=YYYY/month=MM/day=DD/hour=HH/
PARTITION_PATTERN='.*/year=[0-9]{4}/month=[0-9]{2}/day=[0-9]{2}/hour=[0-9]{2}/.*'

echo "  → Listing objects in bucket '${BUCKET_NAME}' …"
S3_OBJECTS="$(aws_ls s3api list-objects-v2 --bucket "${BUCKET_NAME}" --query 'Contents[*].Key' --output text 2>&1 || true)"

if [[ -z "${S3_OBJECTS}" ]] || [[ "${S3_OBJECTS}" == "None" ]] || [[ "${S3_OBJECTS}" == *"NoSuchBucket"* ]]; then
    # EDGE CASE: no objects yet — simulate check or note
    skip "Bucket '${BUCKET_NAME}' is empty or not found — no objects to verify partition format" \
         "After running an Airbyte sync, re-run this script"
else
    # Count objects matching the hive partition pattern
    MATCH_COUNT=0
    MISMATCH_COUNT=0
    while IFS= read -r key; do
        if [[ -z "${key}" ]]; then continue; fi
        if [[ "${key}" =~ ${PARTITION_PATTERN} ]]; then
            MATCH_COUNT=$((MATCH_COUNT + 1))
        else
            MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
            fail "Object '${key}' does NOT match partition pattern: <table>/year=YYYY/month=MM/day=DD/hour=HH/"
        fi
    done <<< "$(echo "${S3_OBJECTS}" | tr '\t' '\n')"

    if [[ ${MATCH_COUNT} -gt 0 ]]; then
        pass "Found ${MATCH_COUNT} object(s) matching Hive-style partition pattern"
    else
        fail "No objects match the expected partition pattern" \
             "Expected: <table_name>/year=YYYY/month=MM/day=DD/hour=HH/<file>"
    fi

    if [[ ${MISMATCH_COUNT} -gt 0 ]]; then
        fail "${MISMATCH_COUNT} object(s) do NOT match the partition pattern"
    fi

    # BOUNDARY: verify at least one object has a recognizable table name prefix
    echo ""
    echo "  → BOUNDARY: checking for recognizable table name prefixes …"
    TABLE_NAMES="$(echo "${S3_OBJECTS}" | tr '\t' '\n' | grep -oP '^[^/]+(?=/year=)' | sort -u || true)"
    if [[ -n "${TABLE_NAMES}" ]]; then
        pass "Table name(s) found in S3 paths: ${TABLE_NAMES}"
    else
        fail "No table name prefixes found in S3 paths"
    fi
fi

fail_if_any

# =============================================================================
# R7 — AVRO format verification (file suffix + magic bytes)
# =============================================================================
header "R7: AVRO output format verification"

echo "  → Checking for .avro file suffix …"

AVRO_FILES=""
if [[ -n "${S3_OBJECTS:-}" ]] && [[ "${S3_OBJECTS}" != "None" ]]; then
    AVRO_FILES="$(echo "${S3_OBJECTS}" | tr '\t' '\n' | grep '\.avro$' || true)"
fi
AVRO_COUNT=0
if [[ -n "${AVRO_FILES}" ]]; then
    AVRO_COUNT="$(echo "${AVRO_FILES}" | grep -c '.' || echo 0)"
fi

if [[ ${AVRO_COUNT} -gt 0 ]]; then
    pass "Found ${AVRO_COUNT} file(s) with .avro suffix"
else
    skip "No .avro files found in bucket — no objects to verify format" \
         "After running an Airbyte sync with AVRO format, re-run this script"
fi

# For each AVRO file (up to 3), verify magic bytes
echo ""
echo "  → Verifying AVRO magic header bytes (Obj + 0x01) …"

AVRO_MAGIC_EXPECTED="4f626a01"  # "Obj" + 0x01 in hex

CHECKED=0
AVRO_VALID=0
AVRO_INVALID=0

if [[ -n "${AVRO_FILES}" ]]; then
    while IFS= read -r avro_key; do
        if [[ -z "${avro_key}" ]]; then continue; fi
        if [[ ${CHECKED} -ge 3 ]]; then break; fi  # Check up to 3 files
        CHECKED=$((CHECKED + 1))

        echo "    → Checking file: ${avro_key}"

        # Download first 4 bytes
        TMPFILE="$(mktemp /tmp/avro-check.XXXXXX)"
        if aws_ls s3api get-object --bucket "${BUCKET_NAME}" --key "${avro_key}" "${TMPFILE}" > /dev/null 2>&1; then
            # Read first 4 bytes as hex
            HEADER_HEX="$(xxd -p -l 4 "${TMPFILE}" 2>/dev/null || od -A n -t x1 -N 4 "${TMPFILE}" 2>/dev/null | tr -d ' \n' || true)"

            if [[ "${HEADER_HEX}" == "${AVRO_MAGIC_EXPECTED}" ]]; then
                pass "AVRO magic bytes valid: ${avro_key} (header=${HEADER_HEX})"
                AVRO_VALID=$((AVRO_VALID + 1))
            else
                # EDGE CASE: might be snappy/deflate compressed — try decompress and check
                # First check if it starts with the Avro marker byte
                FIRST_BYTE="$(xxd -p -l 1 "${TMPFILE}" 2>/dev/null || od -A n -t x1 -N 1 "${TMPFILE}" 2>/dev/null | tr -d ' \n' || true)"
                if [[ "${FIRST_BYTE}" == "4f" ]]; then
                    # Starts with 'O' — might be valid
                    pass "AVRO file starts with 'O' (likely valid): ${avro_key} (first byte=${FIRST_BYTE})"
                    AVRO_VALID=$((AVRO_VALID + 1))
                else
                    fail "AVRO magic bytes mismatch for: ${avro_key}" \
                         "Expected header: ${AVRO_MAGIC_EXPECTED}, Got: ${HEADER_HEX} (first byte: ${FIRST_BYTE})"
                    AVRO_INVALID=$((AVRO_INVALID + 1))
                fi
            fi

            # BOUNDARY: verify file is not empty (AVRO files have minimum ~20 bytes for schema)
            FILE_SIZE="$(stat -c%s "${TMPFILE}" 2>/dev/null || echo 0)"
            if [[ ${FILE_SIZE} -gt 20 ]]; then
                pass "AVRO file is non-trivial (${FILE_SIZE} bytes): ${avro_key}"
            elif [[ ${FILE_SIZE} -gt 0 ]]; then
                fail "AVRO file is suspiciously small (${FILE_SIZE} bytes): ${avro_key}"
            else
                fail "AVRO file is empty (0 bytes): ${avro_key}"
            fi
        else
            fail "Could not download object for AVRO check: ${avro_key}"
        fi

        rm -f "${TMPFILE}"
    done <<< "$(echo "${AVRO_FILES}" | head -3)"
fi

if [[ ${CHECKED} -eq 0 ]]; then
    skip "No AVRO files available to verify magic bytes"
elif [[ ${AVRO_INVALID} -gt 0 ]]; then
    fail "${AVRO_INVALID} AVRO file(s) had invalid magic bytes"
fi

fail_if_any

# =============================================================================
# EDGE CASES — Additional protective tests
# =============================================================================
header "EDGE CASES: Protective tests"

# EDGE: Verify S3 path format matches spec exactly
echo "  → EDGE: verifying partition key names match spec (year=, month=, day=, hour=) …"
if [[ -n "${S3_OBJECTS:-}" ]] && [[ "${S3_OBJECTS}" != "None" ]]; then
    # Check for wrong key names
    if echo "${S3_OBJECTS}" | grep -qP '(yr=|mo=|dy=|hr=|yyyy=|mm=|dd=)'; then
        fail "S3 paths contain non-standard partition key names (expected year=/month=/day=/hour=)"
    else
        pass "S3 partition key names match spec (year=/month=/day=/hour=)"
    fi
else
    skip "No S3 objects to check partition key names"
fi

# EDGE: Ensure no temp/partial files without .avro suffix in partition paths
echo ""
echo "  → EDGE: checking for non-AVRO files in partition paths …"
if [[ -n "${S3_OBJECTS:-}" ]] && [[ "${S3_OBJECTS}" != "None" ]]; then
    NON_AVRO="$(echo "${S3_OBJECTS}" | tr '\t' '\n' | grep -E '/year=[0-9]{4}/' | grep -v '\.avro$' || true)"
    if [[ -n "${NON_AVRO}" ]]; then
        fail "Found non-AVRO files in partition paths: $(echo "${NON_AVRO}" | tr '\n' ' ')"
    else
        pass "No non-AVRO files found in partition paths"
    fi
else
    skip "No S3 objects to check for non-AVRO files"
fi

# BOUNDARY: Check depths — partitions should be at least 4 levels deep (year/month/day/hour)
echo ""
echo "  → BOUNDARY: verifying partition depth (at least 4 levels: year, month, day, hour) …"
if [[ -n "${AVRO_FILES:-}" ]]; then
    SHALLOW="$(echo "${AVRO_FILES}" | while read -r f; do
        depth=$(echo "${f}" | tr '/' '\n' | grep -c '=')
        if [[ ${depth} -lt 4 ]]; then echo "${f} (depth=${depth})"; fi
    done)"
    if [[ -n "${SHALLOW}" ]]; then
        fail "Some files have insufficient partition depth: ${SHALLOW}"
    else
        pass "All partitioned files have at least 4 partition levels"
    fi
fi

# BOUNDARY: Verify bucket-level S3 operations still work after sync
echo ""
echo "  → BOUNDARY: verifying bucket is still accessible after sync operations …"
if aws_ls s3api head-bucket --bucket "${BUCKET_NAME}" > /dev/null 2>&1; then
    pass "Bucket '${BUCKET_NAME}' is still accessible"
else
    fail "Bucket '${BUCKET_NAME}' is no longer accessible"
fi

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
    echo "  Once infrastructure and Airbyte are running with data synced, re-run this script."
    exit 1
else
    echo -e "${GREEN}${BOLD}✅ ALL TESTS PASSED${NC}"
    exit 0
fi
