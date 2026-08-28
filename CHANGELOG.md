# Changelog

## Unreleased

### Fixed

- **Visualizer/beat-sync could silently stop reacting to real audio while a track was
  genuinely playing** (`Service.qml`, `BarWidget.qml`). Player selection, `isPlaying`,
  and the visualizer's amplitude gate all read MPRIS `PlaybackStatus` exclusively —
  never cross-checked against the PipeWire stream's own corked/muted state, even
  though that cross-check (`playerHasActiveStream()`) already existed in
  `MediaModel.js` as dead code, never called from anywhere. Reproduced live on this
  machine: Chromium had 3 actively-streaming (uncorked, unmuted) PipeWire audio nodes
  while its own MPRIS `PlaybackStatus` reported `"Stopped"` (a known Chromium
  media-session quirk) — so the widget fell back to ambient/idle visualizer mode
  while audio was genuinely playing, matching the reported symptom (no visual
  reaction to a beat drop). Added `isPlayerActive()` in `Service.qml` (`player.isPlaying
  || playerHasActiveStream(player)`) and wired it into every place that previously
  read raw `p.isPlaying` for selection/ordering/`isPlaying`
  (`syncPlayingOrder`, `orderedSourcePlayers`, `mostRecentPlayingPlayer`,
  `selectActivePlayer`, `root.isPlaying`), plus `BarWidget.qml`'s own `isPlaying`
  (which prefers `mediaService.isPlaying` when the service backs the current
  player). The no-service fallback path is unchanged (no PipeWire correlation
  available there).

