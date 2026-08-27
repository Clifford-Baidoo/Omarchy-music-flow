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
python3 - << 'PYEOF'
import json, os

plugin_id = os.environ["PLUGIN_ID"]
stock_plugin_id = os.environ["STOCK_PLUGIN_ID"]
section = os.environ["BAR_SECTION"]
anchor_id = os.environ["BAR_ANCHOR_ID"]

config_path = os.path.expanduser("~/.config/omarchy/shell.json")
if os.path.isfile(config_path):
    # No blanket try/except here on purpose: a swallowed failure would let this
    # script print "Uninstall complete! Restored default media widget." even
    # when shell.json was left untouched - exactly the silent-success bug this
    # plugin's install/uninstall flow has already been bitten by once. Let a
    # genuine failure (corrupt JSON, permission denied) abort loudly instead.
    with open(config_path, "r") as f:
        config = json.load(f)

    layout = config.get("bar", {}).get("layout", {})
    for sec in ["left", "center", "right"]:
        if sec in layout and isinstance(layout[sec], list):
            layout[sec] = [item for item in layout[sec] if not (isinstance(item, dict) and item.get("id") == plugin_id)]

    # A bar-widget's "enabled" state is derived from its presence in the
    # layout, not from disabledPlugins - so removing custom.media without
    # putting the stock widget back left the user with no media widget
    # at all, despite disabledPlugins being cleared.
    target = layout.setdefault(section, [])
    if not any(isinstance(item, dict) and item.get("id") == stock_plugin_id for item in target):
        inserted = False
        for i, item in enumerate(target):
            if isinstance(item, dict) and item.get("id") == anchor_id:
                target.insert(i + 1, {"id": stock_plugin_id})
                inserted = True
                break
        if not inserted:
            target.append({"id": stock_plugin_id})

    disabled = config.get("disabledPlugins", [])
    if stock_plugin_id in disabled:
        disabled.remove(stock_plugin_id)

    # Write atomically (temp file + rename) so a crash or power loss mid-write
    # can't leave the user's entire shell.json - not just this plugin's entry -
    # truncated or corrupted.
    tmp_path = config_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(config, f, indent=2)
    os.replace(tmp_path, config_path)
PYEOF

# Reload Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Uninstall complete! Restored default media widget.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
