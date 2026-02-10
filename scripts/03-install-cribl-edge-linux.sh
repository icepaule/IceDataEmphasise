#!/usr/bin/env bash
# =============================================================================
# 03-install-cribl-edge-linux.sh
# Install Cribl Edge as a managed Edge node on the same host as Cribl Stream
# =============================================================================
# Usage: sudo ./03-install-cribl-edge-linux.sh
#
# This script installs the same Cribl binary at /opt/cribl-edge and configures
# it in managed-edge mode, connecting to the local Cribl Stream leader on
# port 4200. A dedicated systemd unit (cribl-edge.service) is created manually
# to avoid conflicts with the existing Cribl Stream service.
# =============================================================================

# --- Resolve script directory and source common functions ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Constants ---
readonly CRIBL_TGZ_URL_TEMPLATE="https://cdn.cribl.io/dl/CRIBL_VERSION/cribl-CRIBL_VERSION-linux-x64.tgz"
readonly SYSTEMD_UNIT="/etc/systemd/system/cribl-edge.service"
readonly CRIBL_EDGE_DEFAULT_PORT=4200
readonly EDGE_REGISTRATION_TIMEOUT=90
readonly EDGE_REGISTRATION_INTERVAL=5

# =============================================================================
# Functions
# =============================================================================

validate_environment() {
    log_step "Validating environment"

    require_root
    require_commands curl tar systemctl id getent

    # Ensure required .env variables are set
    local required_vars=(
        CRIBL_VERSION
        CRIBL_EDGE_HOME
        CRIBL_SERVICE_USER
        CRIBL_SERVICE_GROUP
        CRIBL_EDGE_MGMT_PORT
    )
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            die "Required environment variable $var is not set. Check your .env file."
        fi
    done

    # Verify the cribl service user exists
    if ! id "${CRIBL_SERVICE_USER}" &>/dev/null; then
        die "Service user '${CRIBL_SERVICE_USER}' does not exist. Run the prerequisites script first."
    fi

    log_ok "Environment validation passed"
}

check_existing_installation() {
    log_step "Checking for existing Cribl Edge installation"

    if [[ -d "${CRIBL_EDGE_HOME}" ]]; then
        if [[ -x "${CRIBL_EDGE_HOME}/bin/cribl" ]]; then
            local installed_version
            installed_version=$("${CRIBL_EDGE_HOME}/bin/cribl" version 2>/dev/null | head -1 || echo "unknown")
            log_warn "Cribl Edge is already installed at ${CRIBL_EDGE_HOME} (version: ${installed_version})"

            if service_is_active "cribl-edge"; then
                log_warn "cribl-edge.service is currently running"
            fi

            if ! confirm "Cribl Edge already exists. Reinstall/overwrite?"; then
                log_info "Installation cancelled by user"
                exit 0
            fi

            # Stop the service if running before reinstall
            if service_is_active "cribl-edge"; then
                log_info "Stopping cribl-edge service before reinstall..."
                systemctl stop cribl-edge || log_warn "Failed to stop cribl-edge service"
            fi
        else
            log_warn "Directory ${CRIBL_EDGE_HOME} exists but has no cribl binary. Will overwrite."
        fi
    else
        log_ok "No existing Cribl Edge installation found"
    fi
}

download_cribl_tarball() {
    log_step "Downloading Cribl ${CRIBL_VERSION} tarball"

    local url="${CRIBL_TGZ_URL_TEMPLATE//CRIBL_VERSION/${CRIBL_VERSION}}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local tgz_path="${tmp_dir}/cribl-${CRIBL_VERSION}-linux-x64.tgz"

    # Check if tarball was already downloaded (e.g., by the stream install script)
    local cached_tgz="/tmp/cribl-${CRIBL_VERSION}-linux-x64.tgz"
    if [[ -f "$cached_tgz" ]]; then
        log_info "Using cached tarball: ${cached_tgz}"
        tgz_path="$cached_tgz"
    else
        log_info "Downloading from ${url}"
        if ! curl -fSL --retry 3 --retry-delay 5 -o "$tgz_path" "$url"; then
            rm -rf "$tmp_dir"
            die "Failed to download Cribl tarball from ${url}"
        fi
        log_ok "Download complete: ${tgz_path}"

        # Cache the tarball for potential re-use
        cp "$tgz_path" "$cached_tgz" 2>/dev/null || true
    fi

    # Validate tarball
    if ! tar tzf "$tgz_path" &>/dev/null; then
        rm -rf "$tmp_dir"
        die "Downloaded tarball is corrupt or not a valid gzip archive"
    fi

    echo "$tgz_path"
}

