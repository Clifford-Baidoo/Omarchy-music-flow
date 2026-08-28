#!/usr/bin/env python3
"""Shared shell.json bar-layout editor for install.sh, update.sh and uninstall.sh.

This used to be pasted as a near-identical Python heredoc in all three
scripts. Keeping one copy means a fix here (security or otherwise) applies
to install/update/uninstall at once, instead of relying on remembering to
port it into three files - the exact kind of drift that caused this plugin's
original stale-template-id bug.

Invocation contract (unchanged from the old heredocs): PLUGIN_ID,
STOCK_PLUGIN_ID, BAR_SECTION and BAR_ANCHOR_ID are read from the environment
so the calling shell script remains the single source of truth for those
ids; --action selects enable (install/update) or disable (uninstall); and
--bootstrap (install only) allows building a default shell.json from scratch
when none exists yet.
"""
import argparse
import json
import os
import stat
import tempfile


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
    return fd, stat.S_IMODE(st.st_mode)


def _read_json_no_follow(path, max_bytes=2 * 1024 * 1024):
    # The fstat-based size check in _open_no_follow only holds at the instant
    # it runs. The fd stays open on the same regular file afterward (not a
    # private copy), so a same-user process can still append to it and grow
    # it past max_bytes before the read finishes; json.load() has no byte
    # limit of its own and would read straight to EOF. Read at most
    # max_bytes + 1 bytes directly from the validated fd instead, so an
    # oversized concurrent grow is caught by the read loop rather than
    # trusted to a stale size check, then parse only that bounded buffer.
    fd, mode = _open_no_follow(path, max_bytes)
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
    # Decode as UTF-8 explicitly rather than letting json.loads() auto-detect
    # UTF-8/16/32 from a BOM/null-byte pattern (its default behavior on a bytes
    # input) - shell.json is always written as UTF-8 by _atomic_write_json below,
    # so this should be the only encoding ever expected here, and a mismatch
    # should fail loudly instead of being silently reinterpreted.
    # mode is returned alongside the parsed data so a caller writing back to
    # this same path can fchmod() the fd it already validated, instead of
    # doing a second, pathname-based os.stat() at write time that would just
    # follow a symlink planted at path in the meantime (see _atomic_write_json).
    return json.loads(b"".join(chunks).decode("utf-8")), mode


def _atomic_write_json(path, data, mode=None):
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
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            if mode is not None:
                # Caller already validated `path` via _open_no_follow and
                # captured its mode from that fd - reuse it instead of a
                # fresh os.stat(path) here, which would follow a symlink if
                # one had since been planted at path (harmless either way,
                # since os.replace() below never follows one, but there's no
                # reason to make a pathname-based lookup when an fd-sourced
                # value is already in hand).
                os.fchmod(f.fileno(), mode)
            else:
                # No prior read of this exact path (e.g. install.sh bootstrapping
                # config_path from a different fallback file, or config_path not
                # existing yet) - best effort only, and a missing target is fine.
                try:
                    existing_mode = stat.S_IMODE(os.stat(path).st_mode)
                    os.fchmod(f.fileno(), existing_mode)
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


def _default_config(anchor_id):
    return {
        "version": 1,
        "bar": {
            "position": "top",
            "transparent": True,
            "layout": {
                "left": [{"id": "omarchy.menu"}, {"id": anchor_id}],
                "center": [{"id": "omarchy.clock"}],
                "right": [{"id": "omarchy.tray"}, {"id": "omarchy.network"}, {"id": "omarchy.audio"}],
            },
        },
    }


def enable(plugin_id, stock_plugin_id, section, anchor_id, config_path, bootstrap):
    if bootstrap:
        # Installer: shell.json may not exist yet, or a stray copy might be
        # sitting under OMARCHY_PATH instead. Try each candidate in turn and
        # only fall back to a bare default once none of them produced a
        # usable config - a corrupt candidate here just means "keep
        # looking," not "abort."
        default_paths = [
            config_path,
            os.path.join(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"), "config/omarchy/shell.json"),
            "/usr/share/omarchy/config/omarchy/shell.json",
        ]
        config = None
        existing_mode = None
        for dp in default_paths:
            if dp and os.path.isfile(dp):
                try:
                    config, read_mode = _read_json_no_follow(dp)
                    # Only reuse the fd-sourced mode when we actually read
                    # config_path itself - a fallback candidate (e.g. the
                    # stock template under OMARCHY_PATH) is a different file
                    # and its permissions have no bearing on what config_path
                    # should end up with.
                    if dp == config_path:
                        existing_mode = read_mode
                    break
                except Exception:
                    continue
        if not isinstance(config, dict):
            config = _default_config(anchor_id)
            existing_mode = None
    else:
        # Updater: shell.json is expected to already exist from install. No
        # blanket try/except here on purpose - a swallowed failure would let
        # this script print success even when shell.json was left untouched,
        # exactly the silent-success bug this plugin's install/update flow
        # has already been bitten by once. Let a genuine failure (corrupt
        # JSON, permission denied, or a symlinked config) abort loudly
        # instead. Simply not existing yet is fine - nothing to update.
        if not os.path.isfile(config_path):
            return
        config, existing_mode = _read_json_no_follow(config_path)

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
    _atomic_write_json(config_path, config, mode=existing_mode)

    if bootstrap:
        print(f"Status bar layout updated: {plugin_id} successfully registered in shell.json.")
    else:
        print(f"Layout verified: {plugin_id} is active in shell.json.")


def disable(plugin_id, stock_plugin_id, section, anchor_id, config_path):
    if not os.path.isfile(config_path):
        return

    # No blanket try/except here on purpose: a swallowed failure would let
    # uninstall.sh print "Restored default media widget." even when
    # shell.json was left untouched - the same silent-success bug this
    # plugin's flow has already been bitten by once. Let a genuine failure
    # (corrupt JSON, permission denied, or a symlinked config) abort loudly
    # instead.
    config, existing_mode = _read_json_no_follow(config_path)

    layout = config.get("bar", {}).get("layout", {})
    for sec in ["left", "center", "right"]:
        if sec in layout and isinstance(layout[sec], list):
            layout[sec] = [item for item in layout[sec] if not (isinstance(item, dict) and item.get("id") == plugin_id)]

    # A bar-widget's "enabled" state is derived from its presence in the
    # layout, not from disabledPlugins - so removing custom.media without
    # putting the stock widget back would leave the user with no media
    # widget at all, despite disabledPlugins being cleared.
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

    _atomic_write_json(config_path, config, mode=existing_mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", choices=["enable", "disable"], required=True)
    parser.add_argument("--bootstrap", action="store_true", help="build a default shell.json if none is found (install only)")
    args = parser.parse_args()

    plugin_id = os.environ["PLUGIN_ID"]
    stock_plugin_id = os.environ["STOCK_PLUGIN_ID"]
    section = os.environ["BAR_SECTION"]
    anchor_id = os.environ["BAR_ANCHOR_ID"]
    config_path = os.path.expanduser("~/.config/omarchy/shell.json")

    if args.action == "enable":
        enable(plugin_id, stock_plugin_id, section, anchor_id, config_path, args.bootstrap)
    else:
        disable(plugin_id, stock_plugin_id, section, anchor_id, config_path)


if __name__ == "__main__":
    main()
