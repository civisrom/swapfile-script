#!/bin/bash
#
# swap-setup.sh — Automated hybrid swap (swapfile + zram) setup for Debian/Ubuntu VPS
# Supports RAM templates: 512MB, 1GB, 2GB, 3GB, 4GB, 6GB, 8GB, interactive wizard, and CLI flags
#
# Usage:
#   sudo bash swap-setup.sh                  # interactive wizard with language selection
#   sudo bash swap-setup.sh --lang ru        # force Russian output
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
ZRAM_ALGO_EXPLICIT=false
SWAP_PRIORITY=-2
SWAPPINESS=""
RAM_TEMPLATE=""
AUTO_YES=false
INTERACTIVE=false
ACTION="install"
HAS_INSTALL_OPTIONS=false
COMPRESSION_RATIO_ESTIMATE=3
BTRFS_SWAP=false
ASK_VALUE_USED_DEFAULT=false
DEFAULT_LANG="en"
LANG_CODE=""

# ── Functions ────────────────────────────────────────────────────────────────

current_lang() {
    printf '%s' "${LANG_CODE:-$DEFAULT_LANG}"
}

msg() {
    local en="$1"
    local ru="$2"
    if [[ "$(current_lang)" == "ru" ]]; then
        printf '%s' "$ru"
    else
        printf '%s' "$en"
    fi
}

is_yes() {
    case "$1" in
        y|Y|yes|YES|Yes|д|Д|да|Да|ДА)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

yes_no_hint() {
    msg "y/N" "д/Н"
}

validate_language() {
    case "$1" in
        en|EN|ru|RU)
            ;;
        *)
            log_error "$(msg "Invalid language: '$1'. Use: en or ru" "Недопустимый язык: '$1'. Используйте en или ru")"
            exit 1
            ;;
    esac
}

select_language() {
    local choice

    echo ""
    echo -e "${BOLD}Select language / Выберите язык:${NC}"
    echo "  1) English"
    echo "  2) Русский"
    read -rp "Language [1/en, 2/ru; default: en]: " choice

    case "$choice" in
        ""|1|en|EN|Eng|eng|English|english)
            LANG_CODE="en"
            ;;
        2|ru|RU|Rus|rus|Russian|russian|рус|Рус|русский|Русский)
            LANG_CODE="ru"
            ;;
        *)
            LANG_CODE="en"
            log_warn "Unknown language '$choice', using English / Неизвестный язык '$choice', используется English"
            ;;
    esac
}

init_language() {
    if [[ -z "$LANG_CODE" && -t 0 && "$AUTO_YES" != true && "$ACTION" != "status" ]]; then
        select_language
    fi
    LANG_CODE="${LANG_CODE:-$DEFAULT_LANG}"
}

usage() {
    if [[ "$(current_lang)" == "ru" ]]; then
        cat <<'USAGE'
Использование: sudo bash swap-setup.sh [ОПЦИИ]

Без опций скрипт запускает интерактивный мастер.

Опции:
  --lang en|ru        Язык вывода (en или ru)
  --ram N             Шаблон для N ГБ RAM (0.5, 1, 2, 3, 4, 6, 8)
  --swapfile-size MB  Размер swap-файла в МБ (переопределяет шаблон)
  --zram-percent N    Размер zram как % от RAM (переопределяет шаблон)
  --zram-algo ALGO    Алгоритм сжатия zram (по умолчанию: zstd)
  --zram-priority N   Приоритет zram swap (по умолчанию: 100)
  --swappiness N      Значение vm.swappiness (переопределяет шаблон)
  --yes               Пропустить запросы подтверждения
  --remove            Удалить swapfile и конфигурацию zram
  --status            Показать текущий статус swap/zram и выйти
  -h, --help          Показать эту справку

Шаблоны RAM:
  --ram 0.5   512 МБ RAM: swapfile 1024MB, zram 100%, swappiness 100
  --ram 1     1 ГБ RAM:   swapfile 512MB,  zram 100%, swappiness 100
  --ram 2     2 ГБ RAM:   swapfile 1024MB, zram 75%,  swappiness 100
  --ram 3     3 ГБ RAM:   swapfile 1024MB, zram 60%,  swappiness 80
  --ram 4     4 ГБ RAM:   swapfile 1536MB, zram 50%,  swappiness 80
  --ram 6     6 ГБ RAM:   swapfile 2048MB, zram 40%,  swappiness 60
  --ram 8     8 ГБ RAM:   swapfile 2048MB, zram 25%,  swappiness 60

Примеры:
  sudo bash swap-setup.sh                     # интерактивный мастер с выбором языка
  sudo bash swap-setup.sh --lang ru --ram 1
  sudo bash swap-setup.sh --lang en --ram 2 --zram-algo lz4
  sudo bash swap-setup.sh --swapfile-size 512 --zram-percent 80 --swappiness 100
  sudo bash swap-setup.sh --lang ru --status
  sudo bash swap-setup.sh --lang ru --remove
USAGE
    else
    cat <<'USAGE'
Usage: sudo bash swap-setup.sh [OPTIONS]

Without options the script starts an interactive wizard.

Options:
  --lang en|ru        Output language (en or ru)
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
  sudo bash swap-setup.sh                     # interactive wizard with language selection
  sudo bash swap-setup.sh --lang ru --ram 1
  sudo bash swap-setup.sh --lang en --ram 2 --zram-algo lz4
  sudo bash swap-setup.sh --swapfile-size 512 --zram-percent 80 --swappiness 100
  sudo bash swap-setup.sh --lang ru --status
  sudo bash swap-setup.sh --lang ru --remove
USAGE
    fi
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
        log_error "$(msg "$name must be a positive integer, got: '$value'" "Параметр $name должен быть положительным целым числом, получено: '$value'")"
        exit 1
    fi
}

validate_nonnegative_int() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "$(msg "$name must be a non-negative integer, got: '$value'" "Параметр $name должен быть неотрицательным целым числом, получено: '$value'")"
        exit 1
    fi
}

validate_zram_algo() {
    local algo="$1"
    local valid
    for valid in $VALID_ZRAM_ALGOS; do
        [[ "$algo" == "$valid" ]] && return 0
    done
    log_error "$(msg "Invalid zram algorithm: '$algo'. Valid: $VALID_ZRAM_ALGOS" "Недопустимый алгоритм zram: '$algo'. Допустимые: $VALID_ZRAM_ALGOS")"
    exit 1
}

validate_zram_percent() {
    validate_positive_int "zram-percent" "$ZRAM_PERCENT"
    if (( ZRAM_PERCENT > 300 )); then
        log_error "$(msg "zram-percent must be 1-300, got: $ZRAM_PERCENT" "zram-percent должен быть в диапазоне 1-300, получено: $ZRAM_PERCENT")"
        exit 1
    fi
    if (( ZRAM_PERCENT > 200 )); then
        log_warn "$(msg "zram-percent $ZRAM_PERCENT% is unusually high (>200%)" "zram-percent $ZRAM_PERCENT% необычно высокий (>200%)")"
    fi
}

validate_zram_priority_value() {
    validate_nonnegative_int "zram-priority" "$ZRAM_PRIORITY"
    if (( ZRAM_PRIORITY > 32767 )); then
        log_error "$(msg "zram-priority must be 0-32767, got: $ZRAM_PRIORITY" "zram-priority должен быть в диапазоне 0-32767, получено: $ZRAM_PRIORITY")"
        exit 1
    fi
}

validate_swappiness_value() {
    if ! [[ "$SWAPPINESS" =~ ^[0-9]+$ ]] || (( SWAPPINESS > 200 )); then
        log_error "$(msg "swappiness must be 0-200, got: '$SWAPPINESS'" "swappiness должен быть в диапазоне 0-200, получено: '$SWAPPINESS'")"
        exit 1
    fi
}

