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
python3 - << 'PYEOF'
import json, os, stat, tempfile

plugin_id = os.environ["PLUGIN_ID"]
stock_plugin_id = os.environ["STOCK_PLUGIN_ID"]
section = os.environ["BAR_SECTION"]
anchor_id = os.environ["BAR_ANCHOR_ID"]


def _open_no_follow(path, max_bytes=2 * 1024 * 1024):
    # O_NOFOLLOW rejects a symlinked config file outright instead of
    # transparently following it, so there's no check-then-open window
    # between an isfile() check and the actual read for a same-user process
    # to swap a symlink into. O_NONBLOCK stops a planted FIFO from blocking
    # open() indefinitely - the same failure mode already fixed in the
    # artwork-fetch path (Service.qml/BarWidget.qml); it's a no-op for the
    # regular file this is required to be. After opening, fstat the fd (not
    # the path, which could have changed again) to reject anything that
    # isn't a bounded-size regular file before it's ever handed to
    # json.load().
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise OSError(f"refusing to read non-regular file at {path}")
        if st.st_size > max_bytes:
            raise OSError(f"refusing to read oversized config at {path} ({st.st_size} bytes)")
    except BaseException:
        os.close(fd)
        raise
    return os.fdopen(fd, "r")


def _atomic_write_json(path, data):
    # tempfile.mkstemp creates the temp file with O_CREAT|O_EXCL in one
    # syscall (mode 0600, unpredictable random suffix) in the *same*
    # directory as the target - no predictable ".tmp" name and no separate
    # check-then-open window for another same-user process to pre-plant a
    # symlink there and redirect this write into an arbitrary file. fsync
    # before the rename so a crash immediately after writing can't lose the
    # data; os.replace is still the atomic swap into the final path.
    directory = os.path.dirname(path) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=".shell.json.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            try:
                mode = stat.S_IMODE(os.stat(path).st_mode)
                os.fchmod(f.fileno(), mode)
            except FileNotFoundError:
                pass
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise


config_path = os.path.expanduser("~/.config/omarchy/shell.json")
default_paths = [
    config_path,
    os.path.join(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"), "config/omarchy/shell.json"),
    "/usr/share/omarchy/config/omarchy/shell.json",
]

config = None
if os.path.isfile(config_path):
    try:
        with _open_no_follow(config_path) as f:
            config = json.load(f)
    except Exception:
        pass

if not config:
    for dp in default_paths:
        if dp and os.path.isfile(dp):
            try:
                with _open_no_follow(dp) as f:
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
                "left": [{"id": "omarchy.menu"}, {"id": anchor_id}],
                "center": [{"id": "omarchy.clock"}],
                "right": [{"id": "omarchy.tray"}, {"id": "omarchy.network"}, {"id": "omarchy.audio"}]
            }
        }
    }

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

# 4. Disable the stock media plugin to prevent duplicate service collision
disabled = config.setdefault("disabledPlugins", [])
if stock_plugin_id not in disabled:
    disabled.append(stock_plugin_id)

os.makedirs(os.path.dirname(config_path), exist_ok=True)
_atomic_write_json(config_path, config)

print(f"Status bar layout updated: {plugin_id} successfully registered in shell.json.")
PYEOF

# 6. Restart Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Installation successful! Music Flow is now active on your bar.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
