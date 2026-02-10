#!/usr/bin/env bash
# =============================================================================
# 08-backup-cribl-config.sh - Cribl Configuration Backup
# =============================================================================
# Creates timestamped backups of Cribl Stream and Edge local configuration
# directories, plus an API-exported JSON snapshot.  Old backups are pruned
# according to BACKUP_RETENTION_DAYS.
#
# Safe to run as root or as the cribl service user.
# Designed for unattended execution via cron.
#
# Usage:
#   sudo ./scripts/08-backup-cribl-config.sh
#   # or as cribl user (if cribl owns the backup directory):
#   ./scripts/08-backup-cribl-config.sh
#
# Example crontab entry (daily at 02:00):
#   0 2 * * * /home/mpauli/IceDataEmphasise/scripts/08-backup-cribl-config.sh \
#       >> /var/log/cribl-backup.log 2>&1
# =============================================================================

# --- Resolve script location and source shared libraries ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "${SCRIPT_DIR}/lib/api-helpers.sh"

# =============================================================================
# Configuration (may be overridden via .env)
# =============================================================================

# Load environment if available -- do not die if .env is missing when running
# from cron (variables may already be exported).
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    load_env "${PROJECT_ROOT}/.env"
else
    log_warn "No .env file found at ${PROJECT_ROOT}/.env -- using defaults / existing environment"
fi

BACKUP_DIR="${BACKUP_DIR:-/opt/cribl-backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
CRIBL_HOME="${CRIBL_HOME:-/opt/cribl}"
CRIBL_EDGE_HOME="${CRIBL_EDGE_HOME:-/opt/cribl-edge}"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# =============================================================================
# Globals for summary
# =============================================================================

declare -a BACKUP_FILES=()
declare -a BACKUP_SIZES=()
BACKUP_ERRORS=0

# =============================================================================
# Helper: record a backup file and its size
# =============================================================================

record_backup() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local size
        size=$(du -h "$file" | cut -f1)
        BACKUP_FILES+=("$file")
        BACKUP_SIZES+=("$size")
        log_ok "Created: ${file} (${size})"
    else
        log_error "Expected backup file missing: ${file}"
        BACKUP_ERRORS=$((BACKUP_ERRORS + 1))
    fi
}

# =============================================================================
# Backup functions
# =============================================================================

backup_stream_config() {
    log_step "Backing up Cribl Stream local config"

    local src="${CRIBL_HOME}/local"
    local dest="${BACKUP_DIR}/cribl-stream-local_${TIMESTAMP}.tar.gz"

    if [[ ! -d "$src" ]]; then
        log_warn "Stream local directory not found: ${src} -- skipping"
        return
    fi

    tar -czf "$dest" -C "$(dirname "$src")" "$(basename "$src")" 2>/dev/null
    record_backup "$dest"
}

backup_edge_config() {
    log_step "Backing up Cribl Edge local config"

    local src="${CRIBL_EDGE_HOME}/local"
    local dest="${BACKUP_DIR}/cribl-edge-local_${TIMESTAMP}.tar.gz"

    if [[ ! -d "$src" ]]; then
        log_warn "Edge local directory not found: ${src} -- skipping"
        return
    fi

    tar -czf "$dest" -C "$(dirname "$src")" "$(basename "$src")" 2>/dev/null
    record_backup "$dest"
}

