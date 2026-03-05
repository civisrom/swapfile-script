#!/bin/bash
#
# swap-setup.sh — Automated hybrid swap (swapfile + zram) setup for Debian/Ubuntu VPS
# Supports RAM templates: 512MB, 1GB, 2GB, 3GB, 4GB, interactive wizard, and CLI flags
#
# Usage:
#   sudo bash swap-setup.sh                  # interactive wizard
#   sudo bash swap-setup.sh --ram 1          # use template for 1GB RAM
#   sudo bash swap-setup.sh --ram 1 --yes    # non-interactive with template
#   sudo bash swap-setup.sh --status         # show current swap info
#   sudo bash swap-setup.sh --remove         # remove swap configuration
#
set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Defaults ─────────────────────────────────────────────────────────────────
SWAPFILE_PATH="/swapfile"
SWAPFILE_SIZE_MB=""
ZRAM_ALGO=""
ZRAM_PERCENT=""
ZRAM_PRIORITY=""
SWAP_PRIORITY=-2
SWAPPINESS=""
RAM_TEMPLATE=""
AUTO_YES=false
INTERACTIVE=false
ACTION="install"

# ── Functions ────────────────────────────────────────────────────────────────

usage() {
    cat <<'USAGE'
Usage: sudo bash swap-setup.sh [OPTIONS]

Without options the script starts an interactive wizard.

Options:
  --ram N             Use preset template for N GB RAM (0.5, 1, 2, 3, 4, 6, 8)
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
  --ram 0.5   512 MB RAM: swapfile 1024MB, zram 100%, swappiness 100
  --ram 1     1 GB RAM:   swapfile 512MB,  zram 100%, swappiness 100
  --ram 2     2 GB RAM:   swapfile 1024MB, zram 75%,  swappiness 100
  --ram 3     3 GB RAM:   swapfile 1024MB, zram 60%,  swappiness 80
  --ram 4     4 GB RAM:   swapfile 1536MB, zram 50%,  swappiness 80
  --ram 6     6 GB RAM:   swapfile 2048MB, zram 40%,  swappiness 60
  --ram 8     8 GB RAM:   swapfile 2048MB, zram 25%,  swappiness 60

Examples:
  sudo bash swap-setup.sh                     # interactive wizard
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

VALID_ZRAM_ALGOS="zstd lz4 lzo lzo-rle lz4hc zlib 842"

validate_positive_int() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value <= 0 )); then
        log_error "$name must be a positive integer, got: '$value'"
        exit 1
    fi
}

validate_zram_algo() {
    local algo="$1"
    local valid
    for valid in $VALID_ZRAM_ALGOS; do
        [[ "$algo" == "$valid" ]] && return 0
    done
    log_error "Invalid zram algorithm: '$algo'. Valid: $VALID_ZRAM_ALGOS"
    exit 1
}

validate_all_params() {
    validate_positive_int "swapfile-size" "$SWAPFILE_SIZE_MB"
    validate_positive_int "zram-percent" "$ZRAM_PERCENT"
    validate_positive_int "zram-priority" "$ZRAM_PRIORITY"
    validate_zram_algo "$ZRAM_ALGO"
    if ! [[ "$SWAPPINESS" =~ ^[0-9]+$ ]] || (( SWAPPINESS > 200 )); then
        log_error "swappiness must be 0-200, got: '$SWAPPINESS'"
        exit 1
    fi
    if (( ZRAM_PERCENT > 300 )); then
        log_warn "zram-percent $ZRAM_PERCENT% is unusually high (>300%), are you sure?"
    fi
    if (( ZRAM_PRIORITY > 32767 )); then
        log_error "zram-priority must be 0-32767, got: $ZRAM_PRIORITY"
        exit 1
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

get_total_ram_mb() {
    awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo
}

get_total_ram_gb_label() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)
    if   (( ram_mb <= 768  )); then echo "< 1 GB"
    elif (( ram_mb <= 1280 )); then echo "~1 GB"
    elif (( ram_mb <= 2304 )); then echo "~2 GB"
    elif (( ram_mb <= 3328 )); then echo "~3 GB"
    elif (( ram_mb <= 4500 )); then echo "~4 GB"
    elif (( ram_mb <= 6500 )); then echo "~6 GB"
    elif (( ram_mb <= 8500 )); then echo "~8 GB"
    else                            echo "$((ram_mb / 1024)) GB"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${PRETTY_NAME:-${NAME:-Linux} ${VERSION_ID:-}}"
    else
        echo "Linux (unknown distro)"
    fi
}

