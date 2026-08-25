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

  readonly property var sourcePlayers: orderedSourcePlayers()
  readonly property var sourceCyclePlayers: orderedCycleSourcePlayers()
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
  readonly property bool isPlaying: (activePlayer && activePlayer.isPlaying) || false

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
        root.syncPlayingOrder()
        root.playbackVersion++
      }
      function onPlaybackStateChanged() {
        root.syncPlayingOrder()
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
    return activePlayer.identity || activePlayer.desktopEntry || "Media Playing"
  }

  readonly property string artist: {
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    return MediaModel.cleanArtist(a, t, activePlayer)
  }

  readonly property string album: activePlayer && activePlayer.trackAlbum ? activePlayer.trackAlbum : ""
  readonly property string artUrl: activePlayer ? MediaModel.extractArtUrl(activePlayer) : ""
  readonly property string identity: activePlayer ? (activePlayer.identity || activePlayer.desktopEntry || "") : ""

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
      if (!p.isPlaying) continue

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
      var aPlay = Boolean(a.isPlaying)
      var bPlay = Boolean(b.isPlaying)
      if (aPlay !== bPlay) return aPlay ? -1 : 1
      if (aPlay && bPlay) {
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
    var newestOrder = -1

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue

      if (p.isPlaying) {
        var order = playerOrder(p, i + 1)
        if (!newest || order > newestOrder) {
          newest = p
          newestOrder = order
        }
      }
    }

    return newest || null
  }

  function selectActivePlayer() {
    // 1. User explicitly selected a preferred player
    if (preferredPlayerKey) {
      var preferred = playerForKey(preferredPlayerKey)
      if (preferred && hasMetadata(preferred)) {
        if (preferred.isPlaying) {
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
      message: osdMessage(player || activePlayer, actionLabel)
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
    var t = p ? (p.trackTitle || (p.metadata && p.metadata["xesam:title"]) || "") : ""
    var a = p ? (p.trackArtist || (p.metadata && p.metadata["xesam:artist"]) || "") : ""
    var cleanedTitle = MediaModel.cleanTitle(t, a)
    var finalTitle = cleanedTitle || (p ? (p.identity || p.desktopEntry || "Media Playing") : "")
    var finalArtist = p ? MediaModel.cleanArtist(a, t, p) : ""

    return JSON.stringify({
      hasPlayer: p !== null,
      hasMedia: p !== null && (Boolean(finalTitle) || Boolean(finalArtist) || playing),
      playing: playing,
      identity: p ? (p.identity || "") : "",
      desktopEntry: p ? (p.desktopEntry || "") : "",
      title: finalTitle,
      artist: finalArtist,
      album: p && p.trackAlbum ? p.trackAlbum : (p && p.metadata && p.metadata["xesam:album"] ? p.metadata["xesam:album"] : ""),
      artUrl: p ? MediaModel.extractArtUrl(p) : "",
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

    function ping(): string {
      return "ok"
    }
  }
}
