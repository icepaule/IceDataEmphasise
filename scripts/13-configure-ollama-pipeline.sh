#!/usr/bin/env bash
# =============================================================================
# 13-configure-ollama-pipeline.sh - Configure Ollama AI Classifier Pipeline
# =============================================================================
# Creates the two-stage classification pipeline and sets Cribl Global Variables
# for Ollama connection settings.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "$SCRIPT_DIR/lib/api-helpers.sh"

# --- Main ---
print_header "Configure Ollama AI Classifier Pipeline"

load_env "$PROJECT_DIR/.env"

require_commands curl jq

# Validate Ollama settings
: "${OLLAMA_HOST:?OLLAMA_HOST is not set in .env}"
: "${OLLAMA_PORT:?OLLAMA_PORT is not set in .env}"
: "${OLLAMA_MODEL:?OLLAMA_MODEL is not set in .env}"

# Verify Cribl is running
cribl_health_check || die "Cribl Stream is not healthy."

# Authenticate
cribl_auth

# ============================================================================
# Step 1: Configure Cribl Global Variables for Ollama
# ============================================================================
log_step "Setting Cribl Global Variables for Ollama"

# Set OLLAMA_HOST global variable
log_info "Setting global var: OLLAMA_HOST = ${OLLAMA_HOST}"
cribl_api PUT "/system/vars/OLLAMA_HOST" "$(jq -n \
    --arg id "OLLAMA_HOST" \
    --arg value "$OLLAMA_HOST" \
    '{id: $id, value: $value, type: "string", description: "Ollama AI server hostname/IP"}'
)" >/dev/null
log_ok "Global var OLLAMA_HOST set"

# Set OLLAMA_PORT global variable
log_info "Setting global var: OLLAMA_PORT = ${OLLAMA_PORT}"
cribl_api PUT "/system/vars/OLLAMA_PORT" "$(jq -n \
    --arg id "OLLAMA_PORT" \
    --arg value "$OLLAMA_PORT" \
    '{id: $id, value: $value, type: "string", description: "Ollama AI server port"}'
)" >/dev/null
log_ok "Global var OLLAMA_PORT set"

# Set OLLAMA_MODEL global variable
log_info "Setting global var: OLLAMA_MODEL = ${OLLAMA_MODEL}"
cribl_api PUT "/system/vars/OLLAMA_MODEL" "$(jq -n \
    --arg id "OLLAMA_MODEL" \
    --arg value "$OLLAMA_MODEL" \
    '{id: $id, value: $value, type: "string", description: "Ollama model for log classification"}'
)" >/dev/null
log_ok "Global var OLLAMA_MODEL set"

# ============================================================================
# Step 2: Create Ollama classifier pipeline
# ============================================================================
log_step "Creating Ollama classifier pipeline"

PIPELINE_FILE="$PROJECT_DIR/configs/stream/pipelines/pipeline-ollama-classifier.json"

if [[ ! -f "$PIPELINE_FILE" ]]; then
    die "Pipeline config not found: $PIPELINE_FILE"
fi

cribl_create_pipeline "$PIPELINE_FILE"

# ============================================================================
# Step 3: Test Ollama connectivity
# ============================================================================
log_step "Testing Ollama connectivity"

log_info "Testing Ollama endpoint: ${OLLAMA_HOST}:${OLLAMA_PORT}"
if check_port_open "$OLLAMA_HOST" "$OLLAMA_PORT" 5; then
    log_ok "Ollama port ${OLLAMA_PORT} is reachable on ${OLLAMA_HOST}"

    # Check if model is available
    log_info "Checking if model '${OLLAMA_MODEL}' is available..."
    models=$(curl -sf "http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/tags" 2>/dev/null | jq -r '.models[].name' 2>/dev/null || echo "")
    if echo "$models" | grep -q "${OLLAMA_MODEL}"; then
        log_ok "Model '${OLLAMA_MODEL}' is available"
    else
        log_warn "Model '${OLLAMA_MODEL}' not found. Available models: $models"
        log_warn "Pull it with: ollama pull ${OLLAMA_MODEL}"
    fi
else
    log_warn "Ollama is NOT reachable at ${OLLAMA_HOST}:${OLLAMA_PORT}"
    log_warn "Classification will fall back to 'operational' for unknown events"
fi

# ============================================================================
# Step 4: Commit and deploy
# ============================================================================
log_step "Committing and deploying Ollama pipeline configuration"

cribl_commit_deploy "Add Ollama AI classifier pipeline with rule-based + AI classification"

log_ok "Ollama classifier pipeline configuration complete!"
log_info "Summary:"
log_info "  - Pipeline: ollama_classifier"
log_info "  - Stage 1: Rule-based classification (~80-90% of events)"
log_info "  - Stage 2: Ollama AI (${OLLAMA_MODEL}) for unknowns"
log_info "  - Fallback: operational (safe default)"
log_info "  - Global vars: OLLAMA_HOST, OLLAMA_PORT, OLLAMA_MODEL"
