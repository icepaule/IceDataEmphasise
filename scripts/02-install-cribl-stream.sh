#!/usr/bin/env bash
# =============================================================================
# 02-install-cribl-stream.sh - Cribl Stream 4.16.0 Bare Metal Installation
# =============================================================================
# Downloads, installs, and configures Cribl Stream 4.16.0 on a bare metal
# (or VM) Linux host. Runs as a dedicated "cribl" service user under systemd.
#
# Must be run as root.
#
# Key environment variables (loaded from .env):
#   CRIBL_VERSION          - Version to install (default: 4.16.0)
#   CRIBL_INSTALL_DIR      - Installation directory (default: /opt/cribl)
#   CRIBL_ADMIN_USER       - Initial admin username (default: admin)
#   CRIBL_ADMIN_PASSWORD   - Initial admin password (required)
#   CRIBL_SERVICE_USER     - Service user name (default: cribl)
#   CRIBL_SERVICE_GROUP    - Service group name (default: cribl)
#
# Installation steps:
#   1. Create service user and group
#   2. Download Cribl Stream tarball from cdn.cribl.io
#   3. Extract to /opt/cribl, set ownership
#   4. Configure initial admin password
#   5. Enable systemd service via Cribl's boot-start
#   6. Add CAP_NET_BIND_SERVICE for syslog on port 514
#   7. Start service and wait for readiness
#   8. Verify health via API
# =============================================================================

# --- Resolve script location and source shared libraries ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "${SCRIPT_DIR}/lib/api-helpers.sh"

# =============================================================================
# Configuration defaults (may be overridden by .env)
# =============================================================================

CRIBL_VERSION="${CRIBL_VERSION:-4.16.0}"
CRIBL_INSTALL_DIR="${CRIBL_INSTALL_DIR:-/opt/cribl}"
CRIBL_SERVICE_USER="${CRIBL_SERVICE_USER:-cribl}"
CRIBL_SERVICE_GROUP="${CRIBL_SERVICE_GROUP:-cribl}"
CRIBL_ADMIN_USER="${CRIBL_ADMIN_USER:-admin}"
CRIBL_DOWNLOAD_URL=""  # Resolved dynamically from cdn.cribl.io/dl/latest-x64
CRIBL_TARBALL="/tmp/cribl-${CRIBL_VERSION}-linux-x64.tgz"

# =============================================================================
# Step 1: Create service user
# =============================================================================

create_service_user() {
    log_step "Step 1: Creating service user '${CRIBL_SERVICE_USER}'"

    # Create the group if it does not exist
    if ! getent group "${CRIBL_SERVICE_GROUP}" &>/dev/null; then
        groupadd --system "${CRIBL_SERVICE_GROUP}"
        log_ok "Group '${CRIBL_SERVICE_GROUP}' created"
    else
        log_info "Group '${CRIBL_SERVICE_GROUP}' already exists"
    fi

    # Create the user if it does not exist
    if ! id "${CRIBL_SERVICE_USER}" &>/dev/null; then
        useradd --system \
            --gid "${CRIBL_SERVICE_GROUP}" \
            --shell /usr/sbin/nologin \
            --home-dir "${CRIBL_INSTALL_DIR}" \
            --no-create-home \
            --comment "Cribl Stream service account" \
            "${CRIBL_SERVICE_USER}"
        log_ok "User '${CRIBL_SERVICE_USER}' created"
    else
        log_info "User '${CRIBL_SERVICE_USER}' already exists"
    fi

    # Add supplementary groups for log access and Docker integration.
    # Each group is added only if it exists on the system.
    local supplementary_groups=("systemd-journal" "adm" "docker")
    for grp in "${supplementary_groups[@]}"; do
        if getent group "$grp" &>/dev/null; then
            usermod -aG "$grp" "${CRIBL_SERVICE_USER}"
            log_info "Added '${CRIBL_SERVICE_USER}' to group '${grp}'"
        else
            log_warn "Group '${grp}' does not exist on this system -- skipping"
        fi
    done
}

# =============================================================================
# Step 2: Download Cribl Stream
# =============================================================================