validate_all_params() {
    validate_positive_int "swapfile-size" "$SWAPFILE_SIZE_MB"
    validate_zram_percent
    validate_zram_priority_value
    validate_zram_algo "$ZRAM_ALGO"
    validate_swappiness_value
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "$(msg "This script must be run as root (use sudo)" "Скрипт нужно запускать от root (используйте sudo)")"
        exit 1
    fi
}

require_commands() {
    local missing=() cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        log_error "$(msg "Missing required command(s): ${missing[*]}" "Не найдены обязательные команды: ${missing[*]}")"
        exit 1
    fi
}

preflight_checks() {
    log_section "$(msg "Preflight checks" "Предварительные проверки")"

    require_commands awk cat chmod chown cp date dd df dirname dpkg du free grep mktemp mkswap mv rm sed swapon swapoff sysctl tr xargs

    if ! command -v systemctl &>/dev/null; then
        log_error "$(msg "systemctl not found. This script manages zram through the zramswap systemd service." "systemctl не найден. Скрипт управляет zram через systemd-сервис zramswap.")"
        exit 1
    fi

    local target_dir
    target_dir=$(dirname "$SWAPFILE_PATH")
    if [[ ! -d "$target_dir" ]]; then
        log_error "$(msg "Swapfile directory does not exist: $target_dir" "Каталог для swap-файла не существует: $target_dir")"
        exit 1
    fi
    if [[ ! -f /etc/fstab || ! -r /etc/fstab || ! -w /etc/fstab ]]; then
        log_error "$(msg "/etc/fstab must exist and be readable/writable" "/etc/fstab должен существовать и быть доступен для чтения/записи")"
        exit 1
    fi
    if [[ ! -d /etc/default || ! -w /etc/default ]]; then
        log_error "$(msg "/etc/default must exist and be writable" "/etc/default должен существовать и быть доступен для записи")"
        exit 1
    fi
    if [[ ! -d /etc/sysctl.d || ! -w /etc/sysctl.d ]]; then
        log_error "$(msg "/etc/sysctl.d must exist and be writable" "/etc/sysctl.d должен существовать и быть доступен для записи")"
        exit 1
    fi
    if [[ -L "$SWAPFILE_PATH" ]]; then
        log_error "$(msg "$SWAPFILE_PATH is a symlink. Refusing to use it as a swap file." "$SWAPFILE_PATH является символической ссылкой. Отказываюсь использовать его как swap-файл.")"
        exit 1
    fi
    if [[ -e "$SWAPFILE_PATH" && ! -f "$SWAPFILE_PATH" ]]; then
        log_error "$(msg "$SWAPFILE_PATH exists but is not a regular file." "$SWAPFILE_PATH существует, но не является обычным файлом.")"
        exit 1
    fi

    log_info "$(msg "Required local commands and paths are available" "Обязательные локальные команды и пути доступны")"
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
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "${PRETTY_NAME:-${NAME:-Linux} ${VERSION_ID:-}}"
    else
        msg "Linux (unknown distro)" "Linux (неизвестный дистрибутив)"
    fi
}

# ── System info banner ───────────────────────────────────────────────────────

show_system_info() {
    local ram_mb ram_label os_name cpu_model
    ram_mb=$(get_total_ram_mb)
    ram_label=$(get_total_ram_gb_label)
    os_name=$(detect_os)
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || msg "unknown" "неизвестно")

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    if [[ "$(current_lang)" == "ru" ]]; then
        echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}swap-setup.sh${NC} — Гибридный swap + zram для VPS      ${BOLD}${CYAN}║${NC}"
    else
        echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}swap-setup.sh${NC} — Hybrid Swap + Zram for VPS         ${BOLD}${CYAN}║${NC}"
    fi
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  $(msg "OS:" "ОС:")    ${BOLD}${os_name}${NC}"
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
        log_error "$(msg "Unsupported RAM template: $ram_gb (use 0.5, 1, 2, 3, 4, 6 or 8)" "Неподдерживаемый шаблон RAM: $ram_gb (используйте 0.5, 1, 2, 3, 4, 6 или 8)")"
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

estimate_compressed_ram_mb() {
    local logical_mb="$1"
    echo $(((logical_mb + COMPRESSION_RATIO_ESTIMATE - 1) / COMPRESSION_RATIO_ESTIMATE))
}

# ── Interactive wizard ───────────────────────────────────────────────────────

print_templates_table() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)

    echo ""
    echo -e "${BOLD}  $(msg "Available RAM templates:" "Доступные шаблоны RAM:")${NC}"
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
            marker=" ${GREEN}<< $(msg "recommended" "рекомендуется")${NC}"
        fi
        printf "  ${DIM}│${NC} %-3s  ${DIM}│${NC} %-5s ${DIM}│${NC} %4s MB      ${DIM}│${NC}   %3s%%    ${DIM}│${NC} zstd  ${DIM}│${NC}   100    ${DIM}│${NC}    %3s     ${DIM}│${NC}%b\n" \
            "$tpl" "$t_ram" "$t_swap" "$t_pct" "$t_swp" "$marker"
    done

    echo -e "  ${DIM}├──────┼────────┼──────────────┼───────────┼───────┼──────────┼────────────┤${NC}"
    if [[ "$(current_lang)" == "ru" ]]; then
        echo -e "  ${DIM}│${NC}  ${MAGENTA}9${NC}   ${DIM}│${NC} ${MAGENTA}Ручной ввод — настройка каждого параметра${NC}                         ${DIM}│${NC}"
    else
        echo -e "  ${DIM}│${NC}  ${MAGENTA}9${NC}   ${DIM}│${NC} ${MAGENTA}Manual input — configure every parameter${NC}                                ${DIM}│${NC}"
    fi
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
    if [[ -z "$result" ]]; then
        ASK_VALUE_USED_DEFAULT=true
        result="$default"
    else
        ASK_VALUE_USED_DEFAULT=false
    fi
    echo "$result"
}

interactive_wizard() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)

    show_system_info
    print_templates_table

    local choice
    read -rp "$(echo -e "  ${BOLD}$(msg "Select template (0.5, 1, 2, 3, 4, 6, 8; 9 for manual):" "Выберите шаблон (0.5, 1, 2, 3, 4, 6, 8; 9 — ручной ввод):")${NC} ")" choice
    echo ""

    case "$choice" in
        0.5|1|2|3|4|6|8)
            apply_template "$choice"
            log_info "$(msg "Template $choice applied" "Шаблон $choice применён")"

            echo ""
            echo -e "  ${YELLOW}$(msg "Adjust individual parameters before installing?" "Изменить отдельные параметры перед установкой?")${NC}"
            read -rp "$(echo -e "  ${BOLD}$(msg "Edit parameters?" "Редактировать параметры?") [$(yes_no_hint)]:${NC} ")" edit_confirm
            if is_yes "$edit_confirm"; then
                interactive_edit_params
            fi
            ;;
        9)
            log_info "$(msg "Manual configuration selected" "Выбрана ручная настройка")"
            echo ""
            interactive_manual_input
            ;;
        *)
            log_error "$(msg "Invalid choice: $choice" "Недопустимый выбор: $choice")"
            exit 1
            ;;
    esac
}

