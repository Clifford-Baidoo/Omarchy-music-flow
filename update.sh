#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Omarchy Music Flow Plugin Updater
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Single source of truth for every id this script and the config-writer below
# touch, so the plugin id never has to be duplicated (and drift) across files.
PLUGIN_ID="custom.media"
STOCK_PLUGIN_ID="omarchy.media"
BAR_SECTION="left"
BAR_ANCHOR_ID="omarchy.workspaces"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
LEGACY_DIR="${HOME}/.config/omarchy/plugins/nek0.media"

MPV_MPRIS_CANDIDATES=(
    "/usr/lib/mpv-mpris/mpris.so"
    "/etc/mpv/scripts/mpris.so"
)

echo -e "${BLUE}==>${NC} Synchronizing ${GREEN}Omarchy Music Flow${NC} [${PLUGIN_ID}]..."

# 1. Ensure target plugin directory exists
mkdir -p "${TARGET_DIR}"

# 2. Clean legacy plugin folder if it exists
if [ -d "${LEGACY_DIR}" ]; then
    echo -e "${BLUE}==>${NC} Cleaning legacy plugin directory: ${LEGACY_DIR}"
    rm -rf "${LEGACY_DIR}"
fi

# 3. Copy updated plugin files
cp -f "${SCRIPT_DIR}/BarWidget.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/Service.qml" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/MediaModel.js" "${TARGET_DIR}/"
cp -f "${SCRIPT_DIR}/manifest.json" "${TARGET_DIR}/"

echo -e "${BLUE}==>${NC} Plugin files synchronized to: ${TARGET_DIR}"

# 4. Catch manifest/schema problems before they get wired into the bar
if command -v omarchy >/dev/null 2>&1; then
    if ! omarchy plugin validate "${TARGET_DIR}"; then
        echo -e "${RED}==> Error:${NC} updated plugin failed validation, aborting before touching your bar config." >&2
        exit 1
    fi
fi

# 5. Enable MPV MPRIS script if mpv is installed
if command -v mpv >/dev/null 2>&1; then
    mkdir -p "${HOME}/.config/mpv/scripts"
    for candidate in "${MPV_MPRIS_CANDIDATES[@]}"; do
        if [ -f "${candidate}" ]; then
            ln -sf "${candidate}" "${HOME}/.config/mpv/scripts/mpris.so"
            echo -e "${BLUE}==>${NC} Verified MPV MPRIS integration."
            break
        fi
    done
fi

# 6. Verify and update status bar layout in ~/.config/omarchy/shell.json
echo -e "${BLUE}==>${NC} Verifying status bar configuration in ~/.config/omarchy/shell.json..."
PLUGIN_ID="${PLUGIN_ID}" STOCK_PLUGIN_ID="${STOCK_PLUGIN_ID}" \
BAR_SECTION="${BAR_SECTION}" BAR_ANCHOR_ID="${BAR_ANCHOR_ID}" \
python3 - << 'PYEOF'
import json, os

plugin_id = os.environ["PLUGIN_ID"]
stock_plugin_id = os.environ["STOCK_PLUGIN_ID"]
section = os.environ["BAR_SECTION"]
anchor_id = os.environ["BAR_ANCHOR_ID"]

config_path = os.path.expanduser("~/.config/omarchy/shell.json")
if os.path.isfile(config_path):
    # No blanket try/except here on purpose: a swallowed failure would let this
    # script print "Update complete!" even when shell.json was left untouched -
    # exactly the silent-success bug this plugin's install/update flow has
    # already been bitten by once. Let a genuine failure (corrupt JSON,
    # permission denied) abort loudly instead.
    with open(config_path, "r") as f:
        config = json.load(f)

    bar = config.setdefault("bar", {})
    layout = bar.setdefault("layout", {})

    # 1. Clean any duplicate or old media widgets from all sections
    for sec in ["left", "center", "right"]:
        if sec in layout and isinstance(layout[sec], list):
            layout[sec] = [
                item for item in layout[sec]
                if not (isinstance(item, dict) and (item.get("id") in [plugin_id, stock_plugin_id] or str(item.get("id", "")).endswith(".media")))
            ]

    # 2. Get the target section AFTER cleaning
    target = layout.setdefault(section, [])

    # 3. Insert plugin_id after the anchor widget (or append if anchor not found)
    inserted = False
    for i, item in enumerate(target):
        if isinstance(item, dict) and item.get("id") == anchor_id:
            target.insert(i + 1, {"id": plugin_id})
            inserted = True
            break

    if not inserted:
        target.append({"id": plugin_id})

    # 4. Ensure the stock media plugin remains disabled
    disabled = config.setdefault("disabledPlugins", [])
    if stock_plugin_id not in disabled:
        disabled.append(stock_plugin_id)

    # Write atomically (temp file + rename) so a crash or power loss mid-write
    # can't leave the user's entire shell.json - not just this plugin's entry -
    # truncated or corrupted.
    tmp_path = config_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(config, f, indent=2)
    os.replace(tmp_path, config_path)

    print(f"Layout verified: {plugin_id} is active in shell.json.")
PYEOF

# 7. Restart Omarchy Shell to apply updates
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell with updated plugin..."
    omarchy restart shell
    echo -e "${GREEN}✔ Update complete! Music Flow is up to date and running.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