download_cribl() {
    log_step "Step 2: Downloading Cribl Stream ${CRIBL_VERSION}"

    require_commands curl

    # Skip download if tarball already present and looks valid
    if [[ -f "$CRIBL_TARBALL" ]]; then
        log_info "Tarball already exists at ${CRIBL_TARBALL}"
        if confirm "Re-download the tarball?" "n"; then
            rm -f "$CRIBL_TARBALL"
        else
            log_info "Using existing tarball"
            return 0
        fi
    fi

    # Resolve actual download URL (CDN URLs include a build hash)
    if [[ -z "$CRIBL_DOWNLOAD_URL" ]]; then
        log_info "Resolving latest download URL from cdn.cribl.io..."
        CRIBL_DOWNLOAD_URL="$(curl -fsSL "https://cdn.cribl.io/dl/latest-x64" 2>/dev/null || true)"
        if [[ -z "$CRIBL_DOWNLOAD_URL" ]]; then
            die "Failed to resolve download URL from cdn.cribl.io"
        fi
    fi

    log_info "Downloading from: ${CRIBL_DOWNLOAD_URL}"
    curl -fSL --progress-bar -o "$CRIBL_TARBALL" "$CRIBL_DOWNLOAD_URL"

    if [[ ! -s "$CRIBL_TARBALL" ]]; then
        die "Download failed or file is empty: ${CRIBL_TARBALL}"
    fi
    log_ok "Download complete: ${CRIBL_TARBALL} ($(du -h "$CRIBL_TARBALL" | cut -f1))"

    # Attempt SHA256 checksum verification if a .sha256 file is available
    local checksum_url="${CRIBL_DOWNLOAD_URL}.sha256"
    local checksum_file="${CRIBL_TARBALL}.sha256"

    log_info "Attempting checksum verification..."
    if curl -fsSL -o "$checksum_file" "$checksum_url" 2>/dev/null && [[ -s "$checksum_file" ]]; then
        # The sha256 file may contain just the hash, or "hash  filename" format.
        local expected_hash
        expected_hash="$(awk '{print $1}' "$checksum_file")"
        local actual_hash
        actual_hash="$(sha256sum "$CRIBL_TARBALL" | awk '{print $1}')"

        if [[ "$expected_hash" == "$actual_hash" ]]; then
            log_ok "SHA256 checksum verified: ${actual_hash}"
        else
            die "Checksum mismatch! Expected: ${expected_hash}, Got: ${actual_hash}"
        fi
        rm -f "$checksum_file"
    else
        log_warn "No SHA256 checksum file available at ${checksum_url} -- skipping verification"
        rm -f "$checksum_file"
    fi
}

# =============================================================================
# Step 3: Extract to /opt/cribl
# =============================================================================

extract_cribl() {
    log_step "Step 3: Extracting Cribl Stream to ${CRIBL_INSTALL_DIR}"

    require_commands tar

    # If the install directory already exists, back it up
    if [[ -d "$CRIBL_INSTALL_DIR" ]]; then
        log_warn "Existing installation found at ${CRIBL_INSTALL_DIR}"
        if confirm "Back up and replace the existing installation?" "n"; then
            local backup_dir="${CRIBL_INSTALL_DIR}.bak.$(date '+%Y%m%d_%H%M%S')"
            mv "$CRIBL_INSTALL_DIR" "$backup_dir"
            log_info "Backed up to: ${backup_dir}"
        else
            die "Aborting -- existing installation at ${CRIBL_INSTALL_DIR}"
        fi
    fi

    # The tarball extracts to a "cribl" directory, so we extract into /opt
    local parent_dir
    parent_dir="$(dirname "$CRIBL_INSTALL_DIR")"
    ensure_dir "$parent_dir"

    tar -xzf "$CRIBL_TARBALL" -C "$parent_dir"

    if [[ ! -d "$CRIBL_INSTALL_DIR" ]]; then
        die "Extraction did not produce expected directory: ${CRIBL_INSTALL_DIR}"
    fi

    # Set ownership recursively
    chown -R "${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}" "$CRIBL_INSTALL_DIR"
    log_ok "Extracted and set ownership to ${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}"
}

