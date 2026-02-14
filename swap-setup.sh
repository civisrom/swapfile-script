#!/bin/bash
#
# swap-setup.sh — Automated hybrid swap (swapfile + zram) setup for Debian/Ubuntu
# Supports RAM templates: 1GB, 2GB, 3GB, 4GB and custom configuration
#
# Usage:
#   sudo bash swap-setup.sh [--ram 1|2|3|4] [--swapfile-size SIZE_MB]
#                            [--zram-percent PERCENT] [--zram-algo ALGO]
#                            [--zram-priority PRIORITY] [--swappiness VALUE]
#                            [--yes] [--remove] [--status]
#
set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Defaults ─────────────────────────────────────────────────────────────────
SWAPFILE_PATH="/swapfile"
SWAPFILE_SIZE_MB=""
ZRAM_ALGO="zstd"
ZRAM_PERCENT=""
ZRAM_PRIORITY=100
SWAP_PRIORITY=-2
SWAPPINESS=""
RAM_TEMPLATE=""
AUTO_YES=false
ACTION="install"

# ── Functions ────────────────────────────────────────────────────────────────

usage() {
    cat <<'USAGE'
Usage: sudo bash swap-setup.sh [OPTIONS]

Options:
  --ram N             Use preset template for N GB RAM (1, 2, 3, 4)
  --swapfile-size MB  Swap file size in MB (overrides template)
  --zram-percent N    zram size as % of RAM (overrides template)
  --zram-algo ALGO    zram compression algorithm (default: zstd)
  --zram-priority N   zram swap priority (default: 100)
  --swappiness N      vm.swappiness value (overrides template)
  --yes               Skip confirmation prompts
  --remove            Remove swapfile and zram configuration
  --status            Show current swap/zram status and exit
  -h, --help          Show this help

RAM Templates:
  --ram 1   1 GB RAM: swapfile 768MB, zram 100%, swappiness 100
  --ram 2   2 GB RAM: swapfile 1024MB, zram 75%, swappiness 100
  --ram 3   3 GB RAM: swapfile 1024MB, zram 60%, swappiness 80
  --ram 4   4 GB RAM: swapfile 1536MB, zram 50%, swappiness 80

Examples:
  sudo bash swap-setup.sh --ram 1
  sudo bash swap-setup.sh --ram 2 --zram-algo lz4
  sudo bash swap-setup.sh --swapfile-size 512 --zram-percent 80 --swappiness 100
  sudo bash swap-setup.sh --status
  sudo bash swap-setup.sh --remove
USAGE
    exit 0
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

get_total_ram_mb() {
    awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo
}

# ── RAM templates ────────────────────────────────────────────────────────────
apply_template() {
    local ram_gb="$1"
    case "$ram_gb" in
        1)
            SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB:-768}"
            ZRAM_PERCENT="${ZRAM_PERCENT:-100}"
            SWAPPINESS="${SWAPPINESS:-100}"
            ;;
        2)
            SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB:-1024}"
            ZRAM_PERCENT="${ZRAM_PERCENT:-75}"
            SWAPPINESS="${SWAPPINESS:-100}"
            ;;
        3)
            SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB:-1024}"
            ZRAM_PERCENT="${ZRAM_PERCENT:-60}"
            SWAPPINESS="${SWAPPINESS:-80}"
            ;;
        4)
            SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB:-1536}"
            ZRAM_PERCENT="${ZRAM_PERCENT:-50}"
            SWAPPINESS="${SWAPPINESS:-80}"
            ;;
        *)
            log_error "Unsupported RAM template: $ram_gb (use 1, 2, 3 or 4)"
            exit 1
            ;;
    esac
}

auto_detect_template() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)
    if   (( ram_mb <= 1280 )); then apply_template 1
    elif (( ram_mb <= 2304 )); then apply_template 2
    elif (( ram_mb <= 3328 )); then apply_template 3
    else                            apply_template 4
    fi
}

# ── Swap checks ──────────────────────────────────────────────────────────────

