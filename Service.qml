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
  property string lastActivePlayerKey: ""
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
    fallbackPeakProc.command = [
      "bash", "-c",
      "set -uo pipefail; NODE_ID=\"$1\"; if ! [[ \"$NODE_ID\" =~ ^[0-9]+$ ]]; then exit 1; fi; set -m; pw-record --target=\"$NODE_ID\" -P '{ format=s16 rate=44100 channels=2 }' - 2>/dev/null | python3 -u -c '\nimport struct, sys\nwhile True:\n    data = sys.stdin.buffer.read(4096)\n    if not data:\n        break\n    n = len(data) // 2\n    if n == 0:\n        continue\n    samples = struct.unpack(\"<\" + str(n) + \"h\", data[:n * 2])\n    peak = max(abs(s) for s in samples) / 32768.0\n    print(\"%.4f\" % peak, flush=True)\n' & JOB_PID=$!; trap 'kill -TERM -- \"-$JOB_PID\" 2>/dev/null' EXIT TERM INT; wait \"$JOB_PID\"",
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
  onFallbackPeakTargetNodeChanged: refreshFallbackPeakMeter()

  Process {
    id: fallbackPeakProc
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        var v = parseFloat(data)
        if (isFinite(v)) {
          root.fallbackPeakActive = true
          root.fallbackPeakLevel = Math.max(0, Math.min(1, v))
        }
      }
    }
    onExited: {
      root.fallbackPeakActive = false
      root.fallbackPeakLevel = 0
    }
  }

  property var sourcePlayers: []
  readonly property var sourceCyclePlayers: orderedCycleSourcePlayers()

  Timer {
    id: sourcePlayersDebounceTimer
    interval: 10
    running: false
    repeat: false
    onTriggered: {
      root.sourcePlayers = root.orderedSourcePlayers()
    }
  }

  onPlayersChanged: sourcePlayersDebounceTimer.restart()
  onPlaybackVersionChanged: sourcePlayersDebounceTimer.restart()
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

  // isPlaying reads activePlayer.isPlaying directly — a real QML property access.
  // When activePlayer switches (e.g. Spotify→YouTube), this re-evaluates immediately.
  // When the current player pauses/resumes, activePlayer.isPlaying notifies this binding.
  // Falls back to isPlayerActive's PipeWire-stream check for players whose MPRIS
  // PlaybackStatus is stale (see isPlayerActive above).
  readonly property bool isPlaying: isPlayerActive(activePlayer)

  Timer {
    id: playbackDebounceTimer
    interval: 10
    running: false
    repeat: false
    onTriggered: {
      root.syncPlayingOrder()
      root.playbackVersion++
    }
  }

  // Per-player signal connections — use Mpris.players (UntypedObjectModel) directly
  // as the Instantiator model so Qt creates one Connections delegate per player.
  // Wire all relevant MprisPlayer notify signals so any change in state, track, or
  // metadata causes immediate UI updates.
  Instantiator {
    model: Mpris.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() { playbackDebounceTimer.restart() }
      function onPlaybackStateChanged() { playbackDebounceTimer.restart() }
      function onMetadataChanged() { playbackDebounceTimer.restart() }
      function onTrackTitleChanged() { playbackDebounceTimer.restart() }
      function onTrackArtistChanged() { playbackDebounceTimer.restart() }
      function onTrackAlbumChanged() { playbackDebounceTimer.restart() }
      function onTrackArtUrlChanged() { playbackDebounceTimer.restart() }
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

  function playerHasActiveStream(player) {
    return MediaModel.playerHasActiveStream(player, playbackStreams)
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
    if (player.isPlaying) return 2
    if (playerHasActiveStream(player)) return 1
    return 0
  }

  function isPlayerActive(player) {
    return playerActivityRank(player) > 0
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
    var serial = playSerial

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue
      var key = playerCanonicalKey(p)
      if (!key) continue

      alive[key] = true
      if (!isPlayerActive(p)) continue

      if (playerStartedAt[key] === undefined) {
        serial += 1
        next[key] = serial
      } else {
        next[key] = playerStartedAt[key]
      }
    }

    if (preferredPlayerKey && !alive[preferredPlayerKey]) preferredPlayerKey = ""
    if (lastActivePlayerKey && !alive[lastActivePlayerKey]) lastActivePlayerKey = ""

    playSerial = serial
    playerStartedAt = next
  }

  function orderedSourcePlayers() {
    var list = []
    var seen = {}

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue
      var cKey = playerCanonicalKey(p)
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
      var cKey = playerCanonicalKey(p)
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

  function selectActivePlayer() {
    // 1. User explicitly selected a preferred player
    if (preferredPlayerKey) {
      var preferred = playerForKey(preferredPlayerKey)
      if (preferred && hasMetadata(preferred)) {
        if (isPlayerActive(preferred)) {
          lastActivePlayerKey = preferredPlayerKey
          return preferred
        }
        // Preferred player is paused — check if any OTHER player is actively playing
        var otherPlaying = mostRecentPlayingPlayer()
        if (otherPlaying) {
          // A different player is actively playing — switch to the actively playing player
          preferredPlayerKey = ""
          var k = playerCanonicalKey(otherPlaying)
          if (k) lastActivePlayerKey = k
          return otherPlaying
        }
        // Nothing else is playing — keep showing the preferred player (paused)
        return preferred
      }
    }

    // 2. Currently playing player (picks most recently started)
    var playingPlayer = mostRecentPlayingPlayer()
    if (playingPlayer) {
      var pk = playerCanonicalKey(playingPlayer)
      if (pk) lastActivePlayerKey = pk
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
        var fKey = playerCanonicalKey(p)
        if (fKey) lastActivePlayerKey = fKey
        return p
      }
    }

    return null
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

  function selectPlayer(key) {
    var player = playerForKey(key)
    if (!player || !hasMetadata(player)) return false
    preferredPlayerKey = playerCanonicalKey(player)
    if (!player.isPlaying && (player.canPlay || player.canTogglePlaying)) {
      playPlayer(player)
    }
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
    }

    if (handled && key) {
      var cKey = playerCanonicalKey(player)
      preferredPlayerKey = cKey
      lastActivePlayerKey = cKey
    }
    if (showFeedback !== false)
      scheduleOsd(actionLabel, iconName, player, handled && (action === "next" || action === "previous"), beforeTrackSignature)
    return handled
  }

  Component.onCompleted: root.syncPlayingOrder()
  onPlayersChanged: root.syncPlayingOrder()

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
