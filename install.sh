#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Omarchy Music Flow Plugin Installer
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

MPV_MPRIS_CANDIDATES=(
    "/usr/lib/mpv-mpris/mpris.so"
    "/etc/mpv/scripts/mpris.so"
)

echo -e "${BLUE}==>${NC} Installing ${GREEN}Omarchy Music Flow${NC} [${PLUGIN_ID}]..."

# 1. Ensure target plugin directory exists
mkdir -p "${TARGET_DIR}"

# 2. Copy all required plugin files
#
# Routed through a fresh mktemp name + mv instead of `cp -f src dest`
# directly: `cp -f` follows a symlink at the destination and overwrites
# whatever it points to (verified), so a same-user process that plants one
# at e.g. TARGET_DIR/BarWidget.qml once would get it silently and
# deterministically corrupted, no race required, on every install. `mv`
# (rename) never follows a symlink at the destination - it replaces the
# directory entry itself - so landing the new content there first and
# swapping it into place closes this off.
PLUGIN_TMP_FILES=()
cleanup_plugin_tmp_files() {
    local f
    for f in "${PLUGIN_TMP_FILES[@]:-}"; do
        [ -n "${f}" ] && rm -f "${f}"
    done
}
trap cleanup_plugin_tmp_files EXIT

install_plugin_file() {
    local src="$1" name="$2" tmp
    tmp=$(mktemp -p "${TARGET_DIR}" ".${name}.XXXXXX")
    PLUGIN_TMP_FILES+=("${tmp}")
    cp -f "${src}" "${tmp}"
    chmod --reference="${src}" "${tmp}"
    mv -f "${tmp}" "${TARGET_DIR}/${name}"
}
install_plugin_file "${SCRIPT_DIR}/BarWidget.qml" "BarWidget.qml"
install_plugin_file "${SCRIPT_DIR}/Service.qml" "Service.qml"
install_plugin_file "${SCRIPT_DIR}/MediaModel.js" "MediaModel.js"
install_plugin_file "${SCRIPT_DIR}/manifest.json" "manifest.json"

echo -e "${BLUE}==>${NC} Plugin files installed to: ${TARGET_DIR}"

# 3. Catch manifest/schema problems before they get wired into the bar
if command -v omarchy >/dev/null 2>&1; then
    if ! omarchy plugin validate "${TARGET_DIR}"; then
        echo -e "${RED}==> Error:${NC} plugin failed validation, aborting before touching your bar config." >&2
        exit 1
    fi
fi

# 4. Enable MPV MPRIS script if mpv is installed (enables Seanime, MPV, and anime video player support)
if command -v mpv >/dev/null 2>&1; then
    mkdir -p "${HOME}/.config/mpv/scripts"
    for candidate in "${MPV_MPRIS_CANDIDATES[@]}"; do
        if [ -f "${candidate}" ]; then
            ln -sf "${candidate}" "${HOME}/.config/mpv/scripts/mpris.so"
            echo -e "${BLUE}==>${NC} Enabled MPV MPRIS integration for video & Seanime playback."
            break
        fi
    done
fi

# 5. Safely configure Omarchy shell.json layout
echo -e "${BLUE}==>${NC} Configuring status bar layout in ~/.config/omarchy/shell.json..."
PLUGIN_ID="${PLUGIN_ID}" STOCK_PLUGIN_ID="${STOCK_PLUGIN_ID}" \
BAR_SECTION="${BAR_SECTION}" BAR_ANCHOR_ID="${BAR_ANCHOR_ID}" \
python3 "${SCRIPT_DIR}/scripts/configure_bar.py" --action enable --bootstrap

# 6. Restart Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Installation successful! Music Flow is now active on your bar.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
