#!/usr/bin/env bash
# =============================================================================
# 10-deploy-phase2-infra.sh - Deploy Phase 2 Infrastructure
# =============================================================================
# Starts MinIO, Elasticsearch, and Kibana via Docker Compose.
# Creates MinIO bucket and loads Elasticsearch index template.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --- Main ---
print_header "Deploy Phase 2 Infrastructure"

load_env "$PROJECT_DIR/.env"

require_commands docker curl jq

# Validate required environment variables
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER is not set in .env}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD is not set in .env}"
: "${MINIO_BUCKET:?MINIO_BUCKET is not set in .env}"
: "${ELASTICSEARCH_URL:?ELASTICSEARCH_URL is not set in .env}"

# ============================================================================
# Step 1: Start Docker Compose stack
# ============================================================================
log_step "Starting Phase 2 Docker Compose stack"

docker compose -f "$PROJECT_DIR/docker-compose.phase2.yml" up -d

log_ok "Docker Compose stack started"

# ============================================================================
# Step 2: Wait for services to be healthy
# ============================================================================
log_step "Waiting for services to become healthy"

# Wait for MinIO
wait_for_port localhost 9100 90
log_ok "MinIO S3 API is reachable"

# Wait for Elasticsearch
wait_for_port localhost 9200 120
log_ok "Elasticsearch is reachable"

# Wait for ES to be fully ready (cluster health green/yellow)
log_info "Waiting for Elasticsearch cluster health..."
es_ready=0
for i in $(seq 1 60); do
    status=$(curl -sf "${ELASTICSEARCH_URL}/_cluster/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "")
    if [[ "$status" == "green" || "$status" == "yellow" ]]; then
        es_ready=1
        break
    fi
    sleep 2
done
if [[ $es_ready -eq 1 ]]; then
    log_ok "Elasticsearch cluster health: $status"
else
    die "Elasticsearch cluster did not become healthy within 120s"
fi

# Wait for Kibana
wait_for_port localhost 5601 180
log_ok "Kibana is reachable"

# ============================================================================
# Step 3: Create MinIO bucket
# ============================================================================
log_step "Creating MinIO bucket: ${MINIO_BUCKET}"

# Install mc (MinIO Client) if not present
if ! command -v mc &>/dev/null; then
    log_info "Installing MinIO Client (mc)..."
    curl -sfL https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc
    chmod +x /tmp/mc
    MC_CMD="/tmp/mc"
else
    MC_CMD="mc"
fi

# Configure mc alias
"$MC_CMD" alias set cribl-minio "http://localhost:9100" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api s3v4 2>/dev/null

# Create bucket if it doesn't exist
if "$MC_CMD" ls "cribl-minio/${MINIO_BUCKET}" &>/dev/null; then
    log_info "Bucket '${MINIO_BUCKET}' already exists"
else
    "$MC_CMD" mb "cribl-minio/${MINIO_BUCKET}"
    log_ok "Bucket '${MINIO_BUCKET}' created"
fi

# ============================================================================
# Step 4: Load Elasticsearch index template
# ============================================================================
log_step "Loading Elasticsearch index template"

ES_TEMPLATE_FILE="$PROJECT_DIR/configs/elasticsearch/index-template.json"
if [[ ! -f "$ES_TEMPLATE_FILE" ]]; then
    die "Index template not found: $ES_TEMPLATE_FILE"
fi

response=$(curl -sf -X PUT "${ELASTICSEARCH_URL}/_index_template/cribl-ops" \
    -H "Content-Type: application/json" \
    -d @"$ES_TEMPLATE_FILE" 2>&1)

if echo "$response" | jq -e '.acknowledged' &>/dev/null; then
    log_ok "Index template 'cribl-ops' loaded successfully"
else
    log_warn "Index template response: $response"
fi

# ============================================================================
# Summary
# ============================================================================
log_step "Phase 2 Infrastructure Summary"

log_ok "Phase 2 infrastructure deployed successfully!"
log_info "Services:"
log_info "  - MinIO S3 API:      http://localhost:9100"
log_info "  - MinIO Console:     http://localhost:9101"
log_info "  - Elasticsearch:     http://localhost:9200"
log_info "  - Kibana:            http://localhost:5601"
log_info ""
log_info "MinIO Bucket: ${MINIO_BUCKET}"
log_info "ES Index Template: cribl-ops-*"
