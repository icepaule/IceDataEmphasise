#!/usr/bin/env bash
# =============================================================================
# configure-s2s-receiver.sh - Enable S2S Receiving on Splunk
# =============================================================================
# Enables the Splunk-to-Splunk (S2S) receiving port 9997 via the Splunk REST
# API. This allows Cribl Stream to forward data to Splunk using the native
# Splunk forwarding protocol.
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

S2S_PORT="${SPLUNK_S2S_PORT:-9997}"

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

check_existing_receiver() {
    log_step "Checking existing S2S receiver configuration"

    local result
    result=$(splunk_api GET "/servicesNS/admin/search/data/inputs/splunktcp/${S2S_PORT}" \
        -d "output_mode=json" 2>/dev/null) || true

    local existing_port
    existing_port=$(echo "$result" | jq -r '.entry[0].name // empty' 2>/dev/null)

    if [[ -n "$existing_port" ]]; then
        log_ok "S2S receiver already configured on port $S2S_PORT."
        return 0
    fi
    return 1
}

enable_s2s_receiver() {
    log_step "Enabling S2S receiver on port $S2S_PORT"

    local result
    result=$(splunk_api POST "/servicesNS/admin/search/data/inputs/splunktcp" \
        -d "name=${S2S_PORT}" \
        -d "disabled=0" \
        -d "output_mode=json")

    if [[ $? -ne 0 ]]; then
        # Check if the error is because it already exists
        if echo "$result" | grep -qi "already exists"; then
            log_ok "S2S receiver on port $S2S_PORT already exists."
            return 0
        fi
        die "Failed to enable S2S receiver on port $S2S_PORT. Response: $result"
    fi

    log_ok "S2S receiver enabled on port $S2S_PORT."
}

verify_port_listening() {
    log_step "Verifying port $S2S_PORT is listening on Splunk host"

    # Give Splunk a moment to open the port
    sleep 3

    if check_port_open "$SPLUNK_HOST" "$S2S_PORT" 10; then
        log_ok "Port $S2S_PORT is open on $SPLUNK_HOST."
    else
        log_warn "Port $S2S_PORT does not appear to be listening on $SPLUNK_HOST."
        log_warn "This may be normal if the Splunk service needs a restart."
        log_info "You can restart Splunk to apply the change:"
        log_info "  splunk restart"
        log_info "Or via the REST API:"
        log_info "  curl -k -X POST -u admin:password https://${SPLUNK_HOST}:8089/services/server/control/restart"
    fi
}

print_summary() {
    echo ""
    echo "============================================================================="
    echo "  S2S Receiver Configuration Complete"
    echo "============================================================================="
    echo ""
    echo "  Splunk Host:     $SPLUNK_HOST"
    echo "  S2S Port:        $S2S_PORT"
    echo "  Protocol:        Splunk-to-Splunk (S2S / splunktcp)"
    echo ""
    echo "  Cribl Stream can now forward data to this Splunk instance using"
    echo "  a Splunk S2S destination pointing to ${SPLUNK_HOST}:${S2S_PORT}."
    echo ""
    echo "============================================================================="
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Splunk S2S Receiver Configuration"
    require_commands curl jq

    # Load environment
    load_env "${PROJECT_ROOT}/.env"

    # Validate required variables
    : "${SPLUNK_HOST:?SPLUNK_HOST not set in .env}"
    : "${SPLUNK_ADMIN_USER:?SPLUNK_ADMIN_USER not set in .env}"
    : "${SPLUNK_ADMIN_PASSWORD:?SPLUNK_ADMIN_PASSWORD not set in .env}"

    log_info "Splunk host: $SPLUNK_HOST"
    log_info "S2S port:    $S2S_PORT"

    if check_existing_receiver; then
        verify_port_listening
    else
        enable_s2s_receiver
        verify_port_listening
    fi

    print_summary
}

main "$@"
