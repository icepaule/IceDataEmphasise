#!/usr/bin/env bash
# =============================================================================
# 06-configure-pipelines.sh - Configure Cribl Stream pipelines and routes
# =============================================================================
# Creates all processing pipelines and configures the route table
# to direct events from sources through pipelines to destinations.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "$SCRIPT_DIR/lib/api-helpers.sh"

# --- Main ---
print_header "Configure Pipelines & Routes"

# Load environment
load_env "$PROJECT_DIR/.env"

require_commands curl jq

# Verify Cribl is running
cribl_health_check || die "Cribl Stream is not healthy. Start it before running this script."

# Authenticate
cribl_auth

# ============================================================================
# Step 1: Create pipelines from JSON configs
# ============================================================================
log_step "Creating pipelines from JSON config files"

PIPELINES_DIR="$PROJECT_DIR/configs/stream/pipelines"

if [[ ! -d "$PIPELINES_DIR" ]]; then
    die "Pipelines config directory not found: $PIPELINES_DIR"
fi

pipeline_count=0
for config_file in "$PIPELINES_DIR"/pipeline-*.json; do
    [[ -f "$config_file" ]] || continue

    pipeline_id=$(jq -r '.id' "$config_file")

    if [[ -z "$pipeline_id" || "$pipeline_id" == "null" ]]; then
        log_warn "Skipping $config_file - no 'id' field found"
        continue
    fi

    log_info "Creating pipeline: $pipeline_id"
    cribl_create_pipeline "$config_file"
    pipeline_count=$((pipeline_count + 1))
done

log_ok "Created $pipeline_count pipelines"

# ============================================================================
# Step 2: Configure routes
# ============================================================================
log_step "Configuring route table"

ROUTES_FILE="$PIPELINES_DIR/routes.json"

if [[ ! -f "$ROUTES_FILE" ]]; then
    die "Routes config file not found: $ROUTES_FILE"
fi

route_count=$(jq '.routes | length' "$ROUTES_FILE")
log_info "Applying route table with $route_count routes"

cribl_create_route "$ROUTES_FILE"

log_ok "Route table configured with $route_count routes"

# List configured routes for verification
log_info "Configured routes:"
jq -r '.routes[] | "  - \(.name) [\(.id)]: filter=\(.filter) -> pipeline=\(.pipeline) -> output=\(.output)"' "$ROUTES_FILE"

# ============================================================================
# Step 3: Commit and deploy
# ============================================================================
log_step "Committing and deploying pipeline and route configuration"

cribl_commit_deploy "Configure pipelines and routes (${pipeline_count} pipelines, ${route_count} routes)"

log_ok "Pipeline and route configuration complete!"
log_info "Summary:"
log_info "  - Pipelines created: $pipeline_count"
log_info "  - Routes configured: $route_count"
log_info ""
log_info "Pipeline overview:"
log_info "  - pipeline_syslog_enrichment : Syslog metadata + timestamp extraction"
log_info "  - pipeline_apache_clf        : Apache Combined Log Format parser"
log_info "  - pipeline_docker_json       : Docker JSON log parser"
log_info "  - pipeline_security_auth     : SSH auth parser + MITRE ATT&CK tagging"
log_info "  - pipeline_generic_passthrough : Minimal metadata passthrough"
log_info ""
log_info "Route overview:"
log_info "  - Apache access  -> pipeline_apache_clf        -> splunk_hec"
log_info "  - Apache error   -> pipeline_syslog_enrichment -> splunk_hec"
log_info "  - SSH auth       -> pipeline_security_auth     -> splunk_s2s"
log_info "  - Docker/HA      -> pipeline_docker_json       -> splunk_hec"
log_info "  - Systemd journal-> pipeline_syslog_enrichment -> splunk_s2s"
log_info "  - Samba          -> pipeline_generic_passthrough-> splunk_s2s"
log_info "  - Default (all)  -> pipeline_generic_passthrough-> splunk_hec"
