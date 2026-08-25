#!/usr/bin/env bash
set -e

# ==============================================================================
# Omarchy Music Flow Plugin Updater
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="custom.media"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
LEGACY_DIR="${HOME}/.config/omarchy/plugins/nek0.media"

echo -e "${BLUE}==>${NC} Updating ${GREEN}Omarchy Music Flow${NC} [${PLUGIN_ID}]..."

# 1. Pull latest git commits if running inside a git repository
if [ -d "${SCRIPT_DIR}/.git" ]; then
    echo -e "${BLUE}==>${NC} Fetching latest updates from GitHub repository..."
    cd "${SCRIPT_DIR}"
    if git pull --rebase 2>/dev/null || git pull; then
        echo -e "${GREEN}✔ Repository updated to latest version.${NC}"
    else
        echo -e "${YELLOW}==> Warning: git pull encountered conflicts or offline mode; continuing with local files.${NC}"
    fi
fi

# 2. Ensure target plugin directory exists
mkdir -p "${TARGET_DIR}"

# 3. Clean legacy plugin folder if it exists
if [ -d "${LEGACY_DIR}" ]; then
    echo -e "${BLUE}==>${NC} Cleaning legacy plugin directory: ${LEGACY_DIR}"
    rm -rf "${LEGACY_DIR}"
fi

# 4. Copy updated plugin files
cp -f "${SCRIPT_DIR}/BarWidget.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/Service.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/MediaModel.js" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/manifest.json" "${TARGET_DIR}/"

echo -e "${BLUE}==>${NC} Plugin files synchronized to: ${TARGET_DIR}"

# 5. Enable MPV MPRIS script if mpv is installed
if command -v mpv >/dev/null 2>&1; then
    mkdir -p "${HOME}/.config/mpv/scripts"
    if [ -f "/usr/lib/mpv-mpris/mpris.so" ]; then
        ln -sf "/usr/lib/mpv-mpris/mpris.so" "${HOME}/.config/mpv/scripts/mpris.so"
        echo -e "${BLUE}==>${NC} Verified MPV MPRIS integration."
    elif [ -f "/etc/mpv/scripts/mpris.so" ]; then
        ln -sf "/etc/mpv/scripts/mpris.so" "${HOME}/.config/mpv/scripts/mpris.so"
        echo -e "${BLUE}==>${NC} Verified MPV MPRIS integration."
    fi
fi

# 6. Verify and update status bar layout in ~/.config/omarchy/shell.json
echo -e "${BLUE}==>${NC} Verifying status bar configuration in ~/.config/omarchy/shell.json..."
python3 - << 'PYEOF'
import json, os

config_path = os.path.expanduser("~/.config/omarchy/shell.json")
if os.path.isfile(config_path):
    try:
        with open(config_path, "r") as f:
            config = json.load(f)
        
        bar = config.setdefault("bar", {})
        layout = bar.setdefault("layout", {})
        plugin_id = "custom.media"

        # 1. Clean any duplicate or old media widgets from all sections
        for sec in ["left", "center", "right"]:
            if sec in layout and isinstance(layout[sec], list):
                layout[sec] = [
                    item for item in layout[sec] 
                    if not (isinstance(item, dict) and (item.get("id") in [plugin_id, "omarchy.media"] or str(item.get("id", "")).endswith(".media")))
                ]

        # 2. Get the left section AFTER cleaning
        left = layout.setdefault("left", [])

        # 3. Insert custom.media after omarchy.workspaces (or append if workspaces not in left)
        inserted = False
        for i, item in enumerate(left):
            if isinstance(item, dict) and item.get("id") == "omarchy.workspaces":
                left.insert(i + 1, {"id": plugin_id})
                inserted = True
                break

        if not inserted:
            left.append({"id": plugin_id})

        # 4. Ensure stock omarchy.media remains disabled
        disabled = config.setdefault("disabledPlugins", [])
        if "omarchy.media" not in disabled:
            disabled.append("omarchy.media")

        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)

        print("Layout verified: custom.media is active in shell.json.")
    except Exception as e:
        print(f"Note: Could not update shell.json automatically: {e}")
PYEOF

# 7. Restart Omarchy Shell to apply updates
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell with updated plugin..."
    omarchy restart shell
    echo -e "${GREEN}✔ Update complete! Music Flow is up to date and running.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
