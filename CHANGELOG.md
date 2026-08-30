# Changelog

## Unreleased

### Fixed

- **Artwork intermittently went missing until the next track change**
  (`BarWidget.qml`, `Service.qml`). Quickshell delivers the `exited()` signal
  for a killed `Process` asynchronously — after `running = false` returns. So
  when a fetch was killed by a track change, its late failure exit landed a
  moment AFTER the handler had already set `verifiedArtUrl` to the new value,
  blanking it; since the candidate URL didn't change again, nothing re-fetched
  and the panel stayed without artwork. Both fetchers now carry a generation
  counter: the process records which generation it was started for and ignores
  its own exit if the generation has moved on (stale exits are dropped).
  Additionally, the bar widget no longer launches its own fetch while the
  service is mid-fetch (its `artUrl` is briefly `""` in that window) — that
  duplicate download raced the service's fetch into the same cache file and
  left orphaned temp files behind. When the service is present it is now
  trusted exclusively; standalone mode still fetches directly.
- **Artwork never displayed for any player whose art the service successfully
  fetched** — including Cider (all versions that expose MPRIS), Spotify, and
  browsers (`MediaModel.js`, `BarWidget.qml`, `Service.qml`). The security
  hardening in `50d5b75` started exposing the verified artwork cache URL as
  `file://…artwork.cache?t=<Date.now()>` (the query forces Qt to reload the
  image when the cache file is replaced), but two places then rejected the
  query string itself: `sanitizeArtUrl()` fed the whole URI into
  `isAllowedLocalPath()`, whose basename character check refuses `?`, and the
  bash fetch scripts captured the query into `FILE_PATH` and handed
  `…artwork.cache?t=…` to `os.open()`, which fails because no such literal
  path exists. The sanitizer now validates the path portion only and reattaches
  the query afterwards; the fetch scripts strip the query before opening. All
  existing path restrictions still hold (verified via unit checks: cache/tmp
  roots only, `/home` personal paths, `/proc`, traversal, SVG, and
  non-whitelisted hosts all still blocked). Confirmed live against Cider
  4.0.9.1: `mpris:artUrl` is a whitelisted `is1-ssl.mzstatic.com` URL, the
  service fetched and cached a valid 640x640 JPEG, and only the widget-side
  re-sanitization dropped it.
- **Orphaned `artwork.*` temp files accumulated in the artwork cache dir**
  (`BarWidget.qml`, `Service.qml`). Quickshell kills the fetch process when the
  candidate URL changes mid-track, and a killed bash never runs its cleanup
  trap — 16 leaked temps (~120KB each) were found on the machine this was
  debugged on. Each fetch now sweeps stale `artwork.??????` files (exactly six
  chars after the dot, so never `artwork.cache`) older than one minute, so a
  concurrently running fetch's fresh temp is never touched.

### Added

- **Cider platform detection** (`MediaModel.js`). Cider previously fell through
  to the generic "Media" fallback with the default note icon; it now reports as
  "Cider", matching on identity, desktop entry, or
  `org.mpris.MediaPlayer2.cider` (including instance suffixes). Note: Cider
  3.1+ ships with MPRIS disabled upstream, so metadata and artwork integration
  covers Cider 1, 2, and 4.
- **Real application icons in the player panel** (`MediaModel.js`,
  `BarWidget.qml`). The panel's source badge, the no-artwork fallback, and the
  source selector cards now render the actual app icon (e.g. Cider's own logo
  from `/usr/share/pixmaps/cider.png`) instead of a Nerd Font glyph, via a new
  `sourceIconPath()` resolver. Candidate paths are validated through the same
  `sanitizeArtUrl()` allowlist artwork uses (system icon roots only, raster
  extensions only), and a missing file degrades gracefully to the text glyph.
  The Apple glyph introduced with Cider detection was removed — the generic
  media glyph remains as the text fallback. The bar capsule stays monochrome
  glyph-based by design.

### Changed

