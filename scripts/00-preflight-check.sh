#!/usr/bin/env bash
# =============================================================================
# 00-preflight-check.sh - Preflight System Verification
# =============================================================================
# Validates that the target host meets all hardware, network, and software
# prerequisites before installing Cribl Stream and related components.
#
# Must be run as root. Exits with a non-zero code if any critical check fails.
#
# Checks performed:
#   - Kernel version >= 3.10
#   - CPU cores >= 4
#   - Available RAM >= 8 GB
#   - Free disk on /opt >= 5 GB
#   - Required ports are free (not already in use)
#   - Outbound network connectivity to cdn.cribl.io and Splunk host
#   - Required CLI tools installed (curl, tar, jq, openssl)
# =============================================================================

# --- Resolve script location and source shared libraries ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/api-helpers.sh
source "${SCRIPT_DIR}/lib/api-helpers.sh"

# =============================================================================
# Configuration
# =============================================================================

# Minimum requirements
MIN_KERNEL="3.10"
MIN_CPU_CORES=4
MIN_RAM_GB=8
MIN_DISK_GB=5
DISK_MOUNT="/opt"

# Ports that must be free (not already bound by another process)
REQUIRED_PORTS=(9000 9420 9997 4200 514)

# Required CLI tools
REQUIRED_PACKAGES=(curl tar jq openssl)

# Hosts we need outbound connectivity to
CDN_HOST="cdn.cribl.io"
CDN_PORT=443

# =============================================================================
# Globals for summary tracking
# =============================================================================

# Parallel arrays: check name, result (PASS/FAIL), detail message
declare -a CHECK_NAMES=()
declare -a CHECK_RESULTS=()
declare -a CHECK_DETAILS=()
FAIL_COUNT=0

# =============================================================================
# Helper: record a check result
# =============================================================================