# ── System info banner ───────────────────────────────────────────────────────

show_system_info() {
    local ram_mb ram_label os_name cpu_model
    ram_mb=$(get_total_ram_mb)
    ram_label=$(get_total_ram_gb_label)
    os_name=$(detect_os)
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "unknown")

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}swap-setup.sh${NC} — Hybrid Swap + Zram for VPS         ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  OS:    ${BOLD}${os_name}${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  CPU:   ${cpu_model}"
    echo -e "${BOLD}${CYAN}║${NC}  RAM:   ${BOLD}${YELLOW}${ram_mb} MB${NC} (${ram_label})"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
}

# ── RAM templates ────────────────────────────────────────────────────────────

# Returns template values: swapfile_mb zram_percent swappiness
get_template_values() {
    local ram_gb="$1"
    case "$ram_gb" in
        0.5) echo "1024 100 100" ;;
        1)   echo "512 100 100"  ;;
        2)   echo "1024 75 100"  ;;
        3)   echo "1024 60 80"   ;;
        4)   echo "1536 50 80"   ;;
        6)   echo "2048 40 60"   ;;
        8)   echo "2048 25 60"   ;;
        *)   echo "" ;;
    esac
}

apply_template() {
    local ram_gb="$1"
    local vals
    vals=$(get_template_values "$ram_gb")
    if [[ -z "$vals" ]]; then
        log_error "Unsupported RAM template: $ram_gb (use 0.5, 1, 2, 3, 4, 6 or 8)"
        exit 1
    fi
    local t_swap t_percent t_swappiness
    read -r t_swap t_percent t_swappiness <<< "$vals"

    SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB:-$t_swap}"
    ZRAM_PERCENT="${ZRAM_PERCENT:-$t_percent}"
    ZRAM_ALGO="${ZRAM_ALGO:-zstd}"
    ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"
    SWAPPINESS="${SWAPPINESS:-$t_swappiness}"
}

auto_detect_template() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)
    if   (( ram_mb <= 640  )); then apply_template 0.5
    elif (( ram_mb <= 1280 )); then apply_template 1
    elif (( ram_mb <= 2304 )); then apply_template 2
    elif (( ram_mb <= 3328 )); then apply_template 3
    elif (( ram_mb <= 4500 )); then apply_template 4
    elif (( ram_mb <= 6500 )); then apply_template 6
    else                            apply_template 8
    fi
}

# ── Interactive wizard ───────────────────────────────────────────────────────

print_templates_table() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)

    echo ""
    echo -e "${BOLD}  Available templates:${NC}"
    echo ""
    echo -e "  ${DIM}┌──────┬────────┬──────────────┬───────────┬───────┬──────────┬────────────┐${NC}"
    echo -e "  ${DIM}│${NC} ${BOLD}  #  ${NC}${DIM}│${NC} ${BOLD} RAM  ${NC}${DIM}│${NC} ${BOLD}  Swapfile   ${NC}${DIM}│${NC} ${BOLD} zram %   ${NC}${DIM}│${NC} ${BOLD}ALGO ${NC}${DIM}│${NC} ${BOLD}PRIORITY ${NC}${DIM}│${NC} ${BOLD}swappiness ${NC}${DIM}│${NC}"
    echo -e "  ${DIM}├──────┼────────┼──────────────┼───────────┼───────┼──────────┼────────────┤${NC}"

    local recommended=""
    if   (( ram_mb <= 640  )); then recommended=0.5
    elif (( ram_mb <= 1280 )); then recommended=1
    elif (( ram_mb <= 2304 )); then recommended=2
    elif (( ram_mb <= 3328 )); then recommended=3
    elif (( ram_mb <= 4500 )); then recommended=4
    elif (( ram_mb <= 6500 )); then recommended=6
    else                            recommended=8
    fi

    for tpl in 0.5 1 2 3 4 6 8; do
        local vals t_swap t_pct t_swp t_ram
        vals=$(get_template_values "$tpl")
        read -r t_swap t_pct t_swp <<< "$vals"
        case "$tpl" in
            0.5) t_ram="512MB" ;;
            *)   t_ram="${tpl} GB"  ;;
        esac
        local marker=""
        if [[ "$tpl" == "$recommended" ]]; then
            marker=" ${GREEN}<< recommended${NC}"
        fi
        printf "  ${DIM}│${NC} %-3s  ${DIM}│${NC} %-5s ${DIM}│${NC} %4s MB      ${DIM}│${NC}   %3s%%    ${DIM}│${NC} zstd  ${DIM}│${NC}   100    ${DIM}│${NC}    %3s     ${DIM}│${NC}%b\n" \
            "$tpl" "$t_ram" "$t_swap" "$t_pct" "$t_swp" "$marker"
    done

    echo -e "  ${DIM}├──────┼────────┼──────────────┼───────────┼───────┼──────────┼────────────┤${NC}"
    echo -e "  ${DIM}│${NC}  ${MAGENTA}9${NC}   ${DIM}│${NC} ${MAGENTA}Manual input — set each parameter yourself${NC}                              ${DIM}│${NC}"
    echo -e "  ${DIM}└──────┴────────┴──────────────┴───────────┴───────┴──────────┴────────────┘${NC}"
    echo ""
}

