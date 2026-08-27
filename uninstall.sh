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
    # script print "Uninstall complete! Restored default media widget." even
    # when shell.json was left untouched - exactly the silent-success bug this
    # plugin's install/uninstall flow has already been bitten by once. Let a
    # genuine failure (corrupt JSON, permission denied, or a symlinked config)
    # abort loudly instead.
    config = _read_json_no_follow(config_path)

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

    _atomic_write_json(config_path, config)
PYEOF

# Reload Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Uninstall complete! Restored default media widget.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