# record_check NAME RESULT DETAIL
# RESULT must be "PASS" or "FAIL"
record_check() {
    local name="$1"
    local result="$2"
    local detail="$3"

    CHECK_NAMES+=("$name")
    CHECK_RESULTS+=("$result")
    CHECK_DETAILS+=("$detail")

    if [[ "$result" == "FAIL" ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log_error "$name: $detail"
    else
        log_ok "$name: $detail"
    fi
}

# =============================================================================
# Individual checks
# =============================================================================

check_kernel() {
    log_step "Checking kernel version"

    local kernel_version
    kernel_version="$(uname -r | grep -oE '^[0-9]+\.[0-9]+')"

    if version_gte "$kernel_version" "$MIN_KERNEL"; then
        record_check "Kernel" "PASS" "Running ${kernel_version} (>= ${MIN_KERNEL} required)"
    else
        record_check "Kernel" "FAIL" "Running ${kernel_version} (>= ${MIN_KERNEL} required)"
    fi
}

check_cpu() {
    log_step "Checking CPU cores"

    local cores
    cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"

    if [[ "$cores" -ge "$MIN_CPU_CORES" ]]; then
        record_check "CPU Cores" "PASS" "${cores} cores available (>= ${MIN_CPU_CORES} required)"
    else
        record_check "CPU Cores" "FAIL" "${cores} cores available (>= ${MIN_CPU_CORES} required)"
    fi
}

check_ram() {
    log_step "Checking available RAM"

    # MemAvailable from /proc/meminfo gives usable memory (includes cache/buffers)
    local mem_kb
    mem_kb="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"

    # Fall back to MemTotal if MemAvailable is not present (older kernels)
    if [[ "$mem_kb" -eq 0 ]]; then
        mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
    fi

    local mem_gb
    mem_gb="$(awk "BEGIN { printf \"%.1f\", ${mem_kb} / 1048576 }")"

    # Integer comparison (truncate to floor)
    local mem_gb_int
    mem_gb_int="$(awk "BEGIN { printf \"%d\", ${mem_kb} / 1048576 }")"

    if [[ "$mem_gb_int" -ge "$MIN_RAM_GB" ]]; then
        record_check "RAM" "PASS" "${mem_gb} GB available (>= ${MIN_RAM_GB} GB required)"
    else
        record_check "RAM" "FAIL" "${mem_gb} GB available (>= ${MIN_RAM_GB} GB required)"
    fi
}

check_disk() {
    log_step "Checking free disk space on ${DISK_MOUNT}"

    # Ensure mount point exists; fall back to / if /opt is not a separate mount
    local check_path="$DISK_MOUNT"
    if [[ ! -d "$check_path" ]]; then
        check_path="/"
    fi

    # df -BG gives output in whole GB; parse the available column
    local free_gb
    free_gb="$(df -BG --output=avail "$check_path" 2>/dev/null | tail -1 | tr -d ' G')"

    if [[ "$free_gb" -ge "$MIN_DISK_GB" ]]; then
        record_check "Disk (${DISK_MOUNT})" "PASS" "${free_gb} GB free (>= ${MIN_DISK_GB} GB required)"
    else
        record_check "Disk (${DISK_MOUNT})" "FAIL" "${free_gb} GB free (>= ${MIN_DISK_GB} GB required)"
    fi
}

check_ports() {
    log_step "Checking required ports are free"

    for port in "${REQUIRED_PORTS[@]}"; do
        # Use ss to check if anything is listening on this port
        if ss -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
            local process
            process="$(ss -tlnp 2>/dev/null | grep -E ":${port}\b" | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo "unknown")"
            record_check "Port ${port}" "FAIL" "Already in use by: ${process}"
        else
            record_check "Port ${port}" "PASS" "Port is free"
        fi
    done
}

check_network() {
    log_step "Checking network connectivity"

    # Check outbound HTTPS to cdn.cribl.io
    if curl -sf --connect-timeout 10 --max-time 15 -o /dev/null "https://${CDN_HOST}/" 2>/dev/null; then
        record_check "Network (${CDN_HOST})" "PASS" "HTTPS connectivity OK"
    else
        record_check "Network (${CDN_HOST})" "FAIL" "Cannot reach https://${CDN_HOST}/ -- check firewall/DNS"
    fi

    # Check connectivity to Splunk host if SPLUNK_HOST is defined
    # Attempt to load .env for the Splunk host variable; if .env is missing, skip gracefully
    local splunk_host="${SPLUNK_HOST:-}"
    local splunk_port="${SPLUNK_HEC_PORT:-8088}"

    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        # Source .env silently to pick up SPLUNK_HOST without dying on missing file
        set -a
        # shellcheck source=/dev/null
        source "${PROJECT_ROOT}/.env" 2>/dev/null || true
        set +a
        splunk_host="${SPLUNK_HOST:-$splunk_host}"
        splunk_port="${SPLUNK_HEC_PORT:-$splunk_port}"
    fi

    if [[ -n "$splunk_host" ]]; then
        if check_port_open "$splunk_host" "$splunk_port" 10; then
            record_check "Network (Splunk)" "PASS" "Reachable at ${splunk_host}:${splunk_port}"
        else
            record_check "Network (Splunk)" "FAIL" "Cannot reach ${splunk_host}:${splunk_port}"
        fi
    else
        record_check "Network (Splunk)" "FAIL" "SPLUNK_HOST not set -- define it in .env"
    fi
}

check_packages() {
    log_step "Checking required packages"

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if command -v "$pkg" &>/dev/null; then
            local pkg_version
            pkg_version="$("$pkg" --version 2>&1 | head -1 || echo "unknown")"
            record_check "Package (${pkg})" "PASS" "Installed: ${pkg_version}"
        else
            record_check "Package (${pkg})" "FAIL" "Not found in PATH"
        fi
    done
}

# =============================================================================
# Summary table
# =============================================================================

print_summary() {
    local total=${#CHECK_NAMES[@]}
    local pass_count=$((total - FAIL_COUNT))

    echo ""
    echo "============================================================================="
    printf "  %-35s  %-6s  %s\n" "CHECK" "RESULT" "DETAILS"
    echo "-----------------------------------------------------------------------------"

    for i in "${!CHECK_NAMES[@]}"; do
        local name="${CHECK_NAMES[$i]}"
        local result="${CHECK_RESULTS[$i]}"
        local detail="${CHECK_DETAILS[$i]}"

        if [[ "$result" == "PASS" ]]; then
            printf "  %-35s  ${GREEN}%-6s${NC}  %s\n" "$name" "$result" "$detail"
        else
            printf "  %-35s  ${RED}%-6s${NC}  %s\n" "$name" "$result" "$detail"
        fi
    done

    echo "============================================================================="

    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo -e "\n  ${GREEN}${BOLD}All ${total} checks passed. System is ready.${NC}\n"
    else
        echo -e "\n  ${RED}${BOLD}${FAIL_COUNT} of ${total} checks FAILED. Resolve issues before proceeding.${NC}\n"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Preflight System Check"
    require_root

    check_kernel
    check_cpu
    check_ram
    check_disk
    check_ports
    check_network
    check_packages

    print_summary

    # Exit with failure if any check did not pass
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