# Read a value with default and hint
# Usage: ask_value "prompt" "default" "hint"
ask_value() {
    local prompt="$1"
    local default="$2"
    local hint="$3"
    local result

    echo -e "  ${DIM}${hint}${NC}" >&2
    read -rp "$(echo -e "  ${BOLD}${prompt}${NC} [${GREEN}${default}${NC}]: ")" result
    result="${result:-$default}"
    echo "$result"
}

interactive_wizard() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)

    show_system_info
    print_templates_table

    local choice
    read -rp "$(echo -e "  ${BOLD}Select template (0.5, 1-8, or 9 for manual):${NC} ")" choice
    echo ""

    case "$choice" in
        0.5|1|2|3|4|6|8)
            apply_template "$choice"
            log_info "Template $choice applied"

            echo ""
            echo -e "  ${YELLOW}Want to adjust individual parameters?${NC}"
            read -rp "$(echo -e "  ${BOLD}Edit parameters? [y/N]:${NC} ")" edit_confirm
            if [[ "$edit_confirm" =~ ^[Yy]$ ]]; then
                interactive_edit_params
            fi
            ;;
        9)
            log_info "Manual configuration selected"
            echo ""
            interactive_manual_input
            ;;
        *)
            log_error "Invalid choice: $choice"
            exit 1
            ;;
    esac
}

interactive_manual_input() {
    local ram_mb zram_size_mb
    ram_mb=$(get_total_ram_mb)

    echo -e "  ${BOLD}${CYAN}Enter parameters for your VPS (RAM: ${ram_mb} MB):${NC}"
    echo ""

    # ── Swapfile size ────────────────────────────────────────────────────────
    echo -e "  ${BOLD}1. Swap file size (MB)${NC}"
    SWAPFILE_SIZE_MB=$(ask_value "   Swapfile size MB" "1024" \
        "   Recommended: 1024 for 512MB, 512 for 1GB, 1024 for 2GB, 1024-1536 for 3-4GB")
    echo ""

    # ── ALGO ─────────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}2. Compression algorithm (ALGO)${NC}"
    echo -e "  ${DIM}   Available: ${NC}${GREEN}zstd${NC}${DIM} | lz4 | lzo | lzo-rle | lz4hc | zlib | 842${NC}"
    echo -e "  ${DIM}   zstd  — best compression ratio (~3:1), moderate CPU (recommended 2025-2026)${NC}"
    echo -e "  ${DIM}   lz4   — fastest, lower compression (~2:1), good for weak CPU${NC}"
    echo -e "  ${DIM}   lzo   — legacy, balanced${NC}"
    ZRAM_ALGO=$(ask_value "   ALGO" "zstd" "")
    echo ""

    # ── PERCENT ──────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}3. zram size as % of RAM (PERCENT)${NC}"
    zram_size_mb=$(( ram_mb * 75 / 100 ))
    echo -e "  ${DIM}   With PERCENT=75 on your ${ram_mb}MB RAM -> zram ~${zram_size_mb} MB${NC}"
    ZRAM_PERCENT=$(ask_value "   PERCENT" "75" \
        "   Range: 25-200. Recommended: 100 for 1GB, 75 for 2GB, 50-60 for 3-4GB")
    echo ""

    # show calculated zram size
    zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
    echo -e "  ${DIM}   -> zram will be ~${zram_size_mb} MB (${ZRAM_PERCENT}% of ${ram_mb} MB)${NC}"
    echo ""

    # ── PRIORITY ─────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}4. zram swap priority (PRIORITY)${NC}"
    ZRAM_PRIORITY=$(ask_value "   PRIORITY" "100" \
        "   Higher = used first. Disk swap has priority ${SWAP_PRIORITY}. Range: 0-32767")
    echo ""

    # ── swappiness ───────────────────────────────────────────────────────────
    echo -e "  ${BOLD}5. vm.swappiness${NC}"
    SWAPPINESS=$(ask_value "   swappiness" "100" \
        "   How eagerly kernel uses swap. Range: 0-200. For zram: 80-150 recommended")
    echo ""
}