interactive_manual_input() {
    local ram_mb zram_size_mb
    ram_mb=$(get_total_ram_mb)
    auto_detect_template

    echo -e "  ${BOLD}${CYAN}$(msg "Enter parameters for your VPS (RAM: ${ram_mb} MB):" "Введите параметры для вашего VPS (RAM: ${ram_mb} MB):")${NC}"
    echo ""

    # ── Swapfile size ────────────────────────────────────────────────────────
    echo -e "  ${BOLD}$(msg "1. Swap file size (MB)" "1. Размер swap-файла (MB)")${NC}"
    SWAPFILE_SIZE_MB=$(ask_value "$(msg "   Swapfile size MB" "   Размер swap-файла MB")" "$SWAPFILE_SIZE_MB" \
        "$(msg "   Template recommendation for detected RAM: ${SWAPFILE_SIZE_MB} MB. Larger file = more emergency swap, but uses disk space." "   Рекомендация шаблона для обнаруженной RAM: ${SWAPFILE_SIZE_MB} MB. Больший файл даёт больше аварийной подкачки, но занимает место на диске.")")
    echo ""

    # ── ALGO ─────────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}$(msg "2. Compression algorithm (ALGO)" "2. Алгоритм сжатия (ALGO)")${NC}"
    echo -e "  ${DIM}   $(msg "Available:" "Доступно:") ${NC}${GREEN}zstd${NC}${DIM} | lz4 | lzo | lzo-rle | lz4hc | zlib | 842${NC}"
    echo -e "  ${DIM}   zstd  — $(msg "best compression ratio (~3:1), moderate CPU (recommended 2025-2026)" "лучшее сжатие (~3:1), умеренная нагрузка CPU (рекомендуется в 2025-2026)")${NC}"
    echo -e "  ${DIM}   lz4   — $(msg "fastest, lower compression (~2:1), good for weak CPU" "самый быстрый, ниже сжатие (~2:1), хорош для слабого CPU")${NC}"
    echo -e "  ${DIM}   lzo   — $(msg "legacy, balanced" "устаревший, сбалансированный")${NC}"
    ZRAM_ALGO=$(ask_value "   ALGO" "$ZRAM_ALGO" \
        "$(msg "   Press Enter to keep the template default. If default is unsupported, the script can choose a safe supported fallback." "   Нажмите Enter, чтобы оставить значение шаблона. Если значение по умолчанию не поддерживается, скрипт выберет безопасный поддерживаемый вариант.")")
    if [[ "$ASK_VALUE_USED_DEFAULT" != true ]]; then
        ZRAM_ALGO_EXPLICIT=true
    fi
    validate_zram_algo "$ZRAM_ALGO"
    echo ""

    # ── PERCENT ──────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}$(msg "3. zram size as % of RAM (PERCENT)" "3. Размер zram в % от RAM (PERCENT)")${NC}"
    zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
    echo -e "  ${DIM}   $(msg "With PERCENT=${ZRAM_PERCENT} on your ${ram_mb}MB RAM -> zram swap device ~${zram_size_mb} MB" "При PERCENT=${ZRAM_PERCENT} и RAM ${ram_mb}MB -> zram swap-устройство ~${zram_size_mb} MB")${NC}"
    ZRAM_PERCENT=$(ask_value "   PERCENT" "$ZRAM_PERCENT" \
        "$(msg "   Template recommendation: ${ZRAM_PERCENT}%. Normal range: 25-200; hard limit: 300. This is logical zram swap size, not extra RAM." "   Рекомендация шаблона: ${ZRAM_PERCENT}%. Обычный диапазон: 25-200; жёсткий лимит: 300. Это логический размер zram swap, а не дополнительная RAM.")")
    validate_zram_percent
    echo ""

    # show calculated zram size
    zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
    echo -e "  ${DIM}   -> $(msg "zram swap device will be ~${zram_size_mb} MB (${ZRAM_PERCENT}% of ${ram_mb} MB)" "zram swap-устройство будет ~${zram_size_mb} MB (${ZRAM_PERCENT}% от ${ram_mb} MB)")${NC}"
    echo ""

    # ── PRIORITY ─────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}$(msg "4. zram swap priority (PRIORITY)" "4. Приоритет zram swap (PRIORITY)")${NC}"
    ZRAM_PRIORITY=$(ask_value "   PRIORITY" "100" \
        "$(msg "   Higher priority is used first. Keep zram above disk swap (${SWAP_PRIORITY}). Valid range: 0-32767." "   Более высокий приоритет используется первым. Держите zram выше дискового swap (${SWAP_PRIORITY}). Допустимый диапазон: 0-32767.")")
    validate_zram_priority_value
    echo ""

    # ── swappiness ───────────────────────────────────────────────────────────
    echo -e "  ${BOLD}5. vm.swappiness${NC}"
    SWAPPINESS=$(ask_value "   swappiness" "$SWAPPINESS" \
        "$(msg "   Template default: ${SWAPPINESS}. Higher values make Linux use zram earlier. Valid range: 0-200." "   Значение шаблона: ${SWAPPINESS}. Более высокие значения заставляют Linux раньше использовать zram. Допустимый диапазон: 0-200.")")
    validate_swappiness_value
    echo ""
}

interactive_edit_params() {
    local ram_mb zram_size_mb
    ram_mb=$(get_total_ram_mb)

    echo ""
    echo -e "  ${BOLD}${CYAN}$(msg "Current values (press Enter to keep):" "Текущие значения (Enter — оставить без изменений):")${NC}"
    echo ""

    # ── Swapfile size ────────────────────────────────────────────────────────
    echo -e "  ${BOLD}$(msg "1. Swap file size" "1. Размер swap-файла")${NC}"
    SWAPFILE_SIZE_MB=$(ask_value "$(msg "   Swapfile size MB" "   Размер swap-файла MB")" "$SWAPFILE_SIZE_MB" \
        "$(msg "   Current value from selected template or previous input. Press Enter to keep it." "   Текущее значение из выбранного шаблона или предыдущего ввода. Нажмите Enter, чтобы оставить его.")")
    echo ""

    # ── ALGO ─────────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}$(msg "2. Compression algorithm (ALGO)" "2. Алгоритм сжатия (ALGO)")${NC}"
    echo -e "  ${DIM}   $(msg "Available:" "Доступно:") ${NC}${GREEN}zstd${NC}${DIM} | lz4 | lzo | lzo-rle | lz4hc | zlib | 842${NC}"
    ZRAM_ALGO=$(ask_value "   ALGO" "$ZRAM_ALGO" \
        "$(msg "   zstd=best ratio, lz4=fastest. If you type a value here, unsupported algorithms will be treated as errors." "   zstd=лучшее сжатие, lz4=максимальная скорость. Если ввести значение вручную, неподдерживаемые алгоритмы будут ошибкой.")")
    if [[ "$ASK_VALUE_USED_DEFAULT" != true ]]; then
        ZRAM_ALGO_EXPLICIT=true
    fi
    validate_zram_algo "$ZRAM_ALGO"
    echo ""

    # ── PERCENT ──────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}$(msg "3. zram size (PERCENT of RAM)" "3. Размер zram (PERCENT от RAM)")${NC}"
    zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
    echo -e "  ${DIM}   $(msg "Currently ${ZRAM_PERCENT}% = ~${zram_size_mb} MB on your ${ram_mb} MB RAM" "Сейчас ${ZRAM_PERCENT}% = ~${zram_size_mb} MB при RAM ${ram_mb} MB")${NC}"
    ZRAM_PERCENT=$(ask_value "   PERCENT" "$ZRAM_PERCENT" \
        "$(msg "   Normal range: 25-200; hard limit: 300. Higher = larger logical zram swap device." "   Обычный диапазон: 25-200; жёсткий лимит: 300. Больше значение = больше логическое zram swap-устройство.")")
    validate_zram_percent
    echo ""

    zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
    echo -e "  ${DIM}   -> $(msg "zram swap device will be ~${zram_size_mb} MB" "zram swap-устройство будет ~${zram_size_mb} MB")${NC}"
    echo ""

    # ── PRIORITY ─────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}$(msg "4. zram priority (PRIORITY)" "4. Приоритет zram (PRIORITY)")${NC}"
    ZRAM_PRIORITY=$(ask_value "   PRIORITY" "$ZRAM_PRIORITY" \
        "$(msg "   Higher priority is used first. Keep zram above disk swap (${SWAP_PRIORITY}). Valid range: 0-32767." "   Более высокий приоритет используется первым. Держите zram выше дискового swap (${SWAP_PRIORITY}). Допустимый диапазон: 0-32767.")")
    validate_zram_priority_value
    echo ""

    # ── swappiness ───────────────────────────────────────────────────────────
    echo -e "  ${BOLD}5. vm.swappiness${NC}"
    SWAPPINESS=$(ask_value "   swappiness" "$SWAPPINESS" \
        "$(msg "   Valid range: 0-200. Low-RAM templates use 80-100 so zram is used before memory pressure becomes critical." "   Допустимый диапазон: 0-200. Шаблоны для малой RAM используют 80-100, чтобы zram применялся до критического давления на память.")")
    validate_swappiness_value
    echo ""
}