- **Visualizer motion never actually tracked the music — root cause: the wrong
  PipeWire stream was being monitored** (`MediaModel.js`, `Service.qml`,
  `BarWidget.qml`). Two compounding issues:
  - The `phase` value that every visualizer mode's shape/timing is built from
    advanced on a fixed `NumberAnimation` (a full 0→2π cycle every 2200ms,
    forever, regardless of what was playing) - only amplitude reacted to real
    audio, never the motion's speed. Replaced with a `FrameAnimation` that
    advances `phase` at a rate scaled by `root.currentEnergy` (~0.4x at
    idle/quiet up to ~2x at full energy), so a real loudness swing now visibly
    speeds the motion up too, not just its height.
  - The actual root cause, found via live IPC diagnostics added to
    `statusJson()`/`IpcHandler{target:"media"}`: `audioLevel` measured exactly
    `0` across 10 samples over 3 seconds while a video was audibly playing.
    `findPlayerStream()` (used for both volume control and peak monitoring)
    only returns the *first* PipeWire stream matching a player - but a browser
    can have several simultaneous streams (multiple tabs/windows playing audio
    at once), all reporting the same generic app name with no per-tab property
    to distinguish them. Live on this machine: 5 simultaneous Chromium audio
    streams existed, and the one being monitored for peak level wasn't the one
    actually producing sound. Factored the match predicate out of
    `findPlayerStream` into `streamMatchesPlayer()` and added
    `matchingActiveStreams()`, which returns *every* matching non-corked,
    non-muted stream instead of just the first. `Service.qml` now runs a
    `PwNodePeakMonitor` per candidate stream (via `Instantiator`) and takes the
    max peak across all of them, instead of a single monitor tied to
    `activePlayerStream` (which volume control still uses as-is, since picking
    an arbitrary one of several duplicate app streams is a reasonable-enough
    default there). Verified live via `qs ipc call media status` before/after:
    `audioLevel` went from a flat `0` across every sample to genuinely varying
    `0.08`-`0.55` in real time, tracking the actual audio.
  - Note: a pre-existing (not introduced by this fix) "Binding loop detected
    for property activePlayer" warning was noticed in the Quickshell log during
    this investigation - it fires 3 times at startup (component-construction
    churn: `selectActivePlayer()` writes `lastActivePlayerKey`/
    `preferredPlayerKey`, both of which `activePlayer`'s own binding reads) and
    does not recur during normal operation. Confirmed unrelated to this fix
    (audioLevel updated correctly and continuously throughout testing despite
    it), left as-is rather than refactoring `selectActivePlayer()`'s
    side-effect model unprompted.

- **The "Words ON"/"Pure Flow" toggle pill overflowed the popup's right edge,
  truncating its text** (`BarWidget.qml`). The flow-mode-switcher row's content
  (5 fixed-width mode buttons + gaps + the toggle pill's own fixed width) was
  wider than the popup's available inner width, so the last element (the toggle
  pill) ran past the popup's own edge. A first pass widened the fixed pixel
  values (popup content width, pill width), but that's guessing at font
  metrics/theme spacing scale with no way to render and verify locally, and it
  still overflowed. Replaced the guesswork with a structural fix: the outer
  `Row` holding the mode-button group and the toggle pill is now a `Flow`,
  which wraps the toggle pill onto its own line instead of letting it render
  past the popup's edge if it doesn't fit (the popup's height already sizes to
  `column.implicitHeight`, so a wrap just makes the popup slightly taller
  instead of overflowing sideways). Both the mode buttons and the toggle pill
  are now sized from their own label's `implicitWidth` instead of a hardcoded
  guess, so a button can never be narrower than what its own text needs
  regardless of font/theme. The popup's base content width was also reduced
  (410px → 300px, down from the original 340px too) per feedback that the
  widened popup was too large - safe to shrink since the Flow-wrap is now the
  actual overflow guarantee, not the popup's raw width.

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
  - Follow-up hardening: the temp file's permissions are now set with
    `os.fchmod` on the still-open file descriptor instead of `os.chmod` on
    the path after closing it, removing a narrow path-based window between
    fd-close and the permission set / rename.
  - Follow-up fix: `_open_no_follow()` opened `shell.json` with
    `O_NOFOLLOW` but not `O_NONBLOCK`, and never validated the resulting
    descriptor before handing it to `json.load()`. A same-user process
    could win the same check-then-open race already closed for symlinks by
    swapping in a FIFO instead, blocking the open indefinitely (the exact
    failure mode already fixed once in the artwork-fetch path); a swapped-in
    oversized regular file would also have been parsed with no size bound.
    Added `O_NONBLOCK` (a no-op for the regular file this is required to
    be) plus an `fstat`-on-the-fd check that rejects anything that isn't a
    regular file under 2 MiB before it's read. Verified with a live
    regression test: 300 iterations of a tight regular-file/FIFO swap race
    against the fixed open path produced zero hangs, and an oversized
    planted file is rejected before `json.load()` ever runs.
  - Follow-up fix: the `fstat`-based size check above only holds at the
    instant it runs — the fd stays open on the same (mutable) regular file
    afterward, so a same-user process could still grow it past the 2 MiB
    bound after the check passed but before `json.load()`, which has no
    byte limit of its own and reads straight to EOF. Replaced the
    `json.load(f)` call with a bounded read loop (`os.read()` on the
    validated fd, capped at `max_bytes + 1`) that raises before parsing if
    it ever reads past the limit, then parses only that bounded in-memory
    buffer via `json.loads()`. Verified with a deterministic (non-racy)
    reproduction: manually interleaving the exact open→fstat→grow→read
    steps confirmed the old `json.load()` path silently parsed a file grown
    past its checked cap, while the new read loop detects the same
    post-check growth and raises before parsing.
  - Follow-up: made the encoding explicit on both sides instead of relying on
    implicit defaults. The write side (`os.fdopen(fd, "w")`) used the
    platform's locale-dependent default text encoding, not guaranteed to be
    UTF-8 (e.g. a `C`/`POSIX` locale, common in minimal containers/services
    with no locale configured); now opened with `encoding="utf-8"`
    explicitly. The read side's bounded byte buffer was being handed to
    `json.loads(bytes)`, which auto-detects UTF-8/16/32 from a BOM/null-byte
    heuristic rather than assuming a fixed encoding; now decoded via
    `.decode("utf-8")` explicitly first, so a mismatch fails loudly
    (`UnicodeDecodeError`) instead of being silently reinterpreted under a
    different encoding. Verified: round-tripping non-ASCII content (emoji,
    accented characters, CJK) through write→read is unchanged; a file
    containing invalid UTF-8 bytes is now explicitly rejected with a clear
    `UnicodeDecodeError` instead of the previous auto-detection's implicit
    behavior.

- **Fixed a deterministic (non-racy) symlink-overwrite in plugin file
  installation** (`install.sh`, `update.sh`). Both scripts copied plugin
  files straight onto their final names with `cp -f "$SRC" "$TARGET_DIR/"`.
  `cp -f` follows a symlink at the destination and overwrites whatever it
  points to, leaving the symlink itself in place (verified empirically). A
  same-user process only had to plant a symlink once at, say,
  `TARGET_DIR/BarWidget.qml` pointing at any file the user owns — no race
  window needed — and the next install or update would silently overwrite
  that file's contents with QML source. Fixed by copying each file to a
  fresh `mktemp`-generated name in the same directory first, then `mv`ing
  it onto the final filename: `mv` (`rename()`) never follows a symlink at
  the destination, it replaces the directory entry itself, so this closes
  the hole regardless of what currently occupies that name. Verified live:
  normal installs still produce correct regular files with source
  permissions preserved; a symlink planted at a plugin filename before
  running install/update now leaves the linked file completely untouched
  and the plugin directory ends up with a genuine regular file in its
  place. (`ln -sf`, used for the MPV MPRIS integration symlink, was
  checked and does not have this problem — it replaces the link entry
  rather than writing through it.)

### Reliability

- **`install.sh` / `update.sh` no longer leak temp files on a mid-copy
  failure.** `install_plugin_file()`'s `mktemp`-then-`mv` sequence (added
  above) had no cleanup if `cp` or `chmod` failed after the temp file was
  already created (e.g. a missing source file, a full disk) - the orphaned
  `.<name>.XXXXXX` file was left in the plugin directory permanently.
  Reproduced (a simulated failure on the 3rd of 4 files left a dotfile
  behind) and fixed with a script-wide `EXIT` trap that removes any
  temp file that didn't make it to a successful `mv`, mirroring the
  `trap 'rm -f "$TMP_FILE"' EXIT` pattern already used in the artwork-fetch
  script. Verified the same failure injection now leaves zero stray files.