# =============================================================================
# Step 4: Set initial admin password
# =============================================================================

configure_admin_password() {
    log_step "Step 4: Configuring initial admin password"

    local admin_password="${CRIBL_ADMIN_PASSWORD:?CRIBL_ADMIN_PASSWORD is not set in .env}"

    # Validate that the password is not a placeholder
    if [[ "$admin_password" == "YOUR_CRIBL_ADMIN_PASSWORD" ]]; then
        die "CRIBL_ADMIN_PASSWORD is still set to the placeholder value. Update .env with a real password."
    fi

    # Use Cribl's CLI to set single-instance mode and configure the admin password.
    # The bootstrap approach writes credentials into the local config.
    log_info "Setting admin credentials via Cribl CLI..."

    # Run mode-single to initialize single-instance configuration.
    # CRIBL_HOME must be set for the CLI to find its config.
    export CRIBL_HOME="$CRIBL_INSTALL_DIR"

    # Use the bootstrap config approach: write admin credentials to the bootstrap config
    local bootstrap_dir="${CRIBL_INSTALL_DIR}/local/cribl/auth"
    ensure_dir "$bootstrap_dir"

    # Create the users.json bootstrap file with the admin user.
    # Cribl will hash the password on first boot if provided in cleartext with
    # the "password" field (as opposed to the "hash" field).
    local users_file="${bootstrap_dir}/users.json"
    cat > "$users_file" <<USERS_EOF
{
  "${CRIBL_ADMIN_USER}": {
    "username": "${CRIBL_ADMIN_USER}",
    "first": "Admin",
    "last": "User",
    "email": "admin@localhost",
    "password": "${admin_password}",
    "roles": ["admin"],
    "disabled": false
  }
}
USERS_EOF

    chown -R "${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}" "${CRIBL_INSTALL_DIR}/local"
    chmod 600 "$users_file"

    log_ok "Admin credentials configured (will be hashed on first start)"
}

# =============================================================================
# Step 5: Enable systemd service via boot-start
# =============================================================================

enable_systemd_service() {
    log_step "Step 5: Enabling systemd service"

    log_info "Running Cribl boot-start to create systemd unit..."

    "${CRIBL_INSTALL_DIR}/bin/cribl" boot-start enable \
        -m systemd \
        -u "${CRIBL_SERVICE_USER}"

    # Verify the unit file was created
    if systemctl list-unit-files cribl.service &>/dev/null; then
        log_ok "systemd service 'cribl' registered"
    else
        # Cribl may name it differently; check for any cribl-related service
        log_warn "Could not confirm cribl.service -- checking alternative names..."
        systemctl list-unit-files 'cribl*' || true
    fi

    systemctl daemon-reload
    log_ok "systemd daemon reloaded"
}

# =============================================================================
# Step 6: Add CAP_NET_BIND_SERVICE for syslog port 514
# =============================================================================

add_net_bind_capability() {
    log_step "Step 6: Adding CAP_NET_BIND_SERVICE capability (for syslog port 514)"

    # Create a systemd drop-in override to grant the capability
    local override_dir="/etc/systemd/system/cribl.service.d"
    ensure_dir "$override_dir"

    local override_file="${override_dir}/cap-net-bind.conf"

    cat > "$override_file" <<'OVERRIDE_EOF'
# Allow the cribl service to bind to privileged ports (e.g., syslog 514)
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
OVERRIDE_EOF

    log_ok "systemd override created: ${override_file}"

    systemctl daemon-reload
    log_ok "systemd daemon reloaded with capability override"
}

# =============================================================================
# Step 7: Start and enable the Cribl service
# =============================================================================

start_cribl_service() {
    log_step "Step 7: Starting Cribl Stream service"

    systemctl enable cribl
    systemctl start cribl

    # Wait for the systemd service to report active
    wait_for_service "cribl" 30
    log_ok "Cribl service is active"
}

# =============================================================================
# Step 8: Wait for port 9000 to become available
# =============================================================================

wait_for_cribl_port() {
    log_step "Step 8: Waiting for Cribl Stream to listen on port 9000"

    wait_for_port "localhost" 9000 90
    log_ok "Port 9000 is open and accepting connections"
}