# ── Swap checks ──────────────────────────────────────────────────────────────

check_existing_swap() {
    log_section "$(msg "Checking existing swap configuration" "Проверка существующей конфигурации swap")"

    local has_conflict=false

    # Check active swap devices
    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        log_warn "$(msg "Active swap devices found:" "Найдены активные swap-устройства:")"
        swapon --show
        echo ""

        # Check if our target swapfile is already active
        if is_swapfile_active; then
            log_warn "$(msg "$SWAPFILE_PATH is already active as swap" "$SWAPFILE_PATH уже активен как swap")"
            has_conflict=true
        fi
    else
        log_info "$(msg "No active swap devices found" "Активные swap-устройства не найдены")"
    fi

    # Check if swapfile already exists on disk
    if [[ -f "$SWAPFILE_PATH" ]]; then
        local existing_size
        existing_size=$(du -m "$SWAPFILE_PATH" 2>/dev/null | awk '{print $1}')
        log_warn "$(msg "$SWAPFILE_PATH already exists (${existing_size}MB)" "$SWAPFILE_PATH уже существует (${existing_size}MB)")"
        has_conflict=true
    fi

    # Check fstab for existing swap entries (match 'swap' in the fs type field)
    if fstab_has_swap_entries; then
        log_warn "$(msg "Existing swap entries in /etc/fstab:" "Существующие swap-записи в /etc/fstab:")"
        print_fstab_swap_entries
        has_conflict=true
    fi

    # Check if zram is already configured
    if [[ -f /etc/default/zramswap ]]; then
        log_warn "$(msg "zramswap config already exists at /etc/default/zramswap" "Конфигурация zramswap уже существует: /etc/default/zramswap")"
        has_conflict=true
    fi

    if [[ "$has_conflict" == true ]]; then
        echo ""
        log_warn "$(msg "Existing swap configuration detected!" "Обнаружена существующая конфигурация swap!")"
        if [[ "$AUTO_YES" != true ]]; then
            echo -e "${YELLOW}$(msg "The script will:" "Скрипт выполнит:")${NC}"
            echo "  - $(msg "Deactivate and recreate $SWAPFILE_PATH if it exists" "Отключит и пересоздаст $SWAPFILE_PATH, если он существует")"
            echo "  - $(msg "Update /etc/fstab (replace the $SWAPFILE_PATH entry only, keep other swap entries)" "Обновит /etc/fstab (заменит только запись $SWAPFILE_PATH, остальные swap-записи сохранит)")"
            echo "  - $(msg "Overwrite /etc/default/zramswap" "Перезапишет /etc/default/zramswap")"
            echo ""
            read -rp "$(msg "Continue?" "Продолжить?") [$(yes_no_hint)]: " confirm
            if ! is_yes "$confirm"; then
                log_info "$(msg "Aborted by user" "Прервано пользователем")"
                exit 0
            fi
        else
            log_info "$(msg "Auto-confirm enabled (--yes), proceeding..." "Автоподтверждение включено (--yes), продолжаю...")"
        fi
    else
        log_info "$(msg "No conflicts found, proceeding with setup" "Конфликтов не найдено, продолжаю настройку")"
    fi
}

is_swapfile_active() {
    swapon --show --noheadings --raw --output=NAME 2>/dev/null \
        | awk -v path="$SWAPFILE_PATH" '$1 == path { found = 1 } END { exit !found }'
}

is_swap_device_active() {
    local path="$1"
    swapon --show --noheadings --raw --output=NAME 2>/dev/null \
        | awk -v path="$path" '$1 == path { found = 1 } END { exit !found }'
}

get_swap_priority() {
    local path="$1"
    swapon --show --noheadings --raw --output=NAME,PRIO 2>/dev/null \
        | awk -v path="$path" '$1 == path { print $2; found = 1 } END { exit !found }'
}

