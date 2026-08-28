#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Omarchy Music Flow Plugin Uninstaller
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep these in lockstep with install.sh - both scripts must agree on ids.
PLUGIN_ID="custom.media"
STOCK_PLUGIN_ID="omarchy.media"
BAR_SECTION="left"
BAR_ANCHOR_ID="omarchy.workspaces"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"

echo -e "${YELLOW}==>${NC} Uninstalling ${RED}Omarchy Music Flow${NC} [${PLUGIN_ID}]..."

# Back up the plugin directory instead of deleting it outright, in case this
# was run by mistake or the user wants their local edits back.
if [ -d "${TARGET_DIR}" ]; then
    BACKUP_DIR="$(dirname "${TARGET_DIR}")/.$(basename "${TARGET_DIR}").bak.$(date +%Y%m%d%H%M%S)"
    mv "${TARGET_DIR}" "${BACKUP_DIR}"
    echo -e "${BLUE}==>${NC} Removed plugin directory: ${TARGET_DIR}"
    echo -e "${BLUE}==>${NC} Backup saved to: ${BACKUP_DIR}"
fi

# Clean up configuration in shell.json
PLUGIN_ID="${PLUGIN_ID}" STOCK_PLUGIN_ID="${STOCK_PLUGIN_ID}" \
BAR_SECTION="${BAR_SECTION}" BAR_ANCHOR_ID="${BAR_ANCHOR_ID}" \
python3 "${SCRIPT_DIR}/scripts/configure_bar.py" --action disable

# Reload Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Uninstall complete! Restored default media widget.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
