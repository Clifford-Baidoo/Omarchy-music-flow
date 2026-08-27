# Changelog

## Unreleased

### Security

- **Fixed a TOCTOU race in local artwork loading** (`Service.qml`, `BarWidget.qml`). The
  local-file branch of the artwork-fetch script validated a candidate path with
  separate `-f` / `-L` / `stat` pathname checks and then reopened the same
  (mutable) path with `head -c`. Any same-user process — including a malicious
  MPRIS player, since anyone can register one — could swap what lived at that
  path between the check and the read:
  - swapping in a **FIFO** made `head -c` block forever (no timeout on this
    branch, unlike the HTTPS branch's `--max-time 3`), hanging the artwork
    fetch process indefinitely;
  - swapping in a **symlink** after the `-L` check ran let the later read
    follow it anyway, since the check only held at the moment it ran.

  Replaced the check-then-open sequence with a single atomic operation via
  `python3` (already a hard dependency of this plugin): open with
  `O_NOFOLLOW | O_NONBLOCK`, `fstat` the resulting file descriptor, then read
  from that same descriptor. `O_NOFOLLOW` makes symlink rejection atomic,
  `O_NONBLOCK` stops FIFOs from blocking at open time so the regular-file
  check can reject them immediately, and every check plus the read itself
  targets the fd instead of the path — nothing done to the path afterward
  can matter. Verified with a live regression harness: valid images still
  cache correctly; symlinks, FIFOs, oversized/undersized/non-image files are
  all rejected; 60 iterations of a tight regular-file/FIFO swap race produced
  zero hangs (previously hung reliably within 5-6 iterations).

- **Fixed a symlink race in `shell.json` writes** (`install.sh`, `uninstall.sh`,
  `update.sh`). The atomic-write fix from the previous round used a
  predictable temp path (`shell.json.tmp`) opened with plain `open(path,
  "w")`, which creates-or-truncates whatever is at that path — including a
  symlink. A same-user process could pre-plant a symlink at that exact path
  pointing at any file the user owns, and the next install/uninstall/update
  run would silently overwrite it via `os.replace`. Separately, the read
  side had the same shape of bug: `shell.json` was opened by plain pathname
  after an `isfile()` check, so a same-user process could swap in a symlink
  between the check and the open and have its target read and later
  overwritten as if it were `shell.json`.
  - Writes now go through `tempfile.mkstemp()` in `shell.json`'s own
    directory, which creates the temp file with `O_CREAT | O_EXCL` in a
    single syscall — an unpredictable name, and no separate check-then-open
    window for a symlink to be planted into. The write is `fsync`'d before
    the atomic `os.replace` swap, and the temp file's mode is set to match
    the original `shell.json` (mkstemp defaults to 0600, which would
    otherwise silently tighten the config's permissions on every run).
  - Reads now open `shell.json` with `O_NOFOLLOW`, so a symlinked config is
    rejected outright (the script aborts loudly) instead of being
    transparently followed and then overwritten. This is a deliberate
    behavior change: a legitimately symlinked `shell.json` (e.g. managed by
    a dotfiles tool) will now cause install/update/uninstall to abort rather
    than edit through the link.
  - Verified with a live regression test: normal runs still write correctly
    and preserve the original file's permission bits with no leftover temp
    files; a `shell.json` symlinked to an out-of-tree "victim" file is
    rejected (`ELOOP`) before any write is attempted, leaving the victim
    file byte-for-byte untouched.

### Reliability

- **`uninstall.sh` and `update.sh` no longer swallow `shell.json` mutation
  failures.** Both scripts wrapped the entire read/mutate/write of
  `~/.config/omarchy/shell.json` in a blanket `except Exception`, so a
  corrupt config file or a permission error would silently no-op while the
  script still printed "Uninstall complete! Restored default media widget."
  or "Update complete!" — the exact silent-success failure mode this
  plugin's install flow was already bitten by once (see prior session notes
  on the `omarchy plugin enable`/`bar move` swallow bug). A genuine failure
  now aborts the script loudly instead of claiming success.
- **`shell.json` writes are now atomic** across `install.sh`, `update.sh`,
  and `uninstall.sh` (write to a temp file, then `os.replace` into place).
  Previously a crash or power loss mid-write could leave the user's entire
  bar config — not just this plugin's entry — truncated and unreadable.

## Previous session (untagged)

### Added

- Per-app/per-stream volume control: a slider and mute toggle in the popup
  that operate on the PipeWire stream correlated to the active MPRIS player
  (via `Service.qml`'s `findPlayerStream`), not the system output. Exposed
  over the existing `IpcHandler { target: "media" }` as `volumeUp`,
  `volumeDown`, `setVolume`, and `toggleMute`.
- All five visualizer flow modes (Wave, Bars, Dots, Sparks, Pulse) now react
  to the active player's real audio loudness via `PwNodePeakMonitor`, instead
  of a synthetic pulse. Falls back to the previous ambient-drift behavior
  when paused, idle, or when no PipeWire stream could be correlated to the
  player.

### Fixed

- `Style.tint(...)`, called at 10 sites in `BarWidget.qml`, does not exist on
  the `Style` singleton. Because `BorderSurface` extends a plain `Rectangle`
  (which defaults `color` to white) and never redeclared `color`, every
  failing `Style.tint` binding left affected elements stuck white until some
  other valid ternary branch happened to overwrite it — the visible symptom
  being flow-mode buttons rendering white until hovered. Replaced with the
  real `Util.alpha(color, opacity)` helper at all 10 sites; this also fixed
  several previously-silent no-ops beyond the reported bug (canvas
  low-energy dimmed colors, the album-art placeholder tint, the bar pill's
  hover highlight).
- Repeater-generated buttons (flow-mode buttons, source/player cards) could
  show a hover highlight immediately on creation if the cursor already sat
  over their pre-layout position, since their color bound directly to
  `MouseArea.containsMouse`. Switched to an explicit `hovered` property
  driven only by `onEntered`/`onExited`.
