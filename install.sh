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

# 1. Ensure target plugin directory exists
mkdir -p "${TARGET_DIR}"

# 2. Copy all required plugin files
cp -f "${SCRIPT_DIR}/BarWidget.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/Service.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/MediaModel.js" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/manifest.json" "${TARGET_DIR}/"

echo -e "${BLUE}==>${NC} Plugin files installed to: ${TARGET_DIR}"

# 3. Enable MPV MPRIS script if mpv is installed (enables Seanime, MPV, and anime video player support)
if command -v mpv >/dev/null 2>&1; then
    mkdir -p "${HOME}/.config/mpv/scripts"
    if [ -f "/usr/lib/mpv-mpris/mpris.so" ]; then
        ln -sf "/usr/lib/mpv-mpris/mpris.so" "${HOME}/.config/mpv/scripts/mpris.so"
        echo -e "${BLUE}==>${NC} Enabled MPV MPRIS integration for video & Seanime playback."
    elif [ -f "/etc/mpv/scripts/mpris.so" ]; then
        ln -sf "/etc/mpv/scripts/mpris.so" "${HOME}/.config/mpv/scripts/mpris.so"
        echo -e "${BLUE}==>${NC} Enabled MPV MPRIS integration for video & Seanime playback."
    fi
fi

# 4. Safely configure Omarchy shell.json layout
echo -e "${BLUE}==>${NC} Configuring status bar layout in ~/.config/omarchy/shell.json..."
python3 - << 'PYEOF'
import json, os

config_path = os.path.expanduser("~/.config/omarchy/shell.json")
default_paths = [
    os.path.expanduser("~/.config/omarchy/shell.json"),
    os.path.expanduser(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy") + "/config/omarchy/shell.json"),
    "/usr/share/omarchy/config/omarchy/shell.json",
]

config = None
if os.path.isfile(config_path):
    try:
        with open(config_path, "r") as f:
            config = json.load(f)
    except Exception:
        pass

if not config:
    for dp in default_paths:
        if dp and os.path.isfile(dp):
            try:
                with open(dp, "r") as f:
                    config = json.load(f)
                    break
            except Exception:
                pass

if not config or not isinstance(config, dict):
    config = {
        "version": 1,
        "bar": {
            "position": "top",
            "transparent": True,
            "layout": {
                "left": [{"id": "omarchy.menu"}, {"id": "omarchy.workspaces"}],
                "center": [{"id": "omarchy.clock"}],
                "right": [{"id": "omarchy.tray"}, {"id": "omarchy.network"}, {"id": "omarchy.audio"}]
            }
        }
    }

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

# 4. Disable stock omarchy.media to prevent duplicate service collision
disabled = config.setdefault("disabledPlugins", [])
if "omarchy.media" not in disabled:
    disabled.append("omarchy.media")

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

print("Status bar layout updated: custom.media successfully registered in shell.json.")
PYEOF

# 5. Restart Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Installation successful! Music Flow is now active on your bar.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
