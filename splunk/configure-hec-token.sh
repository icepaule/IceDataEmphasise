#!/usr/bin/env bash
# =============================================================================
# configure-hec-token.sh - Create HEC Token on Splunk
# =============================================================================
# Creates an HTTP Event Collector (HEC) token named "cribl_hec" on the Splunk
# server via the REST API. Enables the global HEC endpoint if it is not already
# active. Prints the resulting token value so it can be added to .env.
#
# Requires: curl, jq
# =============================================================================

# --- Resolve script location and source shared libraries ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"

# =============================================================================
# Configuration
# =============================================================================

HEC_TOKEN_NAME="cribl_hec"
HEC_TOKEN_DESCRIPTION="HEC token for Cribl Stream / Cribl Edge ingestion"
HEC_DEFAULT_INDEX="main"
HEC_DEFAULT_SOURCETYPE="httpevent"
HEC_ALLOWED_INDEXES="main,os_journal,os_boot,os_packages,web_apache,infra_samba,infra_dns,infra_cups,iot_homeassistant,iot_mqtt,sec_auth,sec_tor"

# =============================================================================
# Functions
# =============================================================================

splunk_api() {
    local method="$1"
    local endpoint="$2"
    shift 2
    local extra_args=("$@")

    local url="https://${SPLUNK_HOST}:8089${endpoint}"
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -k \
        -X "$method" \
        -u "${SPLUNK_ADMIN_USER}:${SPLUNK_ADMIN_PASSWORD}" \
        "${extra_args[@]}" \
        "$url")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    echo "$body"

    if [[ "$http_code" -ge 400 ]]; then
        log_warn "Splunk API returned HTTP $http_code for $method $endpoint"
        return 1
    fi
    return 0
}

enable_global_hec() {
    log_step "Checking global HEC status"

    local result
    result=$(splunk_api GET "/servicesNS/admin/splunk_httpinput/data/inputs/http/http" \
        -d "output_mode=json") || true

    local hec_disabled
    hec_disabled=$(echo "$result" | jq -r '.entry[0].content.disabled // "1"' 2>/dev/null)

    if [[ "$hec_disabled" == "0" ]]; then
        log_ok "Global HEC is already enabled."
        return 0
    fi

    log_info "Enabling global HEC endpoint..."
    splunk_api POST "/servicesNS/admin/splunk_httpinput/data/inputs/http/http" \
        -d "disabled=0" \
        -d "output_mode=json" >/dev/null

    if [[ $? -eq 0 ]]; then
        log_ok "Global HEC enabled."
    else
        die "Failed to enable global HEC. Check Splunk admin credentials and connectivity."
    fi
}

create_hec_token() {
    log_step "Creating HEC token: $HEC_TOKEN_NAME"

    # Check if token already exists
    local existing
    existing=$(splunk_api GET "/servicesNS/admin/splunk_httpinput/data/inputs/http/${HEC_TOKEN_NAME}" \
        -d "output_mode=json" 2>/dev/null) || true

    local existing_token
    existing_token=$(echo "$existing" | jq -r '.entry[0].content.token // empty' 2>/dev/null)

    if [[ -n "$existing_token" ]]; then
        log_warn "HEC token '$HEC_TOKEN_NAME' already exists."
        log_info "Existing token value: $existing_token"
        HEC_TOKEN="$existing_token"
        return 0
    fi

    # Create the token
    local result
    result=$(splunk_api POST "/servicesNS/admin/splunk_httpinput/data/inputs/http" \
        -d "name=${HEC_TOKEN_NAME}" \
        -d "description=${HEC_TOKEN_DESCRIPTION}" \
        -d "index=${HEC_DEFAULT_INDEX}" \
        -d "sourcetype=${HEC_DEFAULT_SOURCETYPE}" \
        -d "indexes=${HEC_ALLOWED_INDEXES}" \
        -d "useACK=0" \
        -d "disabled=0" \
        -d "output_mode=json")

    if [[ $? -ne 0 ]]; then
        die "Failed to create HEC token. Response: $result"
    fi

    HEC_TOKEN=$(echo "$result" | jq -r '.entry[0].content.token // empty')

    if [[ -z "$HEC_TOKEN" ]]; then
        # Retry: fetch the token we just created
        log_info "Fetching newly created token..."
        local fetch_result
        fetch_result=$(splunk_api GET "/servicesNS/admin/splunk_httpinput/data/inputs/http/${HEC_TOKEN_NAME}" \
            -d "output_mode=json")
        HEC_TOKEN=$(echo "$fetch_result" | jq -r '.entry[0].content.token // empty')
    fi

    if [[ -z "$HEC_TOKEN" ]]; then
        die "HEC token was created but the token value could not be retrieved."
    fi

    log_ok "HEC token created: $HEC_TOKEN_NAME"
}

print_token_info() {
    echo ""
    echo "============================================================================="
    echo "  HEC Token Created Successfully"
    echo "============================================================================="
    echo ""
    echo "  Token Name:   $HEC_TOKEN_NAME"
    echo "  Token Value:  $HEC_TOKEN"
    echo "  Endpoint:     https://${SPLUNK_HOST}:${SPLUNK_HEC_PORT:-8088}/services/collector"
    echo "  Indexes:      $HEC_ALLOWED_INDEXES"
    echo ""
    echo "  Add the following to your .env file:"
    echo ""
    echo "    SPLUNK_HEC_TOKEN=\"$HEC_TOKEN\""
    echo ""
    echo "============================================================================="
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Splunk HEC Token Configuration"
    require_commands curl jq

    # Load environment
    load_env "${PROJECT_ROOT}/.env"

    # Validate required variables
    : "${SPLUNK_HOST:?SPLUNK_HOST not set in .env}"
    : "${SPLUNK_ADMIN_USER:?SPLUNK_ADMIN_USER not set in .env}"
    : "${SPLUNK_ADMIN_PASSWORD:?SPLUNK_ADMIN_PASSWORD not set in .env}"

    log_info "Splunk host: $SPLUNK_HOST"

    enable_global_hec
    create_hec_token
    print_token_info
}

main "$@"
