#!/usr/bin/env bash
# =============================================================================
# 09-uninstall-cribl.sh - Clean Uninstall of Cribl Stream and Edge
# =============================================================================
# Interactively removes Cribl Stream, Cribl Edge, associated systemd services,
# and optionally the cribl user/group, backup directory, and Tailscale.
#
# Must be run as root.
#
# Usage:
#   sudo ./scripts/09-uninstall-cribl.sh
# =============================================================================

# --- Resolve script location and source shared libraries ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# =============================================================================
# Configuration
# =============================================================================

CRIBL_HOME="${CRIBL_HOME:-/opt/cribl}"
CRIBL_EDGE_HOME="${CRIBL_EDGE_HOME:-/opt/cribl-edge}"
CRIBL_SERVICE_USER="${CRIBL_SERVICE_USER:-cribl}"
CRIBL_SERVICE_GROUP="${CRIBL_SERVICE_GROUP:-cribl}"
BACKUP_DIR="${BACKUP_DIR:-/opt/cribl-backups}"

# Systemd unit file locations
STREAM_SERVICE_NAME="cribl"
EDGE_SERVICE_NAME="cribl-edge"
SYSTEMD_DIR="/etc/systemd/system"

# =============================================================================
# Tracking what was removed
# =============================================================================

declare -a REMOVED_ITEMS=()
declare -a SKIPPED_ITEMS=()

track_removed() { REMOVED_ITEMS+=("$1"); }
track_skipped() { SKIPPED_ITEMS+=("$1"); }

# =============================================================================
# Show what will be removed
# =============================================================================

show_removal_plan() {
    echo ""
    echo -e "${BOLD}The following components will be evaluated for removal:${NC}"
    echo ""

    echo "  Services:"
    echo "    - ${EDGE_SERVICE_NAME} (systemd service)"
    echo "    - ${STREAM_SERVICE_NAME} (systemd service)"
    echo ""

    echo "  Directories:"
    echo "    - ${CRIBL_EDGE_HOME}"
    echo "    - ${CRIBL_HOME}"
    echo ""

    echo "  Systemd unit files:"
    echo "    - ${SYSTEMD_DIR}/${STREAM_SERVICE_NAME}.service"
    echo "    - ${SYSTEMD_DIR}/${EDGE_SERVICE_NAME}.service"
    echo ""

    echo "  Optional (you will be asked):"
    echo "    - User/group: ${CRIBL_SERVICE_USER}/${CRIBL_SERVICE_GROUP}"
    echo "    - Backup directory: ${BACKUP_DIR}"
    echo "    - Tailscale (if installed)"
    echo ""
}

# =============================================================================
# Removal functions
# =============================================================================

stop_and_disable_service() {
    local service="$1"

    if systemctl list-unit-files "${service}.service" &>/dev/null 2>&1; then
        log_info "Stopping and disabling ${service}..."
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
        track_removed "Service: ${service} (stopped and disabled)"
        log_ok "Service ${service} stopped and disabled"
    else
        log_info "Service ${service} not found -- skipping"
        track_skipped "Service: ${service} (not found)"
    fi
}

remove_systemd_units() {
    log_step "Removing systemd unit files"

    for service in "$STREAM_SERVICE_NAME" "$EDGE_SERVICE_NAME"; do
        local unit_file="${SYSTEMD_DIR}/${service}.service"
        if [[ -f "$unit_file" ]]; then
            rm -f "$unit_file"
            track_removed "Unit file: ${unit_file}"
            log_ok "Removed ${unit_file}"
        else
            log_info "Unit file ${unit_file} not found -- skipping"
            track_skipped "Unit file: ${unit_file} (not found)"
        fi
    done

    # Reload systemd to pick up the removal
    systemctl daemon-reload 2>/dev/null || true
    log_ok "Systemd daemon reloaded"
}

remove_directory() {
    local dir="$1"
    local label="$2"

    if [[ -d "$dir" ]]; then
        local size
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        rm -rf "$dir"
        track_removed "Directory: ${dir} (${size})"
        log_ok "Removed ${dir} (${size})"
    else
        log_info "${label} directory ${dir} not found -- skipping"
        track_skipped "Directory: ${dir} (not found)"
    fi
}

remove_cribl_user() {
    log_step "Removing cribl user and group"

    if id "$CRIBL_SERVICE_USER" &>/dev/null; then
        # Kill any remaining processes owned by the user
        pkill -u "$CRIBL_SERVICE_USER" 2>/dev/null || true
        sleep 1

        userdel -r "$CRIBL_SERVICE_USER" 2>/dev/null || userdel "$CRIBL_SERVICE_USER" 2>/dev/null || true
        track_removed "User: ${CRIBL_SERVICE_USER}"
        log_ok "User ${CRIBL_SERVICE_USER} removed"
    else
        log_info "User ${CRIBL_SERVICE_USER} does not exist -- skipping"
        track_skipped "User: ${CRIBL_SERVICE_USER} (not found)"
    fi

    # Remove group only if it still exists and is not a primary group of another user
    if getent group "$CRIBL_SERVICE_GROUP" &>/dev/null; then
        groupdel "$CRIBL_SERVICE_GROUP" 2>/dev/null || true
        track_removed "Group: ${CRIBL_SERVICE_GROUP}"
        log_ok "Group ${CRIBL_SERVICE_GROUP} removed"
    else
        track_skipped "Group: ${CRIBL_SERVICE_GROUP} (not found or already removed)"
    fi
}

