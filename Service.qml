import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "MediaModel.js" as MediaModel

Item {
  id: root

  property var shell: null
  property string preferredPlayerKey: ""
  // preferredPlayerKey alone is ambiguous whenever two genuinely different
  // player PROCESSES share the same canonical key (e.g. two separate mpv
  // windows - see sourceListKey() above for the same underlying issue in
  // the source list). playerForKey() resolving that key then just returns
  // whichever matching player happens to come first in `players`, so
  // selecting either one actually controlled the same single player
  // instead of the one actually clicked. preferredPlayerExactKey stores
  // the exact dbusName of the specific player object that was selected,
  // and is checked first wherever the preferred player is resolved, with
  // preferredPlayerKey kept only as the fallback/liveness-tracking key.
  property string preferredPlayerExactKey: ""
  property string lastActivePlayerKey: ""
  // playerActivityRank()'s PipeWire-stream fallback (below) treats "has an
  // uncorked stream" as still-active, which lags behind a pause command -
  // reproduced live: mpv keeps its PipeWire sink node open/uncorked for a
  // moment after player.pause(), so even with MPRIS correctly reporting
  // isPlaying=false, the stream fallback kept ranking it as active, and
  // the play/pause icon (driven by this rank) never flipped. Since this
  // only ever matters for a pause *this plugin itself just issued*, track
  // it explicitly instead of trying to re-derive "really paused" from
  // PipeWire state: a brief window where the just-paused player's rank is
  // forced to 0 regardless of what the stream fallback still reports.
  //
  // Keyed by sourceListKey (same real process, not just the one exact
  // dbus alias actually commanded) - a single real process can register
  // several simultaneous dbus names as separate player objects, and a
  // sibling alias we didn't directly pause can independently keep
  // reporting active (its own isPlaying or stream-fallback lagging on its
  // own schedule) even once the one we commanded has gone quiet.
  property string pauseOverrideKey: ""
  property real pauseOverrideUntil: 0

  function markExplicitPause(player) {
    var key = sourceListKey(player)
    if (!key) return
    pauseOverrideKey = key
    pauseOverrideUntil = Date.now() + 2000
  }

  // A subsequent play/resume on the same player within that 2s window must
  // clear the override immediately, or it keeps forcing rank 0 (reported as
  // "still paused") for up to 2s after the player has genuinely resumed -
  // reproduced live: pause, then play again inside the window, left
  // serviceIsPlaying stuck false despite the player's own isPlaying already
  // back to true.
  function clearPauseOverrideFor(player) {
    var key = sourceListKey(player)
    if (key && pauseOverrideKey === key) {
      pauseOverrideKey = ""
      pauseOverrideUntil = 0
    }
  }
  property var playerStartedAt: ({})
  property var pendingTrackOsd: null
  property int playSerial: 0
  // Bumped by signal connections whenever any player's playback state changes.
  // This forces activePlayer (which reads this) to re-evaluate reactively.
  property int playbackVersion: 0

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  readonly property var playbackStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isStream && isPlaybackStream(n) && n.audio) list.push(n)
    }
    return list
  }

  // playerHasActiveStream()'s "uncorked = active" check is meaningless for
  // mpv: reproduced live via pw-dump, mpv never sets pulse.corked at all
  // (absent, not "false") since it's a native PipeWire client rather than
  // going through the pulse compatibility layer, so the check always read
  // it as "active" regardless of whether it was genuinely paused - both of
  // two persistently-paused mpv sources ranked as active this way, with no
  // transient pause-override involved (confirmed via live debug dump).
  // PipeWire's own node run-state (what pw-dump's info.state shows as
  // idle/running) isn't exposed through Quickshell's PwNode object either
  // (confirmed: absent from its property list). The only remaining signal
  // that actually reflects real audio flow is live peak level, so every
  // playback stream (not just the active player's correlated ones - see
  // audioCandidateMonitors below for that narrower case) gets its own
  // PwNodePeakMonitor, and "active via stream" requires genuine audibility
  // within the last 1.5s, not just an absent cork flag.
  Instantiator {
    id: allStreamMonitors
    model: root.playbackStreams
    delegate: PwNodePeakMonitor {
      required property var modelData
      node: modelData
      enabled: true
    }
  }

  property var streamLastAudibleAt: ({})

  Timer {
    interval: 200
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now()
      var next = {}
      for (var i = 0; i < allStreamMonitors.count; i++) {
        var mon = allStreamMonitors.objectAt(i)
        if (!mon || !mon.node) continue
        var id = mon.node.id
        var prevAt = root.streamLastAudibleAt[id] || 0
        if (mon.peak > 0.01) {
          next[id] = now
        } else if (now - prevAt < 1500) {
          // Keeps a recent-enough timestamp across a brief real silence
          // (a quiet passage, a gap between tracks) instead of flickering
          // the icon off and back on every time the level briefly dips.
          next[id] = prevAt
        }
      }
      root.streamLastAudibleAt = next
    }
  }

  function streamAudibleRecently(node) {
    if (!node) return false
    var at = root.streamLastAudibleAt[node.id]
    return at !== undefined && (Date.now() - at) < 1500
  }

  function playerHasGenuinelyActiveStream(player) {
    var streams = MediaModel.matchingActiveStreams(player, playbackStreams)
    if (streams.length === 0) return false
    // matchingActiveStreams matches by app name/label alone, which can't
    // tell apart two real processes of the same app (confirmed live: two
    // separate mpv windows' streams are both labeled "mpv" with no
    // process-identifying property PipeWire exposes for either - same
    // ambiguity as the player list, but one layer down). PipeWire's
    // media.name DOES carry the real per-stream track title ("<title> -
    // mpv", confirmed live), so when this player's own current title is
    // embedded in more than one matched stream's media.name, narrow to
    // just the stream(s) that actually mention it instead of trusting
    // app-name matching alone to have picked the right one.
    var title = String(player.trackTitle || "").toLowerCase()
    if (title && streams.length > 1) {
      var titled = []
      for (var i = 0; i < streams.length; i++) {
        var props = streams[i].properties || {}
        var mediaName = String(props["media.name"] || "").toLowerCase()
        if (mediaName.indexOf(title) !== -1) titled.push(streams[i])
      }
      if (titled.length > 0) streams = titled
    }
    for (var j = 0; j < streams.length; j++) {
      if (streamAudibleRecently(streams[j])) return true
    }
    return false
  }

  // Per-app volume: the PipeWire stream node correlated to the active player, if any.
  readonly property var activePlayerStream: activePlayer ? MediaModel.findPlayerStream(activePlayer, playbackStreams) : null
  readonly property bool hasVolumeControl: activePlayerStream !== null && activePlayerStream.audio !== null
  readonly property real volume: hasVolumeControl ? activePlayerStream.audio.volume : 1.0
  readonly property bool muted: hasVolumeControl ? activePlayerStream.audio.muted : false

  function setVolume(value) {
    if (!hasVolumeControl) return false
    if (typeof value !== "number" || !isFinite(value)) return false
    activePlayerStream.audio.volume = Math.max(0, Math.min(1, value))
    return true
  }

  function adjustVolume(delta) {
    if (!hasVolumeControl) return false
    return setVolume(activePlayerStream.audio.volume + delta)
  }

  function toggleMute() {
    if (!hasVolumeControl) return false
    activePlayerStream.audio.muted = !activePlayerStream.audio.muted
    return true
  }

  // Live audio level for the active player, so the bar visualizer's amplitude
  // tracks real loudness instead of a synthetic pulse. Deliberately NOT the same
  // single correlated node volume control uses (activePlayerStream/findPlayerStream
  // just take the first match): a player like a browser can have several
  // simultaneous PipeWire streams (multiple tabs/windows playing audio at once),
  // all reporting as the same generic app name with no per-tab property to
  // distinguish them, so the first match isn't necessarily the one actually
  // producing sound. Reproduced live: audioLevel stayed exactly 0 across 10
  // samples over 3s while a video was audibly playing, because 5 simultaneous
  // Chromium streams existed and the monitored one wasn't the loud one. Monitor
  // every matching stream and take the loudest instead.
  readonly property var audioCandidateStreams: activePlayer ? MediaModel.matchingActiveStreams(activePlayer, playbackStreams) : []

  Instantiator {
    id: audioCandidateMonitors
    model: root.audioCandidateStreams
    delegate: PwNodePeakMonitor {
      required property var modelData
      node: modelData
      enabled: true
    }
  }

  readonly property real builtinAudioLevel: {
    var maxPeak = 0
    for (var i = 0; i < audioCandidateMonitors.count; i++) {
      var obj = audioCandidateMonitors.objectAt(i)
      if (obj) maxPeak = Math.max(maxPeak, obj.peak)
    }
    return Math.max(0, Math.min(1, maxPeak))
  }

  readonly property real audioLevel: fallbackPeakActive ? fallbackPeakLevel : builtinAudioLevel

  // Quickshell's PwNodePeakMonitor can itself fail to report real peak data for a
  // given stream regardless of anything this plugin does - confirmed on Quickshell
  // 0.3.1 with a Spotify stream (44.1kHz, vs. a working 48kHz Chromium stream):
  // peak read a flat 0 in an isolated test with zero involvement from this
  // plugin's own matching/Instantiator code, while an independent `pw-record`
  // capture of the same node proved genuinely non-silent audio was flowing. Track
  // how long audioLevel has stayed at (near-)zero while a player is confirmed
  // playing and a candidate stream was found; after a few seconds treat the peak
  // data as unreliable so BarWidget falls back to its no-live-data ambient
  // behavior instead of sitting at a flat, visually-dead floor value.
  property real audioLevelZeroStreak: 0
  property string audioLevelZeroTrackedKey: ""

  Timer {
    interval: 250
    running: true
    repeat: true
    onTriggered: {
      var key = root.activePlayer ? playerCanonicalKey(root.activePlayer) : ""
      if (key !== root.audioLevelZeroTrackedKey) {
        root.audioLevelZeroTrackedKey = key
        root.audioLevelZeroStreak = 0
        return
      }
      // Deliberately checks builtinAudioLevel, not audioLevel: once the fallback
      // meter (below) is active, audioLevel reflects ITS reading, which would
      // read as "reliable again" and immediately stop the fallback, which would
      // make audioLevel broken again, restarting it - an infinite start/stop
      // cycle. Reliability is strictly about whether the built-in monitor
      // itself ever produces a real reading, independent of the fallback.
      if (!root.isPlaying || audioCandidateMonitors.count === 0 || root.builtinAudioLevel > 0.01) {
        root.audioLevelZeroStreak = 0
      } else {
        root.audioLevelZeroStreak += interval / 1000
      }
    }
  }

  readonly property bool audioLevelUnreliable: audioLevelZeroStreak >= 3.0
  readonly property bool hasLiveAudioLevel: audioCandidateMonitors.count > 0 && (!audioLevelUnreliable || fallbackPeakActive)

  // Fallback peak meter for streams the built-in PwNodePeakMonitor can't read
  // (see audioLevelUnreliable above). Since a direct `pw-record` capture of the
  // same node independently proved real, non-silent audio was available, drive
  // the visualizer from that instead of settling for a non-reactive placeholder.
  // Runs pw-record piped through a small python3 peak calculator only while
  // confirmed needed (audioLevelUnreliable), so normal working streams never pay
  // for an extra process. The node id is validated as a plain non-negative
  // integer both before constructing the command and again inside the script,
  // and passed as a positional arg after "--" (never interpolated into the
  // script text) - the same pattern the artwork-fetch process above uses for
  // untrusted-ish values.
  readonly property var fallbackPeakTargetNode: audioCandidateStreams.length > 0 ? audioCandidateStreams[0] : null
  property real fallbackPeakLevel: 0
  property bool fallbackPeakActive: false
  // The pw-record fallback computes a raw per-chunk peak of signed 16-bit PCM
  // samples (max(abs(sample))/32768), which is not the same metric as whatever
  // Quickshell's built-in PwNodePeakMonitor reports - live-sampled side by side,
  // ordinary loud Chromium playback put builtinAudioLevel around 0.33-0.86, while
  // ordinary loud Spotify playback through this fallback (forced on it by the
  // channel-mismatch bug above) sat around 0.03-0.30 for the same perceived
  // loudness. BarWidget's audioGain is tuned against the builtin monitor's scale
  // and applies equally to whichever source is active, so without correcting the
  // fallback's smaller raw numbers here, most fallback-driven playback pins at
  // BarWidget's floor and reads as non-reactive even though the data is genuinely
  // live and varying (reproduced: median raw level 0.17 over a 20s Spotify
  // sample maps to just 0.196 after BarWidget's 1.15x gain, below its own
  // 0.15 floor for anything quieter than that median).
  readonly property real fallbackPeakGain: 3.0

  function stopFallbackPeakMeter() {
    fallbackPeakProc.running = false
    root.fallbackPeakActive = false
    root.fallbackPeakLevel = 0
  }

  function startFallbackPeakMeter() {
    var node = root.fallbackPeakTargetNode
    if (!node) return
    var nodeId = Number(node.id)
    if (!Number.isInteger(nodeId) || nodeId < 0) return

    fallbackPeakProc.running = false
    root.fallbackPeakActive = false
    root.fallbackPeakLevel = 0
    // "set -m" gives the backgrounded pipeline its own process group, so a single
    // signal to the negative PID (-$JOB_PID) reaches both pw-record and python3.
    // Necessary: Quickshell's Process only signals its direct child (this bash
    // instance) when stopped, and a plain `cmd1 | cmd2 &` job doesn't otherwise
    // get its own child processes cleaned up just because the parent script
    // exits - verified live (a standalone test without this left pw-record and
    // python3 running as orphans after the parent bash was killed). Also
    // verified: running python3 as a background job (not a blocking foreground
    // command) is required for the trap to fire promptly on SIGTERM at all -
    // a foreground `python3 ... <&coproc_fd` blocks bash's signal handling
    // until python3 itself exits, which only happens once pw-record dies,
    // which only happens once the trap runs - a deadlock with the earlier
    // foreground-python3 design.
    //
    // stream.capture.sink=true: without it, `pw-record --target=<output-stream-node>`
    // links as a generic monitor input that mostly never actually receives this
    // node's audio - reproduced live: 186/187 captured chunks were pure silence
    // (all-zero samples) despite Quickshell's own PwNodePeakMonitor simultaneously
    // reporting real, loud peak data for the exact same node. This property makes
    // pw-record actually tap the node's own rendered output instead.
    fallbackPeakProc.command = [
      "bash", "-c",
      "set -uo pipefail; NODE_ID=\"$1\"; if ! [[ \"$NODE_ID\" =~ ^[0-9]+$ ]]; then exit 1; fi; set -m; pw-record --target=\"$NODE_ID\" -P '{ format=s16 rate=44100 channels=2 stream.capture.sink=true }' - 2>/dev/null | python3 -u -c '\nimport struct, sys\nwhile True:\n    data = sys.stdin.buffer.read(4096)\n    if not data:\n        break\n    n = len(data) // 2\n    if n == 0:\n        continue\n    samples = struct.unpack(\"<\" + str(n) + \"h\", data[:n * 2])\n    peak = max(abs(s) for s in samples) / 32768.0\n    print(\"%.4f\" % peak, flush=True)\n' & JOB_PID=$!; trap 'kill -TERM -- \"-$JOB_PID\" 2>/dev/null' EXIT TERM INT; wait \"$JOB_PID\"",
      "--",
      String(nodeId)
    ]
    fallbackPeakProc.running = true
  }

  function refreshFallbackPeakMeter() {
    if (root.audioLevelUnreliable && root.fallbackPeakTargetNode) {
      startFallbackPeakMeter()
    } else {
      stopFallbackPeakMeter()
    }
  }

  onAudioLevelUnreliableChanged: refreshFallbackPeakMeter()
  onFallbackPeakTargetNodeChanged: {
    refreshFallbackPeakMeter()
    refreshSpectrumMeter()
  }

  Process {
    id: fallbackPeakProc
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        var v = parseFloat(data)
        if (isFinite(v)) {
          root.fallbackPeakActive = true
          root.fallbackPeakLevel = Math.max(0, Math.min(1, v * root.fallbackPeakGain))
        }
      }
    }
    onExited: {
      root.fallbackPeakActive = false
      root.fallbackPeakLevel = 0
    }
  }

  // Real per-band spectrum for BarWidget's visualizer modes, so bars/dots/
  // particles/cava each reflect their own frequency content (a real
  // equalizer) instead of all moving together off one aggregate loudness
  // scalar. Deliberately not a dependency on the `cava` binary (not
  // installed, and this plugin shouldn't require installing it) - reuses
  // the same pw-record capture this file already depends on, piped through
  // a small python3 Goertzel analyzer (stdlib only, no numpy) instead of
  // cava's own FFT. 14 log-spaced bands (~55Hz-14kHz) is enough resolution
  // for a 100-150px bar strip; each band Goertzel's at block size 2048,
  // which only costs ~14*2048 float ops per ~46ms block - negligible.
  // Each band self-normalizes against its own slowly-decaying recent peak
  // (an AGC per band), so output is already a 0-1 value and needs no
  // separate gain tuning per source the way the peak meters above do.
  readonly property int spectrumBandCount: 14
  property var spectrumBands: []

  function stopSpectrumMeter() {
    spectrumProc.running = false
    root.spectrumBands = []
  }

  function startSpectrumMeter() {
    var node = root.fallbackPeakTargetNode
    if (!node) return
    var nodeId = Number(node.id)
    if (!Number.isInteger(nodeId) || nodeId < 0) return

    spectrumProc.running = false
    var script = "import sys, struct, math\n" +
      "SR = 44100\n" +
      "N = 2048\n" +
      "BANDS = " + root.spectrumBandCount + "\n" +
      "freqs = [55.0 * (14000.0 / 55.0) ** (i / (BANDS - 1)) for i in range(BANDS)]\n" +
      "coeffs = []\n" +
      "for f in freqs:\n" +
      "    k = int(0.5 + (N * f) / SR)\n" +
      "    w = (2.0 * math.pi * k) / N\n" +
      "    coeffs.append(2.0 * math.cos(w))\n" +
      "band_peak = [0.001] * BANDS\n" +
      "DECAY = 0.996\n" +
      "buf = b\"\"\n" +
      "while True:\n" +
      "    chunk = sys.stdin.buffer.read(4096)\n" +
      "    if not chunk:\n" +
      "        break\n" +
      "    buf += chunk\n" +
      "    while len(buf) >= N * 4:\n" +
      "        block = buf[:N * 4]\n" +
      "        buf = buf[N * 4:]\n" +
      "        samples = struct.unpack(\"<\" + str(N * 2) + \"h\", block)\n" +
      "        mono = [(samples[2 * i] + samples[2 * i + 1]) * 0.5 for i in range(N)]\n" +
      "        out = []\n" +
      "        for idx in range(BANDS):\n" +
      "            c = coeffs[idx]\n" +
      "            s1 = 0.0\n" +
      "            s2 = 0.0\n" +
      "            for x in mono:\n" +
      "                s0 = x + c * s1 - s2\n" +
      "                s2 = s1\n" +
      "                s1 = s0\n" +
      "            power = s1 * s1 + s2 * s2 - c * s1 * s2\n" +
      "            mag = math.sqrt(max(0.0, power)) / N\n" +
      "            bp = max(mag, band_peak[idx] * DECAY)\n" +
      "            band_peak[idx] = bp\n" +
      "            out.append(min(1.0, mag / bp) if bp > 0.0001 else 0.0)\n" +
      "        print(\" \".join(\"%.3f\" % v for v in out), flush=True)\n"

    spectrumProc.command = [
      "bash", "-c",
      "set -uo pipefail; NODE_ID=\"$1\"; if ! [[ \"$NODE_ID\" =~ ^[0-9]+$ ]]; then exit 1; fi; set -m; pw-record --target=\"$NODE_ID\" -P '{ format=s16 rate=44100 channels=2 stream.capture.sink=true }' - 2>/dev/null | python3 -u -c '" + script + "' & JOB_PID=$!; trap 'kill -TERM -- \"-$JOB_PID\" 2>/dev/null' EXIT TERM INT; wait \"$JOB_PID\"",
      "--",
      String(nodeId)
    ]
    spectrumProc.running = true
  }

  function refreshSpectrumMeter() {
    if (root.isPlaying && root.fallbackPeakTargetNode) {
      startSpectrumMeter()
    } else {
      stopSpectrumMeter()
    }
  }

  onIsPlayingChanged: refreshSpectrumMeter()

  Process {
    id: spectrumProc
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        var parts = data.trim().split(" ")
        var arr = []
        for (var i = 0; i < parts.length; i++) {
          var v = parseFloat(parts[i])
          arr.push(isFinite(v) ? Math.max(0, Math.min(1, v)) : 0)
        }
        if (arr.length > 0) root.spectrumBands = arr
      }
    }
    onExited: {
      root.spectrumBands = []
    }
  }

  // Plain properties, refreshed via refreshSourcePlayers() below, instead of the
  // eager `readonly property var sourcePlayers: orderedSourcePlayers()` this used
  // to be. That binding read `players` (Mpris.players.values) directly, so it
  // recomputed - and reassigned a brand-new array to BarWidget.qml's
  // `Repeater { model: root.sourcePlayers }` - synchronously, in the exact same
  // tick Quickshell's own Mpris code removes and destroys a closed browser's
  // player object. That's the actual trigger proven by every crash reproduction:
  // browser closes -> "Unregistered MprisPlayer" -> Repeater::setModel ->
  // regenerate -> incubate segfaults inside Qt's delegate-model machinery, which
  // isn't reentrancy-safe against a model swap landing mid-teardown of an object
  // one of its delegates still references. Deferring the recompute with
  // Qt.callLater (see refreshSourcePlayers) moves the Repeater's model
  // reassignment to a later event-loop tick, off that same call stack.
  property var sourcePlayers: []
  property var sourceCyclePlayers: []

  function refreshSourcePlayers() {
    sourcePlayers = orderedSourcePlayers()
    sourceCyclePlayers = orderedCycleSourcePlayers()
  }
  // playerStartedAt changes every time syncPlayingOrder() runs (it writes playerStartedAt = next).
  // syncPlayingOrder() is called on every onIsPlayingChanged (via Instantiator below) and on
  // onPlayersChanged. So activePlayer re-evaluates automatically on every pause/resume/switch.
  // playbackVersion, preferredPlayerKey, and lastActivePlayerKey are also read.
  readonly property var activePlayer: {
    var _ps = playerStartedAt  // re-evaluate when any player's playing state changes
    var _pv = playbackVersion
    var _pk = preferredPlayerKey
    var _lk = lastActivePlayerKey
    return selectActivePlayer()
  }

  // Qt.callLater coalesces same-tick calls and, more importantly, runs this
  // outside the current synchronous property-notify cascade - by the time it
  // fires, activePlayer's binding (and whatever triggered it, e.g. a
  // syncPlayingOrder() from a player disappearing) is fully off the call
  // stack, so writing lastActivePlayerKey/preferredPlayerKey here can only
  // start a fresh, later notify cascade, never nest inside this one.
  onActivePlayerChanged: Qt.callLater(rememberActivePlayer)

  // isPlaying reads activePlayer.isPlaying directly — a real QML property access.
  // When activePlayer switches (e.g. Spotify→YouTube), this re-evaluates immediately.
  // When the current player pauses/resumes, activePlayer.isPlaying notifies this binding.
  // Falls back to isPlayerActive's PipeWire-stream check for players whose MPRIS
  // PlaybackStatus is stale (see isPlayerActive above).
  readonly property bool isPlaying: isSourceActive(activePlayer)

  // Per-player signal connections — use Mpris.players (UntypedObjectModel) directly
  // as the Instantiator model so Qt creates one Connections delegate per player.
  // Wire all relevant MprisPlayer notify signals so any change in state, track, or
  // metadata causes immediate UI updates.
  Instantiator {
    model: Mpris.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() {
        Qt.callLater(root.syncPlayingOrder)
        root.playbackVersion++
      }
      function onPlaybackStateChanged() {
        Qt.callLater(root.syncPlayingOrder)
        root.playbackVersion++
      }
      function onMetadataChanged() {
        root.playbackVersion++
      }
      function onTrackTitleChanged() {
        root.playbackVersion++
      }
      function onTrackArtistChanged() {
        root.playbackVersion++
      }
      function onTrackAlbumChanged() {
        root.playbackVersion++
      }
      function onTrackArtUrlChanged() {
        root.playbackVersion++
      }
    }
  }

  readonly property bool hasMedia: activePlayer !== null && (Boolean(title) || Boolean(artist) || isPlaying)
  
  readonly property string title: {
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    var cleaned = MediaModel.cleanTitle(t, a)
    if (cleaned) return cleaned
    return MediaModel.sanitizeText(activePlayer.identity || activePlayer.desktopEntry || "Media Playing")
  }

  readonly property string artist: {
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    return MediaModel.cleanArtist(a, t, activePlayer)
  }

  readonly property string album: activePlayer && activePlayer.trackAlbum ? MediaModel.cleanAlbum(activePlayer.trackAlbum) : (activePlayer && activePlayer.metadata && activePlayer.metadata["xesam:album"] ? MediaModel.cleanAlbum(activePlayer.metadata["xesam:album"]) : "")
  property string verifiedArtUrl: ""
  readonly property string rawCandidateArtUrl: activePlayer ? MediaModel.extractArtUrl(activePlayer) : ""
  readonly property string artUrl: verifiedArtUrl
  readonly property string artworkCachePath: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy/music-flow/artwork.cache"

  onRawCandidateArtUrlChanged: {
    var raw = root.rawCandidateArtUrl
    if (!raw) {
      artFetchProc.running = false
      root.verifiedArtUrl = ""
      return
    }

    if (MediaModel.isRasterDataUri(raw)) {
      artFetchProc.running = false
      root.verifiedArtUrl = raw
      return
    }

    root.verifiedArtUrl = ""
    artFetchProc.running = false
    artFetchProc.command = [
      "bash", "-c",
      "set -euo pipefail; URL=\"$1\"; CACHE_FILE=\"$2\"; CACHE_DIR=\"$(dirname \"$CACHE_FILE\")\"; mkdir -p -m 0700 \"$CACHE_DIR\"; TMP_FILE=$(mktemp -p \"$CACHE_DIR\" artwork.XXXXXX); trap 'rm -f \"${TMP_FILE:-}\"' EXIT; if [[ \"$URL\" =~ ^https:// ]]; then HTTP_CODE=$(curl -sS --max-time 3 --max-filesize 2097152 --proto \"=https\" -w \"%{http_code}\" \"$URL\" -o \"$TMP_FILE\" 2>/dev/null || echo \"000\"); if [[ \"$HTTP_CODE\" != \"200\" ]]; then exit 1; fi; elif [[ \"$URL\" =~ ^file://(/.*) ]] || [[ \"$URL\" =~ ^(/.*) ]]; then FILE_PATH=\"${BASH_REMATCH[1]}\"; python3 -c '\nimport os,stat,sys\np=sys.argv[1]\nfd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)\nst=os.fstat(fd)\nif not(stat.S_ISREG(st.st_mode) and 4<=st.st_size<=2097152):\n os.close(fd)\n sys.exit(1)\nd=os.read(fd,2097152)\nos.close(fd)\nsys.stdout.buffer.write(d)\n' \"$FILE_PATH\" > \"$TMP_FILE\" 2>/dev/null; else exit 1; fi; MAGIC=$(od -N 12 -A n -t x1 \"$TMP_FILE\" 2>/dev/null | tr -d \" \\n\"); if [[ \"$MAGIC\" =~ ^89504e470d0a1a0a ]] || [[ \"$MAGIC\" =~ ^ffd8 ]] || [[ \"$MAGIC\" =~ ^47494638 ]] || [[ \"$MAGIC\" =~ ^424d ]] || [[ \"$MAGIC\" =~ ^52494646.{8}57454250 ]]; then mv -f \"$TMP_FILE\" \"$CACHE_FILE\"; exit 0; else exit 1; fi",
      "--",
      raw,
      root.artworkCachePath
    ]
    artFetchProc.running = true
  }

  Process {
    id: artFetchProc
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.verifiedArtUrl = "file://" + root.artworkCachePath + "?t=" + Date.now()
      } else {
        root.verifiedArtUrl = ""
      }
    }
  }

  readonly property string identity: activePlayer ? MediaModel.sanitizeText(activePlayer.identity || activePlayer.desktopEntry || "") : ""

  function isProxyPlayer(player) {
    return MediaModel.isProxyPlayer(player)
  }

  function hasMetadata(player) {
    return MediaModel.hasMetadata(player)
  }

  function hasTrackMetadata(player) {
    return MediaModel.hasTrackMetadata(player)
  }

  function playerCanControl(player) {
    return MediaModel.playerCanControl(player)
  }

  function canHandleAction(player, action) {
    return MediaModel.canHandleAction(player, action)
  }

  function canCycleSource(player) {
    return MediaModel.canCycleSource(player)
  }

  function nodeProps(node) {
    return MediaModel.nodeProps(node)
  }

  function isPlaybackStream(node) {
    return MediaModel.isPlaybackStream(node)
  }

  function streamLabelKey(label) {
    return MediaModel.streamLabelKey(label)
  }

  function rawStreamLabel(node) {
    return MediaModel.rawStreamLabel(node)
  }

  function playerAppLabel(player) {
    return MediaModel.playerAppLabel(player)
  }

  function playerHasPlaybackStream(player) {
    return MediaModel.playerHasPlaybackStream(player, playbackStreams)
  }

  // MPRIS PlaybackStatus can go stale while a player is actually producing audio -
  // Chromium in particular can report "Stopped" while one of its tabs still has an
  // unmuted, uncorked PipeWire stream flowing (observed live: 3 active Chromium
  // audio nodes with MPRIS PlaybackStatus == "Stopped"). But an uncorked stream
  // alone doesn't mean much - a browser can sit with several idle/silent tabs'
  // audio contexts open and uncorked with nothing actually playing. Reproduced
  // live: with Chromium's stale-Stopped tabs treated as equally "active" as a
  // genuinely-confirmed-playing Spotify, Chromium kept winning selection over
  // Spotify even while Spotify's own MPRIS said "Playing". Rank real MPRIS
  // confirmation above the stream fallback so it can never be outranked by it -
  // the fallback only matters when nothing is genuinely confirmed playing.
  // 2 = MPRIS-confirmed playing, 1 = active only via the PipeWire-stream
  // fallback, 0 = not active.
  function playerActivityRank(player) {
    if (!player) return 0
    if (pauseOverrideKey && Date.now() < pauseOverrideUntil && sourceListKey(player) === pauseOverrideKey) {
      return 0
    }
    if (player.isPlaying) return 2
    if (playerHasGenuinelyActiveStream(player)) return 1
    return 0
  }

  function isPlayerActive(player) {
    return playerActivityRank(player) > 0
  }

  // Checks every dbus alias of this player's real process (same canonical
  // key), not just this one object's own isPlaying/rank - a real process
  // can register several simultaneous dbus names as separate player
  // objects (see sourceListKey() above), and reproduced live: one specific
  // alias object's isPlaying can lag behind what the process is actually
  // doing while a sibling alias already reflects the real state. The
  // source list's play/pause icon reads this instead of isPlayerActive()
  // on the one representative object the list happened to keep, so it
  // isn't at the mercy of whichever single alias that was.
  function isSourceActive(player) {
    if (!player) return false
    // Groups by sourceListKey (canonical key + current track), not
    // playerCanonicalKey alone: canonicalKey collapses multiple genuinely
    // different real processes of the same app (two separate mpv windows
    // both just "mpv") together, so grouping by it here made one source
    // playing report every other same-app source as "playing" too -
    // reproduced live immediately after this was added. sourceListKey
    // only groups aliases that are actually the same real process (they
    // share identical current track info).
    var lKey = sourceListKey(player)
    if (!lKey) return isPlayerActive(player)
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (p && sourceListKey(p) === lKey && playerActivityRank(p) > 0) return true
    }
    return false
  }

  function playerKey(player) {
    return MediaModel.playerKey(player)
  }

  function playerCanonicalKey(player) {
    return MediaModel.playerCanonicalKey(player)
  }

  function playerForKey(key) {
    if (!key) return null
    var cKey = key.toLowerCase().replace(/[^a-z0-9]/g, "")
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (playerKey(p) === key || playerCanonicalKey(p) === cKey) return p
    }
    return null
  }

  function playerOrder(player, fallback) {
    var key = playerCanonicalKey(player)
    var value = key ? playerStartedAt[key] : undefined
    return value === undefined ? fallback : value
  }

  function syncPlayingOrder() {
    var next = {}
    var alive = {}
    var aliveExact = {}
    var serial = playSerial

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue
      var key = playerCanonicalKey(p)
      if (!key) continue

      alive[key] = true
      var exact = playerKey(p)
      if (exact) aliveExact[exact] = true
      if (!isPlayerActive(p)) continue

      if (playerStartedAt[key] === undefined) {
        serial += 1
        next[key] = serial
      } else {
        next[key] = playerStartedAt[key]
      }
    }

    if (preferredPlayerKey && !alive[preferredPlayerKey]) preferredPlayerKey = ""
    if (preferredPlayerExactKey && !aliveExact[preferredPlayerExactKey]) preferredPlayerExactKey = ""
    if (lastActivePlayerKey && !alive[lastActivePlayerKey]) lastActivePlayerKey = ""

    playSerial = serial
    playerStartedAt = next
  }

  // playerCanonicalKey() alone collapses multiple genuinely distinct player
  // PROCESSES of the same app (e.g. two separate mpv windows, both just
  // "mpv") down to one shared key - reproduced live: 2 separate real mpv
  // processes playing different tracks, together registering 5 dbus names
  // between them (mpv-mpris's instance-suffixed names don't reliably
  // correlate 1:1 with the real process; one single process here owned two
  // DIFFERENT instance suffixes at once), so the source list only ever
  // showed one of the two. That canonical key has to stay app-name-only
  // everywhere else (playerStartedAt/preferredPlayerKey/lastActivePlayerKey
  // all need it stable across a track change, not shifting underneath
  // them), so this is a separate, display-only key used just for listing:
  // appending the current track signature keeps same-process duplicate
  // dbus registrations collapsed (they report the same title) while
  // letting different processes playing different content list separately.
  function sourceListKey(player) {
    var base = playerCanonicalKey(player)
    if (!base) return ""
    var sig = trackSignature(player)
    return sig ? (base + "::" + sig) : base
  }

  function orderedSourcePlayers() {
    var list = []
    var seen = {}

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue
      var cKey = sourceListKey(p)
      if (!cKey || seen[cKey]) continue
      seen[cKey] = true
      if (hasMetadata(p)) {
        list.push(p)
      }
    }

    list.sort(function(a, b) {
      var aRank = playerActivityRank(a)
      var bRank = playerActivityRank(b)
      if (aRank !== bRank) return bRank - aRank
      if (aRank > 0) {
        var orderDelta = playerOrder(b, 0) - playerOrder(a, 0)
        if (orderDelta !== 0) return orderDelta
      }
      return labelFor(a).localeCompare(labelFor(b))
    })

    return list
  }

  function orderedCycleSourcePlayers() {
    var list = []
    var seen = {}

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue
      var cKey = sourceListKey(p)
      if (!cKey || seen[cKey]) continue
      seen[cKey] = true
      if (canCycleSource(p)) {
        list.push(p)
      }
    }

    return list
  }

  function mostRecentPlayingPlayer() {
    var newest = null
    var newestRank = 0
    var newestOrder = -1

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue

      var rank = playerActivityRank(p)
      if (rank === 0) continue

      var order = playerOrder(p, i + 1)
      if (!newest || rank > newestRank || (rank === newestRank && order > newestOrder)) {
        newest = p
        newestRank = rank
        newestOrder = order
      }
    }

    return newest || null
  }

  // Pure: only reads preferredPlayerKey/lastActivePlayerKey/players, never writes
  // them. This is called from the activePlayer binding below - a binding that
  // writes to its own dependencies while it's still being evaluated is a binding
  // loop, and this one was (Quickshell's own scene log confirmed it: "Binding
  // loop detected for property 'activePlayer'"). Reproduced as a real crash, not
  // just a benign warning: closing a browser removes its MPRIS player, which
  // fires onPlayersChanged -> syncPlayingOrder() -> writes playerStartedAt, which
  // re-triggers this binding, which used to write lastActivePlayerKey/
  // preferredPlayerKey mid-evaluation, retriggering itself again - a cascade that
  // showed up in coredumps as 4 nested QQmlBinding update frames terminating in
  // QQuickRepeater::setModel -> regenerate -> incubate (the sourcePlayers-bound
  // Repeater in BarWidget.qml), segfaulting inside Qt's delegate-model machinery
  // while it was reentered mid-update. The "remember what we picked" side effects
  // now live in rememberActivePlayer() below, deferred via Qt.callLater so they
  // can never run while this binding is still on the call stack.
  function selectActivePlayer() {
    // 1. User explicitly selected a preferred player - stays selected
    // regardless of what else starts playing elsewhere, until the user
    // picks a different source or this one disappears entirely (cleared
    // in syncPlayingOrder's alive-check above). Previously this fell back
    // to "whatever else is actively playing" the moment the selected
    // player merely paused, so picking a source and hitting pause on it
    // silently handed control to a different player - the reported
    // "controls stuck to one source" behavior.
    if (preferredPlayerKey) {
      // preferredPlayerExactKey disambiguates which specific player object
      // was actually clicked when multiple real players share the same
      // canonical key (see its declaration above) - checked first, with
      // playerForKey(preferredPlayerKey) as a fallback if that exact
      // object is no longer present but another of the same app is.
      var preferred = null
      if (preferredPlayerExactKey) {
        for (var pi = 0; pi < players.length; pi++) {
          if (players[pi] && playerKey(players[pi]) === preferredPlayerExactKey) {
            preferred = players[pi]
            break
          }
        }
      }
      if (!preferred) preferred = playerForKey(preferredPlayerKey)
      if (preferred && hasMetadata(preferred)) {
        return preferred
      }
    }

    // 2. Currently playing player (picks most recently started)
    var playingPlayer = mostRecentPlayingPlayer()
    if (playingPlayer) {
      return playingPlayer
    }

    // 3. Nothing is currently playing: stick to last active player if still available
    if (lastActivePlayerKey) {
      var last = playerForKey(lastActivePlayerKey)
      if (last && hasMetadata(last)) {
        return last
      }
    }

    // 4. Fallback: first available non-proxy player with metadata
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (p && !isProxyPlayer(p) && hasMetadata(p)) {
        return p
      }
    }

    return null
  }

  // Runs the memory-writing side effects selectActivePlayer() used to perform
  // inline, once activePlayer has actually settled and this binding is off the
  // call stack (deferred via Qt.callLater in onActivePlayerChanged below).
  function rememberActivePlayer() {
    var key = activePlayer ? playerCanonicalKey(activePlayer) : ""
    if (key) lastActivePlayerKey = key
    // No longer clears preferredPlayerKey here: selectActivePlayer's case 1
    // now always returns the preferred player while it resolves and has
    // metadata, so activePlayer only diverges from it when the preference
    // couldn't be resolved at all - which just means automatic selection
    // (cases 2-4) is filling in, not that the preference should be
    // forgotten. A preference that's truly gone is already cleared by
    // syncPlayingOrder's alive-check.
  }

  function cycleSource() {
    var list = orderedSourcePlayers()
    if (list.length <= 1) return false
    var currentKey = activePlayer ? playerCanonicalKey(activePlayer) : ""
    var currentIndex = -1
    for (var i = 0; i < list.length; i++) {
      if (playerCanonicalKey(list[i]) === currentKey) {
        currentIndex = i
        break
      }
    }
    var nextIndex = (currentIndex + 1) % list.length
    return selectPlayer(playerKey(list[nextIndex]))
  }

  function labelFor(player) {
    return MediaModel.labelFor(player)
  }

  function osdMessage(player, fallback) {
    return MediaModel.osdMessage(player, fallback)
  }

  function trackSignature(player) {
    return MediaModel.trackSignature(player)
  }

  function showOsd(actionLabel, iconName, player) {
    if (!shell) return
    shell.summon("omarchy.osd", JSON.stringify({
      icon: iconName || "media",
      message: MediaModel.sanitizeText(osdMessage(player || activePlayer, actionLabel))
    }))
  }

  function scheduleOsd(actionLabel, iconName, player, waitForTrackChange, beforeTrackSignature) {
    if (waitForTrackChange) {
      pendingTrackOsd = {
        actionLabel: actionLabel,
        iconName: iconName,
        player: player,
        playerKey: playerKey(player),
        before: beforeTrackSignature,
        attempts: 0
      }
      trackOsdTimer.restart()
    } else {
      Qt.callLater(function() { root.showOsd(actionLabel, iconName, player) })
    }
  }

  function flushPendingTrackOsd(force) {
    var pending = pendingTrackOsd
    if (!pending) return

    var player = playerForKey(pending.playerKey) || pending.player
    if (force || MediaModel.trackChanged(pending.before, player) || pending.attempts >= 10) {
      pendingTrackOsd = null
      trackOsdTimer.stop()
      root.showOsd(pending.actionLabel, pending.iconName, player)
      return
    }

    pending.attempts = pending.attempts + 1
    pendingTrackOsd = pending
    trackOsdTimer.restart()
  }

  // Only focuses the player - does not start playback. Previously
  // auto-played whatever was selected, so clicking any source while
  // everything was paused immediately resumed it without the user
  // touching play/pause at all. Now that each source row has its own
  // dedicated play/pause control, selecting is a separate action from
  // playing.
  function selectPlayer(key) {
    var player = playerForKey(key)
    if (!player || !hasMetadata(player)) return false
    preferredPlayerKey = playerCanonicalKey(player)
    preferredPlayerExactKey = playerKey(player)
    return true
  }

  function playPlayer(player) {
    if (!player) return false
    if (player.canPlay) {
      player.play()
      return true
    }
    if (player.canTogglePlaying && !player.isPlaying) {
      player.togglePlaying()
      return true
    }
    return false
  }

  function pausePlayer(player) {
    if (!player) return false
    if (player.canPause) {
      player.pause()
      return true
    }
    if (player.canTogglePlaying && player.isPlaying) {
      player.togglePlaying()
      return true
    }
    return false
  }

  function switchSource(delta, transferPlayback, showFeedback) {
    var list = sourceCyclePlayers
    if (!list || list.length === 0) return false

    var activeKey = playerCanonicalKey(activePlayer)
    var index = 0
    for (var i = 0; i < list.length; i++) {
      if (playerCanonicalKey(list[i]) === activeKey) {
        index = i
        break
      }
    }

    index = (index + delta + list.length) % list.length
    var current = activePlayer
    var next = list[index]
    var currentWasPlaying = current && Boolean(current.isPlaying)
    var currentKey = playerCanonicalKey(current)
    var nextKey = playerCanonicalKey(next)

    preferredPlayerKey = nextKey
    preferredPlayerExactKey = playerKey(next)
    lastActivePlayerKey = nextKey

    if (transferPlayback && currentWasPlaying && next && nextKey !== currentKey) {
      var nextWasPlaying = Boolean(next.isPlaying)
      var nextStarted = nextWasPlaying || playPlayer(next)
      if (nextStarted) pausePlayer(current)
    }

    if (showFeedback !== false) Qt.callLater(function() {
      root.showOsd("Source", "media-source", next)
    })

    return true
  }

  function playerForAction(action, targetKey) {
    var targeted = playerForKey(targetKey)
    if (targeted) return targeted

    if (canHandleAction(activePlayer, action)) return activePlayer

    var list = sourcePlayers
    for (var i = 0; i < list.length; i++) {
      if (canHandleAction(list[i], action)) return list[i]
    }

    return activePlayer
  }

  function runAction(action, showFeedback, targetKey) {
    var player = playerForAction(action, targetKey)
    var key = playerKey(player)
    var actionLabel = "Play/pause"
    var iconName = "media"
    var beforeTrackSignature = trackSignature(player)
    var handled = false

    if (action === "next") {
      actionLabel = "Next"
      iconName = "media-next"
      if (player && player.canGoNext) {
        player.next()
        handled = true
      }
    } else if (action === "previous") {
      actionLabel = "Previous"
      iconName = "media-previous"
      if (player && player.canGoPrevious) {
        player.previous()
        handled = true
      }
    } else if (action === "play") {
      actionLabel = "Play"
      iconName = "media-play"
      if (player && player.canPlay) {
        player.play()
        handled = true
      } else if (player && player.canTogglePlaying && !player.isPlaying) {
        player.togglePlaying()
        handled = true
      }
      if (handled) clearPauseOverrideFor(player)
    } else if (action === "pause") {
      actionLabel = "Pause"
      iconName = "media-pause"
      if (player && player.canPause) {
        player.pause()
        handled = true
      } else if (player && player.canTogglePlaying && player.isPlaying) {
        player.togglePlaying()
        handled = true
      }
      if (handled) markExplicitPause(player)
    } else if (action === "playPause") {
      var isCurrentlyPlaying = player && Boolean(player.isPlaying)
      actionLabel = isCurrentlyPlaying ? "Pause" : "Play"
      iconName = isCurrentlyPlaying ? "media-pause" : "media-play"
      if (player && typeof player.togglePlaying === "function") {
        player.togglePlaying()
        handled = true
      } else if (player && player.isPlaying && player.canPause) {
        player.pause()
        handled = true
      } else if (player && !player.isPlaying && player.canPlay) {
        player.play()
        handled = true
      }
      if (handled) {
        if (isCurrentlyPlaying) markExplicitPause(player)
        else clearPauseOverrideFor(player)
      }
    }

    if (handled && key) {
      var cKey = playerCanonicalKey(player)
      preferredPlayerKey = cKey
      preferredPlayerExactKey = key
      lastActivePlayerKey = cKey
    }
    if (showFeedback !== false)
      scheduleOsd(actionLabel, iconName, player, handled && (action === "next" || action === "previous"), beforeTrackSignature)
    return handled
  }

  // Deferred (not called directly) for the same reason as rememberActivePlayer
  // above: syncPlayingOrder() writes playerStartedAt/preferredPlayerKey/
  // lastActivePlayerKey, all of which activePlayer's binding depends on. Called
  // directly, that write could land while activePlayer's very first evaluation
  // (during component construction, or synchronously inside this same
  // onPlayersChanged) is still on the call stack - confirmed via Quickshell's
  // own "Binding loop detected for property activePlayer" warning at startup,
  // even after purifying selectActivePlayer() above. Qt.callLater moves it
  // to a fresh event-loop tick, off that stack, and coalesces repeated calls
  // in the same tick into one.
  Component.onCompleted: {
    Qt.callLater(root.syncPlayingOrder)
    Qt.callLater(root.refreshSourcePlayers)
  }
  onPlayersChanged: {
    Qt.callLater(root.syncPlayingOrder)
    Qt.callLater(root.refreshSourcePlayers)
  }
  onPlayerStartedAtChanged: Qt.callLater(root.refreshSourcePlayers)
  onPlaybackVersionChanged: Qt.callLater(root.refreshSourcePlayers)
  // orderedSourcePlayers() ranks players partly via playerHasGenuinelyActiveStream(),
  // which reads playbackStreams (PipeWire-derived) directly - the old eager
  // `sourcePlayers` binding picked this up automatically via QML's transitive
  // dependency tracking. This plain/deferred version needs it wired explicitly,
  // or the popup's activity-based sort order would go stale whenever only a
  // stream's corked/uncorked state changed with no accompanying MPRIS signal
  // (exactly the stale-PlaybackStatus scenario playerActivityRank exists for).
  onPlaybackStreamsChanged: Qt.callLater(root.refreshSourcePlayers)

  Timer {
    id: trackOsdTimer
    interval: 120
    repeat: false
    onTriggered: root.flushPendingTrackOsd(false)
  }

  PwObjectTracker { objects: root.playbackStreams }

  function statusJson() {
    var p = selectActivePlayer()
    var playing = p ? (p.isPlaying === true) : false
    var playingViaStream = isPlayerActive(p)
    var t = p ? (p.trackTitle || (p.metadata && p.metadata["xesam:title"]) || "") : ""
    var a = p ? (p.trackArtist || (p.metadata && p.metadata["xesam:artist"]) || "") : ""
    var cleanedTitle = MediaModel.cleanTitle(t, a)
    var finalTitle = cleanedTitle || (p ? MediaModel.sanitizeText(p.identity || p.desktopEntry || "Media Playing") : "")
    var finalArtist = p ? MediaModel.cleanArtist(a, t, p) : ""
    var finalAlbum = p ? (p.trackAlbum ? MediaModel.cleanAlbum(p.trackAlbum) : (p.metadata && p.metadata["xesam:album"] ? MediaModel.cleanAlbum(p.metadata["xesam:album"]) : "")) : ""
    var finalIdentity = p ? MediaModel.sanitizeText(p.identity || "") : ""
    var finalDesktop = p ? MediaModel.sanitizeText(p.desktopEntry || "") : ""

    return JSON.stringify({
      hasPlayer: p !== null,
      hasMedia: p !== null && (Boolean(finalTitle) || Boolean(finalArtist) || playing),
      playing: playing,
      playingViaStream: playingViaStream,
      serviceIsPlaying: root.isPlaying,
      audioLevel: root.audioLevel,
      spectrumBands: root.spectrumBands,
      activePlayerStreamFound: root.activePlayerStream !== null,
      audioCandidateStreamCount: root.audioCandidateStreams.length,
      audioLevelUnreliable: root.audioLevelUnreliable,
      audioLevelZeroStreak: root.audioLevelZeroStreak,
      fallbackPeakActive: root.fallbackPeakActive,
      identity: finalIdentity,
      desktopEntry: finalDesktop,
      title: finalTitle,
      artist: finalArtist,
      album: finalAlbum,
      artUrl: root.artUrl,
      hasVolumeControl: root.hasVolumeControl,
      volume: root.volume,
      muted: root.muted,
      canGoNext: p ? !!p.canGoNext : false,
      canGoPrevious: p ? !!p.canGoPrevious : false,
      canTogglePlaying: p ? (!!p.canTogglePlaying || !!p.canPlay || !!p.canPause) : false
    })
  }


  IpcHandler {
    target: "media"

    function status(): string {
      return root.statusJson()
    }

    function playPause(): string {
      return root.runAction("playPause", true) ? "ok" : "unhandled"
    }

    function next(): string {
      return root.runAction("next", true) ? "ok" : "unhandled"
    }

    function previous(): string {
      return root.runAction("previous", true) ? "ok" : "unhandled"
    }

    function play(): string {
      return root.runAction("play", true) ? "ok" : "unhandled"
    }

    function pause(): string {
      return root.runAction("pause", true) ? "ok" : "unhandled"
    }

    function sourceNext(): string {
      return root.switchSource(1, false, true) ? "ok" : "unhandled"
    }

    function sourcePrevious(): string {
      return root.switchSource(-1, false, true) ? "ok" : "unhandled"
    }

    function sourceSwitch(): string {
      return root.switchSource(1, true, true) ? "ok" : "unhandled"
    }

    function sourceSwitchPrevious(): string {
      return root.switchSource(-1, true, true) ? "ok" : "unhandled"
    }

    function volumeUp(): string {
      return root.adjustVolume(0.05) ? "ok" : "unhandled"
    }

    function volumeDown(): string {
      return root.adjustVolume(-0.05) ? "ok" : "unhandled"
    }

    function setVolume(value: real): string {
      return root.setVolume(value) ? "ok" : "unhandled"
    }

    function toggleMute(): string {
      return root.toggleMute() ? "ok" : "unhandled"
    }

    function ping(): string {
      return "ok"
    }
  }
}