check_existing_swap() {
    log_section "Checking existing swap configuration"

    local has_conflict=false

    # Check active swap devices
    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        log_warn "Active swap devices found:"
        swapon --show
        echo ""

        # Check if our target swapfile is already active
        if swapon --show --noheadings 2>/dev/null | grep -q "$SWAPFILE_PATH"; then
            log_warn "$SWAPFILE_PATH is already active as swap"
            has_conflict=true
        fi
    else
        log_info "No active swap devices found"
    fi

    # Check if swapfile already exists on disk
    if [[ -f "$SWAPFILE_PATH" ]]; then
        local existing_size
        existing_size=$(du -m "$SWAPFILE_PATH" 2>/dev/null | awk '{print $1}')
        log_warn "$SWAPFILE_PATH already exists (${existing_size}MB)"
        has_conflict=true
    fi

    # Check fstab for existing swap entries
    if grep -q "^[^#].*swap" /etc/fstab 2>/dev/null; then
        log_warn "Existing swap entries in /etc/fstab:"
        grep "swap" /etc/fstab | grep -v "^#"
        has_conflict=true
    fi

    # Check if zram is already configured
    if [[ -f /etc/default/zramswap ]]; then
        log_warn "zramswap config already exists at /etc/default/zramswap"
        has_conflict=true
    fi

    if [[ "$has_conflict" == true ]]; then
        echo ""
        log_warn "Existing swap configuration detected!"
        if [[ "$AUTO_YES" != true ]]; then
            echo -e "${YELLOW}The script will:${NC}"
            echo "  - Deactivate and recreate $SWAPFILE_PATH if it exists"
            echo "  - Update /etc/fstab (remove old swap entries, add new one)"
            echo "  - Overwrite /etc/default/zramswap"
            echo ""
            read -rp "Continue? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_info "Aborted by user"
                exit 0
            fi
        else
            log_info "Auto-confirm enabled (--yes), proceeding..."
        fi
    else
        log_info "No conflicts found, proceeding with setup"
    fi
}

# ── Setup functions ──────────────────────────────────────────────────────────

setup_swapfile() {
    log_section "Setting up swap file ($SWAPFILE_SIZE_MB MB)"

    # Deactivate existing swapfile if active
    if swapon --show --noheadings 2>/dev/null | grep -q "$SWAPFILE_PATH"; then
        log_info "Deactivating existing $SWAPFILE_PATH..."
        swapoff "$SWAPFILE_PATH" 2>/dev/null || true
    fi

    # Create swap file
    log_info "Creating ${SWAPFILE_SIZE_MB}MB swap file at $SWAPFILE_PATH..."
    dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count="$SWAPFILE_SIZE_MB" status=progress 2>&1

    # Set permissions
    chmod 600 "$SWAPFILE_PATH"
    log_info "Permissions set to 600"

    # Format as swap
    mkswap "$SWAPFILE_PATH"
    log_info "Formatted as swap"

    # Activate with priority
    swapon -p "$SWAP_PRIORITY" "$SWAPFILE_PATH"
    log_info "Activated with priority $SWAP_PRIORITY"

    # Update /etc/fstab
    update_fstab
}

update_fstab() {
    log_info "Updating /etc/fstab..."

    # Remove any existing swap entries for our swapfile
    if grep -q "$SWAPFILE_PATH" /etc/fstab 2>/dev/null; then
        sed -i "\|$SWAPFILE_PATH|d" /etc/fstab
        log_info "Removed old $SWAPFILE_PATH entries from /etc/fstab"
    fi

    # Add new entry
    echo "$SWAPFILE_PATH none swap sw,pri=$SWAP_PRIORITY 0 0" >> /etc/fstab
    log_info "Added: $SWAPFILE_PATH none swap sw,pri=$SWAP_PRIORITY 0 0"
}

setup_zram() {
    log_section "Setting up zram (${ZRAM_PERCENT}% of RAM, algo=${ZRAM_ALGO})"

    # Install zram-tools if not present
    if ! dpkg -l zram-tools 2>/dev/null | grep -q "^ii"; then
        log_info "Installing zram-tools..."
        apt-get update -qq
        apt-get install -y -qq zram-tools
        log_info "zram-tools installed"
    else
        log_info "zram-tools already installed"
    fi

    # Write zramswap config
    log_info "Writing /etc/default/zramswap..."
    cat > /etc/default/zramswap <<EOF
# Configured by swap-setup.sh
# Algorithm: zstd (best balance of speed and compression ratio)
ALGO=${ZRAM_ALGO}

# Percentage of RAM to use for zram
PERCENT=${ZRAM_PERCENT}

# Priority (higher = used first; disk swap should be lower)
PRIORITY=${ZRAM_PRIORITY}
EOF
    log_info "zramswap config written"

    # Restart zramswap service
    log_info "Restarting zramswap service..."
    systemctl restart zramswap
    log_info "zramswap service restarted"
}

setup_swappiness() {
    log_section "Setting vm.swappiness to $SWAPPINESS"

    sysctl vm.swappiness="$SWAPPINESS"

    # Persist across reboots
    local sysctl_file="/etc/sysctl.d/99-swappiness.conf"
    echo "vm.swappiness=$SWAPPINESS" > "$sysctl_file"
    log_info "Saved to $sysctl_file"
}

# ── Status / verification ────────────────────────────────────────────────────

show_status() {
    log_section "zramctl"
    zramctl 2>/dev/null || echo "  (no zram devices found)"

    log_section "swapon --show"
    swapon --show 2>/dev/null || echo "  (no swap devices active)"

    log_section "zramctl --output-all"
    zramctl --output-all 2>/dev/null || echo "  (no zram devices found)"

    log_section "free -h"
    free -h

    echo ""
    local swappiness
    swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")
    log_info "Current vm.swappiness = $swappiness"
}