# Wait until expected swap devices appear active with the configured priority,
# or until the timeout elapses. `systemctl restart zramswap` returns as soon as
# ExecStart completes, but /proc/swaps may not reflect the new state for a
# moment, and during ExecStop the zramswap unit briefly does `swapoff
# /dev/zram0`. Without waiting, verify_configuration races and reports false
# negatives like "/dev/zram0 priority is 'inactive'".
wait_for_swap_active() {
    local timeout_s="${1:-10}"
    local deadline=$(( SECONDS + timeout_s ))
    local prio

    while (( SECONDS < deadline )); do
        local ok=true

        if is_swapfile_active; then
            prio=$(get_swap_priority "$SWAPFILE_PATH" || true)
            [[ "$prio" == "$SWAP_PRIORITY" ]] || ok=false
        else
            ok=false
        fi

        if is_swap_device_active "/dev/zram0"; then
            prio=$(get_swap_priority "/dev/zram0" || true)
            [[ "$prio" == "$ZRAM_PRIORITY" ]] || ok=false
        else
            ok=false
        fi

        if [[ "$ok" == true ]]; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

fstab_has_swap_entries() {
    awk '!/^[[:space:]]*#/ && $3 == "swap" { found = 1 } END { exit !found }' /etc/fstab 2>/dev/null
}

print_fstab_swap_entries() {
    awk '!/^[[:space:]]*#/ && $3 == "swap"' /etc/fstab 2>/dev/null
}

fstab_has_swapfile_entry() {
    awk -v path="$SWAPFILE_PATH" \
        '!/^[[:space:]]*#/ && $1 == path && $3 == "swap" { found = 1 } END { exit !found }' \
        /etc/fstab 2>/dev/null
}

backup_fstab() {
    local backup_path
    backup_path="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    cp -a /etc/fstab "$backup_path"
    log_info "$(msg "Backed up /etc/fstab to $backup_path" "Резервная копия /etc/fstab создана: $backup_path")"
}

rewrite_fstab() {
    local add_swap_entry="$1"
    local tmp
    tmp=$(mktemp /etc/fstab.swap-setup.XXXXXX)

    awk -v path="$SWAPFILE_PATH" \
        '($1 == path && $3 == "swap") { next } { print }' \
        /etc/fstab > "$tmp"

    if [[ "$add_swap_entry" == true ]]; then
        printf '%s\n' "$SWAPFILE_PATH none swap sw,pri=$SWAP_PRIORITY 0 0" >> "$tmp"
    fi

    chmod --reference=/etc/fstab "$tmp"
    chown --reference=/etc/fstab "$tmp"
    mv "$tmp" /etc/fstab
}

restart_zramswap_service() {
    if ! command -v systemctl &>/dev/null; then
        log_error "$(msg "systemctl not found. zram-tools service management requires systemd." "systemctl не найден. Управление сервисом zram-tools требует systemd.")"
        return 1
    fi

    log_info "$(msg "Enabling zramswap service..." "Включаю сервис zramswap...")"
    systemctl enable zramswap || return 1

    log_info "$(msg "Restarting zramswap service..." "Перезапускаю сервис zramswap...")"
    systemctl restart zramswap || return 1
    log_info "$(msg "zramswap service restarted" "Сервис zramswap перезапущен")"
}

stop_disable_zramswap_service() {
    if ! command -v systemctl &>/dev/null; then
        log_warn "$(msg "systemctl not found, skipping zramswap service stop/disable" "systemctl не найден, пропускаю остановку/отключение сервиса zramswap")"
        return
    fi

    if systemctl stop zramswap 2>/dev/null; then
        log_info "$(msg "Stopped zramswap service" "Сервис zramswap остановлен")"
    else
        log_warn "$(msg "zramswap service was not active or could not be stopped" "Сервис zramswap не был активен или его не удалось остановить")"
    fi

    if systemctl disable zramswap 2>/dev/null; then
        log_info "$(msg "Disabled zramswap service" "Сервис zramswap отключён")"
    fi
}

check_zram_kernel_support() {
    log_section "$(msg "Checking zram kernel support" "Проверка поддержки zram в ядре")"

    if ! command -v modprobe &>/dev/null; then
        log_error "$(msg "modprobe not found. Cannot load the zram kernel module." "modprobe не найден. Невозможно загрузить модуль ядра zram.")"
        exit 1
    fi

    if ! modprobe zram 2>/dev/null; then
        log_error "$(msg "Unable to load the zram kernel module. Check kernel support for zram." "Не удалось загрузить модуль ядра zram. Проверьте поддержку zram в ядре.")"
        exit 1
    fi

    if [[ ! -r /sys/block/zram0/comp_algorithm ]]; then
        log_error "$(msg "Unable to read supported zram compression algorithms from /sys/block/zram0/comp_algorithm" "Не удалось прочитать поддерживаемые алгоритмы zram из /sys/block/zram0/comp_algorithm")"
        exit 1
    fi

    local supported
    supported=$(tr '[]' '  ' < /sys/block/zram0/comp_algorithm | xargs)
    if algo_in_list "$ZRAM_ALGO" "$supported"; then
        log_info "$(msg "zram module is available; algorithm '$ZRAM_ALGO' is supported" "Модуль zram доступен; алгоритм '$ZRAM_ALGO' поддерживается")"
        return
    fi

    if [[ "$ZRAM_ALGO_EXPLICIT" == true ]]; then
        log_error "$(msg "zram algorithm '$ZRAM_ALGO' is not supported by this kernel. Supported: $supported" "Алгоритм zram '$ZRAM_ALGO' не поддерживается этим ядром. Поддерживаются: $supported")"
        exit 1
    fi

    local fallback
    for fallback in zstd lz4 lzo-rle lzo zlib 842; do
        if algo_in_list "$fallback" "$supported"; then
            log_warn "$(msg "Default zram algorithm '$ZRAM_ALGO' is not supported by this kernel; using '$fallback' instead" "Алгоритм zram по умолчанию '$ZRAM_ALGO' не поддерживается этим ядром; использую '$fallback'")"
            ZRAM_ALGO="$fallback"
            return
        fi
    done

    log_error "$(msg "No supported zram algorithm found. Kernel reports: $supported" "Не найден поддерживаемый алгоритм zram. Ядро сообщает: $supported")"
    exit 1
}

algo_in_list() {
    local needle="$1"
    local list="$2"
    local item
    for item in $list; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

ensure_zram_tools_installed() {
    if dpkg -l zram-tools 2>/dev/null | grep -q "^ii"; then
        log_info "$(msg "zram-tools already installed" "zram-tools уже установлен")"
        return
    fi

    if ! command -v apt-get &>/dev/null; then
        log_error "$(msg "apt-get not found. zram-tools must be installed manually on this system." "apt-get не найден. zram-tools нужно установить вручную на этой системе.")"
        exit 1
    fi

    log_info "$(msg "Installing zram-tools..." "Устанавливаю zram-tools...")"
    apt-get update -qq
    apt-get install -y -qq zram-tools
    log_info "$(msg "zram-tools installed" "zram-tools установлен")"
}

# ── Setup functions ──────────────────────────────────────────────────────────

check_disk_space() {
    local target_dir
    target_dir=$(dirname "$SWAPFILE_PATH")
    local available_mb
    available_mb=$(df -BM --output=avail "$target_dir" 2>/dev/null | tail -1 | tr -d ' M')
    if [[ -z "$available_mb" || ! "$available_mb" =~ ^[0-9]+$ ]]; then
        log_error "$(msg "Unable to determine available disk space on $target_dir" "Не удалось определить свободное место на $target_dir")"
        exit 1
    fi
    if (( available_mb < SWAPFILE_SIZE_MB + 100 )); then
        log_error "$(msg "Not enough disk space for safe staged creation: need ${SWAPFILE_SIZE_MB}MB + 100MB margin free, only ${available_mb}MB available on $target_dir" "Недостаточно места для безопасного staged-создания: нужно ${SWAPFILE_SIZE_MB}MB + 100MB запаса, доступно только ${available_mb}MB на $target_dir")"
        exit 1
    fi
    log_info "$(msg "Disk space check passed: ${available_mb}MB available, need ${SWAPFILE_SIZE_MB}MB for staged swapfile creation" "Проверка места на диске пройдена: доступно ${available_mb}MB, нужно ${SWAPFILE_SIZE_MB}MB для staged-создания swap-файла")"
}

check_filesystem_type() {
    local target_dir fs_type
    target_dir=$(dirname "$SWAPFILE_PATH")
    BTRFS_SWAP=false
    fs_type=$(df -T "$target_dir" 2>/dev/null | awk 'NR==2 {print $2}')
    if [[ -z "$fs_type" ]]; then
        log_error "$(msg "Unable to detect filesystem type for $target_dir" "Не удалось определить тип файловой системы для $target_dir")"
        exit 1
    fi
    case "$fs_type" in
        btrfs)
            log_warn "$(msg "Filesystem is btrfs — swapfile requires 'chattr +C' (no copy-on-write)" "Файловая система btrfs — для swapfile требуется 'chattr +C' (без copy-on-write)")"
            if ! command -v chattr &>/dev/null; then
                log_error "$(msg "chattr not found; cannot safely create a btrfs swapfile without copy-on-write" "chattr не найден; невозможно безопасно создать btrfs swapfile без copy-on-write")"
                exit 1
            fi
            BTRFS_SWAP=true
            ;;
        zfs)
            log_error "$(msg "ZFS does not support swap files. Use a dedicated zvol instead." "ZFS не поддерживает swap-файлы. Используйте отдельный zvol.")"
            exit 1
            ;;
        *)
            log_info "$(msg "Filesystem: $fs_type (OK for swapfile)" "Файловая система: $fs_type (подходит для swapfile)")"
            ;;
    esac
}

