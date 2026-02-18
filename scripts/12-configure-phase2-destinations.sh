#!/usr/bin/env bash
# =============================================================================
# 12-configure-phase2-destinations.sh - Configure MinIO S3 and Elasticsearch
# =============================================================================
# Creates MinIO S3 and Elasticsearch destinations in Cribl Stream via API.
# Follows the same pattern as 05-configure-destinations.sh.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "$SCRIPT_DIR/lib/api-helpers.sh"

# --- Main ---
print_header "Configure Phase 2 Destinations"

load_env "$PROJECT_DIR/.env"

require_commands curl jq envsubst

# Validate required environment variables
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER is not set in .env}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD is not set in .env}"
: "${MINIO_ENDPOINT:?MINIO_ENDPOINT is not set in .env}"
: "${MINIO_BUCKET:?MINIO_BUCKET is not set in .env}"
: "${ELASTICSEARCH_URL:?ELASTICSEARCH_URL is not set in .env}"

# Verify Cribl is running
cribl_health_check || die "Cribl Stream is not healthy."

# Authenticate
cribl_auth

# ============================================================================
# Step 1: Substitute environment variables in destination configs
# ============================================================================
log_step "Preparing Phase 2 destination configurations"

DEST_DIR="$PROJECT_DIR/configs/stream/destinations"
DEST_WORK_DIR=$(mktemp -d)
trap 'rm -rf "$DEST_WORK_DIR"' EXIT

# Only process Phase 2 destination files
PHASE2_DESTS=("minio-s3.json" "elasticsearch.json")

for dest_file in "${PHASE2_DESTS[@]}"; do
    config_file="$DEST_DIR/$dest_file"
    if [[ ! -f "$config_file" ]]; then
        die "Destination config not found: $config_file"
    fi
    log_info "Substituting env vars in: $dest_file"
    envsubst < "$config_file" > "$DEST_WORK_DIR/$dest_file"
done

# ============================================================================
# Step 2: Create destinations via API
# ============================================================================
log_step "Creating Phase 2 destinations"

dest_count=0
for dest_file in "${PHASE2_DESTS[@]}"; do
    config_file="$DEST_WORK_DIR/$dest_file"
    dest_type=$(jq -r '.type' "$config_file")
    dest_id=$(jq -r '.id' "$config_file")

    log_info "Creating destination: $dest_id (type: $dest_type)"
    cribl_create_destination "$dest_type" "$config_file"
    dest_count=$((dest_count + 1))
done

log_ok "Created $dest_count Phase 2 destinations"

# ============================================================================
# Step 3: Test connectivity
# ============================================================================
log_step "Testing Phase 2 service connectivity"

# Test MinIO
log_info "Testing MinIO endpoint: localhost:9100"
if check_port_open localhost 9100 5; then
    log_ok "MinIO S3 API port 9100 is reachable"
else
    log_warn "MinIO S3 API port 9100 is NOT reachable"
fi

# Test Elasticsearch
log_info "Testing Elasticsearch endpoint: localhost:9200"
if check_port_open localhost 9200 5; then
    log_ok "Elasticsearch port 9200 is reachable"
else
    log_warn "Elasticsearch port 9200 is NOT reachable"
fi

# ============================================================================
# Step 4: Commit and deploy
# ============================================================================
log_step "Committing and deploying Phase 2 destination configuration"

cribl_commit_deploy "Configure Phase 2 destinations: MinIO S3 and Elasticsearch (${dest_count} destinations)"

log_ok "Phase 2 destination configuration complete!"
log_info "Summary:"
log_info "  - Destinations created: $dest_count"
log_info "  - MinIO S3: ${MINIO_ENDPOINT} / Bucket: ${MINIO_BUCKET}"
log_info "  - Elasticsearch: ${ELASTICSEARCH_URL}"
