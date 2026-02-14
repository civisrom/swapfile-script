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

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "Run as root: sudo bash install.sh"
    echo -e "Or: ${BOLD}wget -qO- ${REPO_URL}/install.sh | sudo bash${NC}"
    exit 1
fi

# Check dependencies
for cmd in wget; do
    if ! command -v "$cmd" &>/dev/null; then
        log_info "Installing $cmd..."
        apt-get update -qq && apt-get install -y -qq "$cmd"
    fi
done

echo ""
echo -e "${BOLD}Downloading ${SCRIPT_NAME}...${NC}"
wget -qO "${TMP_DIR}/${SCRIPT_NAME}" "${REPO_URL}/${SCRIPT_NAME}"

if [[ ! -s "${TMP_DIR}/${SCRIPT_NAME}" ]]; then
    log_error "Download failed"
    exit 1
fi

# Install to system path
cp "${TMP_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SCRIPT_NAME}"
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
log_info "Installed to ${INSTALL_DIR}/${SCRIPT_NAME}"
echo -e "${YELLOW}You can run it later as:${NC} sudo swap-setup.sh [options]"
echo ""

# Run the script, pass through any extra arguments
exec bash "${INSTALL_DIR}/${SCRIPT_NAME}" "$@"