remove_backup_dir() {
    if [[ -d "$BACKUP_DIR" ]]; then
        local size count
        size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        count=$(find "$BACKUP_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
        log_warn "Backup directory ${BACKUP_DIR} contains ${count} file(s) (${size})"
        rm -rf "$BACKUP_DIR"
        track_removed "Backup directory: ${BACKUP_DIR} (${count} files, ${size})"
        log_ok "Backup directory removed"
    else
        log_info "Backup directory ${BACKUP_DIR} not found -- skipping"
        track_skipped "Backup directory: ${BACKUP_DIR} (not found)"
    fi
}

remove_tailscale() {
    log_step "Removing Tailscale"

    if command -v tailscale &>/dev/null; then
        # Disconnect from the tailnet first
        tailscale logout 2>/dev/null || true
        tailscale down 2>/dev/null || true

        # Stop the service
        systemctl stop tailscaled 2>/dev/null || true
        systemctl disable tailscaled 2>/dev/null || true

        # Remove the package
        if command -v apt-get &>/dev/null; then
            apt-get remove -y tailscale 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf remove -y tailscale 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum remove -y tailscale 2>/dev/null || true
        else
            log_warn "Cannot determine package manager -- remove tailscale manually"
        fi

        # Remove state directory
        rm -rf /var/lib/tailscale 2>/dev/null || true

        track_removed "Tailscale (service + package + state)"
        log_ok "Tailscale removed"
    else
        log_info "Tailscale not installed -- skipping"
        track_skipped "Tailscale (not installed)"
    fi
}

# =============================================================================
# Summary
# =============================================================================

print_removal_summary() {
    echo ""
    echo "============================================================================="
    echo "  UNINSTALL SUMMARY"
    echo "============================================================================="

    if [[ ${#REMOVED_ITEMS[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${RED}${BOLD}Removed:${NC}"
        for item in "${REMOVED_ITEMS[@]}"; do
            echo -e "    ${RED}- ${item}${NC}"
        done
    fi

    if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${YELLOW}${BOLD}Skipped (not found):${NC}"
        for item in "${SKIPPED_ITEMS[@]}"; do
            echo -e "    ${YELLOW}- ${item}${NC}"
        done
    fi

    echo ""
    echo "============================================================================="

    if [[ ${#REMOVED_ITEMS[@]} -gt 0 ]]; then
        echo -e "\n  ${GREEN}${BOLD}Uninstall complete.${NC} ${#REMOVED_ITEMS[@]} item(s) removed.\n"
    else
        echo -e "\n  ${YELLOW}${BOLD}Nothing was removed.${NC}\n"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Cribl Uninstall"
    require_root

    # Load environment if available (for custom paths)
    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "${PROJECT_ROOT}/.env" 2>/dev/null || true
        set +a
        # Re-apply variables that may have been overridden by .env
        CRIBL_HOME="${CRIBL_HOME:-/opt/cribl}"
        CRIBL_EDGE_HOME="${CRIBL_EDGE_HOME:-/opt/cribl-edge}"
        CRIBL_SERVICE_USER="${CRIBL_SERVICE_USER:-cribl}"
        CRIBL_SERVICE_GROUP="${CRIBL_SERVICE_GROUP:-cribl}"
        BACKUP_DIR="${BACKUP_DIR:-/opt/cribl-backups}"
    fi

    show_removal_plan

    if ! confirm "Proceed with uninstallation?"; then
        log_info "Uninstall cancelled by user"
        exit 0
    fi

    # --- Core removal (always performed after confirmation) ---

    log_step "Stopping services"
    # Edge first, then Stream (Edge depends on Stream for fleet management)
    stop_and_disable_service "$EDGE_SERVICE_NAME"
    stop_and_disable_service "$STREAM_SERVICE_NAME"

    remove_systemd_units

    log_step "Removing installation directories"
    remove_directory "$CRIBL_EDGE_HOME" "Cribl Edge"
    remove_directory "$CRIBL_HOME" "Cribl Stream"

    # --- Optional: cribl user and group ---

    echo ""
    if id "$CRIBL_SERVICE_USER" &>/dev/null; then
        if confirm "Remove cribl user (${CRIBL_SERVICE_USER}) and group (${CRIBL_SERVICE_GROUP})?"; then
            remove_cribl_user
        else
            track_skipped "User/group: ${CRIBL_SERVICE_USER}/${CRIBL_SERVICE_GROUP} (user declined)"
            log_info "Keeping user ${CRIBL_SERVICE_USER}"
        fi
    fi

    # --- Optional: backup directory ---

    if [[ -d "$BACKUP_DIR" ]]; then
        if confirm "Remove backup directory ${BACKUP_DIR} and all backups?"; then
            remove_backup_dir
        else
            track_skipped "Backup directory: ${BACKUP_DIR} (user declined)"
            log_info "Keeping backup directory ${BACKUP_DIR}"
        fi
    fi

    # --- Optional: Tailscale ---

    if command -v tailscale &>/dev/null; then
        if confirm "Remove Tailscale?"; then
            remove_tailscale
        else
            track_skipped "Tailscale (user declined)"
            log_info "Keeping Tailscale"
        fi
    fi

    # --- Done ---

    print_removal_summary
}

main "$@"
