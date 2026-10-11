import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons
import "MediaModel.js" as MediaModel

BarWidget {
  id: root
  moduleName: "custom.media"

  property var service: null
  property string visualizerMode: "wave" // "wave", "bars", "dots", "particles", "pulse", "cava"
  property bool showText: true           // Toggle track title / artist text in bar capsule

  // The original repo registered this plugin under a per-user id
  // (${USER_NAME}.media) before this fork switched to the fixed
  // "custom.media" id above. Derive that legacy id from the account
  // actually running the shell instead of a hardcoded name - a literal
  // like "nek0.media" only ever matched one specific developer's own
  // machine and was a no-op fallback for everyone else.
  readonly property string legacyUserPluginId: {
    var u = Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
    return u ? (u + ".media") : ""
  }

  readonly property var mediaService: {
    if (service) return service
    if (!root.bar || !root.bar.shell) return null
    if (root.moduleName && root.bar.shell.serviceFor(root.moduleName))
      return root.bar.shell.serviceFor(root.moduleName)
    if (root.bar.shell.serviceFor("custom.media"))
      return root.bar.shell.serviceFor("custom.media")
    if (root.legacyUserPluginId && root.bar.shell.serviceFor(root.legacyUserPluginId))
      return root.bar.shell.serviceFor(root.legacyUserPluginId)
    if (root.bar.shell.serviceFor("omarchy.media"))
      return root.bar.shell.serviceFor("omarchy.media")
    if (root.bar.shell.firstPartyServiceFor("omarchy.media"))
      return root.bar.shell.firstPartyServiceFor("omarchy.media")
    return null
  }

  function deduplicatePlayers(players) {
    var list = []
    var seen = {}
    var raw = players || []
    for (var i = 0; i < raw.length; i++) {
      var p = raw[i]
      if (!p || MediaModel.isProxyPlayer(p)) continue
      var cKey = MediaModel.playerCanonicalKey(p)
      if (!cKey || seen[cKey]) continue
      seen[cKey] = true
      if (MediaModel.hasMetadata(p)) list.push(p)
    }
    return list
  }

  readonly property var fallbackPlayers: deduplicatePlayers(Mpris.players ? Mpris.players.values : [])

  function findFallbackActivePlayer() {
    var list = fallbackPlayers || []
    var fallback = null
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p) continue
      if (p.isPlaying) return p
      if (!fallback && (p.trackTitle || p.trackArtist || p.canPlay)) fallback = p
    }
    return fallback
  }

  // Reading mediaService.activePlayer is a direct QML property access — QML tracks
  // it as a dependency and re-evaluates when the service's activePlayer changes.
  // The fallback reads Mpris.players.values directly so isPlaying changes still propagate.
  readonly property var activePlayer: {
    if (mediaService && mediaService.activePlayer) return mediaService.activePlayer
    return findFallbackActivePlayer()
  }
  readonly property var sourcePlayers: mediaService && mediaService.sourcePlayers && mediaService.sourcePlayers.length > 0 ? mediaService.sourcePlayers : fallbackPlayers
  // Prefer mediaService.isPlaying when the service backs the current activePlayer: it
  // also treats a player as playing when its PipeWire stream is actively flowing even
  // if MPRIS's own PlaybackStatus is stale (e.g. Chromium reporting "Stopped" while a
  // tab still has an unmuted, uncorked audio stream). The no-service fallback path has
  // no PipeWire correlation available, so it stays on raw MPRIS state.
  readonly property bool isPlaying: {
    if (mediaService && mediaService.activePlayer) return Boolean(mediaService.isPlaying)
    return (activePlayer && activePlayer.isPlaying) || false
  }

  // Per-app volume mirrors mediaService only — the standalone fallback path (no service)
  // has no PipeWire stream correlation available, so volume control is simply unavailable then.
  readonly property bool hasVolumeControl: Boolean(mediaService && mediaService.hasVolumeControl)
  readonly property real volume: hasVolumeControl ? mediaService.volume : 1.0
  readonly property bool muted: Boolean(mediaService && mediaService.muted)

  function setVolume(value) {
    if (mediaService && typeof mediaService.setVolume === "function") mediaService.setVolume(value)
  }

  function toggleMute() {
    if (mediaService && typeof mediaService.toggleMute === "function") mediaService.toggleMute()
  }

  // While playing, drive amplitude from the active player's real PipeWire peak level
  // (mediaService.audioLevel) so all visualizer modes react to actual loudness instead of
  // a constant. Falls back to the old fixed energy when no matching PipeWire stream could
  // be found for the player at all. Paused/idle keep the ambient drift levels.
  //
  // audioGain went 2.4 -> 1.15 in an earlier session, still not low enough: live
  // mediaService.audioLevel for ordinary loud playback (a YouTube video in Chromium)
  // sat in the 0.77-0.86 range in a live capture, and even 1.15x of that clips the
  // Math.min(1.0, ...) ceiling almost every sample - every visualizer mode rendered
  // the same near-maxed, visually frozen shape regardless of the real level actually
  // moving underneath it ("nothing is moving" despite audioLevel measurably
  // fluctuating sample to sample). The canvas now applies its own perceptual curve
  // (shape(), in BarWidget's Canvas) to lift quiet passages instead, so this no
  // longer needs to pre-boost the signal at all - any gain here just reintroduces
  // the same ceiling-clipping for already-loud content.
  property real audioGain: 1.0
  readonly property real liveAudioLevel: (mediaService && mediaService.audioLevel) || 0
  readonly property bool hasLiveAudioLevel: Boolean(mediaService && mediaService.hasLiveAudioLevel)
  // Was a nonzero idle/paused baseline (0.08-0.18) and an always-on 0.15
  // floor while playing, so every graph/line visualizer mode kept a
  // resting height even with nothing actually happening - never a true
  // zero. All three branches now return 0 whenever there's no real level
  // to show; only genuinely live audio produces nonzero energy.
  readonly property real targetEnergy: {
    if (!isPlaying || !hasLiveAudioLevel) return 0
    return Math.max(0, Math.min(1.0, liveAudioLevel * audioGain))
  }
  property real currentEnergy: targetEnergy

  Behavior on currentEnergy {
    NumberAnimation { duration: 160; easing.type: Easing.OutQuad }
  }

  readonly property bool hasMedia: activePlayer !== null && (Boolean(title) || Boolean(isPlaying) || Boolean(activePlayer.trackTitle || activePlayer.trackArtist))
  readonly property string playIcon: isPlaying ? "󰏤" : "󰐊"
  
  readonly property string title: {
    if (mediaService && mediaService.title) return MediaModel.sanitizeText(mediaService.title)
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    if (t) return MediaModel.cleanTitle(t, a)
    if (activePlayer.identity) return MediaModel.sanitizeText(activePlayer.identity)
    if (activePlayer.desktopEntry) return MediaModel.sanitizeText(activePlayer.desktopEntry)
    return "Playing"
  }

  readonly property string artist: {
    if (mediaService && mediaService.artist) return MediaModel.sanitizeText(mediaService.artist)
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    return MediaModel.cleanArtist(a, t, activePlayer)
  }

  readonly property string album: {
    if (mediaService && mediaService.album) return MediaModel.cleanAlbum(mediaService.album)
    if (!activePlayer) return ""
    if (activePlayer.trackAlbum) return MediaModel.cleanAlbum(activePlayer.trackAlbum)
    if (activePlayer.metadata && activePlayer.metadata["xesam:album"]) return MediaModel.cleanAlbum(activePlayer.metadata["xesam:album"])
    return ""
  }

  property string verifiedArtUrl: ""
  readonly property string rawCandidateArtUrl: {
    if (mediaService && mediaService.artUrl) return MediaModel.sanitizeArtUrl(mediaService.artUrl)
    if (!activePlayer) return ""
    return MediaModel.extractArtUrl(activePlayer)
  }

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

    // Remote HTTPS or local file: validate & cache with strict byte limits, no redirects, secure mktemp, and magic byte check
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

  property bool popupOpen: false
  property bool isMinimized: false

  function close() { popupOpen = false }
  // Was 220, then 140: still stretched the pill wider than the other bar
  // chips for a short title. Trimmed further to keep the capsule closer in
  // scale to the rest of the bar; most short titles still show without
  // scrolling, longer ones just scroll a bit sooner.
  property real maxLabelWidth: 100
  // Width of the visualizer when it sits beside the track text instead of
  // filling the whole pill behind it (see waveCanvas/flowRow below) - was a
  // full-pill background with the title/artist text centered on top of it,
  // which made the moving wave/bars/etc. compete with the text for
  // readability. Icon-only modes (minimized, !showText) still use the full
  // pill width since there's no text there to read past.
  property real visualizerStripWidth: Style.space(30)

  function playerKey(player) {
    if (!player) return ""
    if (mediaService && typeof mediaService.playerKey === "function") return mediaService.playerKey(player)
    return MediaModel.playerKey(player)
  }

  function playerCanonicalKey(player) {
    if (!player) return ""
    return MediaModel.playerCanonicalKey(player)
  }

  function runAction(action, targetPlayer) {
    var p = targetPlayer || activePlayer
    if (!p) return
    if (mediaService && typeof mediaService.runAction === "function") {
      mediaService.runAction(action, false, playerKey(p))
      return
    }
    if (action === "playPause") {
      if (typeof p.togglePlaying === "function") p.togglePlaying()
      else if (typeof p.playPause === "function") p.playPause()
      else if (p.isPlaying && typeof p.pause === "function") p.pause()
      else if (typeof p.play === "function") p.play()
    } else if (action === "next" && typeof p.next === "function") {
      p.next()
    } else if (action === "previous" && typeof p.previous === "function") {
      p.previous()
    }
  }

  function selectPlayer(targetPlayer) {
    if (!targetPlayer) return
    var key = playerKey(targetPlayer)
    if (mediaService && typeof mediaService.selectPlayer === "function") {
      mediaService.selectPlayer(key)
    } else {
      if (typeof targetPlayer.play === "function") {
        targetPlayer.play()
      } else if (typeof targetPlayer.togglePlaying === "function") {
        targetPlayer.togglePlaying()
      }
    }
  }

  function sourceName(player) {
    return MediaModel.sourceName(player)
  }

  function sourceIcon(player) {
    return MediaModel.sourceIcon(player)
  }

  visible: true
  implicitWidth: pill.width + Style.space(8)
  implicitHeight: barSize

  Behavior on implicitWidth {
    NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
  }

  // Bar Pill Capsule - Dynamic Continuous Flow Audio Visualizer
  BorderSurface {
    id: pill
    anchors.centerIn: parent
    height: Math.min(parent.height - Style.space(6), Style.space(28))
    width: root.isMinimized
      ? height
      : (root.showText
          ? (Style.space(1) + root.visualizerStripWidth + Style.space(5) + flowRow.implicitWidth + Style.space(6))
          // Was Style.space(110): wider than the visualizer (which fills this
          // whole pill in icon-only mode, unlike the narrow strip it gets
          // beside text) needs to still read clearly, so it left noticeable
          // empty-looking background around it. Trimmed while keeping enough
          // room for the wave/bars/dots/particles shapes to stay legible.
          : Style.space(72))
    radius: height / 2
    clip: true
    color: clickArea.containsMouse ? Util.alpha(root.bar ? root.bar.barForeground : Color.foreground, 0.05) : "transparent"
    borderSpec: Border.none()

    Behavior on width {
      NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
    }
    Behavior on color {
      ColorAnimation { duration: 180 }
    }

    // Dynamic Multi-Mode Continuous Audio Visualizer Canvas
    Canvas {
      id: waveCanvas
      visible: !root.isMinimized
      // Side by side with flowRow's icon+text in text mode (a narrow left-hand
      // strip) instead of anchors.fill: parent with the text centered on top
      // of it - full pill width still applies to the icon-only modes below,
      // which have no text to compete with.
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(2)
      anchors.topMargin: Style.space(2)
      anchors.bottomMargin: Style.space(2)
      width: root.showText ? root.visualizerStripWidth : (parent.width - Style.space(4))

      // Real per-band spectrum (root.mediaService.spectrumBands, a 14-band
      // live Goertzel analysis - see Service.qml) instead of one aggregate
      // loudness scalar. Every mode below reads its own slice of the real
      // spectrum, so bars/dots/particles/cava genuinely move independently
      // like a real equalizer instead of all rising and falling together
      // off the same number; wave draws the actual frequency curve instead
      // of a formula. scrollX still just paces particles' x-flow (speed
      // tracks real energy, frozen at 0 energy - no motion with nothing
      // playing).
      property real scrollX: 0

      function sampleEnergy(dt) {
        scrollX += dt * root.currentEnergy * 50
        requestPaint()
      }

      Timer {
        id: sampleTimer
        interval: 33
        running: true
        repeat: true
        onTriggered: waveCanvas.sampleEnergy(interval / 1000)
      }

      // Resamples the real band array (whatever its length) onto `count`
      // elements by nearest-neighbor index mapping, so bar/dot/particle
      // counts (which scale with canvas width, not the band count) each
      // still read a genuine, distinct slice of the spectrum.
      function bandAt(bands, index, count) {
        if (!bands || bands.length === 0) return 0
        var i = Math.min(bands.length - 1, Math.floor((index / count) * bands.length))
        return bands[i]
      }

      // Perceptual curve so quiet bands still read as visible motion
      // instead of flat-lining: raw linear values near the AGC floor
      // render as a barely-there sliver otherwise.
      function shape(v) { return Math.pow(Math.max(0, Math.min(1, v)), 0.6) }

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (width <= 0 || height <= 0) return

        var midY = height / 2
        var energy = root.currentEnergy
        var mode = root.visualizerMode
        var bands = root.mediaService ? root.mediaService.spectrumBands : []
        var bn = bands.length

        if (mode === "wave") {
          // The real frequency-response curve itself (bass on the left,
          // treble on the right) instead of a sine formula - genuinely
          // reflects what's playing, and is "wavy" because real spectra
          // are. A second curve walks the same bands in reverse (treble
          // to bass), so the two lines cross wherever the spectrum's low
          // and high ends happen to agree, instead of running parallel.
          ctx.lineWidth = 1.2
          ctx.strokeStyle = energy > 0.4 ? Color.accent : Util.alpha(Color.accent, 0.4)
          ctx.beginPath()
          for (var i = 0; i < bn; i++) {
            var x = bn > 1 ? (i / (bn - 1)) * width : 0
            var y = midY - shape(bands[i]) * height * 0.42
            if (i === 0) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.stroke()

          if (bn > 0) {
            ctx.lineWidth = 0.9
            ctx.strokeStyle = root.bar ? root.bar.barForeground : Color.foreground
            ctx.beginPath()
            for (var j = 0; j < bn; j++) {
              var xj = bn > 1 ? (j / (bn - 1)) * width : 0
              var yj = midY + shape(bands[bn - 1 - j]) * height * 0.32
              if (j === 0) ctx.moveTo(xj, yj)
              else ctx.lineTo(xj, yj)
            }
            ctx.stroke()
          }
        } else if (mode === "bars") {
          // Scaled to the canvas's actual width rather than a showText-keyed
          // constant: the visualizer strip is much narrower (~30px) beside the
          // text than it is filling the whole pill (~100px+) in icon-only mode,
          // and a fixed 16 bars packed into 30px rendered as an illegible smear.
          var numBars = Math.max(3, Math.round(width / 5))
          var barW = (width / numBars) * 0.45
          var gap = (width / numBars) * 0.55
          ctx.fillStyle = energy > 0.4 ? Color.accent : Util.alpha(Color.accent, 0.4)
          for (var b = 0; b < numBars; b++) {
            var bh = shape(bandAt(bands, b, numBars)) * height * 0.85 + 2
            var bx = b * (barW + gap) + gap / 2
            var by = midY - bh / 2
            ctx.fillRect(bx, by, barW, bh)
          }
        } else if (mode === "dots") {
          // Width-scaled for the same reason as numBars above.
          var numDots = Math.max(3, Math.round(width / 6))
          var step = width / (numDots + 1)
          ctx.fillStyle = energy > 0.4 ? Color.accent : Util.alpha(Color.accent, 0.4)
          for (var d = 1; d <= numDots; d++) {
            var dx = d * step
            var dsample = shape(bandAt(bands, d, numDots))
            var dy = midY + (d % 2 === 0 ? 1 : -1) * dsample * height * 0.4
            var r = 1.5 + dsample * 1.8
            ctx.beginPath()
            ctx.arc(dx, dy, r, 0, Math.PI * 2)
            ctx.fill()
          }
        } else if (mode === "particles") {
          // Width-scaled for the same reason as numBars above. X position
          // scrolls on real elapsed time (speed still tracks real energy);
          // size/Y amplitude come from this particle's own band.
          var numParts = Math.max(3, Math.round(width / 7))
          for (var pIdx = 0; pIdx < numParts; pIdx++) {
            var px = (pIdx * 28 + scrollX) % width
            var psample = shape(bandAt(bands, pIdx, numParts))
            var py = midY + (pIdx % 2 === 0 ? 1 : -1) * psample * height * 0.35
            ctx.fillStyle = (pIdx % 2 === 0) ? (energy > 0.4 ? Color.accent : Util.alpha(Color.accent, 0.4)) : (root.bar ? root.bar.barForeground : Color.foreground)
            ctx.beginPath()
            ctx.arc(px, py, 1.4 + psample * 1.4, 0, Math.PI * 2)
            ctx.fill()
          }
        } else if (mode === "pulse") {
          // Driven directly by the live scalar, no synthetic beat formula.
          var pulseScale = 0.25 + energy * 0.65
          var grad = ctx.createRadialGradient(width / 2, midY, 2, width / 2, midY, (width / 2) * pulseScale)
          grad.addColorStop(0, energy > 0.4 ? Color.accent : Util.alpha(Color.accent, 0.3))
          grad.addColorStop(1, "transparent")
          ctx.fillStyle = grad
          ctx.fillRect(0, 0, width, height)
        } else if (mode === "cava") {
          // Classic cava-style equalizer: same bar count/width scaling as
          // "bars" above, but anchored to the bottom (0 height when silent)
          // and growing straight up only, instead of "bars"'s symmetric
          // grow-from-middle.
          var numCavaBars = Math.max(3, Math.round(width / 5))
          var cavaBarW = (width / numCavaBars) * 0.45
          var cavaGap = (width / numCavaBars) * 0.55
          ctx.fillStyle = energy > 0.4 ? Color.accent : Util.alpha(Color.accent, 0.4)
          for (var cb = 0; cb < numCavaBars; cb++) {
            var cbh = shape(bandAt(bands, cb, numCavaBars)) * height
            var cbx = cb * (cavaBarW + cavaGap) + cavaGap / 2
            ctx.fillRect(cbx, height - cbh, cavaBarW, cbh)
          }
        }
      }
    }

    // Minimized Mode (Single icon)
    Item {
      anchors.fill: parent
      visible: root.isMinimized

      Text {
        anchors.centerIn: parent
        text: "󰝚"
        textFormat: Text.PlainText
        color: root.isPlaying ? Color.accent : (clickArea.containsMouse ? Color.accent : (root.bar ? root.bar.barForeground : Color.foreground))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        Behavior on color { ColorAnimation { duration: 140 } }
      }
    }

    // Pure Minimalist Visualizer Mode (Source Glyph centered over flow)
    Item {
      anchors.fill: parent
      visible: !root.isMinimized && !root.showText

      Text {
        anchors.centerIn: parent
        text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
        textFormat: Text.PlainText
        color: root.isPlaying ? Color.accent : (root.hasMedia ? (root.bar ? root.bar.barForeground : Color.foreground) : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.4))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        Behavior on color { ColorAnimation { duration: 140 } }
      }
    }

    // Full Expanded Mode (Music icon + Scrolling song name, beside the flow visualizer)
    Row {
      id: flowRow
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: waveCanvas.right
      anchors.leftMargin: Style.space(7)
      spacing: Style.space(7)
      visible: !root.isMinimized && root.showText

      // Music Icon / Source Glyph
      Text {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
        textFormat: Text.PlainText
        color: root.isPlaying ? Color.accent : (root.hasMedia ? (root.bar ? root.bar.barForeground : Color.foreground) : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.4))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }

      // Track Title & Artist with smooth marquee scroll, or idle placeholder
      Item {
        id: scrollClip
        width: root.hasMedia ? Math.min(root.maxLabelWidth, titleRow.implicitWidth) : idleLabel.implicitWidth
        height: Math.max(glyph.implicitHeight, Style.space(16))
        clip: true
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.bar || !root.bar.vertical

        Text {
          id: idleLabel
          visible: !root.hasMedia
          text: "Music"
          textFormat: Text.PlainText
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          id: titleRow
          visible: root.hasMedia
          spacing: Style.space(5)
          anchors.verticalCenter: parent.verticalCenter

          property bool needsScroll: titleRow.implicitWidth > root.maxLabelWidth

          Text {
            id: titleText
            text: root.title
            textFormat: Text.PlainText
            color: root.bar ? root.bar.barForeground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: sepText
            visible: root.artist !== ""
            text: "·"
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: artistText
            visible: root.artist !== ""
            text: root.artist
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          SequentialAnimation on x {
            id: scrollAnim
            running: titleRow.needsScroll && !root.popupOpen && (!root.bar || !root.bar.vertical) && root.hasMedia && !root.isMinimized && root.showText
            loops: Animation.Infinite

            PauseAnimation { duration: 2500 }
            NumberAnimation {
              to: -(titleRow.implicitWidth - scrollClip.width)
              duration: Math.max(3000, (titleRow.implicitWidth - scrollClip.width) * 35)
              easing.type: Easing.Linear
            }
            PauseAnimation { duration: 2000 }
            NumberAnimation {
              to: 0
              duration: Math.max(1500, (titleRow.implicitWidth - scrollClip.width) * 15)
              easing.type: Easing.InOutQuad
            }
          }
        }
      }
    }
  }

  // Interactive Bar Click Area
  MouseArea {
    id: clickArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        root.runAction("playPause", root.activePlayer)
      } else if (mouse.button === Qt.RightButton) {
        root.showText = !root.showText
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
    onWheel: function(wheel) {
      if (!root.activePlayer) return
      if (wheel.angleDelta.y > 0) {
        root.runAction("previous", root.activePlayer)
      } else if (wheel.angleDelta.y < 0) {
        root.runAction("next", root.activePlayer)
      }
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? MediaModel.sanitizeText(root.title + (root.artist ? " — " + root.artist : "")) : "Music Player (Right-click: Toggle Text)")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // Dedicated Floating Player & Source Selection Window
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(12)

      // Top Row: Album Cover Art & Song Info
      Row {
        spacing: Style.space(12)
        width: parent.width

        BorderSurface {
          width: Style.space(72)
          height: Style.space(72)
          radius: Style.spacing.labelGap
          color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.08)
          borderSpec: Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            autoTransform: true
            sourceSize.width: Style.space(144)
            sourceSize.height: Style.space(144)
            source: root.artUrl
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: root.artUrl === ""
            text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(3)
          width: parent.width - Style.space(84)
          anchors.verticalCenter: parent.verticalCenter

          // Active Source Badge
          Row {
            spacing: Style.space(4)
            Text {
              text: root.sourceIcon(root.activePlayer)
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: root.sourceName(root.activePlayer).toUpperCase()
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            text: root.title || "Nothing playing"
            textFormat: Text.PlainText
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: root.artist
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            text: root.album
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      // Playback Controls
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(12)

        Button {
          iconText: "󰒮"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: Boolean(root.activePlayer && root.activePlayer.canGoPrevious)
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runAction("previous", root.activePlayer)
        }

        Button {
          iconText: root.isPlaying ? "󰏤" : "󰐊"
          foreground: Color.accent
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: Boolean(root.activePlayer && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause || root.isPlaying))
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runAction("playPause", root.activePlayer)
        }

        Button {
          iconText: "󰒭"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: Boolean(root.activePlayer && root.activePlayer.canGoNext)
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runAction("next", root.activePlayer)
        }
      }

      // Per-Source Volume (the PipeWire stream correlated to the active player)
      Row {
        width: parent.width
        spacing: Style.space(8)
        visible: root.hasVolumeControl

        Text {
          id: volumeIcon
          text: root.muted ? "󰝟" : (root.volume > 0.5 ? "󰕾" : (root.volume > 0 ? "󰖀" : "󰕿"))
          textFormat: Text.PlainText
          color: volumeIconMouse.containsMouse ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          anchors.verticalCenter: parent.verticalCenter

          Behavior on color { ColorAnimation { duration: 140 } }

          MouseArea {
            id: volumeIconMouse
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleMute()
          }
        }

        PanelSlider {
          id: volumeSlider
          bar: root.bar
          width: parent.width - volumeIcon.width - Style.space(8)
          minimum: 0
          maximum: 1
          step: 0.05
          value: root.muted ? 0 : root.volume
          anchors.verticalCenter: parent.verticalCenter
          onMoved: function(v) { root.setVolume(v) }
          onReleased: function(v) { root.setVolume(v) }
          onRightClicked: root.toggleMute()
        }
      }

      // Visualizer Flow & Text Visibility Switcher
      Column {
        width: parent.width
        spacing: Style.space(6)

        // Column instead of Flow/Row: Column only ever positions children
        // vertically and leaves their x alone, so each child below can use
        // anchors.horizontalCenter to actually center itself - a positioner
        // that also controls x (Row, Flow) overrides any anchor on its
        // direct children, which is why centering wasn't possible before.
        Column {
          width: parent.width
          spacing: Style.space(6)

          Grid {
            // Grid instead of Flow: a fixed column count gives a
            // deterministic, centerable block width (columns * cell width)
            // regardless of each label's text length, instead of Flow's
            // width-dependent wrap point - and it still reliably wraps the
            // 6 mode buttons onto a second row instead of overflowing the
            // popup edge, which is what broke when Cava was added as a 6th
            // button inside a plain (non-wrapping) Row.
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 3
            spacing: Style.space(4)
            Repeater {
              model: [
                { id: "wave", name: "Wave", icon: "󰎆" },
                { id: "bars", name: "Bars", icon: "󰝛" },
                { id: "dots", name: "Dots", icon: "󰄰" },
                { id: "particles", name: "Sparks", icon: "󰠱" },
                { id: "pulse", name: "Pulse", icon: "󰓎" },
                { id: "cava", name: "Cava", icon: "󰤽" }
              ]

              BorderSurface {
                id: flowBtn
                required property var modelData
                readonly property bool isSelected: root.visualizerMode === modelData.id
                // Repeater delegates can be created while the mouse cursor already sits over
                // their pre-layout position, which seeds MouseArea.containsMouse to true before
                // any real enter event fires. Track hover via onEntered/onExited instead so idle
                // buttons never start out looking hovered.
                property bool hovered: false

                // Sized from the label's own implicit width instead of a fixed guess:
                // a hardcoded width can't account for font metrics/theme scale, and a
                // fixed-width sibling of this same row already overflowed once from
                // exactly that kind of guess (see the toggle pill below).
                width: flowBtnLabel.implicitWidth + Style.space(16)
                height: Style.space(24)
                radius: Style.spacing.labelGap
                color: isSelected
                  ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                  : (flowBtn.hovered ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
                borderSpec: isSelected
                  ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                  : Border.none()

                Row {
                  id: flowBtnLabel
                  anchors.centerIn: parent
                  spacing: Style.space(2)
                  Text {
                    text: flowBtn.modelData.icon
                    textFormat: Text.PlainText
                    color: flowBtn.isSelected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: flowBtn.modelData.name
                    textFormat: Text.PlainText
                    color: flowBtn.isSelected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: flowBtn.isSelected
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: flowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: flowBtn.hovered = true
                  onExited: flowBtn.hovered = false
                  onClicked: {
                    root.visualizerMode = flowBtn.modelData.id
                    waveCanvas.requestPaint()
                  }
                }
              }
            }
          }

          // Text / Pure Flow Toggle Pill
          BorderSurface {
            id: textToggleBtn
            anchors.horizontalCenter: parent.horizontalCenter
            // Sized from the label's own implicit width instead of a fixed guess -
            // a hardcoded width here is exactly what overflowed the popup's edge.
            width: toggleLabel.implicitWidth + Style.space(16)
            height: Style.space(24)
            radius: Style.spacing.labelGap
            color: root.showText
              ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : (textToggleMouse.containsMouse ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
            borderSpec: root.showText
              ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : Border.none()

            Row {
              id: toggleLabel
              anchors.centerIn: parent
              spacing: Style.space(3)
              Text {
                text: root.showText ? "󰈈" : "󰈉"
                textFormat: Text.PlainText
                color: root.showText ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: root.showText ? "Words ON" : "Pure Flow"
                textFormat: Text.PlainText
                color: root.showText ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: root.showText
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: textToggleMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showText = !root.showText
            }
          }
        }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      // Source / Player Switcher Section
      Column {
        width: parent.width
        spacing: Style.space(6)

        Row {
          spacing: Style.space(6)
          Text {
            text: "󱘖"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: "SELECT PLAYER / SOURCE"
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Empty state when no players are active
        Text {
          visible: root.sourcePlayers.length === 0
          text: "No active media players found."
          textFormat: Text.PlainText
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          anchors.horizontalCenter: parent.horizontalCenter
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
        }

        // Player Source Cards
        Repeater {
          model: root.sourcePlayers

          BorderSurface {
            id: sourceRow
            required property var modelData

            readonly property var player: modelData
            readonly property bool selected: root.activePlayer && player
              && root.playerCanonicalKey(root.activePlayer) === root.playerCanonicalKey(player)
            readonly property string name: root.sourceName(player)
            readonly property string icon: root.sourceIcon(player)
            readonly property string track: {
              if (!player) return "Active Player"
              var t = player.trackTitle || (player.metadata && player.metadata["xesam:title"]) || ""
              var a = player.trackArtist || (player.metadata && player.metadata["xesam:artist"]) || ""
              if (t) return MediaModel.cleanTitle(t, a)
              return MediaModel.sanitizeText(player.identity || "Active Player")
            }
            readonly property string artistName: {
              if (!player) return ""
              var t = player.trackTitle || (player.metadata && player.metadata["xesam:title"]) || ""
              var a = player.trackArtist || (player.metadata && player.metadata["xesam:artist"]) || ""
              return MediaModel.cleanArtist(a, t, player)
            }
            // Same Repeater-delegate stale-hover issue as the flow-mode buttons above.
            property bool hovered: false

            width: parent.width
            height: Style.space(42)
            radius: Style.spacing.labelGap
            color: selected
              ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : (sourceRow.hovered ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
            borderSpec: selected
              ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : (sourceRow.hovered ? Border.controlSpec("hover-cursor", root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Border.none())

            // Declared before Row (and its nested play/pause MouseArea) so it
            // stacks underneath: non-interactive content in Row still lets
            // clicks fall through to this for select, but the play/pause
            // icon's own MouseArea (stacked on top, inside Row below) takes
            // priority over its small hit area instead of this swallowing
            // every click in the row first.
            MouseArea {
              id: sourceCardMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: sourceRow.hovered = true
              onExited: sourceRow.hovered = false
              onClicked: root.selectPlayer(sourceRow.player)
            }

            Row {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              Text {
                text: sourceRow.icon
                textFormat: Text.PlainText
                color: sourceRow.selected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.subtitle
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(60)
                spacing: Style.space(1)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: sourceRow.name
                  textFormat: Text.PlainText
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: sourceRow.selected
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: sourceRow.track + (sourceRow.artistName && sourceRow.artistName !== sourceRow.name ? " — " + sourceRow.artistName : "")
                  textFormat: Text.PlainText
                  color: sourceRow.selected ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              // A real toggle, not just a status glyph: previously this only
              // ever reflected the raw (sometimes stale - see currentEnergy's
              // audioGain comment history) player.isPlaying, and the row's
              // own click only ever selected-and-played, never paused, so
              // there was no way to pause a source from here at all - the
              // reported "play/pause on each source doesn't respond". Reads
              // through mediaService's PipeWire-aware activity check instead
              // of the raw MPRIS flag, and has its own MouseArea (consumes
              // the click before it reaches the row's select-only area below)
              // that calls playPause for this specific source.
              Item {
                width: playPauseIcon.implicitWidth + Style.space(12)
                height: parent.height
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: playPauseIcon
                  anchors.centerIn: parent
                  text: (sourceRow.player && root.mediaService && root.mediaService.isSourceActive(sourceRow.player)) ? "󰏤" : "󰐊"
                  textFormat: Text.PlainText
                  color: playPauseMouse.containsMouse
                    ? Color.accent
                    : (sourceRow.selected ? Color.accent : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6))
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: playPauseMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.runAction("playPause", sourceRow.player)
                }
              }
            }
          }
        }
      }
    }
  }
}
