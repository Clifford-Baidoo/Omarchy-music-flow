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

# Remove plugin directory
if [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
    echo -e "${BLUE}==>${NC} Removed plugin directory: ${TARGET_DIR}"
fi

# Clean up configuration in shell.json
python3 - << 'PYEOF'
import json, os

config_path = os.path.expanduser("~/.config/omarchy/shell.json")
if os.path.isfile(config_path):
    try:
        with open(config_path, "r") as f:
            config = json.load(f)
        
        layout = config.get("bar", {}).get("layout", {})
        for sec in ["left", "center", "right"]:
            if sec in layout and isinstance(layout[sec], list):
                layout[sec] = [item for item in layout[sec] if not (isinstance(item, dict) and item.get("id") == "custom.media")]
        
        disabled = config.get("disabledPlugins", [])
        if "omarchy.media" in disabled:
            disabled.remove("omarchy.media")
            
        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)
    except Exception:
        pass
PYEOF

# Reload Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Uninstall complete! Restored default media widget.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
