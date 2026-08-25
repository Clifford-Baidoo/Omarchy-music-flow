import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons
import "MediaModel.js" as MediaModel

BarWidget {
  id: root
  moduleName: "custom.media"

  property var service: null
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

  readonly property var fallbackPlayers: Mpris.players ? Mpris.players.values : []

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

  readonly property var activePlayer: mediaService && mediaService.activePlayer ? mediaService.activePlayer : findFallbackActivePlayer()
  readonly property var sourcePlayers: mediaService && mediaService.sourcePlayers && mediaService.sourcePlayers.length > 0 ? mediaService.sourcePlayers : fallbackPlayers

  readonly property bool hasMedia: activePlayer !== null && (Boolean(title) || Boolean(activePlayer.isPlaying) || Boolean(activePlayer.isStreamPlayer) || Boolean(activePlayer.trackTitle || activePlayer.trackArtist))
  readonly property string playIcon: activePlayer && activePlayer.isPlaying ? "󰏤" : "󰐊"
  
  readonly property string title: {
    if (mediaService && mediaService.title) return mediaService.title
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    if (t) return MediaModel.cleanTitle(t, a)
    if (activePlayer.identity) return String(activePlayer.identity)
    if (activePlayer.desktopEntry) return String(activePlayer.desktopEntry)
    return "Playing"
  }

  readonly property string artist: {
    if (mediaService && mediaService.artist) return mediaService.artist
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    return MediaModel.cleanArtist(a, t, activePlayer)
  }

  readonly property string album: {
    if (mediaService && mediaService.album) return mediaService.album
    if (!activePlayer) return ""
    if (activePlayer.trackAlbum) return String(activePlayer.trackAlbum)
    if (activePlayer.metadata && activePlayer.metadata["xesam:album"]) return String(activePlayer.metadata["xesam:album"])
    return ""
  }

  readonly property string artUrl: {
    if (mediaService && mediaService.artUrl) return mediaService.artUrl
    if (!activePlayer) return ""
    if (activePlayer.trackArtUrl) return String(activePlayer.trackArtUrl)
    if (activePlayer.metadata && (activePlayer.metadata["mpris:artUrl"] || activePlayer.metadata["xesam:artUrl"]))
      return String(activePlayer.metadata["mpris:artUrl"] || activePlayer.metadata["xesam:artUrl"])
    return ""
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
    }
    if (typeof targetPlayer.play === "function") {
      targetPlayer.play()
    } else if (typeof targetPlayer.togglePlaying === "function") {
      targetPlayer.togglePlaying()
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

  // Bar Pill Capsule - Pure Visualizer Flow
  BorderSurface {
    id: pill
    anchors.centerIn: parent
    height: Math.min(parent.height - Style.space(6), Style.space(28))
    width: root.isMinimized ? height : (flowRow.implicitWidth + Style.space(16))
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

    // Horizontal audio wave flow spanning across the capsule
    Canvas {
      id: waveCanvas
      anchors.fill: parent
      anchors.margins: Style.space(2)
      visible: !root.isMinimized

      property real phase: 0

      NumberAnimation on phase {
        running: Boolean(root.activePlayer && root.activePlayer.isPlaying)
        from: 0
        to: Math.PI * 2
        duration: 1800
        loops: Animation.Infinite
      }

      onPhaseChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (width <= 0 || height <= 0) return

        var midY = height / 2
        var isPlaying = Boolean(root.activePlayer && root.activePlayer.isPlaying)
        var amp = isPlaying ? height * 0.32 : 0

        // Primary flowing wave
        ctx.lineWidth = 1.5
        ctx.strokeStyle = Color.accent
        ctx.beginPath()
        for (var x = 0; x <= width; x += 3) {
          var k = (x / width) * Math.PI * 4
          var y = midY + (isPlaying ? Math.sin(k + phase) * Math.cos(k * 0.5 + phase * 0.8) * amp : 0)
          if (x === 0) ctx.moveTo(x, y)
          else ctx.lineTo(x, y)
        }
        ctx.stroke()

        // Secondary harmonic flowing wave
        if (isPlaying) {
          ctx.lineWidth = 1.0
          ctx.strokeStyle = root.bar ? root.bar.barForeground : Color.foreground
          ctx.beginPath()
          for (var x2 = 0; x2 <= width; x2 += 3) {
            var k2 = (x2 / width) * Math.PI * 3
            var y2 = midY + Math.sin(k2 - phase * 1.3) * (amp * 0.65)
            if (x2 === 0) ctx.moveTo(x2, y2)
            else ctx.lineTo(x2, y2)
          }
          ctx.stroke()
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
        color: (root.activePlayer && root.activePlayer.isPlaying) ? Color.accent : (clickArea.containsMouse ? Color.accent : (root.bar ? root.bar.barForeground : Color.foreground))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        Behavior on color { ColorAnimation { duration: 140 } }
      }
    }

    // Expanded Mode - Pure Flow (Music icon + Scrolling song name)
    Row {
      id: flowRow
      anchors.centerIn: parent
      spacing: Style.space(7)
      visible: !root.isMinimized

      // Music Icon / Source Glyph
      Text {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
        color: (root.activePlayer && root.activePlayer.isPlaying) ? Color.accent : (root.hasMedia ? (root.bar ? root.bar.barForeground : Color.foreground) : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.4))
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
            color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: artistText
            visible: root.artist !== ""
            text: root.artist
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          SequentialAnimation on x {
            id: scrollAnim
            running: titleRow.needsScroll && !root.popupOpen && (!root.bar || !root.bar.vertical) && root.hasMedia && !root.isMinimized
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
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? (root.title + (root.artist ? " — " + root.artist : "")) : "Music Player")
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
            source: root.artUrl
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: root.artUrl === ""
            text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
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
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: root.sourceName(root.activePlayer).toUpperCase()
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            text: root.title || "Nothing playing"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: root.artist
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            text: root.album
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
          iconText: root.activePlayer && root.activePlayer.isPlaying ? "󰏤" : "󰐊"
          foreground: Color.accent
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: Boolean(root.activePlayer && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause || root.activePlayer.isStreamPlayer))
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
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: "SELECT PLAYER / SOURCE"
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
              && root.playerKey(root.activePlayer) === root.playerKey(player)
            readonly property string name: root.sourceName(player)
            readonly property string icon: root.sourceIcon(player)
            readonly property string track: {
              if (!player) return "Active Player"
              var t = player.trackTitle || (player.metadata && player.metadata["xesam:title"]) || ""
              var a = player.trackArtist || (player.metadata && player.metadata["xesam:artist"]) || ""
              if (t) return MediaModel.cleanTitle(t, a)
              return player.identity || player.appName || "Active Player"
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
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: sourceRow.selected
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: sourceRow.track + (sourceRow.artistName && sourceRow.artistName !== sourceRow.name ? " — " + sourceRow.artistName : "")
                  color: sourceRow.selected ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Text {
                text: sourceRow.player && sourceRow.player.isPlaying ? "󰏤" : "󰐊"
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
