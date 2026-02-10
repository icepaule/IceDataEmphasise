#!/usr/bin/env bash
# =============================================================================
# 05-configure-destinations.sh - Configure Cribl Stream destinations
# =============================================================================
# Creates Splunk HEC and S2S destinations via Cribl API.
# Substitutes environment variables in destination JSON configs before sending.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "$SCRIPT_DIR/lib/api-helpers.sh"

# --- Main ---
print_header "Configure Destinations"

# Load environment
load_env "$PROJECT_DIR/.env"

require_commands curl jq envsubst

# Validate required Splunk environment variables
: "${SPLUNK_HOST:?SPLUNK_HOST is not set in .env}"
: "${SPLUNK_HEC_TOKEN:?SPLUNK_HEC_TOKEN is not set in .env}"

# Verify Cribl is running
cribl_health_check || die "Cribl Stream is not healthy. Start it before running this script."

# Authenticate
cribl_auth

# ============================================================================
# Step 1: Substitute environment variables in destination configs
# ============================================================================
log_step "Preparing destination configurations"

DEST_DIR="$PROJECT_DIR/configs/stream/destinations"
DEST_WORK_DIR=$(mktemp -d)
trap 'rm -rf "$DEST_WORK_DIR"' EXIT

if [[ ! -d "$DEST_DIR" ]]; then
    die "Destinations config directory not found: $DEST_DIR"
fi

for config_file in "$DEST_DIR"/*.json; do
    [[ -f "$config_file" ]] || continue
    local_name=$(basename "$config_file")
    log_info "Substituting env vars in: $local_name"
    envsubst < "$config_file" > "$DEST_WORK_DIR/$local_name"
done

# ============================================================================
# Step 2: Create destinations via API
# ============================================================================
log_step "Creating Splunk destinations"

dest_count=0
for config_file in "$DEST_WORK_DIR"/*.json; do
    [[ -f "$config_file" ]] || continue

    dest_type=$(jq -r '.type' "$config_file")
    dest_id=$(jq -r '.id' "$config_file")

    if [[ -z "$dest_type" || "$dest_type" == "null" ]]; then
        log_warn "Skipping $config_file - no 'type' field found"
        continue
    fi

    log_info "Creating destination: $dest_id (type: $dest_type)"
    cribl_create_destination "$dest_type" "$config_file"
    dest_count=$((dest_count + 1))
done

log_ok "Created $dest_count destinations"

# ============================================================================
# Step 3: Test connectivity to Splunk
# ============================================================================
log_step "Testing connectivity to Splunk"

# Test HEC port
log_info "Testing Splunk HEC endpoint: ${SPLUNK_HOST}:8088"
if check_port_open "$SPLUNK_HOST" 8088 5; then
    log_ok "Splunk HEC port 8088 is reachable"
else
    log_warn "Splunk HEC port 8088 is NOT reachable - data delivery may fail"
fi

# Test S2S port
log_info "Testing Splunk S2S endpoint: ${SPLUNK_HOST}:9997"
if check_port_open "$SPLUNK_HOST" 9997 5; then
    log_ok "Splunk S2S port 9997 is reachable"
else
    log_warn "Splunk S2S port 9997 is NOT reachable - data delivery may fail"
fi

# ============================================================================
# Step 4: Commit and deploy
# ============================================================================
log_step "Committing and deploying destination configuration"

cribl_commit_deploy "Configure Splunk destinations: HEC and S2S (${dest_count} destinations)"

log_ok "Destination configuration complete!"
log_info "Summary:"
log_info "  - Destinations created: $dest_count"
log_info "  - Splunk Host: ${SPLUNK_HOST}"
log_info "  - HEC endpoint: ${SPLUNK_HOST}:8088 (TLS: ${SPLUNK_HEC_TLS:-false})"
log_info "  - S2S endpoint: ${SPLUNK_HOST}:9997 (TLS disabled)"