- **The bar widget no longer re-validates and re-copies the service's own
  verified cache file** (`BarWidget.qml`). When `mediaService.artUrl` is the
  plugin's own `file://<artworkCachePath>?t=…` URL, that file already passed
  the service's magic-byte verification; re-fetching it just copied the file
  onto itself and raced the service's next-track fetch into the same cache
  path. The exact-prefix match only ever accepts the plugin's own cache file.

### Fixed

- **The Chromium/YouTube visualizer looked like it was stuck on the ambient
  fallback even though it genuinely wasn't** (`BarWidget.qml`). Reported live:
  `mediaService.audioLevel` was demonstrably real and varying (confirmed via
  IPC: `fallbackPeakActive: false`, `audioLevelUnreliable: false`, level moving
  sample to sample), yet the visualizer still looked flat. Root cause found by
  sampling `audioLevel` live and running it through the actual formula:
  `targetEnergy = Math.max(audioFloor, Math.min(1.0, liveAudioLevel *
  audioGain))` with `audioGain = 2.4` clipped to the hard `1.0` ceiling for
  14 of 15 live samples of ordinary loud playback (raw levels observed in the
  0.33-0.86 range) - the *exact same constant* the `!hasLiveAudioLevel`
  branch above it returns for "no live data at all." So the genuinely
  reactive path was visually indistinguishable from the fallback for most
  real playback, independent of the fallback logic itself being correct.
  Lowered `audioGain` to `1.15` - re-verified against a fresh live sample: 0
  of 15 values now clip, spread runs roughly 0.4-0.99 and tracks the
  underlying loudness variation instead of saturating.

### Changed

- **Hardened two remaining rough edges in the `shell.json`/legacy-plugin-directory
  handling** flagged by a follow-up review of `bbe61ff`, neither exploitable as-is
  but both worth closing for defense-in-depth:
  - `update.sh`'s legacy-directory cleanup (`rm -rf "${LEGACY_DIR}"`) is now a
    `[ -d ] && [ ! -L ]`-guarded `mv` into a timestamped backup, matching
    `uninstall.sh`'s existing `TARGET_DIR` handling, instead of an unconditional
    recursive delete. `rm -rf` was already safe here in practice (`LEGACY_DIR` is
    `$HOME` + a fixed literal, never attacker input, and `rm`/`mv` never traverse
    a symlink to reach its target) - this just makes "don't touch it if it isn't
    really a directory" and "never destroy, only move aside" explicit and
    verifiable rather than relying on that reasoning holding.
  - `scripts/configure_bar.py`'s `_atomic_write_json` mirrored the target's file
    mode via a fresh `os.stat(path)` at write time - a pathname-based lookup
    that (harmlessly, since `os.replace()` never follows a symlink for the final
    swap) would still follow a symlink planted at `path` since the earlier read.
    `_open_no_follow`/`_read_json_no_follow` now also return the mode captured
    from the already-validated fd, threaded through `enable()`/`disable()` into
    `_atomic_write_json(path, data, mode=...)` for the common case (reading and
    writing the same `config_path`); the pathname-based fallback remains only
    for `install.sh`'s cross-file bootstrap case (reading a fallback template,
    writing `config_path`), where mirroring a different file's mode wouldn't be
    meaningful anyway. Verified behaviorally: a `shell.json` given mode `640`
    keeps that mode across both an update and a subsequent uninstall.

### Fixed

- **The legacy-plugin-id lookups in `update.sh` and `BarWidget.qml` were hardcoded
  to one developer's own username (`nek0.media`) instead of the actual account
  running the script/shell.** `update.sh`'s `LEGACY_DIR` cleanup and
  `BarWidget.qml`'s `mediaService` fallback chain both existed to find leftovers
  from the original repo's per-user plugin id scheme (`${USER_NAME}.media`), but
  a literal `"nek0.media"` only ever matches the id string when this repo's
  original author is the one running it - for anyone else it's a silent no-op.
  Fixed by deriving the id at runtime instead: `update.sh` now uses
  `LEGACY_DIR="${HOME}/.config/omarchy/plugins/$(id -un).media"`, and
  `BarWidget.qml` adds a `legacyUserPluginId` property built from
  `Quickshell.env("USER")` (falling back to `LOGNAME`).