setup_swapfile() {
    log_section "$(msg "Setting up swap file ($SWAPFILE_SIZE_MB MB)" "Настройка swap-файла ($SWAPFILE_SIZE_MB MB)")"

    check_disk_space
    check_filesystem_type

    local target_dir tmp_swapfile old_swapfile_backup old_swapfile_active
    target_dir=$(dirname "$SWAPFILE_PATH")
    tmp_swapfile=$(mktemp "${target_dir}/.swapfile.new.XXXXXX")
    old_swapfile_backup=""
    old_swapfile_active=false

    cleanup_new_swapfile() {
        [[ -n "${tmp_swapfile:-}" && -e "$tmp_swapfile" ]] && rm -f "$tmp_swapfile"
    }

    log_info "$(msg "Creating staged ${SWAPFILE_SIZE_MB}MB swap file at $tmp_swapfile..." "Создаю staged swap-файл ${SWAPFILE_SIZE_MB}MB: $tmp_swapfile...")"
    chmod 600 "$tmp_swapfile"
    if [[ "$BTRFS_SWAP" == true ]]; then
        chattr +C "$tmp_swapfile"
    fi
    if ! dd if=/dev/zero of="$tmp_swapfile" bs=1M count="$SWAPFILE_SIZE_MB" conv=fsync status=progress 2>&1; then
        cleanup_new_swapfile
        log_error "$(msg "Failed to create staged swap file" "Не удалось создать staged swap-файл")"
        exit 1
    fi
    chmod 600 "$tmp_swapfile"

    if ! mkswap "$tmp_swapfile"; then
        cleanup_new_swapfile
        log_error "$(msg "Failed to format staged swap file" "Не удалось отформатировать staged swap-файл")"
        exit 1
    fi
    log_info "$(msg "Staged swap file is formatted" "Staged swap-файл отформатирован")"

    if is_swapfile_active; then
        old_swapfile_active=true
        log_info "$(msg "Deactivating existing $SWAPFILE_PATH..." "Отключаю существующий $SWAPFILE_PATH...")"
        if ! swapoff "$SWAPFILE_PATH"; then
            cleanup_new_swapfile
            log_error "$(msg "Failed to deactivate existing $SWAPFILE_PATH; leaving current swapfile unchanged" "Не удалось отключить существующий $SWAPFILE_PATH; текущий swapfile оставлен без изменений")"
            exit 1
        fi
    fi

    if [[ -f "$SWAPFILE_PATH" ]]; then
        old_swapfile_backup="${SWAPFILE_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$SWAPFILE_PATH" "$old_swapfile_backup"
        log_info "$(msg "Moved old $SWAPFILE_PATH to $old_swapfile_backup" "Старый $SWAPFILE_PATH перемещён в $old_swapfile_backup")"
    fi

    if ! mv "$tmp_swapfile" "$SWAPFILE_PATH"; then
        log_error "$(msg "Failed to move staged swapfile into place; attempting to restore previous swapfile" "Не удалось поставить staged swapfile на место; пробую восстановить предыдущий swapfile")"
        if [[ -n "$old_swapfile_backup" && -f "$old_swapfile_backup" ]]; then
            mv "$old_swapfile_backup" "$SWAPFILE_PATH"
            if [[ "$old_swapfile_active" == true ]]; then
                swapon "$SWAPFILE_PATH" 2>/dev/null || log_warn "$(msg "Previous $SWAPFILE_PATH was restored but could not be reactivated" "Предыдущий $SWAPFILE_PATH восстановлен, но его не удалось повторно активировать")"
            fi
        fi
        cleanup_new_swapfile
        exit 1
    fi
    if ! chmod 600 "$SWAPFILE_PATH"; then
        log_error "$(msg "Failed to set permissions on $SWAPFILE_PATH" "Не удалось установить права на $SWAPFILE_PATH")"
        exit 1
    fi

    if ! swapon -p "$SWAP_PRIORITY" "$SWAPFILE_PATH"; then
        log_error "$(msg "Failed to activate new $SWAPFILE_PATH; attempting to restore previous swapfile" "Не удалось активировать новый $SWAPFILE_PATH; пробую восстановить предыдущий swapfile")"
        rm -f "$SWAPFILE_PATH"
        if [[ -n "$old_swapfile_backup" && -f "$old_swapfile_backup" ]]; then
            mv "$old_swapfile_backup" "$SWAPFILE_PATH"
            if [[ "$old_swapfile_active" == true ]]; then
                swapon "$SWAPFILE_PATH" 2>/dev/null || log_warn "$(msg "Previous $SWAPFILE_PATH was restored but could not be reactivated" "Предыдущий $SWAPFILE_PATH восстановлен, но его не удалось повторно активировать")"
            fi
        fi
        exit 1
    fi
    log_info "$(msg "Activated with priority $SWAP_PRIORITY" "Активирован с приоритетом $SWAP_PRIORITY")"

    if [[ -n "$old_swapfile_backup" && -f "$old_swapfile_backup" ]]; then
        rm -f "$old_swapfile_backup"
    fi

    update_fstab
}

update_fstab() {
    log_info "$(msg "Updating /etc/fstab..." "Обновляю /etc/fstab...")"

    backup_fstab
    if fstab_has_swapfile_entry; then
        log_info "$(msg "Removed old $SWAPFILE_PATH entries from /etc/fstab" "Старые записи $SWAPFILE_PATH удалены из /etc/fstab")"
    fi
    rewrite_fstab true
    log_info "$(msg "Added: $SWAPFILE_PATH none swap sw,pri=$SWAP_PRIORITY 0 0" "Добавлено: $SWAPFILE_PATH none swap sw,pri=$SWAP_PRIORITY 0 0")"
}

setup_zram() {
    log_section "$(msg "Setting up zram (${ZRAM_PERCENT}% of RAM, algo=${ZRAM_ALGO}, priority=${ZRAM_PRIORITY})" "Настройка zram (${ZRAM_PERCENT}% от RAM, algo=${ZRAM_ALGO}, priority=${ZRAM_PRIORITY})")"

    local config_path="/etc/default/zramswap"
    local tmp_config backup_config
    tmp_config=$(mktemp /etc/default/zramswap.swap-setup.XXXXXX)
    backup_config=""

    if [[ -f "$config_path" ]]; then
        backup_config="${config_path}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$config_path" "$backup_config"
        log_info "$(msg "Backed up $config_path to $backup_config" "Резервная копия $config_path создана: $backup_config")"
    fi

    log_info "$(msg "Writing /etc/default/zramswap..." "Записываю /etc/default/zramswap...")"
    cat > "$tmp_config" <<EOF
# Configured by swap-setup.sh
# Compression algorithm: ${ZRAM_ALGO}
# Available: zstd | lz4 | lzo | lzo-rle | lz4hc | zlib | 842
ALGO=${ZRAM_ALGO}

# Percentage of RAM to use for zram (e.g. 100 = same as RAM size)
PERCENT=${ZRAM_PERCENT}

# Swap priority (higher = used first; disk swap typically has priority ${SWAP_PRIORITY})
PRIORITY=${ZRAM_PRIORITY}
EOF
    chmod 644 "$tmp_config"
    mv "$tmp_config" "$config_path"
    log_info "$(msg "zramswap config written" "Конфигурация zramswap записана")"

    # Enable for boot and restart with the new config
    if ! restart_zramswap_service; then
        log_error "$(msg "Failed to enable/restart zramswap service" "Не удалось включить/перезапустить сервис zramswap")"
        if [[ -n "$backup_config" && -f "$backup_config" ]]; then
            cp -a "$backup_config" "$config_path"
            log_warn "$(msg "Restored previous $config_path from backup" "Предыдущая конфигурация $config_path восстановлена из резервной копии")"
            systemctl restart zramswap 2>/dev/null || log_warn "$(msg "Previous zramswap configuration was restored but the service could not be restarted" "Предыдущая конфигурация zramswap восстановлена, но сервис не удалось перезапустить")"
        fi
        exit 1
    fi
}

setup_swappiness() {
    log_section "$(msg "Setting vm.swappiness to $SWAPPINESS" "Настройка vm.swappiness = $SWAPPINESS")"

    sysctl vm.swappiness="$SWAPPINESS"

    # Persist across reboots
    local sysctl_file="/etc/sysctl.d/99-swappiness.conf"
    local tmp_sysctl
    tmp_sysctl=$(mktemp /etc/sysctl.d/99-swappiness.conf.XXXXXX)
    printf '%s\n' "vm.swappiness=$SWAPPINESS" > "$tmp_sysctl"
    chmod 644 "$tmp_sysctl"
    mv "$tmp_sysctl" "$sysctl_file"
    log_info "$(msg "Saved to $sysctl_file (persistent after reboot)" "Сохранено в $sysctl_file (сохраняется после перезагрузки)")"
}

# ── Status / verification ────────────────────────────────────────────────────

print_command_output() {
    local empty_message="$1"
    shift

    local output
    if output="$("$@" 2>/dev/null)" && [[ -n "$output" ]]; then
        printf '%s\n' "$output"
    else
        echo "  ($empty_message)"
    fi
}

show_status() {
    local ram_mb
    ram_mb=$(get_total_ram_mb)

    log_section "$(msg "System: $(detect_os), RAM: ${ram_mb} MB ($(get_total_ram_gb_label))" "Система: $(detect_os), RAM: ${ram_mb} MB ($(get_total_ram_gb_label))")"

    log_section "zramctl"
    print_command_output "$(msg "no zram devices found or zramctl returned no rows" "zram-устройства не найдены или zramctl не вернул строк")" zramctl

    log_section "swapon --show"
    print_command_output "$(msg "no swap devices active" "активные swap-устройства не найдены")" swapon --show

    log_section "zramctl --output-all"
    print_command_output "$(msg "no zram devices found or zramctl returned no rows" "zram-устройства не найдены или zramctl не вернул строк")" zramctl --output-all

    log_section "free -h"
    free -h

    echo ""
    local swappiness
    swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || msg "unknown" "неизвестно")
    log_info "$(msg "Current vm.swappiness = $swappiness" "Текущий vm.swappiness = $swappiness")"
}

