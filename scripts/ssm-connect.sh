#!/usr/bin/env bash
# =============================================================================
# ssm-connect.sh — SSM Session Manager access to the Airbyte EC2 host
# =============================================================================
# Subcommands:
#   ui     Port-forward localhost:${LOCAL_PORT} -> instance:8000 (Airbyte UI)
#   shell  Interactive SSM session (SSM-SessionManagerRunShell default doc)
#
# Environment overrides:
#   PROJECT=data4ai  ENVIRONMENT=prod  AWS_REGION=us-east-1  LOCAL_PORT=8000
#
# Exit codes:
#   0  session closed cleanly
#   1  instance resolution / instance-state error
#   2  usage / preflight error (aws CLI, session-manager-plugin, credentials)
#
# Flow (per specs/airbyte-ui-access/plan.md):
#   usage-check -> aws CLI present -> session-manager-plugin present ->
#   sts get-caller-identity -> resolve instance ID (terraform output, then
#   Name-tag describe-instances fallback) -> assert running -> start-session
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT="${PROJECT:-data4ai}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LOCAL_PORT="${LOCAL_PORT:-8000}"

PLUGIN_INSTALL_URL="https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"

log() { echo "[ssm-connect] $*"; }
err() { echo "[ssm-connect] ERROR: $*" >&2; }

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <ui|shell>

Subcommands:
  ui      Port-forward localhost:${LOCAL_PORT} to the Airbyte UI (instance:8000)
  shell   Interactive SSM shell session (SSM-SessionManagerRunShell)

Environment overrides:
  PROJECT=${PROJECT}  ENVIRONMENT=${ENVIRONMENT}  AWS_REGION=${AWS_REGION}  LOCAL_PORT=${LOCAL_PORT}

Exit codes: 0 session closed cleanly · 1 resolution/state error · 2 usage/preflight error
EOF
}

# ---------------------------------------------------------------------------
# 1. Subcommand validation FIRST (no dependency preconditions — spec R3)
# ---------------------------------------------------------------------------
if [[ $# -ne 1 ]] || { [[ "$1" != "ui" ]] && [[ "$1" != "shell" ]]; }; then
  usage
  exit 2
fi
SUBCOMMAND="$1"

# ---------------------------------------------------------------------------
# 2. Preflight: tooling + credentials
# ---------------------------------------------------------------------------
if ! command -v aws >/dev/null 2>&1; then
  err "aws CLI not found in PATH — install AWS CLI v2 first"
  exit 2
fi

if ! command -v session-manager-plugin >/dev/null 2>&1; then
  err "session-manager-plugin not found in PATH"
  err "Install instructions: ${PLUGIN_INSTALL_URL}"
  exit 2
fi

if ! aws sts get-caller-identity --region "${AWS_REGION}" >/dev/null; then
  err "AWS credentials missing or expired (sts get-caller-identity failed — see above)"
  exit 2
fi

# ---------------------------------------------------------------------------
# 3. Resolve the Airbyte instance ID
#    Primary: terraform output (from the repo root)
#    Fallback: Name-tag lookup via EC2 API (pending,running)
# ---------------------------------------------------------------------------
INSTANCE_ID=""

cd "${PROJECT_ROOT}"
if [[ -d ".terraform" ]]; then
  INSTANCE_ID="$(terraform output -raw airbyte_instance_id 2>/dev/null || true)"
fi

if [[ -z "${INSTANCE_ID}" ]]; then
  log "terraform output unavailable — falling back to Name-tag lookup (${PROJECT}-${ENVIRONMENT}-airbyte-ec2)"
  INSTANCE_ID="$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-airbyte-ec2" \
              "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || true)"
  if [[ "${INSTANCE_ID}" == "None" ]]; then
    INSTANCE_ID=""
  fi
fi

if [[ -z "${INSTANCE_ID}" ]]; then
  err "could not resolve the Airbyte instance ID (working dir: ${PROJECT_ROOT})"
  err "run 'terraform apply' first, or set PROJECT/ENVIRONMENT to match the deployment"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Assert the instance is running
# ---------------------------------------------------------------------------
INSTANCE_STATE="$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null || true)"

if [[ "${INSTANCE_STATE}" != "running" ]]; then
  err "instance ${INSTANCE_ID} is in state '${INSTANCE_STATE:-unknown}' (expected 'running')"
  err "run 'terraform apply' to (re)create or start the instance"
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Start the session
# ---------------------------------------------------------------------------
case "${SUBCOMMAND}" in
  ui)
    log "Airbyte UI → http://localhost:${LOCAL_PORT} (Ctrl-C to close tunnel)"
    aws ssm start-session \
      --region "${AWS_REGION}" \
      --target "${INSTANCE_ID}" \
      --document-name AWS-StartPortForwardingSession \
      --parameters "{\"portNumber\":[\"8000\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
    ;;
  shell)
    log "Opening SSM shell on ${INSTANCE_ID} (default document SSM-SessionManagerRunShell)"
    aws ssm start-session \
      --region "${AWS_REGION}" \
      --target "${INSTANCE_ID}"
    ;;
esac
