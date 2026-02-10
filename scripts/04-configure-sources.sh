#!/usr/bin/env bash
# =============================================================================
# 04-configure-sources.sh - Configure Cribl Stream data sources
# =============================================================================
# Creates all log sources via Cribl API, sets file permissions and ACLs
# for the cribl service user to read log files.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "$SCRIPT_DIR/lib/api-helpers.sh"

# --- Main ---
print_header "Configure Sources"

# Load environment
load_env "$PROJECT_DIR/.env"

# Require root for permission changes
require_root
require_commands curl jq setfacl

# Verify Cribl is running
cribl_health_check || die "Cribl Stream is not healthy. Start it before running this script."

# Authenticate
cribl_auth

# ============================================================================
# Step 1: Create sources from JSON configs
# ============================================================================
log_step "Creating sources from JSON config files"

SOURCES_DIR="$PROJECT_DIR/configs/stream/sources"

if [[ ! -d "$SOURCES_DIR" ]]; then
    die "Sources config directory not found: $SOURCES_DIR"
fi

source_count=0
for config_file in "$SOURCES_DIR"/*.json; do
    [[ -f "$config_file" ]] || continue

    source_type=$(jq -r '.type' "$config_file")
    source_id=$(jq -r '.id' "$config_file")

    if [[ -z "$source_type" || "$source_type" == "null" ]]; then
        log_warn "Skipping $config_file - no 'type' field found"
        continue
    fi

    log_info "Processing source: $source_id (type: $source_type)"
    cribl_create_source "$source_type" "$config_file"
    source_count=$((source_count + 1))
done

log_ok "Created $source_count sources"

# ============================================================================
# Step 2: Set file permissions for cribl service user
# ============================================================================
log_step "Configuring file permissions for cribl user"

CRIBL_USER="${CRIBL_SERVICE_USER:-cribl}"

# Add cribl user to required groups for log access
declare -a REQUIRED_GROUPS=(
    "systemd-journal"   # Access to journald logs
    "adm"               # Access to /var/log files (auth.log, syslog, etc.)
    "docker"            # Access to Docker container logs
)

for group in "${REQUIRED_GROUPS[@]}"; do
    if getent group "$group" &>/dev/null; then
        if id -nG "$CRIBL_USER" 2>/dev/null | grep -qw "$group"; then
            log_info "User $CRIBL_USER already in group: $group"
        else
            usermod -aG "$group" "$CRIBL_USER"
            log_ok "Added $CRIBL_USER to group: $group"
        fi
    else
        log_warn "Group does not exist, skipping: $group"
    fi
done

# ============================================================================
# Step 3: Set ACLs for restricted log directories
# ============================================================================
log_step "Setting ACLs for restricted log directories"

declare -A ACL_DIRS=(
    ["/var/log/samba"]="Samba logs"
    ["/var/log/tor"]="Tor logs"
    ["/var/log/cups"]="CUPS logs"
    ["/var/log/apache2"]="Apache logs"
)

for dir in "${!ACL_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        log_info "Setting ACLs on ${ACL_DIRS[$dir]}: $dir"
        # Set default ACL so new files also get read access
        setfacl -R -m "u:${CRIBL_USER}:rX" "$dir"
        setfacl -R -d -m "u:${CRIBL_USER}:rX" "$dir"
        log_ok "ACLs set for: $dir"
    else
        log_warn "Directory does not exist, skipping ACL: $dir (${ACL_DIRS[$dir]})"
    fi
done

# Docker container logs directory
DOCKER_LOG_DIR="/var/lib/docker/containers"
if [[ -d "$DOCKER_LOG_DIR" ]]; then
    log_info "Setting ACLs on Docker container logs: $DOCKER_LOG_DIR"
    setfacl -R -m "u:${CRIBL_USER}:rX" "$DOCKER_LOG_DIR"
    setfacl -R -d -m "u:${CRIBL_USER}:rX" "$DOCKER_LOG_DIR"
    log_ok "ACLs set for: $DOCKER_LOG_DIR"
else
    log_warn "Docker log directory does not exist: $DOCKER_LOG_DIR"
fi

# Individual log files that may have restrictive permissions
declare -a ACL_FILES=(
    "/var/log/auth.log"
    "/var/log/dnsmasq-tor.log"
)

for logfile in "${ACL_FILES[@]}"; do
    if [[ -f "$logfile" ]]; then
        setfacl -m "u:${CRIBL_USER}:r" "$logfile"
        log_ok "ACL set for file: $logfile"
    else
        log_warn "Log file does not exist, skipping: $logfile"
    fi
done

# ============================================================================
# Step 4: Commit and deploy
# ============================================================================
log_step "Committing and deploying source configuration"

cribl_commit_deploy "Configure data sources: file monitors, journald (${source_count} sources)"

log_ok "Source configuration complete!"
log_info "Summary:"
log_info "  - Sources created: $source_count"
log_info "  - Groups configured: ${REQUIRED_GROUPS[*]}"
log_info "  - ACL directories: ${!ACL_DIRS[*]}"
log_info ""
log_info "Note: If group memberships were changed, restart the cribl service:"
log_info "  systemctl restart cribl"