### Changed

- **Deduplicated the `shell.json` layout-editing logic that was pasted as a
  ~150-line Python heredoc into all three of `install.sh`, `update.sh`, and
  `uninstall.sh`** (the `_open_no_follow`/`_read_json_no_follow`/
  `_atomic_write_json` security primitives plus the insert/clean/restore logic
  around them). Consistent today, but a maintenance hazard: a future fix to one
  copy could easily miss the other two, silently reopening a bug already fixed
  elsewhere - exactly the kind of drift that caused this plugin's original
  stale-template-id bug. Moved into a single `scripts/configure_bar.py`, invoked
  by each script as `python3 "${SCRIPT_DIR}/scripts/configure_bar.py" --action
  enable|disable [--bootstrap]`; `install.sh`/`update.sh` keep their existing
  per-script behavior difference (install bootstraps a default `shell.json` if
  none exists anywhere, update aborts loudly on a missing/corrupt one) via the
  `--bootstrap` flag, and `uninstall.sh` now defines `SCRIPT_DIR` (previously
  missing, since it had no need for it before this change) to locate the shared
  script. Verified behaviorally against a sandboxed `$HOME`: bootstrap-install
  on a missing `shell.json`, idempotent re-run via update (no duplicate
  `custom.media` entries), uninstall restoring the stock widget and clearing
  `disabledPlugins`, and update as a safe no-op when `shell.json` doesn't exist.

### Fixed

- **A genuinely-playing player could lose active-player selection to a different
  player that merely had an idle/silent PipeWire stream open** (`Service.qml`).
  The PipeWire-stream fallback added for the Chromium desync bug (below) treated
  "has an uncorked stream" as equally valid as "MPRIS confirms playing" when
  ranking candidates. Reproduced live: Spotify's MPRIS reported `"Playing"` while
  Chromium's stale `"Stopped"` tabs still had idle, uncorked streams open -
  Chromium kept winning selection anyway. Added `playerActivityRank()` (2 =
  MPRIS-confirmed playing, 1 = fallback-active only, 0 = inactive) so a real
  MPRIS confirmation can never be outranked by the fallback; the fallback only
  matters when nothing is genuinely confirmed playing. Verified live via IPC:
  `identity` now correctly switches to Spotify once it starts playing.

- **Quickshell 0.3.1's own PwNodePeakMonitor can silently fail to report peak
  data for a stream regardless of anything this plugin does** - confirmed with
  an isolated standalone test (zero involvement from this plugin's code) against
  a Spotify stream: `peak` read a flat `0` continuously, while an independent
  `pw-record` capture of the exact same node proved genuinely non-silent audio
  was flowing (mean sample amplitude 288/32767). The only structural difference
  from a working case (Chromium, 48kHz) was sample rate (44.1kHz). Since this is
  a compiled system component this plugin doesn't control, added: (1) a
  zero-streak detector (`audioLevelZeroStreak`/`audioLevelUnreliable`) that
  treats the built-in monitor as unreliable after 3s of flat-zero readings while
  a player is confirmed playing, and (2) a fallback peak meter that runs
  `pw-record` piped through a small `python3` peak calculator only while
  confirmed needed. The node id is validated as a non-negative integer both in
  QML before use and again inside the script, passed as a positional arg after
  `--` (never interpolated into the script text) - the same pattern this file's
  artwork-fetch process already uses for untrusted-ish values; verified an
  injection attempt in the id fails cleanly. The pipeline runs under `set -m`
  with a `trap ... EXIT TERM INT` killing the negative (process-group) PID,
  since Quickshell's `Process` only signals its direct child on stop and a
  plain backgrounded pipe doesn't otherwise get cleaned up - verified live that
  an earlier design left `pw-record`/`python3` orphaned after termination, and
  that the process-group version leaves zero orphans.

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
