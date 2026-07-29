#!/usr/bin/env bash
# =============================================================================
# local-up.sh — Spin up the full local environment
# =============================================================================
# 1. Starts LocalStack via docker compose (waits on the health endpoint)
# 2. terraform init
# 3. terraform apply -var-file=envs/local.tfvars
#
# Safe to re-run (idempotent). Use scripts/local-down.sh to tear down.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

TFVARS="envs/local.tfvars"
LOCALSTACK_HEALTH_URL="http://localhost:4566/_localstack/health"
HEALTH_TIMEOUT=60   # seconds
HEALTH_INTERVAL=2   # seconds

log()  { echo "[local-up] $*"; }
fail() { echo "[local-up] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
command -v docker    >/dev/null 2>&1 || fail "docker is not installed or not in PATH"
command -v terraform >/dev/null 2>&1 || fail "terraform is not installed or not in PATH"
command -v curl      >/dev/null 2>&1 || fail "curl is not installed or not in PATH"
docker info >/dev/null 2>&1          || fail "docker daemon is not running (or no permission). Start Docker first."
[[ -f "${TFVARS}" ]]                 || fail "${TFVARS} not found"

# Safety: this script only ever targets the local environment.
grep -Eq '^\s*environment\s*=\s*"local"' "${TFVARS}" \
  || fail "safety check: ${TFVARS} does not set environment = \"local\""

# ---------------------------------------------------------------------------
# 1. LocalStack
# ---------------------------------------------------------------------------
log "Starting LocalStack (docker compose up -d) ..."
docker compose up -d

log "Waiting for LocalStack health at ${LOCALSTACK_HEALTH_URL} (timeout ${HEALTH_TIMEOUT}s) ..."
elapsed=0
until curl -sf --max-time 3 "${LOCALSTACK_HEALTH_URL}" >/dev/null 2>&1; do
  if (( elapsed >= HEALTH_TIMEOUT )); then
    echo "[local-up] ERROR: LocalStack did not become healthy within ${HEALTH_TIMEOUT}s" >&2
    echo "[local-up] Inspect with: docker compose logs localstack" >&2
    exit 1
  fi
  sleep "${HEALTH_INTERVAL}"
  elapsed=$((elapsed + HEALTH_INTERVAL))
done
log "LocalStack is healthy (${elapsed}s)."

# ---------------------------------------------------------------------------
# 2. Terraform init
# ---------------------------------------------------------------------------
log "Running terraform init ..."
terraform init -input=false

# ---------------------------------------------------------------------------
# 3. Terraform apply (local)
# ---------------------------------------------------------------------------
log "Running terraform apply (-var-file=${TFVARS}) ..."
terraform apply -var-file="${TFVARS}" -auto-approve -input=false

log "Apply complete. Current outputs:"
terraform output

echo ""
log "Local environment is up."
log "  • Run integration tests:  ./scripts/test-local.sh"
log "  • Tear everything down:   ./scripts/local-down.sh"
