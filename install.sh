#!/usr/bin/env bash
set -e

# ==============================================================================
# Omarchy Music Flow Plugin Installer
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="custom.media"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"

echo -e "${BLUE}==>${NC} Installing ${GREEN}Omarchy Music Flow${NC} [${PLUGIN_ID}]..."

# Ensure target plugin directory exists
mkdir -p "${TARGET_DIR}"

# Copy all required plugin files
cp -f "${SCRIPT_DIR}/BarWidget.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/Service.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/MediaModel.js" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/manifest.json" "${TARGET_DIR}/"

echo -e "${BLUE}==>${NC} Plugin installed to: ${TARGET_DIR}"

# Configure Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Enabling ${PLUGIN_ID} in Omarchy status bar..."
    omarchy plugin enable "${PLUGIN_ID}" >/dev/null 2>&1 || true
    omarchy bar move "${PLUGIN_ID}" --section left --after omarchy.workspaces >/dev/null 2>&1 || true

    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Installation successful! Music Flow is now active on your bar.${NC}"
else
    echo -e "${YELLOW}==> Note: 'omarchy' CLI was not found in PATH. Please restart omarchy-shell manually.${NC}"
fi