interactive_edit_params() {
    local ram_mb zram_size_mb
    ram_mb=$(get_total_ram_mb)

    echo ""
    echo -e "  ${BOLD}${CYAN}Current values (press Enter to keep):${NC}"
    echo ""

    # ── Swapfile size ────────────────────────────────────────────────────────
    echo -e "  ${BOLD}1. Swap file size${NC}"
    SWAPFILE_SIZE_MB=$(ask_value "   Swapfile size MB" "$SWAPFILE_SIZE_MB" \
        "   Recommended: 1024 for 512MB, 512 for 1GB, 1024 for 2GB, 1024-1536 for 3-4GB")
    echo ""

    # ── ALGO ─────────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}2. Compression algorithm (ALGO)${NC}"
    echo -e "  ${DIM}   Available: ${NC}${GREEN}zstd${NC}${DIM} | lz4 | lzo | lzo-rle | lz4hc | zlib | 842${NC}"
    ZRAM_ALGO=$(ask_value "   ALGO" "$ZRAM_ALGO" \
        "   zstd=best ratio, lz4=fastest, lzo=legacy balanced")
    echo ""

    # ── PERCENT ──────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}3. zram size (PERCENT of RAM)${NC}"
    zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
    echo -e "  ${DIM}   Currently ${ZRAM_PERCENT}% = ~${zram_size_mb} MB on your ${ram_mb} MB RAM${NC}"
    ZRAM_PERCENT=$(ask_value "   PERCENT" "$ZRAM_PERCENT" \
        "   Range: 25-200. Higher = more virtual swap via compression")
    echo ""

    zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
    echo -e "  ${DIM}   -> zram will be ~${zram_size_mb} MB${NC}"
    echo ""

    # ── PRIORITY ─────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}4. zram priority (PRIORITY)${NC}"
    ZRAM_PRIORITY=$(ask_value "   PRIORITY" "$ZRAM_PRIORITY" \
        "   Higher = used first. Disk swap has priority ${SWAP_PRIORITY}")
    echo ""

    # ── swappiness ───────────────────────────────────────────────────────────
    echo -e "  ${BOLD}5. vm.swappiness${NC}"
    SWAPPINESS=$(ask_value "   swappiness" "$SWAPPINESS" \
        "   Range: 0-200. With zram recommended: 80-150")
    echo ""
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

    # Check fstab for existing swap entries (match 'swap' in the fs type field)
    if grep -v '^\s*#' /etc/fstab 2>/dev/null | awk '$3 == "swap"' | grep -q .; then
        log_warn "Existing swap entries in /etc/fstab:"
        grep -v '^\s*#' /etc/fstab | awk '$3 == "swap"'
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

check_disk_space() {
    local target_dir
    target_dir=$(dirname "$SWAPFILE_PATH")
    local available_mb
    available_mb=$(df -BM --output=avail "$target_dir" 2>/dev/null | tail -1 | tr -d ' M')
    if [[ -n "$available_mb" ]] && (( available_mb < SWAPFILE_SIZE_MB + 100 )); then
        log_error "Not enough disk space: need ${SWAPFILE_SIZE_MB}MB + 100MB margin, only ${available_mb}MB available on $target_dir"
        exit 1
    fi
    log_info "Disk space check passed: ${available_mb}MB available, need ${SWAPFILE_SIZE_MB}MB"
}

check_filesystem_type() {
    local target_dir fs_type
    target_dir=$(dirname "$SWAPFILE_PATH")
    fs_type=$(df -T "$target_dir" 2>/dev/null | awk 'NR==2 {print $2}')
    case "$fs_type" in
        btrfs)
            log_warn "Filesystem is btrfs — swapfile requires 'chattr +C' (no copy-on-write)"
            log_warn "The script will attempt this automatically"
            BTRFS_SWAP=true
            ;;
        zfs)
            log_error "ZFS does not support swap files. Use a dedicated zvol instead."
            exit 1
            ;;
        *)
            log_info "Filesystem: $fs_type (OK for swapfile)"
            ;;
    esac
}

