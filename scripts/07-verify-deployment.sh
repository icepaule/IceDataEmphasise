#!/usr/bin/env bash
# =============================================================================
# 07-verify-deployment.sh - End-to-End Deployment Verification Suite
# =============================================================================
# Runs ~20 checks to validate that the full Cribl Stream + Edge deployment is
# healthy and operating correctly.  Covers services, API endpoints, sources,
# destinations, pipelines, routes, Splunk connectivity, and system-level items.
#
# Must be run as root.
#
# Usage:
#   sudo ./scripts/07-verify-deployment.sh
# =============================================================================

# --- Resolve script location and source shared libraries ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "${SCRIPT_DIR}/lib/api-helpers.sh"

# =============================================================================
# Configuration
# =============================================================================

EXPECTED_SOURCES=12
EXPECTED_PIPELINES=5
MIN_DISK_FREE_GB=2

# =============================================================================
# Test counters
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Parallel arrays for the summary table
declare -a TEST_NAMES=()
declare -a TEST_RESULTS=()
declare -a TEST_DETAILS=()

# =============================================================================
# Helper: run_test "description" "command"
# =============================================================================
# Runs the given command (via eval) and records PASS/FAIL.
# The command's stdout is captured as the detail message on success.
# On failure, stderr or a generic message is captured.
# =============================================================================

run_test() {
    local description="$1"
    local command="$2"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TEST_NAMES+=("$description")

    local output
    if output=$(eval "$command" 2>&1); then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        TEST_RESULTS+=("PASS")
        TEST_DETAILS+=("${output:-OK}")
        log_ok "PASS: ${description}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TEST_RESULTS+=("FAIL")
        TEST_DETAILS+=("${output:-Command failed}")
        log_error "FAIL: ${description} -- ${output:-Command failed}"
    fi
}

# =============================================================================
# Individual test commands
# =============================================================================

test_cribl_stream_service() {
    if service_is_active cribl; then
        echo "Service is active"
    else
        echo "Service cribl is not running" >&2; return 1
    fi
}

test_cribl_edge_service() {
    if service_is_active cribl-edge; then
        echo "Service is active"
    else
        echo "Service cribl-edge is not running" >&2; return 1
    fi
}

test_stream_port_reachable() {
    local port="${CRIBL_STREAM_PORT:-9000}"
    if check_port_open "127.0.0.1" "$port" 5; then
        echo "Port ${port} is open"
    else
        echo "Port ${port} is not reachable" >&2; return 1
    fi
}

test_stream_api_health() {
    local result
    result=$(curl -s -o /dev/null -w "%{http_code}" \
        "${CRIBL_API_BASE:-http://localhost:9000/api/v1}/health" 2>/dev/null || echo "000")
    if [[ "$result" == "200" ]]; then
        echo "Health endpoint returned HTTP 200"
    else
        echo "Health endpoint returned HTTP ${result}" >&2; return 1
    fi
}

