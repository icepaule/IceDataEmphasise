#!/usr/bin/env bash
# =============================================================================
# 15-deploy-universal-classifier.sh - Deploy Universal Classifier Pipeline
# =============================================================================
# Deploys the universal classifier pipeline and updated routes to Cribl Stream.
# ES-First Architecture: ALL events go to ES, SIEM additionally to Splunk.
# Uses filesystem deployment (pipeline contains async JS that the API validator
# cannot parse) + Cribl reload for single-instance mode.
#
# Usage:
#   ./scripts/15-deploy-universal-classifier.sh
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

# Cribl config paths (single-instance mode)
CRIBL_LOCAL_DIR="${CRIBL_HOME:-/opt/cribl}/local/cribl"
CRIBL_PIPELINE_DIR="$CRIBL_LOCAL_DIR/pipelines"
CRIBL_SERVICE_USER="${CRIBL_SERVICE_USER:-cribl}"
CRIBL_SERVICE_GROUP="${CRIBL_SERVICE_GROUP:-cribl}"

# =============================================================================
# Main
# =============================================================================
main() {
    print_header "Deploy Universal Classifier Pipeline (ES-First Architecture)"
    require_commands curl jq python3

    # =========================================================================
    # Step 1: Health check
    # =========================================================================
    log_step "Step 1/7: Cribl Stream Health Check"
    cribl_health_check || die "Cribl Stream is not healthy. Aborting."

    # =========================================================================
    # Step 2: Authenticate (for verification steps)
    # =========================================================================
    log_step "Step 2/7: Authenticate with Cribl API"
    cribl_auth

    # =========================================================================
    # Step 3: Deploy universal_classifier pipeline via filesystem
    # =========================================================================
    log_step "Step 3/7: Deploy universal_classifier pipeline"

    local pipeline_file="$PROJECT_DIR/configs/stream/pipelines/pipeline-universal-classifier.json"
    if [[ ! -f "$pipeline_file" ]]; then
        die "Pipeline config not found: $pipeline_file"
    fi

    # Convert JSON to YAML and write to Cribl's local config
    local pipeline_dir="$CRIBL_PIPELINE_DIR/universal_classifier"
    log_info "Writing pipeline to $pipeline_dir/conf.yml ..."

    sudo mkdir -p "$pipeline_dir"
    python3 -c "
import json, yaml, sys
with open('$pipeline_file') as f:
    d = json.load(f)
yaml_str = yaml.dump(d['conf'], default_flow_style=False, allow_unicode=True, width=1000, sort_keys=False)
sys.stdout.write(yaml_str)
" | sudo tee "$pipeline_dir/conf.yml" > /dev/null

    sudo chown -R "${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}" "$pipeline_dir"
    log_ok "Pipeline written: universal_classifier ($(wc -l < "$pipeline_dir/conf.yml") lines)"

    # =========================================================================
    # Step 4: Update routes via filesystem (ES-First Architecture)
    # =========================================================================
    log_step "Step 4/7: Update routes (ES-First: ALL->ES, SIEM->ES+Splunk)"

    local routes_file="$PROJECT_DIR/configs/stream/pipelines/routes.json"
    if [[ ! -f "$routes_file" ]]; then
        die "Routes config not found: $routes_file"
    fi

    # Backup current routes
    if [[ -f "$CRIBL_PIPELINE_DIR/route.yml" ]]; then
        sudo cp "$CRIBL_PIPELINE_DIR/route.yml" "$CRIBL_PIPELINE_DIR/route.yml.bak.$(date '+%Y%m%d_%H%M%S')"
        log_info "Backed up current routes"
    fi

    # Convert JSON routes to YAML
    log_info "Writing routes to $CRIBL_PIPELINE_DIR/route.yml ..."
    python3 -c "
import json, yaml, sys
with open('$routes_file') as f:
    d = json.load(f)
yaml_str = yaml.dump(d, default_flow_style=False, allow_unicode=True, width=1000, sort_keys=False)
sys.stdout.write(yaml_str)
" | sudo tee "$CRIBL_PIPELINE_DIR/route.yml" > /dev/null

    sudo chown "${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}" "$CRIBL_PIPELINE_DIR/route.yml"
    log_ok "Routes written (5 ES-First routes)"

    # =========================================================================
    # Step 5: Reload Cribl Stream
    # =========================================================================
    log_step "Step 5/7: Reload Cribl Stream"

    log_info "Reloading Cribl to pick up new config..."
    sudo -u "${CRIBL_SERVICE_USER}" "${CRIBL_HOME:-/opt/cribl}/bin/cribl" reload 2>/dev/null \
        || sudo systemctl restart cribl 2>/dev/null \
        || log_warn "Could not reload Cribl via CLI or systemd"

    log_info "Waiting 10s for Cribl to reload..."
    sleep 10

    # Verify Cribl is healthy after reload
    cribl_health_check || die "Cribl Stream is not healthy after reload!"
    # Re-authenticate after reload
    cribl_auth
    log_ok "Cribl reloaded successfully"

    # =========================================================================
    # Step 6: Enable Edge inputs (single-instance mode)
    # =========================================================================
    log_step "Step 6/7: Enable Edge inputs"

    # In single-instance mode, use direct /system/inputs/ paths
    log_info "Enabling in_cribl_tcp (for receiving Edge data)..."
    local tcp_result
    tcp_result=$(cribl_patch "/system/inputs/in_cribl_tcp" '{"disabled":false}' 2>/dev/null)
    if echo "$tcp_result" | jq -e '.items' &>/dev/null 2>&1; then
        log_ok "in_cribl_tcp enabled"
    else
        log_warn "in_cribl_tcp: $(echo "$tcp_result" | head -c 200)"
    fi

    # =========================================================================
    # Step 7: Verify deployment
    # =========================================================================
    log_step "Step 7/7: Verify deployment"

    local verify_passed=0
    local verify_total=0

    # Check pipeline exists
    verify_total=$((verify_total + 1))
    local pipe_check
    pipe_check=$(cribl_get "/pipelines/universal_classifier" 2>/dev/null)
    if echo "$pipe_check" | jq -e '.items[0].id == "universal_classifier"' &>/dev/null; then
        log_ok "VERIFY: Pipeline 'universal_classifier' exists"
        verify_passed=$((verify_passed + 1))
    else
        log_error "VERIFY: Pipeline 'universal_classifier' NOT found"
    fi

    # Check routes (ES-First architecture) - routes are nested in items[0].routes[]
    verify_total=$((verify_total + 1))
    local route_check
    route_check=$(cribl_get "/routes" 2>/dev/null)
    if echo "$route_check" | jq -e '.items[0].routes[] | select(.id == "route_classify_all")' &>/dev/null; then
        log_ok "VERIFY: Route 'route_classify_all' exists"
        verify_passed=$((verify_passed + 1))
    else
        log_error "VERIFY: Route 'route_classify_all' NOT found"
    fi

    verify_total=$((verify_total + 1))
    if echo "$route_check" | jq -e '.items[0].routes[] | select(.id == "route_all_to_es")' &>/dev/null; then
        log_ok "VERIFY: Route 'route_all_to_es' exists (ES-First)"
        verify_passed=$((verify_passed + 1))
    else
        log_error "VERIFY: Route 'route_all_to_es' NOT found"
    fi

    verify_total=$((verify_total + 1))
    if echo "$route_check" | jq -e '.items[0].routes[] | select(.id == "route_siem_to_splunk")' &>/dev/null; then
        log_ok "VERIFY: Route 'route_siem_to_splunk' exists"
        verify_passed=$((verify_passed + 1))
    else
        log_error "VERIFY: Route 'route_siem_to_splunk' NOT found"
    fi

    # Check route_all_to_es is non-final
    verify_total=$((verify_total + 1))
    if echo "$route_check" | jq -e '.items[0].routes[] | select(.id == "route_all_to_es" and .final == false)' &>/dev/null; then
        log_ok "VERIFY: Route 'route_all_to_es' is non-final (dual-write enabled)"
        verify_passed=$((verify_passed + 1))
    else
        log_error "VERIFY: Route 'route_all_to_es' should be non-final for dual-write"
    fi

    # Check route count
    verify_total=$((verify_total + 1))
    local route_count
    route_count=$(echo "$route_check" | jq '[.items[0].routes[]] | length' 2>/dev/null || echo "0")
    if [[ "$route_count" -ge 5 ]]; then
        log_ok "VERIFY: ${route_count} routes configured (expected >= 5)"
        verify_passed=$((verify_passed + 1))
    else
        log_error "VERIFY: Only ${route_count} routes found (expected >= 5)"
    fi

    # =========================================================================
    # Verify ES data flow (ES-First)
    # =========================================================================
    log_info "Verifying ES data flow..."

    local es_url="${ES_URL:-http://localhost:9200}"
    log_info "Checking Elasticsearch at ${es_url}..."

    verify_total=$((verify_total + 1))
    local es_count
    es_count=$(curl -s "${es_url}/cribl-ops*/_count" 2>/dev/null | jq -r '.count // 0' 2>/dev/null || echo "0")
    if [[ "$es_count" -gt 0 ]]; then
        log_ok "VERIFY: ES contains ${es_count} events in cribl-ops* indices"
        verify_passed=$((verify_passed + 1))
    else
        log_warn "VERIFY: ES cribl-ops* count is ${es_count} (events may take a moment to appear)"
    fi

    # Check that ES receives events with classification field
    verify_total=$((verify_total + 1))
    local es_classified
    es_classified=$(curl -s "${es_url}/cribl-ops*/_count" \
        -H 'Content-Type: application/json' \
        -d '{"query":{"exists":{"field":"classification"}}}' 2>/dev/null | jq -r '.count // 0' 2>/dev/null || echo "0")
    if [[ "$es_classified" -gt 0 ]]; then
        log_ok "VERIFY: ES has ${es_classified} classified events (ES-First working)"
        verify_passed=$((verify_passed + 1))
    else
        log_warn "VERIFY: No classified events in ES yet (may take time after deployment)"
    fi

    # Summary
    echo ""
    echo "============================================================================="
    echo "  Universal Classifier Deployment Summary (ES-First Architecture)"
    echo "============================================================================="
    echo ""
    echo -e "  ${verify_passed}/${verify_total} verification checks passed"
    echo ""
    echo "  Architecture: ALL events -> ES (primary data lake)"
    echo "                SIEM events -> ES + Splunk (dual-write)"
    echo "                Ops events  -> ES + S3 (archive)"
    echo ""

    if [[ "$verify_passed" -eq "$verify_total" ]]; then
        echo -e "  ${GREEN}${BOLD}Deployment successful!${NC}"
        echo ""
        echo "  Next steps:"
        echo "    1. Check Edge Nodes: http://10.10.0.100:9000/edge/fleets"
        echo "    2. Monitor ALL events: http://10.10.0.100:5601 (Kibana - ES Data Lake)"
        echo "    3. SIEM events:        http://10.10.0.66:8000 (Splunk)"
        echo "    4. AI Panel:           http://10.10.0.100:8080/docs/16-ai-status-panel.html"
        echo "    5. SIEM Discovery:     Use AI Panel to find sources with SIEM potential"
    else
        echo -e "  ${YELLOW}${BOLD}Deployment completed with warnings. Review output above.${NC}"
    fi
    echo ""
}

main "$@"