extract_and_install() {
    local tgz_path="$1"

    log_step "Extracting Cribl Edge to ${CRIBL_EDGE_HOME}"

    # Create parent directory if needed
    ensure_dir "$(dirname "${CRIBL_EDGE_HOME}")"

    # Extract tarball - it contains a 'cribl/' directory, so we strip and target edge home
    local tmp_extract
    tmp_extract="$(mktemp -d)"

    if ! tar xzf "$tgz_path" -C "$tmp_extract"; then
        rm -rf "$tmp_extract"
        die "Failed to extract tarball"
    fi

    # The tarball extracts to a 'cribl' directory
    if [[ ! -d "${tmp_extract}/cribl" ]]; then
        rm -rf "$tmp_extract"
        die "Unexpected tarball structure - expected 'cribl/' directory inside archive"
    fi

    # Remove old installation if it exists (backup the local config if any)
    if [[ -d "${CRIBL_EDGE_HOME}/local" ]]; then
        log_info "Backing up existing local configuration..."
        local config_backup="${CRIBL_EDGE_HOME}/local.bak.$(date '+%Y%m%d_%H%M%S')"
        cp -a "${CRIBL_EDGE_HOME}/local" "$config_backup"
        log_info "Configuration backed up to: ${config_backup}"
    fi

    # Move extracted files into place
    if [[ -d "${CRIBL_EDGE_HOME}" ]]; then
        rm -rf "${CRIBL_EDGE_HOME}"
    fi
    mv "${tmp_extract}/cribl" "${CRIBL_EDGE_HOME}"
    rm -rf "$tmp_extract"

    # Set ownership
    chown -R "${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}" "${CRIBL_EDGE_HOME}"

    log_ok "Cribl Edge extracted to ${CRIBL_EDGE_HOME}"
}

configure_managed_edge() {
    log_step "Configuring Cribl Edge as managed-edge node"

    local master_url="tcp://127.0.0.1:${CRIBL_EDGE_MGMT_PORT:-${CRIBL_EDGE_DEFAULT_PORT}}"

    # Ensure local config directory exists
    local local_cribl_dir="${CRIBL_EDGE_HOME}/local/cribl"
    ensure_dir "$local_cribl_dir"

    # Write cribl.yml with managed-edge configuration
    # This configures Edge to connect to the local Stream leader
    local cribl_yml="${local_cribl_dir}/cribl.yml"

    log_info "Writing managed-edge configuration to ${cribl_yml}"
    cat > "$cribl_yml" <<YAML
distributed:
  mode: managed-edge
  master:
    host: "127.0.0.1"
    port: ${CRIBL_EDGE_MGMT_PORT:-${CRIBL_EDGE_DEFAULT_PORT}}
    tls:
      disabled: true
    authToken: ""
YAML

    chown "${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}" "$cribl_yml"
    chmod 640 "$cribl_yml"

    # Ensure the entire local directory tree has correct ownership
    chown -R "${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}" "${CRIBL_EDGE_HOME}/local"

    log_ok "Managed-edge configuration written"
    log_info "Master URL: ${master_url}"
}