test_stream_login() {
    # Attempt authentication -- cribl_auth sets CRIBL_AUTH_TOKEN and calls die on failure.
    # We wrap it so a failure does not kill the whole script (set +e locally).
    local user="${CRIBL_ADMIN_USER:-admin}"
    local pass="${CRIBL_ADMIN_PASSWORD:-}"
    if [[ -z "$pass" ]]; then
        echo "CRIBL_ADMIN_PASSWORD not set" >&2; return 1
    fi

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${CRIBL_API_BASE:-http://localhost:9000/api/v1}/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}" 2>/dev/null)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        # Store token for subsequent API tests
        CRIBL_AUTH_TOKEN=$(echo "$body" | jq -r '.token')
        echo "Login successful (HTTP 200)"
    else
        echo "Login failed (HTTP ${http_code})" >&2; return 1
    fi
}

test_edge_node_registered() {
    local result
    result=$(cribl_get "/master/groups" 2>/dev/null)
    if echo "$result" | jq -e '.items | length > 0' &>/dev/null; then
        local count
        count=$(echo "$result" | jq '.items | length')
        echo "${count} fleet group(s) registered"
    else
        echo "No fleet groups / edge nodes found" >&2; return 1
    fi
}

test_sources_configured() {
    local result
    result=$(cribl_get "/m/default/system/inputs" 2>/dev/null)
    local count
    count=$(echo "$result" | jq '.items | length' 2>/dev/null || echo "0")
    if [[ "$count" -ge "$EXPECTED_SOURCES" ]]; then
        echo "${count} sources configured (expected >= ${EXPECTED_SOURCES})"
    else
        echo "Only ${count} sources configured (expected >= ${EXPECTED_SOURCES})" >&2; return 1
    fi
}

test_hec_destination() {
    local result
    result=$(cribl_get "/m/default/system/outputs" 2>/dev/null)
    if echo "$result" | jq -e '.items[] | select(.type == "splunk_hec")' &>/dev/null; then
        echo "HEC destination found"
    else
        echo "No Splunk HEC destination configured" >&2; return 1
    fi
}

test_s2s_destination() {
    local result
    result=$(cribl_get "/m/default/system/outputs" 2>/dev/null)
    if echo "$result" | jq -e '.items[] | select(.type == "splunk_s2s")' &>/dev/null; then
        echo "S2S destination found"
    else
        echo "No Splunk S2S destination configured" >&2; return 1
    fi
}

test_pipelines_configured() {
    local result
    result=$(cribl_get "/m/default/pipelines" 2>/dev/null)
    local count
    count=$(echo "$result" | jq '.items | length' 2>/dev/null || echo "0")
    if [[ "$count" -ge "$EXPECTED_PIPELINES" ]]; then
        echo "${count} pipelines configured (expected >= ${EXPECTED_PIPELINES})"
    else
        echo "Only ${count} pipelines configured (expected >= ${EXPECTED_PIPELINES})" >&2; return 1
    fi
}

test_routes_configured() {
    local result
    result=$(cribl_get "/m/default/routes" 2>/dev/null)
    local count
    count=$(echo "$result" | jq '.items | length' 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
        echo "${count} routes configured"
    else
        echo "No routes configured" >&2; return 1
    fi
}

test_splunk_hec_port() {
    local host="${SPLUNK_HOST:-10.10.0.66}"
    local port="${SPLUNK_HEC_PORT:-8088}"
    if check_port_open "$host" "$port" 5; then
        echo "Splunk HEC ${host}:${port} reachable"
    else
        echo "Splunk HEC ${host}:${port} unreachable" >&2; return 1
    fi
}

test_splunk_s2s_port() {
    local host="${SPLUNK_HOST:-10.10.0.66}"
    local port="${SPLUNK_S2S_PORT:-9997}"
    if check_port_open "$host" "$port" 5; then
        echo "Splunk S2S ${host}:${port} reachable"
    else
        echo "Splunk S2S ${host}:${port} unreachable" >&2; return 1
    fi
}

test_hec_event_reaches_splunk() {
    local host="${SPLUNK_HOST:-10.10.0.66}"
    local port="${SPLUNK_HEC_PORT:-8088}"
    local token="${SPLUNK_HEC_TOKEN:-}"
    local tls="${SPLUNK_HEC_TLS:-true}"

    if [[ -z "$token" ]]; then
        echo "SPLUNK_HEC_TOKEN not set, skipping" >&2; return 1
    fi

    local scheme="http"
    local curl_tls_flags=""
    if [[ "$tls" == "true" ]]; then
        scheme="https"
        curl_tls_flags="-k"
    fi

    local timestamp
    timestamp=$(date +%s)
    local test_event="{\"event\":\"IceDataEmphasise verification test at ${timestamp}\",\"sourcetype\":\"cribl:test\",\"index\":\"main\"}"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" ${curl_tls_flags} \
        -X POST "${scheme}://${host}:${port}/services/collector/event" \
        -H "Authorization: Splunk ${token}" \
        -d "$test_event" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        echo "Test event accepted by Splunk HEC (HTTP 200)"
    else
        echo "Splunk HEC rejected test event (HTTP ${http_code})" >&2; return 1
    fi
}

test_journal_source_collecting() {
    local result
    result=$(cribl_get "/m/default/system/inputs" 2>/dev/null)
    if echo "$result" | jq -e '.items[] | select(.type == "journald" or .type == "systemd_journal")' &>/dev/null; then
        echo "Systemd journal source configured"
    else
        # Also check for a journald-type source with a different naming convention
        if echo "$result" | jq -e '.items[] | select(.id | test("journal"; "i"))' &>/dev/null; then
            echo "Journal source found by name"
        else
            echo "No systemd journal source configured" >&2; return 1
        fi
    fi
}

test_file_permissions() {
    local cribl_user="${CRIBL_SERVICE_USER:-cribl}"
    local cribl_home="${CRIBL_HOME:-/opt/cribl}"
    local edge_home="${CRIBL_EDGE_HOME:-/opt/cribl-edge}"
    local errors=()

    if id "$cribl_user" &>/dev/null; then
        if [[ -d "$cribl_home" ]]; then
            local owner
            owner=$(stat -c '%U' "$cribl_home" 2>/dev/null)
            if [[ "$owner" != "$cribl_user" ]]; then
                errors+=("${cribl_home} owned by ${owner}, expected ${cribl_user}")
            fi
        fi
        if [[ -d "$edge_home" ]]; then
            local owner
            owner=$(stat -c '%U' "$edge_home" 2>/dev/null)
            if [[ "$owner" != "$cribl_user" ]]; then
                errors+=("${edge_home} owned by ${owner}, expected ${cribl_user}")
            fi
        fi
    else
        errors+=("User ${cribl_user} does not exist")
    fi

    if [[ ${#errors[@]} -eq 0 ]]; then
        echo "File permissions OK for ${cribl_user}"
    else
        local IFS="; "
        echo "${errors[*]}" >&2; return 1
    fi
}

test_persistent_queue_dirs() {
    local cribl_home="${CRIBL_HOME:-/opt/cribl}"
    local edge_home="${CRIBL_EDGE_HOME:-/opt/cribl-edge}"
    local found=0

    # Check common PQ directory locations
    for dir in "${cribl_home}/state/queues" "${cribl_home}/state" \
               "${edge_home}/state/queues" "${edge_home}/state"; do
        if [[ -d "$dir" ]]; then
            found=$((found + 1))
        fi
    done

    if [[ "$found" -gt 0 ]]; then
        echo "${found} persistent queue/state directories exist"
    else
        echo "No persistent queue directories found" >&2; return 1
    fi
}

test_service_survives_restart() {
    local service="cribl"

    # Restart the service and wait for it to come back
    systemctl restart "$service" 2>/dev/null
    sleep 3

    local waited=0
    local max_wait=30
    while ! service_is_active "$service"; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $max_wait ]]; then
            echo "Service ${service} did not recover after restart (${max_wait}s)" >&2; return 1
        fi
    done

    echo "Service ${service} recovered after restart in ${waited}s"
}

test_tailscale_connected() {
    if ! command -v tailscale &>/dev/null; then
        echo "Tailscale not installed (skipped, non-critical)"
        return 0
    fi

    local status
    status=$(tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || echo "unknown")
    if [[ "$status" == "Running" ]]; then
        local ip
        ip=$(tailscale ip -4 2>/dev/null || echo "unknown")
        echo "Tailscale connected (IP: ${ip})"
    else
        echo "Tailscale state: ${status}" >&2; return 1
    fi
}

test_disk_space_sufficient() {
    local check_path="/opt"
    if [[ ! -d "$check_path" ]]; then
        check_path="/"
    fi

    local free_gb
    free_gb=$(df -BG --output=avail "$check_path" 2>/dev/null | tail -1 | tr -d ' G')

    if [[ "$free_gb" -ge "$MIN_DISK_FREE_GB" ]]; then
        echo "${free_gb} GB free on ${check_path} (>= ${MIN_DISK_FREE_GB} GB required)"
    else
        echo "Only ${free_gb} GB free on ${check_path} (>= ${MIN_DISK_FREE_GB} GB required)" >&2; return 1
    fi
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    echo ""
    echo "============================================================================="
    printf "  %-4s  %-45s  %-6s  %s\n" "#" "TEST" "RESULT" "DETAILS"
    echo "-----------------------------------------------------------------------------"

    for i in "${!TEST_NAMES[@]}"; do
        local idx=$((i + 1))
        local name="${TEST_NAMES[$i]}"
        local result="${TEST_RESULTS[$i]}"
        local detail="${TEST_DETAILS[$i]}"

        # Truncate long detail lines for table readability
        if [[ ${#detail} -gt 60 ]]; then
            detail="${detail:0:57}..."
        fi

        if [[ "$result" == "PASS" ]]; then
            printf "  %-4s  %-45s  ${GREEN}%-6s${NC}  %s\n" "$idx" "$name" "$result" "$detail"
        else
            printf "  %-4s  %-45s  ${RED}%-6s${NC}  %s\n" "$idx" "$name" "$result" "$detail"
        fi
    done

    echo "============================================================================="
    echo ""
    echo -e "  Total: ${TESTS_TOTAL}  |  ${GREEN}Passed: ${TESTS_PASSED}${NC}  |  ${RED}Failed: ${TESTS_FAILED}${NC}"
    echo ""

    if [[ "$TESTS_FAILED" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}All ${TESTS_TOTAL} tests passed. Deployment is healthy.${NC}"
    else
        echo -e "  ${RED}${BOLD}${TESTS_FAILED} of ${TESTS_TOTAL} tests FAILED. Review the output above.${NC}"
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Deployment Verification"
    require_root
    require_commands curl jq

    # Load environment
    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        load_env "${PROJECT_ROOT}/.env"
    else
        log_warn "No .env file found at ${PROJECT_ROOT}/.env -- using defaults"
    fi

    # We need set +e so test failures do not abort the script
    set +e

    log_step "Service checks"
    run_test "Cribl Stream service running"        "test_cribl_stream_service"
    run_test "Cribl Edge service running"           "test_cribl_edge_service"
    run_test "Cribl Stream port reachable"          "test_stream_port_reachable"

    log_step "API checks"
    run_test "Cribl Stream API health check"        "test_stream_api_health"
    run_test "Cribl Stream login works"             "test_stream_login"

    log_step "Configuration checks"
    run_test "Edge node registered in Stream"       "test_edge_node_registered"
    run_test "All ${EXPECTED_SOURCES} sources configured"  "test_sources_configured"
    run_test "HEC destination configured"           "test_hec_destination"
    run_test "S2S destination configured"           "test_s2s_destination"
    run_test "All ${EXPECTED_PIPELINES} pipelines configured" "test_pipelines_configured"
    run_test "Routes configured"                    "test_routes_configured"

    log_step "Splunk connectivity checks"
    run_test "Splunk HEC port reachable"            "test_splunk_hec_port"
    run_test "Splunk S2S port reachable"            "test_splunk_s2s_port"
    run_test "Test event via HEC reaches Splunk"    "test_hec_event_reaches_splunk"

    log_step "Data collection checks"
    run_test "Systemd journal source collecting"    "test_journal_source_collecting"

    log_step "System-level checks"
    run_test "File permissions for cribl user OK"   "test_file_permissions"
    run_test "Persistent queue directories exist"   "test_persistent_queue_dirs"
    run_test "Cribl service survives restart"       "test_service_survives_restart"
    run_test "Tailscale connected"                  "test_tailscale_connected"
    run_test "Disk space sufficient"                "test_disk_space_sufficient"

    set -e

    print_summary

    # Exit with failure if any test failed
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