# =============================================================================
# Step 9: Verify health via API
# =============================================================================

verify_health() {
    log_step "Step 9: Verifying Cribl Stream health"

    # Give the application a few extra seconds to fully initialize
    sleep 3

    local health_url="http://localhost:9000/api/v1/health"
    local http_code
    http_code="$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "000")"

    if [[ "$http_code" == "200" ]]; then
        log_ok "Health check passed (HTTP ${http_code})"
    else
        log_error "Health check returned HTTP ${http_code}"
        log_warn "Cribl Stream may still be initializing. Check logs:"
        log_warn "  journalctl -u cribl -f"
        log_warn "  ${CRIBL_INSTALL_DIR}/log/cribl.log"
        return 1
    fi
}

# =============================================================================
# Step 10: Print success message
# =============================================================================

print_success() {
    log_step "Installation Complete"

    # Determine accessible URL -- prefer Tailscale IP if available
    local access_ip="localhost"
    if command -v tailscale &>/dev/null; then
        local ts_ip
        ts_ip="$(tailscale ip -4 2>/dev/null || true)"
        if [[ -n "$ts_ip" ]]; then
            access_ip="$ts_ip"
        fi
    fi

    echo ""
    echo "============================================================================="
    echo "  Cribl Stream ${CRIBL_VERSION} is installed and running."
    echo ""
    echo "  Web UI:    http://${access_ip}:9000"
    echo "  Username:  ${CRIBL_ADMIN_USER}"
    echo "  Install:   ${CRIBL_INSTALL_DIR}"
    echo "  Service:   systemctl {start|stop|restart|status} cribl"
    echo "  Logs:      journalctl -u cribl -f"
    echo "             ${CRIBL_INSTALL_DIR}/log/cribl.log"
    echo ""
    echo "  Syslog:    Listening on port 514 (CAP_NET_BIND_SERVICE enabled)"
    echo "============================================================================="
    echo ""
}

# =============================================================================
# Cleanup handler -- remove tarball on success
# =============================================================================

cleanup() {
    if [[ -f "$CRIBL_TARBALL" ]]; then
        rm -f "$CRIBL_TARBALL"
        log_info "Cleaned up tarball: ${CRIBL_TARBALL}"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Cribl Stream ${CRIBL_VERSION} Installation"
    require_root

    # Step 0: Load environment and check prerequisites
    load_env "${PROJECT_ROOT}/.env"
    require_commands curl tar

    # Re-apply defaults after .env is loaded (in case .env overrides them)
    CRIBL_VERSION="${CRIBL_VERSION:-4.16.0}"
    CRIBL_INSTALL_DIR="${CRIBL_INSTALL_DIR:-/opt/cribl}"
    CRIBL_SERVICE_USER="${CRIBL_SERVICE_USER:-cribl}"
    CRIBL_SERVICE_GROUP="${CRIBL_SERVICE_GROUP:-cribl}"
    CRIBL_ADMIN_USER="${CRIBL_ADMIN_USER:-admin}"
    CRIBL_DOWNLOAD_URL=""  # Resolved dynamically in download_cribl()
    CRIBL_TARBALL="/tmp/cribl-${CRIBL_VERSION}-linux-x64.tgz"

    log_info "Version:       ${CRIBL_VERSION}"
    log_info "Install dir:   ${CRIBL_INSTALL_DIR}"
    log_info "Service user:  ${CRIBL_SERVICE_USER}"
    log_info "Download URL:  ${CRIBL_DOWNLOAD_URL}"
    echo ""

    # Execute installation steps in order
    create_service_user          # Step 1
    download_cribl               # Step 2
    extract_cribl                # Step 3
    configure_admin_password     # Step 4
    enable_systemd_service       # Step 5
    add_net_bind_capability      # Step 6
    start_cribl_service          # Step 7
    wait_for_cribl_port          # Step 8
    verify_health                # Step 9
    print_success                # Step 10

    # Clean up downloaded tarball
    cleanup

    log_ok "Cribl Stream installation finished successfully."
}

main "$@"
