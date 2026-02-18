#!/usr/bin/env bash
# =============================================================================
# 15-deploy-universal-classifier.sh - Deploy Universal Classifier Pipeline
# =============================================================================
# Deploys the universal classifier pipeline and updated routes to Cribl Stream.
# Activates Edge inputs (in_cribl_tcp on Worker, in_win_event_logs on Fleet).
# Commits and deploys the configuration.
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

# =============================================================================
# Main
# =============================================================================
main() {
    print_header "Deploy Universal Classifier Pipeline"
    require_commands curl jq

    # =========================================================================
    # Step 1: Health check
    # =========================================================================
    log_step "Step 1/7: Cribl Stream Health Check"
    cribl_health_check || die "Cribl Stream is not healthy. Aborting."

    # =========================================================================
    # Step 2: Authenticate
    # =========================================================================
    log_step "Step 2/7: Authenticate with Cribl API"
    cribl_auth

    # =========================================================================
    # Step 3: Deploy universal_classifier pipeline
    # =========================================================================
    log_step "Step 3/7: Deploy universal_classifier pipeline"

    local pipeline_file="$PROJECT_DIR/configs/stream/pipelines/pipeline-universal-classifier.json"
    if [[ ! -f "$pipeline_file" ]]; then
        die "Pipeline config not found: $pipeline_file"
    fi

    # Check if pipeline already exists
    local existing
    existing=$(cribl_get "/pipelines/universal_classifier" 2>/dev/null)

    if echo "$existing" | jq -e '.items[0].id' &>/dev/null 2>&1; then
        log_info "Pipeline 'universal_classifier' already exists, updating..."
        local result
        result=$(cribl_put "/pipelines/universal_classifier" "$(cat "$pipeline_file")")
        if echo "$result" | jq -e '.items' &>/dev/null; then
            log_ok "Pipeline updated: universal_classifier"
        else
            log_warn "Pipeline update response: $result"
        fi
    else
        log_info "Creating new pipeline: universal_classifier"
        cribl_create_pipeline "$pipeline_file"
    fi

    # =========================================================================
    # Step 4: Update routes
    # =========================================================================
    log_step "Step 4/7: Update routes"

    local routes_file="$PROJECT_DIR/configs/stream/pipelines/routes.json"
    if [[ ! -f "$routes_file" ]]; then
        die "Routes config not found: $routes_file"
    fi

    cribl_create_route "$routes_file"

    # =========================================================================
    # Step 5: Enable Edge inputs
    # =========================================================================
    log_step "Step 5/7: Enable Edge inputs"

    # Enable in_cribl_tcp on default Worker Group (for receiving Edge data)
    log_info "Enabling in_cribl_tcp on default Worker Group..."
    local tcp_result
    tcp_result=$(cribl_patch "/m/default/system/inputs/in_cribl_tcp" '{"disabled":false}' 2>/dev/null)
    if echo "$tcp_result" | jq -e '.items' &>/dev/null 2>&1; then
        log_ok "in_cribl_tcp enabled on Worker Group"
    else
        log_warn "in_cribl_tcp enable response (may not exist or already enabled): $(echo "$tcp_result" | head -c 200)"
    fi

    # Enable in_win_event_logs on Edge Fleet
    log_info "Enabling in_win_event_logs on default_fleet..."
    local win_result
    win_result=$(cribl_patch "/m/default_fleet/system/inputs/in_win_event_logs" '{"disabled":false}' 2>/dev/null)
    if echo "$win_result" | jq -e '.items' &>/dev/null 2>&1; then
        log_ok "in_win_event_logs enabled on default_fleet"
    else
        log_warn "in_win_event_logs enable response (may not exist on this fleet): $(echo "$win_result" | head -c 200)"
    fi

    # Enable journal source on Edge Fleet (for Linux Edge)
    log_info "Enabling journal source on default_fleet..."
    local journal_result
    journal_result=$(cribl_patch "/m/default_fleet/system/inputs/in_journal_local" '{"disabled":false}' 2>/dev/null)
    if echo "$journal_result" | jq -e '.items' &>/dev/null 2>&1; then
        log_ok "in_journal_local enabled on default_fleet"
    else
        log_warn "in_journal_local enable response: $(echo "$journal_result" | head -c 200)"
    fi

    # =========================================================================
    # Step 6: Commit & Deploy
    # =========================================================================
    log_step "Step 6/7: Commit & Deploy configuration"

    cribl_commit_deploy "Deploy universal_classifier pipeline + updated routes + enable Edge inputs"
    log_ok "Configuration committed"

    # Deploy to Worker Group
    log_info "Deploying to default Worker Group..."
    local deploy_result
    deploy_result=$(cribl_post "/master/groups/default/deploy" '{"version":"current"}' 2>/dev/null)
    if echo "$deploy_result" | jq -e '.' &>/dev/null; then
        log_ok "Deployed to default Worker Group"
    else
        log_warn "Deploy response: $(echo "$deploy_result" | head -c 200)"
    fi

    # Deploy to Edge Fleet
    log_info "Deploying to default_fleet Edge Fleet..."
    local fleet_deploy
    fleet_deploy=$(cribl_post "/master/groups/default_fleet/deploy" '{"version":"current"}' 2>/dev/null)
    if echo "$fleet_deploy" | jq -e '.' &>/dev/null; then
        log_ok "Deployed to default_fleet"
    else
        log_warn "Fleet deploy response: $(echo "$fleet_deploy" | head -c 200)"
    fi

    # =========================================================================
    # Step 7: Verify
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

    # Check routes
    verify_total=$((verify_total + 1))
    local route_check
    route_check=$(cribl_get "/routes" 2>/dev/null)
    if echo "$route_check" | jq -e '.items[] | select(.id == "route_classify_all")' &>/dev/null; then
        log_ok "VERIFY: Route 'route_classify_all' exists"
        verify_passed=$((verify_passed + 1))
    else
        log_error "VERIFY: Route 'route_classify_all' NOT found"
    fi

    verify_total=$((verify_total + 1))
    if echo "$route_check" | jq -e '.items[] | select(.id == "route_siem_splunk")' &>/dev/null; then
        log_ok "VERIFY: Route 'route_siem_splunk' exists"
        verify_passed=$((verify_passed + 1))
    else
        log_error "VERIFY: Route 'route_siem_splunk' NOT found"
    fi

    # Check route count
    verify_total=$((verify_total + 1))
    local route_count
    route_count=$(echo "$route_check" | jq '[.items[]] | length' 2>/dev/null || echo "0")
    if [[ "$route_count" -ge 5 ]]; then
        log_ok "VERIFY: ${route_count} routes configured (expected >= 5)"
        verify_passed=$((verify_passed + 1))
    else
        log_error "VERIFY: Only ${route_count} routes found (expected >= 5)"
    fi

    # Summary
    echo ""
    echo "============================================================================="
    echo "  Universal Classifier Deployment Summary"
    echo "============================================================================="
    echo ""
    echo -e "  ${verify_passed}/${verify_total} verification checks passed"
    echo ""

    if [[ "$verify_passed" -eq "$verify_total" ]]; then
        echo -e "  ${GREEN}${BOLD}Deployment successful!${NC}"
        echo ""
        echo "  Next steps:"
        echo "    1. Check Edge Nodes: http://10.10.0.100:9000/edge/fleets"
        echo "    2. Monitor events:   http://10.10.0.100:5601 (Kibana)"
        echo "    3. SIEM events:      http://10.10.0.66:8000 (Splunk)"
        echo "    4. AI Panel:         http://10.10.0.100:8080/docs/16-ai-status-panel.html"
    else
        echo -e "  ${YELLOW}${BOLD}Deployment completed with warnings. Review output above.${NC}"
    fi
    echo ""
}

main "$@"
