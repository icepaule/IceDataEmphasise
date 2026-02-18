#!/usr/bin/env bash
# =============================================================================
# 14-verify-phase2.sh - Phase 2 Deployment Verification Suite
# =============================================================================
# Runs 17 checks to validate that the Phase 2 infrastructure (MinIO,
# Elasticsearch, Kibana, Ollama) and corresponding Cribl Stream configuration
# (Docker sources, S3/ES destinations, Ollama pipeline, routes) are healthy.
#
# Usage:
#   ./scripts/14-verify-phase2.sh
# =============================================================================

# --- Resolve script location and source shared libraries ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "$SCRIPT_DIR/lib/api-helpers.sh"

# =============================================================================
# Load environment
# =============================================================================
load_env "$PROJECT_DIR/.env"

# =============================================================================
# Test counters
# =============================================================================
TESTS_PASSED=0
TESTS_WARNED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# =============================================================================
# Helpers
# =============================================================================

pass_test() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    log_ok "PASS [${TESTS_TOTAL}/17]: $1"
}

warn_test() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_WARNED=$((TESTS_WARNED + 1))
    log_warn "WARN [${TESTS_TOTAL}/17]: $1"
}

fail_test() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    log_error "FAIL [${TESTS_TOTAL}/17]: $1"
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Phase 2 Deployment Verification"
    require_commands curl jq docker

    # Disable exit-on-error so test failures do not abort the script
    set +e

    # =========================================================================
    # Container Health (Tests 1-3)
    # =========================================================================
    log_step "Container Health"

    # Test 1: cribl-minio container is running
    if docker ps --format '{{.Names}}' | grep -q '^cribl-minio$'; then
        pass_test "cribl-minio container is running"
    else
        fail_test "cribl-minio container is NOT running"
    fi

    # Test 2: cribl-elasticsearch container is running
    if docker ps --format '{{.Names}}' | grep -q '^cribl-elasticsearch$'; then
        pass_test "cribl-elasticsearch container is running"
    else
        fail_test "cribl-elasticsearch container is NOT running"
    fi

    # Test 3: cribl-kibana container is running
    if docker ps --format '{{.Names}}' | grep -q '^cribl-kibana$'; then
        pass_test "cribl-kibana container is running"
    else
        fail_test "cribl-kibana container is NOT running"
    fi

    # =========================================================================
    # API Reachability (Tests 4-7)
    # =========================================================================
    log_step "API Reachability"

    # Test 4: MinIO S3 API (localhost:9100) responds
    if check_port_open "localhost" 9100 5; then
        pass_test "MinIO S3 API (localhost:9100) is reachable"
    else
        fail_test "MinIO S3 API (localhost:9100) is NOT reachable"
    fi

    # Test 5: MinIO Console (localhost:9101) responds
    if check_port_open "localhost" 9101 5; then
        pass_test "MinIO Console (localhost:9101) is reachable"
    else
        fail_test "MinIO Console (localhost:9101) is NOT reachable"
    fi

    # Test 6: Elasticsearch (localhost:9200) responds with cluster health
    local es_health
    es_health=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:9200/_cluster/health" 2>/dev/null || echo "000")
    if [[ "$es_health" == "200" ]]; then
        local cluster_status
        cluster_status=$(curl -s "http://localhost:9200/_cluster/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unknown")
        pass_test "Elasticsearch (localhost:9200) is healthy (cluster status: ${cluster_status})"
    else
        fail_test "Elasticsearch (localhost:9200) is NOT reachable (HTTP ${es_health})"
    fi

    # Test 7: Kibana (localhost:5601) responds
    if check_port_open "localhost" 5601 5; then
        pass_test "Kibana (localhost:5601) is reachable"
    else
        fail_test "Kibana (localhost:5601) is NOT reachable"
    fi

    # =========================================================================
    # Cribl Configuration (Tests 8-12)
    # =========================================================================
    log_step "Cribl Configuration"

    # Test 8: Cribl Stream is healthy (API health check)
    local cribl_health
    cribl_health=$(curl -s -o /dev/null -w "%{http_code}" \
        "${CRIBL_API_BASE:-http://localhost:9000/api/v1}/health" 2>/dev/null || echo "000")
    if [[ "$cribl_health" == "200" ]]; then
        pass_test "Cribl Stream API is healthy"
    else
        fail_test "Cribl Stream API health check failed (HTTP ${cribl_health})"
    fi

    # Authenticate for subsequent API checks
    log_info "Authenticating with Cribl API for configuration checks..."
    cribl_auth 2>/dev/null || true

    # Test 9: Docker source exists (docker_all_containers via API)
    local sources_result
    sources_result=$(cribl_get "/system/inputs" 2>/dev/null)
    if echo "$sources_result" | jq -e '.items[] | select(.id == "docker_all_containers")' &>/dev/null; then
        pass_test "Docker source 'docker_all_containers' exists"
    else
        fail_test "Docker source 'docker_all_containers' NOT found"
    fi

    # Test 10: MinIO S3 destination exists (minio_s3 via API)
    local outputs_result
    outputs_result=$(cribl_get "/system/outputs" 2>/dev/null)
    if echo "$outputs_result" | jq -e '.items[] | select(.id == "minio_s3")' &>/dev/null; then
        pass_test "MinIO S3 destination 'minio_s3' exists"
    else
        fail_test "MinIO S3 destination 'minio_s3' NOT found"
    fi

    # Test 11: Elasticsearch destination exists (elasticsearch_ops via API)
    if echo "$outputs_result" | jq -e '.items[] | select(.id == "elasticsearch_ops")' &>/dev/null; then
        pass_test "Elasticsearch destination 'elasticsearch_ops' exists"
    else
        fail_test "Elasticsearch destination 'elasticsearch_ops' NOT found"
    fi

    # Test 12: Ollama classifier pipeline exists (ollama_classifier via API)
    local pipelines_result
    pipelines_result=$(cribl_get "/pipelines" 2>/dev/null)
    if echo "$pipelines_result" | jq -e '.items[] | select(.id == "ollama_classifier")' &>/dev/null; then
        pass_test "Ollama classifier pipeline 'ollama_classifier' exists"
    else
        fail_test "Ollama classifier pipeline 'ollama_classifier' NOT found"
    fi

    # =========================================================================
    # Routing (Tests 13-15)
    # =========================================================================
    log_step "Routing"

    local routes_result
    routes_result=$(cribl_get "/routes" 2>/dev/null)

    # Test 13: Route route_docker_siem exists
    if echo "$routes_result" | jq -e '.items[] | select(.id == "route_docker_siem")' &>/dev/null; then
        pass_test "Route 'route_docker_siem' exists"
    else
        fail_test "Route 'route_docker_siem' NOT found"
    fi

    # Test 14: Route route_docker_ops_s3 exists
    if echo "$routes_result" | jq -e '.items[] | select(.id == "route_docker_ops_s3")' &>/dev/null; then
        pass_test "Route 'route_docker_ops_s3' exists"
    else
        fail_test "Route 'route_docker_ops_s3' NOT found"
    fi

    # Test 15: Route route_docker_ops_es exists
    if echo "$routes_result" | jq -e '.items[] | select(.id == "route_docker_ops_es")' &>/dev/null; then
        pass_test "Route 'route_docker_ops_es' exists"
    else
        fail_test "Route 'route_docker_ops_es' NOT found"
    fi

    # =========================================================================
    # Data Flow (Tests 16-17)
    # =========================================================================
    log_step "Data Flow"

    # Test 16: Elasticsearch index cribl-ops-* exists (or warn if no data yet)
    local indices_result
    indices_result=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:9200/cribl-ops-*" 2>/dev/null || echo "000")
    if [[ "$indices_result" == "200" ]]; then
        local doc_count
        doc_count=$(curl -s "http://localhost:9200/cribl-ops-*/_count" 2>/dev/null | jq -r '.count' 2>/dev/null || echo "0")
        pass_test "Elasticsearch index cribl-ops-* exists (${doc_count} documents)"
    elif [[ "$indices_result" == "404" ]]; then
        warn_test "Elasticsearch index cribl-ops-* does not exist yet (no data received)"
    else
        fail_test "Elasticsearch index cribl-ops-* check failed (HTTP ${indices_result})"
    fi

    # Test 17: Ollama connectivity test (OLLAMA_HOST:OLLAMA_PORT reachable)
    local ollama_host="${OLLAMA_HOST:-localhost}"
    local ollama_port="${OLLAMA_PORT:-11434}"
    if check_port_open "$ollama_host" "$ollama_port" 5; then
        pass_test "Ollama is reachable at ${ollama_host}:${ollama_port}"
    else
        fail_test "Ollama is NOT reachable at ${ollama_host}:${ollama_port}"
    fi

    set -e

    # =========================================================================
    # Summary
    # =========================================================================
    echo ""
    echo "============================================================================="
    echo "  Phase 2 Verification Summary"
    echo "============================================================================="
    echo ""
    echo -e "  ${TESTS_PASSED}/17 tests passed, ${TESTS_WARNED} warnings, ${TESTS_FAILED} failures"
    echo ""

    if [[ "$TESTS_FAILED" -eq 0 && "$TESTS_WARNED" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}All 17 tests passed. Phase 2 deployment is healthy.${NC}"
    elif [[ "$TESTS_FAILED" -eq 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}All tests passed with ${TESTS_WARNED} warning(s). Review warnings above.${NC}"
    else
        echo -e "  ${RED}${BOLD}${TESTS_FAILED} test(s) FAILED. Review the output above.${NC}"
    fi
    echo ""

    # Exit with failure if any test failed
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
