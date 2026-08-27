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
#
# Routed through a fresh mktemp name + mv instead of `cp -f src dest`
# directly: `cp -f` follows a symlink at the destination and overwrites
# whatever it points to (verified), so a same-user process that plants one
# at e.g. TARGET_DIR/BarWidget.qml once would get it silently and
# deterministically corrupted, no race required, on every update. `mv`
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
import json, os, stat, tempfile

plugin_id = os.environ["PLUGIN_ID"]
stock_plugin_id = os.environ["STOCK_PLUGIN_ID"]
section = os.environ["BAR_SECTION"]
anchor_id = os.environ["BAR_ANCHOR_ID"]


def _open_no_follow(path, max_bytes=2 * 1024 * 1024):
    # O_NOFOLLOW rejects a symlinked config file outright instead of
    # transparently following it, so there's no check-then-open window
    # between the isfile() check below and the actual read for a same-user
    # process to swap a symlink into. O_NONBLOCK stops a planted FIFO from
    # blocking open() indefinitely - the same failure mode already fixed in
    # the artwork-fetch path (Service.qml/BarWidget.qml); it's a no-op for
    # the regular file this is required to be. After opening, fstat the fd
    # (not the path, which could have changed again) to reject anything
    # that isn't a bounded-size regular file before it's ever handed to
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
    return fd


def _read_json_no_follow(path, max_bytes=2 * 1024 * 1024):
    # The fstat-based size check in _open_no_follow only holds at the instant
    # it runs. The fd stays open on the same regular file afterward (not a
    # private copy), so a same-user process can still append to it and grow
    # it past max_bytes before the read finishes; json.load() has no byte
    # limit of its own and would read straight to EOF. Read at most
    # max_bytes + 1 bytes directly from the validated fd instead, so an
    # oversized concurrent grow is caught by the read loop rather than
    # trusted to a stale size check, then parse only that bounded buffer.
    fd = _open_no_follow(path, max_bytes)
    try:
        limit = max_bytes + 1
        chunks = []
        total = 0
        while total < limit:
            chunk = os.read(fd, min(65536, limit - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > max_bytes:
            raise OSError(f"refusing to read oversized config at {path} (>{max_bytes} bytes)")
    finally:
        os.close(fd)
    return json.loads(b"".join(chunks))


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
if os.path.isfile(config_path):
    # No blanket try/except here on purpose: a swallowed failure would let this
    # script print "Update complete!" even when shell.json was left untouched -
    # exactly the silent-success bug this plugin's install/update flow has
    # already been bitten by once. Let a genuine failure (corrupt JSON,
    # permission denied, or a symlinked config) abort loudly instead.
    config = _read_json_no_follow(config_path)

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

    _atomic_write_json(config_path, config)

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