setup_swapfile() {
    log_section "Setting up swap file ($SWAPFILE_SIZE_MB MB)"

    check_disk_space
    check_filesystem_type

    # Deactivate existing swapfile if active
    if swapon --show --noheadings 2>/dev/null | grep -q "$SWAPFILE_PATH"; then
        log_info "Deactivating existing $SWAPFILE_PATH..."
        swapoff "$SWAPFILE_PATH" 2>/dev/null || true
    fi

    # Create swap file — prefer fallocate (faster), fallback to dd
    log_info "Creating ${SWAPFILE_SIZE_MB}MB swap file at $SWAPFILE_PATH..."
    if [[ "${BTRFS_SWAP:-}" == true ]]; then
        # btrfs requires dd, not fallocate
        truncate -s 0 "$SWAPFILE_PATH"
        chattr +C "$SWAPFILE_PATH" 2>/dev/null || true
        dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count="$SWAPFILE_SIZE_MB" status=progress 2>&1
    elif fallocate -l "${SWAPFILE_SIZE_MB}M" "$SWAPFILE_PATH" 2>/dev/null; then
        log_info "Created via fallocate (fast)"
    else
        log_info "fallocate failed, falling back to dd..."
        dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count="$SWAPFILE_SIZE_MB" status=progress 2>&1
    fi

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

    # Backup fstab before modifying
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
    log_info "Backed up /etc/fstab"

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
    log_section "Setting up zram (${ZRAM_PERCENT}% of RAM, algo=${ZRAM_ALGO}, priority=${ZRAM_PRIORITY})"

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
# Compression algorithm: ${ZRAM_ALGO}
# Available: zstd | lz4 | lzo | lzo-rle | lz4hc | zlib | 842
ALGO=${ZRAM_ALGO}

# Percentage of RAM to use for zram (e.g. 100 = same as RAM size)
PERCENT=${ZRAM_PERCENT}

# Swap priority (higher = used first; disk swap typically has priority ${SWAP_PRIORITY})
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
    log_info "Saved to $sysctl_file (persistent after reboot)"
}

# ── Status / verification ────────────────────────────────────────────────────

show_status() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)

    log_section "System: $(detect_os), RAM: ${ram_mb} MB ($(get_total_ram_gb_label))"

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

    # Remove zramswap config
    if [[ -f /etc/default/zramswap ]]; then
        rm -f /etc/default/zramswap
        log_info "Removed /etc/default/zramswap"
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
    local ram_mb zram_size_mb
    ram_mb=$(get_total_ram_mb)
    zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))

    log_section "Installation plan"
    echo ""
    echo -e "  ${DIM}┌─────────────────────┬─────────────────────────────────────┐${NC}"
    echo -e "  ${DIM}│${NC} System RAM          ${DIM}│${NC} ${BOLD}${YELLOW}${ram_mb} MB${NC} ($(get_total_ram_gb_label))                     ${DIM}│${NC}"
    echo -e "  ${DIM}├─────────────────────┼─────────────────────────────────────┤${NC}"
    echo -e "  ${DIM}│${NC} Swap file           ${DIM}│${NC} ${BOLD}${SWAPFILE_SIZE_MB} MB${NC} at ${SWAPFILE_PATH} (pri ${SWAP_PRIORITY})     ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC} zram ALGO           ${DIM}│${NC} ${BOLD}${ZRAM_ALGO}${NC}                                ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC} zram PERCENT        ${DIM}│${NC} ${BOLD}${ZRAM_PERCENT}%${NC} (~${zram_size_mb} MB)                       ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC} zram PRIORITY       ${DIM}│${NC} ${BOLD}${ZRAM_PRIORITY}${NC}                                 ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC} vm.swappiness       ${DIM}│${NC} ${BOLD}${SWAPPINESS}${NC}                                 ${DIM}│${NC}"
    echo -e "  ${DIM}└─────────────────────┴─────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${DIM}Swap priority: zram (${ZRAM_PRIORITY}) >> disk swap (${SWAP_PRIORITY})${NC}"
    echo -e "  ${DIM}Effective zram capacity after compression (~3:1): ~$((zram_size_mb * 3)) MB${NC}"
    echo ""

    if [[ "$AUTO_YES" != true ]]; then
        read -rp "$(echo -e "  ${BOLD}Proceed with installation? [y/N]:${NC} ")" confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Aborted by user"
            exit 0
        fi
    fi
}

