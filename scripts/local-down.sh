#!/usr/bin/env bash
# =============================================================================
# local-down.sh — Tear down the full local environment
# =============================================================================
# 1. terraform destroy (local environment only)
# 2. docker compose down -v (stops LocalStack and drops its state volume)
#
# Safety: destroys ONLY the local environment — the tfvars file is verified
# to contain environment = "local" before anything destructive happens.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

TFVARS="envs/local.tfvars"

log() { echo "[local-down] $*"; }
fail() { echo "[local-down] ERROR: $*" >&2; exit 1; }

[[ -f "${TFVARS}" ]] || fail "${TFVARS} not found"

# Safety: never let this script destroy anything but the local environment.
grep -Eq '^\s*environment\s*=\s*"local"' "${TFVARS}" \
  || fail "safety check: ${TFVARS} does not set environment = \"local\" — refusing to destroy"

# Dummy basic-auth credentials for the required airbyte-ui-access variables
# (inert LocalStack-only values: destroy evaluates required variables too;
# the dummy lives only in gitignored local state).
export TF_VAR_airbyte_basic_auth_username="${TF_VAR_airbyte_basic_auth_username:-local-dev}"
export TF_VAR_airbyte_basic_auth_password="${TF_VAR_airbyte_basic_auth_password:-local-dummy-pw-sentinel-keep-local}"

# ---------------------------------------------------------------------------
# 1. Terraform destroy (local)
# ---------------------------------------------------------------------------
if [[ -d ".terraform" ]] && terraform state list >/dev/null 2>&1; then
  if [[ -n "$(terraform state list 2>/dev/null || true)" ]]; then
    log "Running terraform destroy (-var-file=${TFVARS}) ..."
    terraform destroy -var-file="${TFVARS}" -auto-approve -input=false
  else
    log "Terraform state is empty — nothing to destroy."
  fi
else
  log "Terraform not initialised — skipping destroy."
fi

# ---------------------------------------------------------------------------
# 2. LocalStack down (+ state volume)
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  log "Stopping LocalStack (docker compose down -v) ..."
  docker compose down -v --remove-orphans
else
  log "Docker unavailable — skipping docker compose down."
fi

log "Local environment torn down."
