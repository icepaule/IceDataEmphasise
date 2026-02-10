#!/usr/bin/env bash
# =============================================================================
# 01-install-tailscale.sh - Tailscale Installation & Headscale Connection
# =============================================================================
# Installs the Tailscale client from the official Debian/Ubuntu repository,
# starts the daemon, and connects to the Headscale coordination server
# defined in the project .env file.
#
# Must be run as root.
#
# Environment variables (loaded from .env):
#   HEADSCALE_URL       - Full URL of the Headscale server (required)
#   HEADSCALE_AUTH_KEY  - Pre-auth key for unattended join (optional)
#
# If HEADSCALE_AUTH_KEY is not set, `tailscale up` will print a login URL
# that must be opened in a browser and approved in Headscale.
# =============================================================================

# --- Resolve script location and source shared libraries ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "${SCRIPT_DIR}/lib/api-helpers.sh"

# =============================================================================
# Functions
# =============================================================================

# Detect the Debian/Ubuntu version codename from os-release
detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect distribution: /etc/os-release not found"
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    # ID is "debian", "ubuntu", etc.  VERSION_CODENAME is "bookworm", "jammy", etc.
    DISTRO_ID="${ID:-}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"

    # Fallback: try to extract codename from VERSION for older os-release files
    if [[ -z "$DISTRO_CODENAME" ]]; then
        DISTRO_CODENAME="$(echo "${VERSION:-}" | grep -oP '\((\K[^)]+)' || true)"
    fi

    if [[ -z "$DISTRO_ID" || -z "$DISTRO_CODENAME" ]]; then
        die "Could not determine distribution ID or codename from /etc/os-release"
    fi

    log_info "Detected distribution: ${DISTRO_ID} (${DISTRO_CODENAME})"
}

# Add the official Tailscale APT repository
add_tailscale_repo() {
    log_step "Adding Tailscale package repository"

    require_commands curl gpg apt-get

    local keyring="/usr/share/keyrings/tailscale-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/tailscale.list"

    # Download and install the signing key
    log_info "Downloading Tailscale GPG key..."
    curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO_ID}/${DISTRO_CODENAME}.noarmor.gpg" \
        | tee "$keyring" > /dev/null

    if [[ ! -s "$keyring" ]]; then
        die "Failed to download Tailscale GPG key"
    fi
    log_ok "GPG key installed to ${keyring}"

    # Add the repository source
    log_info "Adding APT source list..."
    curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO_ID}/${DISTRO_CODENAME}.tailscale-keyring.list" \
        | tee "$list_file" > /dev/null

    if [[ ! -s "$list_file" ]]; then
        die "Failed to create Tailscale APT source list"
    fi
    log_ok "APT source added: ${list_file}"

    # Update package index
    log_info "Running apt-get update..."
    apt-get update -qq
    log_ok "Package index updated"
}

# Install the tailscale package via apt
install_tailscale_package() {
    log_step "Installing Tailscale package"

    apt-get install -y -qq tailscale
    log_ok "Tailscale package installed: $(tailscale version 2>/dev/null | head -1)"
}

# Offer to upgrade if tailscale is already installed
handle_existing_installation() {
    local current_version
    current_version="$(tailscale version 2>/dev/null | head -1 || echo "unknown")"
    log_info "Tailscale is already installed (version: ${current_version})"

    if confirm "Do you want to upgrade Tailscale to the latest version?" "n"; then
        log_step "Upgrading Tailscale"
        detect_distro
        add_tailscale_repo
        apt-get install -y -qq --only-upgrade tailscale
        local new_version
        new_version="$(tailscale version 2>/dev/null | head -1 || echo "unknown")"
        log_ok "Tailscale upgraded to: ${new_version}"
    else
        log_info "Skipping upgrade"
    fi
}

# Ensure the tailscaled system service is running
start_tailscaled() {
    log_step "Starting tailscaled service"

    systemctl enable --now tailscaled

    # Wait for the service to become active
    wait_for_service "tailscaled" 15
    log_ok "tailscaled is running"
}

# Connect to the Headscale coordination server
connect_to_headscale() {
    log_step "Connecting to Headscale"

    local headscale_url="${HEADSCALE_URL:?HEADSCALE_URL is not set in .env}"

    log_info "Headscale server: ${headscale_url}"

    # Build the tailscale up command
    local ts_args=(
        "--login-server" "$headscale_url"
    )

    # If an auth key is provided, use it for unattended registration
    local auth_key="${HEADSCALE_AUTH_KEY:-}"
    if [[ -n "$auth_key" && "$auth_key" != "YOUR_HEADSCALE_PREAUTH_KEY" ]]; then
        log_info "Using pre-auth key for automatic registration"
        ts_args+=("--authkey" "$auth_key")
    else
        log_warn "No HEADSCALE_AUTH_KEY set -- tailscale will print a login URL."
        log_warn "Open the URL in a browser and approve the node in Headscale."
    fi

    # Run tailscale up (this may block waiting for approval if no authkey)
    tailscale up "${ts_args[@]}"

    log_ok "tailscale up completed"
}

# Verify the Tailscale connection and display the assigned IP
verify_connection() {
    log_step "Verifying Tailscale connection"

    local status
    status="$(tailscale status 2>&1 || true)"

    if echo "$status" | grep -q "stopped\|not running"; then
        die "Tailscale does not appear to be connected. Check 'tailscale status' for details."
    fi

    log_info "Tailscale status:"
    echo "$status"
    echo ""

    # Extract and display the Tailscale IP
    local ts_ip
    ts_ip="$(tailscale ip -4 2>/dev/null || echo "unknown")"

    if [[ "$ts_ip" != "unknown" ]]; then
        log_ok "Tailscale IPv4 address: ${ts_ip}"
    else
        log_warn "Could not determine Tailscale IPv4 address"
    fi
}

# Print firewall recommendations
print_firewall_note() {
    log_step "Firewall Recommendations"

    local ts_iface
    ts_iface="$(ip -o link show | awk -F': ' '/tailscale/ {print $2}' | head -1 || echo "tailscale0")"

    echo ""
    echo "  To restrict Cribl Stream port 9000 to the Tailscale interface only,"
    echo "  consider adding the following iptables rules:"
    echo ""
    echo "    # Allow Cribl Stream (9000) only on the Tailscale interface"
    echo "    iptables -A INPUT -i ${ts_iface} -p tcp --dport 9000 -j ACCEPT"
    echo "    iptables -A INPUT -p tcp --dport 9000 -j DROP"
    echo ""
    echo "  If using ufw:"
    echo "    ufw allow in on ${ts_iface} to any port 9000 proto tcp"
    echo "    ufw deny 9000/tcp"
    echo ""
    echo "  Remember to persist rules with iptables-save or netfilter-persistent."
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Tailscale Installation"
    require_root

    # Load environment variables from project .env
    load_env "${PROJECT_ROOT}/.env"

    # Check if tailscale is already installed
    if command -v tailscale &>/dev/null; then
        handle_existing_installation
    else
        # Fresh installation
        detect_distro
        add_tailscale_repo
        install_tailscale_package
    fi

    # Start the daemon and connect to Headscale
    start_tailscaled
    connect_to_headscale
    verify_connection

    # Firewall guidance
    print_firewall_note

    log_ok "Tailscale installation and Headscale connection complete."
}

main "$@"