# ── Parse arguments ──────────────────────────────────────────────────────────

require_arg() {
    if [[ $# -lt 2 || "$2" == --* ]]; then
        log_error "Option $1 requires an argument"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ram)
                require_arg "$@"
                RAM_TEMPLATE="$2"; shift 2 ;;
            --swapfile-size)
                require_arg "$@"
                SWAPFILE_SIZE_MB="$2"; shift 2 ;;
            --zram-percent)
                require_arg "$@"
                ZRAM_PERCENT="$2"; shift 2 ;;
            --zram-algo)
                require_arg "$@"
                ZRAM_ALGO="$2"; shift 2 ;;
            --zram-priority)
                require_arg "$@"
                ZRAM_PRIORITY="$2"; shift 2 ;;
            --swappiness)
                require_arg "$@"
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

    # Determine if we should run interactive wizard:
    # No template, no manual values, no --yes flag
    if [[ "$ACTION" == "install" && -z "$RAM_TEMPLATE" && -z "$SWAPFILE_SIZE_MB" \
        && -z "$ZRAM_PERCENT" && -z "$SWAPPINESS" && "$AUTO_YES" != true ]]; then
        INTERACTIVE=true
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    check_root

    case "$ACTION" in
        status)
            show_system_info
            show_status
            exit 0
            ;;
        remove)
            show_system_info
            remove_swap
            exit 0
            ;;
    esac

    # Decide configuration path
    if [[ "$INTERACTIVE" == true ]]; then
        # Full interactive wizard
        interactive_wizard
    elif [[ -n "$RAM_TEMPLATE" ]]; then
        # Template from CLI args
        show_system_info
        apply_template "$RAM_TEMPLATE"
        log_info "Template $RAM_TEMPLATE applied"
    else
        # Auto-detect or use provided values
        show_system_info
        if [[ -z "$SWAPFILE_SIZE_MB" && -z "$ZRAM_PERCENT" && -z "$SWAPPINESS" ]]; then
            log_info "No template specified, auto-detecting based on system RAM..."
            auto_detect_template
        else
            SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB:-1024}"
            ZRAM_ALGO="${ZRAM_ALGO:-zstd}"
            ZRAM_PERCENT="${ZRAM_PERCENT:-50}"
            ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"
            SWAPPINESS="${SWAPPINESS:-80}"
        fi
    fi

    # Ensure all values are set (fallback for any empty)
    ZRAM_ALGO="${ZRAM_ALGO:-zstd}"
    ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"

    # Validate all parameters before proceeding
    validate_all_params

    check_existing_swap
    show_plan
    setup_swapfile
    setup_zram
    setup_swappiness

    # Reload systemd to pick up fstab changes
    systemctl daemon-reload 2>/dev/null || true

    log_section "Setup complete! Verification:"
    show_status

    echo ""
    echo -e "${BOLD}${GREEN}Done!${NC} Hybrid swap is configured and active."
    echo -e "${DIM}To check status later: sudo bash swap-setup.sh --status${NC}"
    echo -e "${DIM}To remove:             sudo bash swap-setup.sh --remove${NC}"
}

main "$@"