backup_api_export() {
    log_step "Exporting current configuration via API"

    local dest="${BACKUP_DIR}/cribl-api-export_${TIMESTAMP}.json"

    # Attempt API authentication -- if it fails, skip this step gracefully
    local api_available=true
    if ! cribl_auth 2>/dev/null; then
        log_warn "Cannot authenticate with Cribl API -- skipping API export"
        api_available=false
    fi

    if [[ "$api_available" == "true" ]]; then
        local export_data="{}"

        # Collect sources
        local sources
        sources=$(cribl_get "/m/default/system/inputs" 2>/dev/null || echo '{"items":[]}')

        # Collect destinations
        local destinations
        destinations=$(cribl_get "/m/default/system/outputs" 2>/dev/null || echo '{"items":[]}')

        # Collect pipelines
        local pipelines
        pipelines=$(cribl_get "/m/default/pipelines" 2>/dev/null || echo '{"items":[]}')

        # Collect routes
        local routes
        routes=$(cribl_get "/m/default/routes" 2>/dev/null || echo '{"items":[]}')

        # Collect fleet/groups
        local fleets
        fleets=$(cribl_get "/master/groups" 2>/dev/null || echo '{"items":[]}')

        # Assemble into a single JSON document
        export_data=$(jq -n \
            --arg ts "$TIMESTAMP" \
            --arg host "$(hostname)" \
            --argjson sources "$sources" \
            --argjson destinations "$destinations" \
            --argjson pipelines "$pipelines" \
            --argjson routes "$routes" \
            --argjson fleets "$fleets" \
            '{
                metadata: {
                    timestamp: $ts,
                    hostname: $host,
                    export_type: "api"
                },
                sources: $sources,
                destinations: $destinations,
                pipelines: $pipelines,
                routes: $routes,
                fleets: $fleets
            }')

        echo "$export_data" > "$dest"
        record_backup "$dest"
    fi
}

# =============================================================================
# Retention: prune old backups
# =============================================================================

prune_old_backups() {
    log_step "Pruning backups older than ${BACKUP_RETENTION_DAYS} days"

    local count
    count=$(find "$BACKUP_DIR" -maxdepth 1 -type f \
        \( -name "cribl-stream-local_*.tar.gz" \
        -o -name "cribl-edge-local_*.tar.gz" \
        -o -name "cribl-api-export_*.json" \) \
        -mtime "+${BACKUP_RETENTION_DAYS}" 2>/dev/null | wc -l)

    if [[ "$count" -gt 0 ]]; then
        find "$BACKUP_DIR" -maxdepth 1 -type f \
            \( -name "cribl-stream-local_*.tar.gz" \
            -o -name "cribl-edge-local_*.tar.gz" \
            -o -name "cribl-api-export_*.json" \) \
            -mtime "+${BACKUP_RETENTION_DAYS}" \
            -delete 2>/dev/null
        log_ok "Deleted ${count} backup(s) older than ${BACKUP_RETENTION_DAYS} days"
    else
        log_info "No backups older than ${BACKUP_RETENTION_DAYS} days to prune"
    fi
}

# =============================================================================
# Summary
# =============================================================================

print_backup_summary() {
    echo ""
    echo "============================================================================="
    echo "  BACKUP SUMMARY"
    echo "============================================================================="
    printf "  %-60s  %s\n" "FILE" "SIZE"
    echo "-----------------------------------------------------------------------------"

    for i in "${!BACKUP_FILES[@]}"; do
        printf "  %-60s  %s\n" "${BACKUP_FILES[$i]}" "${BACKUP_SIZES[$i]}"
    done

    echo "============================================================================="

    local total_backups
    total_backups=$(find "$BACKUP_DIR" -maxdepth 1 -type f \
        \( -name "cribl-*.tar.gz" -o -name "cribl-*.json" \) 2>/dev/null | wc -l)

    local total_size
    total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

    echo ""
    echo -e "  Backup directory:   ${BACKUP_DIR}"
    echo -e "  Total backups:      ${total_backups}"
    echo -e "  Total size:         ${total_size}"
    echo -e "  Retention:          ${BACKUP_RETENTION_DAYS} days"
    echo ""

    if [[ "$BACKUP_ERRORS" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}Backup completed successfully.${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}Backup completed with ${BACKUP_ERRORS} error(s).${NC}"
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Configuration Backup"
    require_commands tar jq curl

    # Ensure backup directory exists
    ensure_dir "$BACKUP_DIR"

    # If running as root and the cribl user exists, ensure the backup dir
    # is accessible to the cribl user for future runs
    local cribl_user="${CRIBL_SERVICE_USER:-cribl}"
    if [[ $EUID -eq 0 ]] && id "$cribl_user" &>/dev/null; then
        chown "$cribl_user":"${CRIBL_SERVICE_GROUP:-cribl}" "$BACKUP_DIR" 2>/dev/null || true
    fi

    backup_stream_config
    backup_edge_config
    backup_api_export
    prune_old_backups
    print_backup_summary

    if [[ "$BACKUP_ERRORS" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
