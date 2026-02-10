#!/usr/bin/env bash
# =============================================================================
# api-helpers.sh - Cribl REST API Wrapper Functions
# =============================================================================
# Requires: curl, jq
# Requires: common.sh sourced first
# =============================================================================

# --- API Configuration ---
CRIBL_API_BASE="${CRIBL_API_BASE:-http://localhost:9000/api/v1}"
CRIBL_AUTH_TOKEN=""

# --- Authentication ---
cribl_auth() {
    local user="${CRIBL_ADMIN_USER:-admin}"
    local pass="${CRIBL_ADMIN_PASSWORD:?CRIBL_ADMIN_PASSWORD not set}"

    log_info "Authenticating with Cribl API..."
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${CRIBL_API_BASE}/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        die "Cribl authentication failed (HTTP $http_code): $body"
    fi

    CRIBL_AUTH_TOKEN=$(echo "$body" | jq -r '.token')
    if [[ -z "$CRIBL_AUTH_TOKEN" || "$CRIBL_AUTH_TOKEN" == "null" ]]; then
        die "Failed to extract auth token from response"
    fi
    log_ok "Authenticated successfully"
}

# --- Generic API Call ---
cribl_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    if [[ -z "$CRIBL_AUTH_TOKEN" ]]; then
        cribl_auth
    fi

    local curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Authorization: Bearer ${CRIBL_AUTH_TOKEN}"
        -H "Content-Type: application/json"
    )

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local response
    response=$(curl "${curl_args[@]}" "${CRIBL_API_BASE}${endpoint}")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    echo "$body"
    return 0
}

cribl_get()    { cribl_api GET    "$1"; }
cribl_post()   { cribl_api POST   "$1" "$2"; }
cribl_put()    { cribl_api PUT    "$1" "$2"; }
cribl_patch()  { cribl_api PATCH  "$1" "$2"; }
cribl_delete() { cribl_api DELETE "$1"; }

# --- Source Management ---
cribl_create_source() {
    local source_type="$1"  # e.g., "file_monitor", "journald"
    local config_file="$2"  # JSON config file path

    if [[ ! -f "$config_file" ]]; then
        die "Source config file not found: $config_file"
    fi

    local source_id
    source_id=$(jq -r '.id' "$config_file")
    log_info "Creating source: $source_id (type: $source_type)"

    local result
    result=$(cribl_post "/m/default/system/inputs/${source_type}" "$(cat "$config_file")")

    if echo "$result" | jq -e '.items' &>/dev/null; then
        log_ok "Source created: $source_id"
    else
        log_warn "Source creation response: $result"
    fi
}

# --- Destination Management ---
cribl_create_destination() {
    local dest_type="$1"  # e.g., "splunk_hec", "splunk_s2s"
    local config_file="$2"

    if [[ ! -f "$config_file" ]]; then
        die "Destination config file not found: $config_file"
    fi

    local dest_id
    dest_id=$(jq -r '.id' "$config_file")
    log_info "Creating destination: $dest_id (type: $dest_type)"

    local result
    result=$(cribl_post "/m/default/system/outputs/${dest_type}" "$(cat "$config_file")")

    if echo "$result" | jq -e '.items' &>/dev/null; then
        log_ok "Destination created: $dest_id"
    else
        log_warn "Destination creation response: $result"
    fi
}

# --- Pipeline Management ---
cribl_create_pipeline() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        die "Pipeline config file not found: $config_file"
    fi

    local pipeline_id
    pipeline_id=$(jq -r '.id' "$config_file")
    log_info "Creating pipeline: $pipeline_id"

    local result
    result=$(cribl_post "/m/default/pipelines" "$(cat "$config_file")")

    if echo "$result" | jq -e '.items' &>/dev/null; then
        log_ok "Pipeline created: $pipeline_id"
    else
        log_warn "Pipeline creation response: $result"
    fi
}

# --- Route Management ---
cribl_create_route() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        die "Route config file not found: $config_file"
    fi

    log_info "Configuring routes..."

    local result
    result=$(cribl_put "/m/default/routes" "$(cat "$config_file")")

    if echo "$result" | jq -e '.items' &>/dev/null; then
        log_ok "Routes configured"
    else
        log_warn "Route configuration response: $result"
    fi
}

# --- Fleet Management ---
cribl_create_fleet() {
    local fleet_id="$1"
    local description="$2"

    log_info "Creating fleet: $fleet_id"
    local data
    data=$(jq -n --arg id "$fleet_id" --arg desc "$description" \
        '{id: $id, description: $desc}')

    local result
    result=$(cribl_post "/master/groups" "$data")
    log_ok "Fleet created: $fleet_id"
}

# --- Commit & Deploy ---
cribl_commit_deploy() {
    local message="${1:-Automated configuration deployment}"

    log_info "Committing configuration..."
    local commit_data
    commit_data=$(jq -n --arg msg "$message" '{message: $msg, effective: true}')

    cribl_post "/version/commit" "$commit_data"
    log_info "Deploying configuration..."
    cribl_post "/master/groups/default/deploy" '{}'
    log_ok "Configuration committed and deployed"
}

# --- Health Check ---
cribl_health_check() {
    log_info "Checking Cribl Stream health..."
    local result
    result=$(curl -s -o /dev/null -w "%{http_code}" \
        "${CRIBL_API_BASE}/health" 2>/dev/null || echo "000")

    if [[ "$result" == "200" ]]; then
        log_ok "Cribl Stream is healthy"
        return 0
    else
        log_error "Cribl Stream health check failed (HTTP $result)"
        return 1
    fi
}

# --- Utility ---
cribl_list_sources() {
    cribl_get "/m/default/system/inputs" | jq -r '.items[] | "\(.id) (\(.type))"'
}

cribl_list_destinations() {
    cribl_get "/m/default/system/outputs" | jq -r '.items[] | "\(.id) (\(.type))"'
}

cribl_list_pipelines() {
    cribl_get "/m/default/pipelines" | jq -r '.items[] | .id'
}