verify_configuration() {
    log_section "$(msg "Verifying configured swap/zram" "Проверка настроенного swap/zram")"

    local failed=false
    local priority current_swappiness expected_zram_bytes actual_zram_bytes diff_bytes current_algo memtotal_kb

    if is_swapfile_active; then
        priority=$(get_swap_priority "$SWAPFILE_PATH" || true)
        if [[ "$priority" == "$SWAP_PRIORITY" ]]; then
            log_info "$(msg "$SWAPFILE_PATH is active with priority $SWAP_PRIORITY" "$SWAPFILE_PATH активен с приоритетом $SWAP_PRIORITY")"
        else
            log_error "$(msg "$SWAPFILE_PATH is active but priority is '${priority:-unknown}', expected $SWAP_PRIORITY" "$SWAPFILE_PATH активен, но приоритет '${priority:-unknown}', ожидалось $SWAP_PRIORITY")"
            failed=true
        fi
    else
        log_error "$(msg "$SWAPFILE_PATH is not active" "$SWAPFILE_PATH не активен")"
        failed=true
    fi

    priority=$(get_swap_priority "/dev/zram0" || true)
    if [[ "$priority" == "$ZRAM_PRIORITY" ]]; then
        log_info "$(msg "/dev/zram0 is active with priority $ZRAM_PRIORITY" "/dev/zram0 активен с приоритетом $ZRAM_PRIORITY")"
    else
        log_error "$(msg "/dev/zram0 priority is '${priority:-inactive}', expected $ZRAM_PRIORITY" "Приоритет /dev/zram0: '${priority:-inactive}', ожидалось $ZRAM_PRIORITY")"
        failed=true
    fi

    if [[ -r /sys/block/zram0/disksize ]]; then
        memtotal_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        expected_zram_bytes=$(( memtotal_kb * 1024 * ZRAM_PERCENT / 100 ))
        actual_zram_bytes=$(cat /sys/block/zram0/disksize)
        diff_bytes=$(( actual_zram_bytes > expected_zram_bytes ? actual_zram_bytes - expected_zram_bytes : expected_zram_bytes - actual_zram_bytes ))
        if (( diff_bytes <= 2 * 1024 * 1024 )); then
            log_info "$(msg "/dev/zram0 size matches configured ${ZRAM_PERCENT}% of RAM" "Размер /dev/zram0 соответствует настроенным ${ZRAM_PERCENT}% от RAM")"
        else
            log_error "$(msg "/dev/zram0 size is $actual_zram_bytes bytes, expected about $expected_zram_bytes bytes" "Размер /dev/zram0: $actual_zram_bytes байт, ожидалось около $expected_zram_bytes байт")"
            failed=true
        fi
    else
        log_warn "$(msg "Cannot verify /dev/zram0 size from sysfs" "Не удалось проверить размер /dev/zram0 через sysfs")"
    fi

    if [[ -r /sys/block/zram0/comp_algorithm ]]; then
        current_algo=$(tr ' ' '\n' < /sys/block/zram0/comp_algorithm | awk '/^\[/ { gsub(/\[|\]/, ""); print; exit }')
        if [[ "$current_algo" == "$ZRAM_ALGO" ]]; then
            log_info "$(msg "/dev/zram0 compression algorithm is $ZRAM_ALGO" "Алгоритм сжатия /dev/zram0: $ZRAM_ALGO")"
        else
            log_error "$(msg "/dev/zram0 compression algorithm is '${current_algo:-unknown}', expected $ZRAM_ALGO" "Алгоритм сжатия /dev/zram0: '${current_algo:-unknown}', ожидалось $ZRAM_ALGO")"
            failed=true
        fi
    else
        log_warn "$(msg "Cannot verify /dev/zram0 compression algorithm from sysfs" "Не удалось проверить алгоритм сжатия /dev/zram0 через sysfs")"
    fi

    current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || msg "unknown" "неизвестно")
    if [[ "$current_swappiness" == "$SWAPPINESS" ]]; then
        log_info "$(msg "vm.swappiness is $SWAPPINESS" "vm.swappiness = $SWAPPINESS")"
    else
        log_error "$(msg "vm.swappiness is '$current_swappiness', expected $SWAPPINESS" "vm.swappiness = '$current_swappiness', ожидалось $SWAPPINESS")"
        failed=true
    fi

    if fstab_has_swapfile_entry; then
        log_info "$(msg "/etc/fstab contains the managed $SWAPFILE_PATH entry" "/etc/fstab содержит управляемую запись $SWAPFILE_PATH")"
    else
        log_error "$(msg "/etc/fstab does not contain the managed $SWAPFILE_PATH entry" "/etc/fstab не содержит управляемую запись $SWAPFILE_PATH")"
        failed=true
    fi

    if [[ "$failed" == true ]]; then
        log_error "$(msg "Verification failed. See messages above." "Проверка не пройдена. Смотрите сообщения выше.")"
        exit 1
    fi

    log_info "$(msg "Verification passed" "Проверка пройдена")"
}

# ── Remove ───────────────────────────────────────────────────────────────────

remove_swap() {
    log_section "$(msg "Removing swap configuration" "Удаление конфигурации swap")"

    if [[ "$AUTO_YES" != true ]]; then
        echo -e "${YELLOW}$(msg "This will:" "Будет выполнено:")${NC}"
        echo "  - $(msg "Deactivate and delete $SWAPFILE_PATH" "Отключить и удалить $SWAPFILE_PATH")"
        echo "  - $(msg "Remove swap entry from /etc/fstab" "Удалить swap-запись из /etc/fstab")"
        echo "  - $(msg "Stop zramswap service" "Остановить сервис zramswap")"
        echo "  - $(msg "Remove /etc/sysctl.d/99-swappiness.conf" "Удалить /etc/sysctl.d/99-swappiness.conf")"
        echo ""
        read -rp "$(msg "Continue?" "Продолжить?") [$(yes_no_hint)]: " confirm
        if ! is_yes "$confirm"; then
            log_info "$(msg "Aborted by user" "Прервано пользователем")"
            exit 0
        fi
    fi

    # Deactivate swapfile
    if is_swapfile_active; then
        swapoff "$SWAPFILE_PATH" 2>/dev/null || true
        log_info "$(msg "Deactivated $SWAPFILE_PATH" "$SWAPFILE_PATH отключён")"
    fi

    # Remove swapfile
    if [[ -f "$SWAPFILE_PATH" ]]; then
        rm -f "$SWAPFILE_PATH"
        log_info "$(msg "Removed $SWAPFILE_PATH" "$SWAPFILE_PATH удалён")"
    fi

    # Clean fstab
    if fstab_has_swapfile_entry; then
        backup_fstab
        rewrite_fstab false
        log_info "$(msg "Removed swap entry from /etc/fstab" "swap-запись удалена из /etc/fstab")"
    fi

    # Stop and disable zramswap so zram does not come back after reboot
    stop_disable_zramswap_service

    # Remove zramswap config
    if [[ -f /etc/default/zramswap ]]; then
        rm -f /etc/default/zramswap
        log_info "$(msg "Removed /etc/default/zramswap" "/etc/default/zramswap удалён")"
    fi

    # Remove swappiness config
    if [[ -f /etc/sysctl.d/99-swappiness.conf ]]; then
        rm -f /etc/sysctl.d/99-swappiness.conf
        sysctl vm.swappiness=60 2>/dev/null || true
        log_info "$(msg "Removed swappiness config, reset to default (60)" "Конфигурация swappiness удалена, значение сброшено к стандартному (60)")"
    fi

    log_info "$(msg "Swap configuration removed" "Конфигурация swap удалена")"
    echo ""
    show_status
}

# ── Summary before install ───────────────────────────────────────────────────

