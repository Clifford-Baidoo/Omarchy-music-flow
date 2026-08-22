#!/usr/bin/env bash
set -e

# ==============================================================================
# Omarchy Music Flow Plugin Uninstaller
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PLUGIN_ID="custom.media"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"

echo -e "${YELLOW}==>${NC} Uninstalling ${RED}Omarchy Music Flow${NC} [${PLUGIN_ID}]..."

# Remove plugin files
if [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
    echo -e "${BLUE}==>${NC} Removed plugin directory: ${TARGET_DIR}"
fi

# Remove from Omarchy shell configuration
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Removing ${PLUGIN_ID} from status bar..."
    omarchy bar remove "${PLUGIN_ID}" >/dev/null 2>&1 || true
    omarchy plugin disable "${PLUGIN_ID}" >/dev/null 2>&1 || true

    # Restore default omarchy.media plugin if desired
    omarchy plugin enable "omarchy.media" >/dev/null 2>&1 || true

    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Uninstall complete! Restored default media widget.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