# ── Remove ───────────────────────────────────────────────────────────────────

remove_swap() {
    log_section "Removing swap configuration"

    if [[ "$AUTO_YES" != true ]]; then
        echo -e "${YELLOW}This will:${NC}"
        echo "  - Deactivate and delete $SWAPFILE_PATH"
        echo "  - Remove swap entry from /etc/fstab"
        echo "  - Stop zramswap service"
        echo "  - Remove /etc/sysctl.d/99-swappiness.conf"
        echo ""
        read -rp "Continue? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Aborted by user"
            exit 0
        fi
    fi

    # Deactivate swapfile
    if swapon --show --noheadings 2>/dev/null | grep -q "$SWAPFILE_PATH"; then
        swapoff "$SWAPFILE_PATH" 2>/dev/null || true
        log_info "Deactivated $SWAPFILE_PATH"
    fi

    # Remove swapfile
    if [[ -f "$SWAPFILE_PATH" ]]; then
        rm -f "$SWAPFILE_PATH"
        log_info "Removed $SWAPFILE_PATH"
    fi

    # Clean fstab
    if grep -q "$SWAPFILE_PATH" /etc/fstab 2>/dev/null; then
        sed -i "\|$SWAPFILE_PATH|d" /etc/fstab
        log_info "Removed swap entry from /etc/fstab"
    fi

    # Stop zramswap
    if systemctl is-active --quiet zramswap 2>/dev/null; then
        systemctl stop zramswap
        log_info "Stopped zramswap service"
    fi

    # Remove swappiness config
    if [[ -f /etc/sysctl.d/99-swappiness.conf ]]; then
        rm -f /etc/sysctl.d/99-swappiness.conf
        sysctl vm.swappiness=60 2>/dev/null || true
        log_info "Removed swappiness config, reset to default (60)"
    fi

    log_info "Swap configuration removed"
    echo ""
    show_status
}

# ── Summary before install ───────────────────────────────────────────────────

show_plan() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)
    local zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))

    log_section "Installation plan"
    echo -e "  System RAM:        ${BOLD}${ram_mb} MB${NC}"
    echo -e "  Swap file:         ${BOLD}${SWAPFILE_SIZE_MB} MB${NC} at ${SWAPFILE_PATH} (priority ${SWAP_PRIORITY})"
    echo -e "  zram size:         ${BOLD}~${zram_size_mb} MB${NC} (${ZRAM_PERCENT}% of RAM)"
    echo -e "  zram algorithm:    ${BOLD}${ZRAM_ALGO}${NC}"
    echo -e "  zram priority:     ${BOLD}${ZRAM_PRIORITY}${NC}"
    echo -e "  vm.swappiness:     ${BOLD}${SWAPPINESS}${NC}"
    echo ""

    if [[ "$AUTO_YES" != true ]]; then
        read -rp "Proceed with installation? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Aborted by user"
            exit 0
        fi
    fi
}

# ── Parse arguments ──────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ram)
                RAM_TEMPLATE="$2"; shift 2 ;;
            --swapfile-size)
                SWAPFILE_SIZE_MB="$2"; shift 2 ;;
            --zram-percent)
                ZRAM_PERCENT="$2"; shift 2 ;;
            --zram-algo)
                ZRAM_ALGO="$2"; shift 2 ;;
            --zram-priority)
                ZRAM_PRIORITY="$2"; shift 2 ;;
            --swappiness)
                SWAPPINESS="$2"; shift 2 ;;
            --yes)
                AUTO_YES=true; shift ;;
            --remove)
                ACTION="remove"; shift ;;
            --status)
                ACTION="status"; shift ;;
            -h|--help)
                usage ;;
            *)
                log_error "Unknown option: $1"
                usage ;;
        esac
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    check_root

    case "$ACTION" in
        status)
            show_status
            exit 0
            ;;
        remove)
            remove_swap
            exit 0
            ;;
    esac

    # Apply template or auto-detect
    if [[ -n "$RAM_TEMPLATE" ]]; then
        apply_template "$RAM_TEMPLATE"
    else
        # If no template and no manual values — auto-detect
        if [[ -z "$SWAPFILE_SIZE_MB" && -z "$ZRAM_PERCENT" && -z "$SWAPPINESS" ]]; then
            log_info "No template specified, auto-detecting based on system RAM..."
            auto_detect_template
        else
            # Fill in any missing values with defaults
            SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB:-1024}"
            ZRAM_PERCENT="${ZRAM_PERCENT:-50}"
            SWAPPINESS="${SWAPPINESS:-80}"
        fi
    fi

    check_existing_swap
    show_plan
    setup_swapfile
    setup_zram
    setup_swappiness

    # Reload systemd to pick up fstab changes
    systemctl daemon-reload 2>/dev/null || true

    log_section "Setup complete! Verification:"
    show_status
}

main "$@"