create_systemd_service() {
    log_step "Creating systemd service: cribl-edge.service"

    # Determine supplementary groups that exist on this system
    local supplementary_groups=""
    local desired_groups=("systemd-journal" "adm" "docker")
    local found_groups=()

    for grp in "${desired_groups[@]}"; do
        if getent group "$grp" &>/dev/null; then
            found_groups+=("$grp")
        else
            log_warn "Group '${grp}' does not exist on this system, skipping"
        fi
    done

    if [[ ${#found_groups[@]} -gt 0 ]]; then
        supplementary_groups=$(IFS=,; echo "${found_groups[*]}")
    fi

    # Backup existing unit file if present
    if [[ -f "$SYSTEMD_UNIT" ]]; then
        backup_file "$SYSTEMD_UNIT"
    fi

    log_info "Writing systemd unit file: ${SYSTEMD_UNIT}"

    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Cribl Edge - Managed Edge Node
Documentation=https://docs.cribl.io/edge/
After=network-online.target cribl.service
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=forking
User=${CRIBL_SERVICE_USER}
Group=${CRIBL_SERVICE_GROUP}
${supplementary_groups:+SupplementaryGroups=${supplementary_groups}}
WorkingDirectory=${CRIBL_EDGE_HOME}
ExecStart=${CRIBL_EDGE_HOME}/bin/cribl start
ExecStop=${CRIBL_EDGE_HOME}/bin/cribl stop
ExecReload=${CRIBL_EDGE_HOME}/bin/cribl restart
PIDFile=${CRIBL_EDGE_HOME}/pid/cribl.pid
Restart=on-failure
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30

# Environment variables for managed-edge mode
Environment=CRIBL_DIST_MODE=managed-edge
Environment=CRIBL_DIST_MASTER_URL=tcp://127.0.0.1:${CRIBL_EDGE_MGMT_PORT:-${CRIBL_EDGE_DEFAULT_PORT}}

# Capabilities for reading logs and journal
AmbientCapabilities=CAP_DAC_READ_SEARCH CAP_SYSLOG
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SYSLOG CAP_NET_BIND_SERVICE

# Security hardening
NoNewPrivileges=false
ProtectSystem=full
ReadWritePaths=${CRIBL_EDGE_HOME}
ProtectHome=true

# Increase file descriptor limits for log collection
LimitNOFILE=65536
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd to pick up the new unit
    systemctl daemon-reload

    log_ok "Systemd unit file created and daemon reloaded"
}

enable_and_start_service() {
    log_step "Enabling and starting cribl-edge service"

    # Ensure the PID directory exists and is writable
    ensure_dir "${CRIBL_EDGE_HOME}/pid"
    chown "${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}" "${CRIBL_EDGE_HOME}/pid"

    # Enable the service
    if ! systemctl enable cribl-edge.service; then
        die "Failed to enable cribl-edge.service"
    fi
    log_ok "cribl-edge.service enabled"

    # Start the service
    log_info "Starting cribl-edge.service..."
    if ! systemctl start cribl-edge.service; then
        log_error "Failed to start cribl-edge.service"
        log_error "--- journalctl output ---"
        journalctl -u cribl-edge.service --no-pager -n 30 >&2
        die "cribl-edge.service failed to start. See logs above."
    fi

    # Wait for the service to be active
    wait_for_service "cribl-edge" 30

    log_ok "cribl-edge.service is running"
}

wait_for_edge_registration() {
    log_step "Waiting for Edge node to register with Stream leader"

    # First, verify the Stream leader management port is reachable
    if ! check_port_open "127.0.0.1" "${CRIBL_EDGE_MGMT_PORT:-${CRIBL_EDGE_DEFAULT_PORT}}" 5; then
        log_warn "Stream leader management port ${CRIBL_EDGE_MGMT_PORT:-${CRIBL_EDGE_DEFAULT_PORT}} is not reachable"
        log_warn "Ensure Cribl Stream is running and listening on port ${CRIBL_EDGE_MGMT_PORT:-${CRIBL_EDGE_DEFAULT_PORT}}"
        log_warn "Edge node will keep retrying connection in the background"
        return 0
    fi

    log_info "Stream leader port is reachable, waiting for edge registration (max ${EDGE_REGISTRATION_TIMEOUT}s)..."

    local elapsed=0
    while [[ $elapsed -lt $EDGE_REGISTRATION_TIMEOUT ]]; do
        # Check if the edge process is still running
        if ! service_is_active "cribl-edge"; then
            log_error "cribl-edge service stopped unexpectedly during registration"
            journalctl -u cribl-edge.service --no-pager -n 20 >&2
            die "Edge node failed during registration"
        fi

        # Check if edge has established connection by looking at logs
        if journalctl -u cribl-edge.service --no-pager -q 2>/dev/null | grep -qi "connected to master\|successfully connected\|registered"; then
            log_ok "Edge node registered with Stream leader"
            return 0
        fi

        sleep "$EDGE_REGISTRATION_INTERVAL"
        elapsed=$((elapsed + EDGE_REGISTRATION_INTERVAL))
        log_info "Still waiting... (${elapsed}s / ${EDGE_REGISTRATION_TIMEOUT}s)"
    done

    log_warn "Edge registration not confirmed within ${EDGE_REGISTRATION_TIMEOUT}s"
    log_warn "This may be normal - the node might still be negotiating. Check the Stream UI."
}

verify_installation() {
    log_step "Verifying Cribl Edge installation"

    # Check binary
    if [[ ! -x "${CRIBL_EDGE_HOME}/bin/cribl" ]]; then
        die "Cribl Edge binary not found or not executable at ${CRIBL_EDGE_HOME}/bin/cribl"
    fi
    local version
    version=$("${CRIBL_EDGE_HOME}/bin/cribl" version 2>/dev/null | head -1 || echo "unknown")
    log_ok "Cribl Edge binary: ${version}"

    # Check service status
    if service_is_active "cribl-edge"; then
        log_ok "cribl-edge.service is active"
    else
        log_warn "cribl-edge.service is not active"
    fi

    # Check ownership
    local owner
    owner=$(stat -c '%U:%G' "${CRIBL_EDGE_HOME}" 2>/dev/null || echo "unknown")
    if [[ "$owner" == "${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}" ]]; then
        log_ok "Ownership: ${owner}"
    else
        log_warn "Ownership mismatch: expected ${CRIBL_SERVICE_USER}:${CRIBL_SERVICE_GROUP}, got ${owner}"
    fi

    # Optional: API health check against Stream leader
    local api_port="${CRIBL_STREAM_API_PORT:-9000}"
    if check_port_open "127.0.0.1" "$api_port" 3; then
        log_info "Attempting API verification against Stream leader..."
        local api_url="http://127.0.0.1:${api_port}/api/v1/edge/nodes"
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -u "${CRIBL_ADMIN_USER:-admin}:${CRIBL_ADMIN_PASSWORD:-}" \
            "$api_url" 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            log_ok "Stream API is reachable and returned edge node data"
        elif [[ "$http_code" == "401" ]]; then
            log_warn "Stream API returned 401 - check API credentials in .env"
        else
            log_info "Stream API returned HTTP ${http_code} (edge node may not be visible yet)"
        fi
    else
        log_info "Stream API port ${api_port} not reachable - skipping API verification"
    fi
}

print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}=============================================${NC}"
    echo -e "${BOLD}${GREEN}  Cribl Edge Installation Complete${NC}"
    echo -e "${BOLD}${GREEN}=============================================${NC}"
    echo ""
    echo -e "  Install directory:  ${CRIBL_EDGE_HOME}"
    echo -e "  Service name:       cribl-edge.service"
    echo -e "  Mode:               managed-edge"
    echo -e "  Leader:             tcp://127.0.0.1:${CRIBL_EDGE_MGMT_PORT:-${CRIBL_EDGE_DEFAULT_PORT}}"
    echo -e "  Service user:       ${CRIBL_SERVICE_USER}"
    echo ""
    echo -e "  Useful commands:"
    echo -e "    systemctl status cribl-edge"
    echo -e "    journalctl -fu cribl-edge"
    echo -e "    ${CRIBL_EDGE_HOME}/bin/cribl status"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Install Cribl Edge (Managed Node)"

    # Load environment from project root
    local project_root
    project_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    load_env "${project_root}/.env"

    validate_environment
    check_existing_installation

    # Download and extract
    local tgz_path
    tgz_path=$(download_cribl_tarball)
    extract_and_install "$tgz_path"

    # Configure and start
    configure_managed_edge
    create_systemd_service
    enable_and_start_service
    wait_for_edge_registration

    # Verify
    verify_installation
    print_summary
}

main "$@"
