#!/usr/bin/env bash
# =============================================================================
# 11-configure-docker-sources.sh - Configure Docker log source in Cribl
# =============================================================================
# Creates a file_monitor source for all Docker container logs.
# Sets file ACLs so the cribl user can read Docker logs.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "$SCRIPT_DIR/lib/api-helpers.sh"

# --- Main ---
print_header "Configure Docker Log Sources"

load_env "$PROJECT_DIR/.env"

require_commands curl jq

# Verify Cribl is running
cribl_health_check || die "Cribl Stream is not healthy."

# Authenticate
cribl_auth

# ============================================================================
# Step 1: Set ACLs for Docker log directory
# ============================================================================
log_step "Setting file ACLs for Docker container logs"

DOCKER_LOG_DIR="/var/lib/docker/containers"
CRIBL_USER="${CRIBL_SERVICE_USER:-cribl}"

if [[ -d "$DOCKER_LOG_DIR" ]]; then
    if command -v setfacl &>/dev/null; then
        log_info "Granting ${CRIBL_USER} read access to $DOCKER_LOG_DIR"
        setfacl -R -m "u:${CRIBL_USER}:rx" "$DOCKER_LOG_DIR" 2>/dev/null || \
            log_warn "Failed to set ACLs (may need root). Ensure cribl user is in docker group."
        setfacl -R -d -m "u:${CRIBL_USER}:rx" "$DOCKER_LOG_DIR" 2>/dev/null || true
        log_ok "ACLs set for $DOCKER_LOG_DIR"
    else
        log_warn "setfacl not available. Ensure cribl user is in docker group:"
        log_warn "  usermod -aG docker ${CRIBL_USER}"
    fi
else
    log_warn "Docker log directory not found: $DOCKER_LOG_DIR"
    log_warn "Docker may not be installed or logs may be in a different location."
fi

# ============================================================================
# Step 2: Create Docker source via API
# ============================================================================
log_step "Creating Docker all-containers source"

SOURCE_FILE="$PROJECT_DIR/configs/stream/sources/docker-all-containers.json"

if [[ ! -f "$SOURCE_FILE" ]]; then
    die "Source config not found: $SOURCE_FILE"
fi

cribl_create_source "file_monitor" "$SOURCE_FILE"

# ============================================================================
# Step 3: Commit and deploy
# ============================================================================
log_step "Committing and deploying Docker source configuration"

cribl_commit_deploy "Add Docker all-containers file_monitor source with AI classifier pre-pipeline"

log_ok "Docker source configuration complete!"
log_info "Summary:"
log_info "  - Source: docker_all_containers (file_monitor)"
log_info "  - Path: /var/lib/docker/containers/*/*.log"
log_info "  - Pre-pipeline: ollama_classifier"
log_info "  - Note: Ensure ollama_classifier pipeline exists (run script 13)"
