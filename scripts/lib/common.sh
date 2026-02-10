#!/usr/bin/env bash
# =============================================================================
# common.sh - Shared functions for IceDataEmphasise scripts
# =============================================================================
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Logging ---
log_info()    { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}>>> $*${NC}"; }

# --- Error Handling ---
die() {
    log_error "$@"
    exit 1
}

trap_handler() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script failed with exit code $exit_code (line ${BASH_LINENO[0]})"
    fi
}
trap trap_handler EXIT

# --- Environment ---
load_env() {
    local env_file="${1:-.env}"
    if [[ -f "$env_file" ]]; then
        log_info "Loading environment from $env_file"
        set -a
        # shellcheck source=/dev/null
        source "$env_file"
        set +a
    else
        die "Environment file not found: $env_file. Copy .env.example to .env and configure it."
    fi
}

# --- Root Check ---
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi
}

require_non_root() {
    if [[ $EUID -eq 0 ]]; then
        die "This script should NOT be run as root"
    fi
}

# --- Dependency Checks ---
require_commands() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
}

# --- Confirmation ---
confirm() {
    local prompt="${1:-Are you sure?}"
    local default="${2:-n}"
    local answer
    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]:${NC} ")" answer
        answer="${answer:-y}"
    else
        read -rp "$(echo -e "${YELLOW}${prompt} [y/N]:${NC} ")" answer
        answer="${answer:-n}"
    fi
    [[ "$answer" =~ ^[Yy] ]]
}

# --- File Helpers ---
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date '+%Y%m%d_%H%M%S')"
        cp "$file" "$backup"
        log_info "Backup created: $backup"
    fi
}

ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log_info "Created directory: $dir"
    fi
}

# --- Network ---
check_port_open() {
    local host="$1"
    local port="$2"
    local timeout="${3:-5}"
    if timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

wait_for_port() {
    local host="$1"
    local port="$2"
    local max_wait="${3:-60}"
    local interval="${4:-2}"
    local elapsed=0
    log_info "Waiting for $host:$port (max ${max_wait}s)..."
    while ! check_port_open "$host" "$port" 2; do
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [[ $elapsed -ge $max_wait ]]; then
            die "Timeout waiting for $host:$port after ${max_wait}s"
        fi
    done
    log_ok "$host:$port is reachable (${elapsed}s)"
}

# --- Service Helpers ---
service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

wait_for_service() {
    local service="$1"
    local max_wait="${2:-30}"
    local elapsed=0
    while ! service_is_active "$service"; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $max_wait ]]; then
            die "Timeout waiting for service $service after ${max_wait}s"
        fi
    done
    log_ok "Service $service is active (${elapsed}s)"
}

# --- Version Helpers ---
version_gte() {
    # Returns 0 if $1 >= $2 (version comparison)
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# --- Script Header ---
print_header() {
    local title="$1"
    echo -e "\n${BOLD}${CYAN}=============================================${NC}"
    echo -e "${BOLD}${CYAN}  IceDataEmphasise - ${title}${NC}"
    echo -e "${BOLD}${CYAN}=============================================${NC}"
    echo -e "${BLUE}  Date: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BLUE}  Host: $(hostname)${NC}"
    echo -e "${BLUE}  User: $(whoami)${NC}\n"
}
