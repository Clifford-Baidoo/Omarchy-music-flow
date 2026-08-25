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

echo -e "${BLUE}==>${NC} Updating ${GREEN}Omarchy Music Flow${NC} [${PLUGIN_ID}]..."

# 1. Pull latest git commits if running inside a git repository
if [ -d "${SCRIPT_DIR}/.git" ]; then
    echo -e "${BLUE}==>${NC} Fetching latest updates from GitHub repository..."
    cd "${SCRIPT_DIR}"
    if git pull --rebase 2>/dev/null || git pull 2>/dev/null; then
        echo -e "${GREEN}✔ Repository updated to latest version.${NC}"
    else
        echo -e "${YELLOW}==> Warning: git pull encountered conflicts or offline mode; continuing with local files.${NC}"
        git rebase --abort >/dev/null 2>&1 || true
        git merge --abort >/dev/null 2>&1 || true
    fi

    # A failed/partial pull can leave conflict markers in tracked files. Never
    # deploy that into a live, running shell as executable QML/JS - refuse and
    # bail instead of silently shipping broken or half-merged code.
    if git status --porcelain=v1 --untracked-files=no | grep -qE '^(UU|AA|DD|AU|UA|UD|DU) '; then
        echo -e "${RED}==> Error:${NC} repository has unresolved merge conflicts after 'git pull'." >&2
        echo -e "    Resolve them manually in ${SCRIPT_DIR} before re-running update.sh." >&2
        exit 1
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

# 5. Catch manifest/schema problems before they get wired into the bar
if command -v omarchy >/dev/null 2>&1; then
    if ! omarchy plugin validate "${TARGET_DIR}"; then
        echo -e "${RED}==> Error:${NC} updated plugin failed validation, aborting before touching your bar config." >&2
        exit 1
    fi
fi

# 6. Enable MPV MPRIS script if mpv is installed
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

# 7. Verify and update status bar layout in ~/.config/omarchy/shell.json
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
    try:
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

        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)

        print(f"Layout verified: {plugin_id} is active in shell.json.")
    except Exception as e:
        print(f"Note: Could not update shell.json automatically: {e}")
PYEOF

# 8. Restart Omarchy Shell to apply updates
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell with updated plugin..."
    omarchy restart shell
    echo -e "${GREEN}✔ Update complete! Music Flow is up to date and running.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