show_plan() {
    local ram_mb zram_size_mb compressed_ram_mb
    ram_mb=$(get_total_ram_mb)
    zram_size_mb=$(( ram_mb * ZRAM_PERCENT / 100 ))
    compressed_ram_mb=$(estimate_compressed_ram_mb "$zram_size_mb")

    log_section "$(msg "Installation plan" "План установки")"
    echo ""
    if [[ "$(current_lang)" == "ru" ]]; then
        echo -e "  ${DIM}┌─────────────────────┬─────────────────────────────────────┐${NC}"
        echo -e "  ${DIM}│${NC} RAM системы        ${DIM}│${NC} ${BOLD}${YELLOW}${ram_mb} MB${NC} ($(get_total_ram_gb_label))                     ${DIM}│${NC}"
        echo -e "  ${DIM}├─────────────────────┼─────────────────────────────────────┤${NC}"
        echo -e "  ${DIM}│${NC} Swap-файл          ${DIM}│${NC} ${BOLD}${SWAPFILE_SIZE_MB} MB${NC} в ${SWAPFILE_PATH} (pri ${SWAP_PRIORITY})      ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC} zram ALGO          ${DIM}│${NC} ${BOLD}${ZRAM_ALGO}${NC}                                ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC} zram PERCENT       ${DIM}│${NC} ${BOLD}${ZRAM_PERCENT}%${NC} (~${zram_size_mb} MB)                       ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC} zram PRIORITY      ${DIM}│${NC} ${BOLD}${ZRAM_PRIORITY}${NC}                                 ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC} vm.swappiness      ${DIM}│${NC} ${BOLD}${SWAPPINESS}${NC}                                 ${DIM}│${NC}"
        echo -e "  ${DIM}└─────────────────────┴─────────────────────────────────────┘${NC}"
    else
        echo -e "  ${DIM}┌─────────────────────┬─────────────────────────────────────┐${NC}"
        echo -e "  ${DIM}│${NC} System RAM          ${DIM}│${NC} ${BOLD}${YELLOW}${ram_mb} MB${NC} ($(get_total_ram_gb_label))                     ${DIM}│${NC}"
        echo -e "  ${DIM}├─────────────────────┼─────────────────────────────────────┤${NC}"
        echo -e "  ${DIM}│${NC} Swap file           ${DIM}│${NC} ${BOLD}${SWAPFILE_SIZE_MB} MB${NC} at ${SWAPFILE_PATH} (pri ${SWAP_PRIORITY})     ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC} zram ALGO           ${DIM}│${NC} ${BOLD}${ZRAM_ALGO}${NC}                                ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC} zram PERCENT        ${DIM}│${NC} ${BOLD}${ZRAM_PERCENT}%${NC} (~${zram_size_mb} MB)                       ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC} zram PRIORITY       ${DIM}│${NC} ${BOLD}${ZRAM_PRIORITY}${NC}                                 ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC} vm.swappiness       ${DIM}│${NC} ${BOLD}${SWAPPINESS}${NC}                                 ${DIM}│${NC}"
        echo -e "  ${DIM}└─────────────────────┴─────────────────────────────────────┘${NC}"
    fi
    echo ""
    echo -e "  ${DIM}$(msg "Swap priority: zram (${ZRAM_PRIORITY}) >> disk swap (${SWAP_PRIORITY})" "Приоритет swap: zram (${ZRAM_PRIORITY}) >> дисковый swap (${SWAP_PRIORITY})")${NC}"
    echo -e "  ${DIM}$(msg "zram logical swap size is ~${zram_size_mb} MB; at ~${COMPRESSION_RATIO_ESTIMATE}:1 compression its data may use ~${compressed_ram_mb} MB RAM" "Логический размер zram swap ~${zram_size_mb} MB; при сжатии ~${COMPRESSION_RATIO_ESTIMATE}:1 данные могут занимать ~${compressed_ram_mb} MB RAM")${NC}"
    echo ""

    if [[ "$AUTO_YES" != true ]]; then
        read -rp "$(echo -e "  ${BOLD}$(msg "Proceed with installation?" "Продолжить установку?") [$(yes_no_hint)]:${NC} ")" confirm
        if ! is_yes "$confirm"; then
            log_info "$(msg "Aborted by user" "Прервано пользователем")"
            exit 0
        fi
    fi
}

# ── Parse arguments ──────────────────────────────────────────────────────────

require_arg() {
    if [[ $# -lt 2 || "$2" == --* ]]; then
        log_error "$(msg "Option $1 requires an argument" "Опции $1 нужен аргумент")"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lang)
                require_arg "$@"
                validate_language "$2"
                LANG_CODE="${2,,}"; shift 2 ;;
            --ram)
                require_arg "$@"
                RAM_TEMPLATE="$2"; HAS_INSTALL_OPTIONS=true; shift 2 ;;
            --swapfile-size)
                require_arg "$@"
                SWAPFILE_SIZE_MB="$2"; HAS_INSTALL_OPTIONS=true; shift 2 ;;
            --zram-percent)
                require_arg "$@"
                ZRAM_PERCENT="$2"; HAS_INSTALL_OPTIONS=true; shift 2 ;;
            --zram-algo)
                require_arg "$@"
                ZRAM_ALGO="$2"; ZRAM_ALGO_EXPLICIT=true; HAS_INSTALL_OPTIONS=true; shift 2 ;;
            --zram-priority)
                require_arg "$@"
                ZRAM_PRIORITY="$2"; HAS_INSTALL_OPTIONS=true; shift 2 ;;
            --swappiness)
                require_arg "$@"
                SWAPPINESS="$2"; HAS_INSTALL_OPTIONS=true; shift 2 ;;
            --yes)
                AUTO_YES=true; shift ;;
            --remove)
                ACTION="remove"; shift ;;
            --status)
                ACTION="status"; shift ;;
            -h|--help)
                usage ;;
            *)
                log_error "$(msg "Unknown option: $1" "Неизвестная опция: $1")"
                usage ;;
        esac
    done

    # Determine if we should run interactive wizard:
    # No install options and no --yes flag
    if [[ "$ACTION" == "install" && "$HAS_INSTALL_OPTIONS" != true && "$AUTO_YES" != true ]]; then
        INTERACTIVE=true
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    init_language
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
        log_info "$(msg "Template $RAM_TEMPLATE applied" "Шаблон $RAM_TEMPLATE применён")"
    else
        # Auto-detect template as a base; CLI values override matching fields.
        show_system_info
        log_info "$(msg "No RAM template specified, auto-detecting base settings from system RAM..." "Шаблон RAM не задан, автоматически выбираю базовые настройки по системной RAM...")"
        auto_detect_template
    fi

    # Ensure all values are set (fallback for any empty)
    ZRAM_ALGO="${ZRAM_ALGO:-zstd}"
    ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"

    # Validate all parameters before proceeding
    validate_all_params

    preflight_checks
    check_existing_swap
    show_plan
    check_zram_kernel_support
    ensure_zram_tools_installed
    setup_swapfile
    setup_zram
    setup_swappiness

    # Reload systemd to pick up fstab changes
    systemctl daemon-reload 2>/dev/null || true

    # Give swapon / zramswap.service a brief window to reach steady state
    # before verifying, otherwise /proc/swaps races against the just-issued
    # systemctl restart and verify_configuration sees stale "inactive" rows.
    wait_for_swap_active 10 || true

    verify_configuration

    log_section "$(msg "Setup complete! Verification:" "Настройка завершена! Проверка:")"
    show_status

    echo ""
    echo -e "${BOLD}${GREEN}$(msg "Done!" "Готово!")${NC} $(msg "Hybrid swap is configured and active." "Гибридный swap настроен и активен.")"
    echo -e "${DIM}$(msg "To check status later: sudo bash swap-setup.sh --status" "Проверить статус позже: sudo bash swap-setup.sh --lang ru --status")${NC}"
    echo -e "${DIM}$(msg "To remove:             sudo bash swap-setup.sh --remove" "Удалить настройку:       sudo bash swap-setup.sh --lang ru --remove")${NC}"
}

main "$@"
