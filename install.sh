#!/usr/bin/env bash
set -e

# ==============================================================================
# Omarchy Music Flow Plugin Installer
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="$(whoami)"
PLUGIN_ID="${USER_NAME}.media"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"

echo -e "${BLUE}==>${NC} Installing ${GREEN}Omarchy Music Flow${NC} (${PLUGIN_ID})..."

# Create plugins folder if needed
mkdir -p "${TARGET_DIR}"

# Copy plugin files
cp -f "${SCRIPT_DIR}/BarWidget.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/Service.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/MediaModel.js" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/manifest.json" "${TARGET_DIR}/"

# Update manifest ID and moduleName if username differs
sed -i "s/\"id\": \".*\"/\"id\": \"${PLUGIN_ID}\"/" "${TARGET_DIR}/manifest.json"
sed -i "s/moduleName: \".*\"/moduleName: \"${PLUGIN_ID}\"/" "${TARGET_DIR}/BarWidget.qml"
sed -i "s/serviceFor(\".*\.media\")/serviceFor(\"${PLUGIN_ID}\")/" "${TARGET_DIR}/BarWidget.qml"

echo -e "${BLUE}==>${NC} Plugin files installed to ${TARGET_DIR}"

# Enable widget in omarchy shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Enabling ${PLUGIN_ID} in top bar..."
    omarchy plugin enable "${PLUGIN_ID}" >/dev/null 2>&1 || true
    omarchy bar move "${PLUGIN_ID}" --section left --after omarchy.workspaces >/dev/null 2>&1 || true
    echo -e "${BLUE}==>${NC} Restarting Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}==> Installation complete! Music Flow is now active on your bar.${NC}"
else
    echo -e "${YELLOW}==> Note: 'omarchy' CLI not found. Please restart quickshell/omarchy-shell manually.${NC}"
fi
