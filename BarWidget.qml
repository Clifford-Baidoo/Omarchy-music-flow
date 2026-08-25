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
  property string visualizerMode: "wave" // "wave", "bars", "dots", "particles", "pulse"
  property bool showText: true           // Toggle track title / artist text in bar capsule

  readonly property var mediaService: {
    if (service) return service
    if (!root.bar || !root.bar.shell) return null
    if (root.moduleName && root.bar.shell.serviceFor(root.moduleName))
      return root.bar.shell.serviceFor(root.moduleName)
    if (root.bar.shell.serviceFor("custom.media"))
      return root.bar.shell.serviceFor("custom.media")
    if (root.bar.shell.serviceFor("nek0.media"))
      return root.bar.shell.serviceFor("nek0.media")
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
  readonly property bool isPlaying: (activePlayer && activePlayer.isPlaying) || false

  // Smooth fluid energy level (1.0 when playing, 0.18 calm ambient drift when paused)
  readonly property real targetEnergy: isPlaying ? 1.0 : (hasMedia ? 0.18 : 0.08)
  property real currentEnergy: targetEnergy

  Behavior on currentEnergy {
    NumberAnimation { duration: 550; easing.type: Easing.OutQuad }
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
      "set -euo pipefail; URL=\"$1\"; CACHE_FILE=\"$2\"; CACHE_DIR=\"$(dirname \"$CACHE_FILE\")\"; mkdir -p -m 0700 \"$CACHE_DIR\"; TMP_FILE=$(mktemp -p \"$CACHE_DIR\" artwork.XXXXXX); trap 'rm -f \"${TMP_FILE:-}\"' EXIT; if [[ \"$URL\" =~ ^https:// ]]; then HTTP_CODE=$(curl -sS --max-time 3 --max-filesize 2097152 --proto \"=https\" -w \"%{http_code}\" \"$URL\" -o \"$TMP_FILE\" 2>/dev/null || echo \"000\"); if [[ \"$HTTP_CODE\" != \"200\" ]]; then exit 1; fi; elif [[ \"$URL\" =~ ^file://(/.*) ]] || [[ \"$URL\" =~ ^(/.*) ]]; then FILE_PATH=\"${BASH_REMATCH[1]}\"; if [[ ! -f \"$FILE_PATH\" || -L \"$FILE_PATH\" ]]; then exit 1; fi; FILE_SIZE=$(stat -c %s \"$FILE_PATH\" 2>/dev/null || echo 99999999); if (( FILE_SIZE > 2097152 || FILE_SIZE < 4 )); then exit 1; fi; head -c 2097152 \"$FILE_PATH\" > \"$TMP_FILE\"; else exit 1; fi; MAGIC=$(od -N 12 -A n -t x1 \"$TMP_FILE\" 2>/dev/null | tr -d \" \\n\"); if [[ \"$MAGIC\" =~ ^89504e470d0a1a0a ]] || [[ \"$MAGIC\" =~ ^ffd8 ]] || [[ \"$MAGIC\" =~ ^47494638 ]] || [[ \"$MAGIC\" =~ ^424d ]] || [[ \"$MAGIC\" =~ ^52494646.{8}57454250 ]]; then mv -f \"$TMP_FILE\" \"$CACHE_FILE\"; exit 0; else exit 1; fi",
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
  property real maxLabelWidth: 220

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
      : (root.showText ? (flowRow.implicitWidth + Style.space(16)) : Style.space(110))
    radius: height / 2
    clip: true
    color: clickArea.containsMouse ? Style.tint(root.bar ? root.bar.barForeground : Color.foreground, 0.05) : "transparent"
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
      anchors.fill: parent
      anchors.margins: Style.space(2)
      visible: !root.isMinimized

      property real phase: 0

      // Continuously moving phase so motion never freezes abruptly
      NumberAnimation on phase {
        running: true
        from: 0
        to: Math.PI * 2
        duration: 2200
        loops: Animation.Infinite
      }

      onPhaseChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (width <= 0 || height <= 0) return

        var midY = height / 2
        var energy = root.currentEnergy
        var mode = root.visualizerMode

        // Multi-frequency rhythm & beat intensity physics
        var bassPulse = Math.pow(Math.abs(Math.sin(phase * 2.5)), 3) * energy
        var melodySwell = (0.5 + 0.5 * Math.sin(phase * 0.35)) * energy
        var intensity = 0.2 + (bassPulse * 0.5 + melodySwell * 0.3) * energy

        if (mode === "wave") {
          // 1. DUAL HARMONIC REACTIVE OCEAN WAVE
          var amp = height * (0.06 + energy * (0.22 + intensity * 0.15))

          ctx.lineWidth = 1.2 + bassPulse * 0.8
          ctx.strokeStyle = energy > 0.4 ? Color.accent : Style.tint(Color.accent, 0.4)
          ctx.beginPath()
          for (var x = 0; x <= width; x += 3) {
            var k = (x / width) * Math.PI * 4
            var y = midY + Math.sin(k + phase * (0.8 + energy * 0.4)) * Math.cos(k * 0.5 + phase * 0.6) * amp
            if (x === 0) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.stroke()

          if (energy > 0.25) {
            ctx.lineWidth = 0.9
            ctx.strokeStyle = root.bar ? root.bar.barForeground : Color.foreground
            ctx.beginPath()
            for (var x2 = 0; x2 <= width; x2 += 3) {
              var k2 = (x2 / width) * Math.PI * 3
              var y2 = midY + Math.sin(k2 - phase * 1.2) * (amp * 0.65)
              if (x2 === 0) ctx.moveTo(x2, y2)
              else ctx.lineTo(x2, y2)
            }
            ctx.stroke()
          }
        } else if (mode === "bars") {
          // 2. ADAPTIVE FREQUENCY EQUALIZER BARS
          var numBars = root.showText ? 16 : 22
          var barW = (width / numBars) * 0.45
          var gap = (width / numBars) * 0.55
          ctx.fillStyle = energy > 0.4 ? Color.accent : Style.tint(Color.accent, 0.4)
          for (var b = 0; b < numBars; b++) {
            var barFreq = Math.abs(Math.sin(phase * 2.0 + b * 0.75) * Math.cos(phase * 1.2 + b * 0.35))
            var bh = (barFreq * (height * (0.15 + energy * (0.3 + intensity * 0.35))) + 2)
            var bx = b * (barW + gap) + gap / 2
            var by = midY - bh / 2
            ctx.fillRect(bx, by, barW, bh)
          }
        } else if (mode === "dots") {
          // 3. PULSING WAVE MATRIX BEADS
          var numDots = root.showText ? 14 : 18
          var step = width / (numDots + 1)
          ctx.fillStyle = energy > 0.4 ? Color.accent : Style.tint(Color.accent, 0.4)
          for (var d = 1; d <= numDots; d++) {
            var dx = d * step
            var dotOsc = Math.sin(phase * 2.0 + d * 0.6)
            var dy = midY + dotOsc * (height * (0.08 + energy * (0.18 + intensity * 0.16)))
            var r = (1.5 + (bassPulse * 1.0) + (energy * 0.8))
            ctx.beginPath()
            ctx.arc(dx, dy, r, 0, Math.PI * 2)
            ctx.fill()
          }
        } else if (mode === "particles") {
          // 4. FLOWING SOUND DUST / SPARKS
          var numParts = root.showText ? 12 : 16
          for (var pIdx = 0; pIdx < numParts; pIdx++) {
            var speed = 20 + energy * 20 + bassPulse * 10
            var px = ((pIdx * 28 + (phase / (Math.PI * 2)) * width * (0.6 + energy * 0.6)) % width)
            var py = midY + Math.sin(px * 0.08 + phase + pIdx) * (height * (0.08 + energy * (0.2 + intensity * 0.15)))
            ctx.fillStyle = (pIdx % 2 === 0) ? (energy > 0.4 ? Color.accent : Style.tint(Color.accent, 0.4)) : (root.bar ? root.bar.barForeground : Color.foreground)
            ctx.beginPath()
            ctx.arc(px, py, 1.4 + energy * 0.8 + bassPulse * 0.6, 0, Math.PI * 2)
            ctx.fill()
          }
        } else if (mode === "pulse") {
          // 5. RHYTHMIC BREATHING AUDIO HEARTBEAT
          var pulseScale = 0.25 + energy * (0.35 + intensity * 0.4)
          var grad = ctx.createRadialGradient(width / 2, midY, 2, width / 2, midY, (width / 2) * pulseScale)
          grad.addColorStop(0, energy > 0.4 ? Color.accent : Style.tint(Color.accent, 0.3))
          grad.addColorStop(1, "transparent")
          ctx.fillStyle = grad
          ctx.fillRect(0, 0, width, height)
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

    // Full Expanded Mode (Music icon + Scrolling song name over flow)
    Row {
      id: flowRow
      anchors.centerIn: parent
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
    contentWidth: popup.fittedContentWidth(Style.space(340))
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
          color: Style.tint(root.bar ? root.bar.foreground : Color.foreground, 0.08)
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

      // Visualizer Flow & Text Visibility Switcher
      Column {
        width: parent.width
        spacing: Style.space(6)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Row {
            spacing: Style.space(4)
            Repeater {
              model: [
                { id: "wave", name: "Wave", icon: "󰎆" },
                { id: "bars", name: "Bars", icon: "󰝛" },
                { id: "dots", name: "Dots", icon: "󰄰" },
                { id: "particles", name: "Sparks", icon: "󰠱" },
                { id: "pulse", name: "Pulse", icon: "󰓎" }
              ]

              BorderSurface {
                id: flowBtn
                required property var modelData
                readonly property bool isSelected: root.visualizerMode === modelData.id

                width: Style.space(48)
                height: Style.space(24)
                radius: Style.spacing.labelGap
                color: isSelected
                  ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                  : (flowMouse.containsMouse ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Style.tint(root.bar ? root.bar.foreground : Color.foreground, 0.04))
                borderSpec: isSelected
                  ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                  : Border.none()

                Row {
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
            width: Style.space(80)
            height: Style.space(24)
            radius: Style.spacing.labelGap
            color: root.showText
              ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : (textToggleMouse.containsMouse ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Style.tint(root.bar ? root.bar.foreground : Color.foreground, 0.04))
            borderSpec: root.showText
              ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : Border.none()

            Row {
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

            width: parent.width
            height: Style.space(42)
            radius: Style.spacing.labelGap
            color: selected
              ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : (sourceCardMouse.containsMouse ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Style.tint(root.bar ? root.bar.foreground : Color.foreground, 0.04))
            borderSpec: selected
              ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : (sourceCardMouse.containsMouse ? Border.controlSpec("hover-cursor", root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Border.none())

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

              Text {
                text: (sourceRow.player && sourceRow.player.isPlaying) ? "󰏤" : "󰐊"
                textFormat: Text.PlainText
                color: sourceRow.selected ? Color.accent : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: sourceCardMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.selectPlayer(sourceRow.player)
            }
          }
        }
      }
    }
  }
}