- **Bounded worst-case CPU/memory from unbounded MPRIS metadata text**
  (`MediaModel.js`). `sanitizeText`, `cleanTitle`, `detectPlatform`, and
  `extractArtUrl` ran their regex/string-scan cascades over raw
  `xesam:title` / `xesam:url` / `trackArtUrl` text with no length cap -
  unlike this same file's URL and data-URI validators, which already bound
  input to `MAX_URL_LENGTH` / `MAX_DATA_IMAGE_LENGTH`. Unlike D-Bus bus
  names (spec-capped at 255 bytes), MPRIS metadata *values* have no size
  limit, so a same-user malicious MPRIS player (or a webpage feeding an
  oversized `document.title` through a browser's media-session
  integration) could set a multi-megabyte title, re-processed in full on
  every metadata change. Measured on the pre-fix code: a 20 MB attacker
  title took 234ms per change and was retained in memory at full size;
  D-Bus allows messages up to ~128MB, so cost scales with whatever the
  attacker sends. Added a `capText()` helper (reusing the same
  `MAX_URL_LENGTH` for URL-shaped fields, a new 4096-char `MAX_TEXT_LENGTH`
  for freeform text) applied at the entry points that read raw metadata.
  Verified: normal titles/URLs clean identically to before; the same 20MB
  payload now processes in single-digit milliseconds with output bounded
  to 4096 chars.

- **Bounded worst-case CPU from unbounded PipeWire node properties fed into
  player/stream matching** (`MediaModel.js`). The Chromium-visualizer-desync fix
  above wires `playerHasActiveStream()` into the player-selection hot path, which
  runs its matching (`streamLabelKey`, `normalizeAppName`, `isBlacklistedStream`,
  `isPlaybackStream`) over raw PipeWire node properties (`application.name`,
  `node.name`, `media.name`, `application.process.binary`, `node.description`) —
  same trust model as the MPRIS metadata already capped above: any same-user
  process can register a PipeWire node and set these properties to an arbitrary,
  protocol-unbounded length. Measured on the pre-fix code: a 50MB attacker
  property took 759ms per `playerHasActiveStream()` call, now running on every
  player/stream change instead of being dead code. Applied `capText()` at the
  same two leaf functions every caller already routes through
  (`streamLabelKey`, `normalizeAppName`) plus the two spots that scan raw
  joined properties directly (`isBlacklistedStream`, `isPlaybackStream`).
  Verified: normal player/stream correlation (including the live Chromium/
  Spotify case above) is unaffected; the same 50MB payload now processes in
  14ms, roughly constant regardless of input size (2ms at 1MB, 5ms at 10MB,
  14ms at 50MB).

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
