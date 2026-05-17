#!/bin/bash
#
# install.sh — Download and run swap-setup.sh
# Usage: wget -qO- https://raw.githubusercontent.com/civisrom/swapfile-script/main/install.sh | sudo bash
#
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/civisrom/swapfile-script/main"
SCRIPT_NAME="swap-setup.sh"
INSTALL_DIR="/usr/local/sbin"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

install_package() {
    local package="$1"

    if ! command -v apt-get &>/dev/null; then
        log_error "apt-get not found. This installer supports Debian/Ubuntu systems."
        exit 1
    fi

    log_info "Installing $package..."
    apt-get update -qq
    apt-get install -y -qq "$package"
}

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "Run as root: sudo bash install.sh"
    echo -e "Or: ${BOLD}wget -qO- ${REPO_URL}/install.sh | sudo bash${NC}"
    exit 1
fi

# Check dependencies
if ! command -v wget &>/dev/null; then
    install_package wget
fi

echo ""
echo -e "${BOLD}Downloading ${SCRIPT_NAME}...${NC}"
wget -qO "${TMP_DIR}/${SCRIPT_NAME}" "${REPO_URL}/${SCRIPT_NAME}"

if [[ ! -s "${TMP_DIR}/${SCRIPT_NAME}" ]]; then
    log_error "Download failed"
    exit 1
fi

if ! bash -n "${TMP_DIR}/${SCRIPT_NAME}"; then
    log_error "Downloaded ${SCRIPT_NAME} failed bash syntax validation"
    exit 1
fi

# Install to system path
mkdir -p "$INSTALL_DIR"
install -m 0755 "${TMP_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SCRIPT_NAME}"
log_info "Installed to ${INSTALL_DIR}/${SCRIPT_NAME}"
echo -e "${YELLOW}You can run it later as:${NC} sudo swap-setup.sh [options]"
echo ""

# Run the script, restoring stdin from terminal (needed when piped via wget|bash)
if [[ -e /dev/tty ]]; then
    exec bash "${INSTALL_DIR}/${SCRIPT_NAME}" "$@" </dev/tty
else
    log_info "No TTY detected (container/CI). Script installed but not started."
    echo -e "${BOLD}Run manually:${NC} sudo swap-setup.sh"
    echo -e "${BOLD}Or non-interactive:${NC} sudo swap-setup.sh --ram 2"
fi
