import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

BarWidget {
  moduleName: "custom.media"

  readonly property var mediaService: (bar && bar.shell)
    ? (bar.shell.serviceFor(root.moduleName) || bar.shell.serviceFor("custom.media") || bar.shell.serviceFor("omarchy.media") || bar.shell.firstPartyServiceFor("omarchy.media"))
    : null
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null
  readonly property var sourcePlayers: mediaService ? mediaService.sourcePlayers : []

  readonly property bool hasMedia: activePlayer !== null && Boolean(activePlayer.trackTitle || activePlayer.trackArtist)
  readonly property string playIcon: activePlayer && activePlayer.isPlaying ? "󰏤" : "󰐊"
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string album: activePlayer && activePlayer.trackAlbum ? activePlayer.trackAlbum : ""
  readonly property string artUrl: activePlayer && activePlayer.trackArtUrl ? activePlayer.trackArtUrl : ""

  property bool popupOpen: false
  property bool isMinimized: false

  function close() { popupOpen = false }
  property real maxLabelWidth: 220

  function sourceName(player) {
    if (!player) return "Media"
    var id = String(player.identity || player.desktopEntry || player.dbusName || "").toLowerCase()
    if (id.indexOf("spotify") !== -1) return "Spotify"
    if (id.indexOf("firefox") !== -1 || id.indexOf("zen") !== -1) return "Firefox"
    if (id.indexOf("chrome") !== -1 || id.indexOf("chromium") !== -1 || id.indexOf("brave") !== -1) return "Browser"
    if (id.indexOf("cliamp") !== -1) return "cliamp"
    if (id.indexOf("vlc") !== -1) return "VLC"
    return player.identity || player.desktopEntry || "Player"
  }

  function sourceIcon(player) {
    if (!player) return "󰝚"
    var id = String(player.identity || player.desktopEntry || player.dbusName || "").toLowerCase()
    if (id.indexOf("spotify") !== -1) return "󰓇"
    if (id.indexOf("firefox") !== -1 || id.indexOf("zen") !== -1 || id.indexOf("chrome") !== -1 || id.indexOf("chromium") !== -1) return "󰗃"
    if (id.indexOf("cliamp") !== -1) return "󰎆"
    if (id.indexOf("vlc") !== -1) return "󰕼"
    return "󰝚"
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
    color: clickArea.containsMouse ? Style.tint(root.bar.barForeground, 0.05) : "transparent"
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
      opacity: (activePlayer && activePlayer.isPlaying) ? 0.38 : 0.12

      property real phase: 0

      NumberAnimation on phase {
        running: activePlayer && activePlayer.isPlaying && !root.isMinimized
        loops: Animation.Infinite
        from: 0
        to: Math.PI * 2
        duration: 3000
      }

      onPhaseChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (width <= 0 || height <= 0) return

        var midY = height / 2
        var isPlaying = Boolean(activePlayer && activePlayer.isPlaying)
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
          ctx.strokeStyle = root.bar.barForeground
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
        color: (activePlayer && activePlayer.isPlaying) ? Color.accent : (clickArea.containsMouse ? Color.accent : root.bar.barForeground)
        font.family: root.bar.fontFamily
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
        color: (activePlayer && activePlayer.isPlaying) ? Color.accent : (root.hasMedia ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.4))
        font.family: root.bar.fontFamily
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
        visible: !root.bar.vertical

        Text {
          id: idleLabel
          visible: !root.hasMedia
          text: "Music"
          color: Qt.darker(root.bar.barForeground, 1.4)
          font.family: root.bar.fontFamily
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
            color: root.bar.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: sepText
            visible: root.artist !== ""
            text: "·"
            color: Qt.darker(root.bar.barForeground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: artistText
            visible: root.artist !== ""
            text: root.artist
            color: Qt.darker(root.bar.barForeground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          SequentialAnimation on x {
            id: scrollAnim
            running: titleRow.needsScroll && !root.popupOpen && !root.bar.vertical && root.hasMedia && !root.isMinimized
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
        if (root.mediaService) root.mediaService.runAction("playPause", false, root.activePlayer ? root.mediaService.playerKey(root.activePlayer) : undefined)
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
    onWheel: function(wheel) {
      if (!root.activePlayer) return
      if (wheel.angleDelta.y > 0 && root.mediaService) {
        root.mediaService.runAction("previous", false, root.mediaService.playerKey(root.activePlayer))
      } else if (wheel.angleDelta.y < 0 && root.mediaService) {
        root.mediaService.runAction("next", false, root.mediaService.playerKey(root.activePlayer))
      }
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? (root.title + (root.artist ? " — " + root.artist : "")) : "Music Player")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // Dedicated Floating Player & Source Selection Window (like Battery/Display panels)
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

      // Header: Album Artwork Hero & Track Info
      Row {
        spacing: Style.space(12)
        width: parent.width

        BorderSurface {
          width: Style.space(72)
          height: Style.space(72)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

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
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(3)
          width: parent.width - Style.space(84)
          anchors.verticalCenter: parent.verticalCenter

          // Source Tag
          Row {
            spacing: Style.space(4)
            visible: root.hasMedia

            Text {
              text: root.sourceIcon(root.activePlayer)
              color: Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.sourceName(root.activePlayer)
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            text: root.title || "No track playing"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: root.artist
            color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            text: root.album
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
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
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoPrevious
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("previous", false, root.mediaService.playerKey(root.activePlayer))
        }

        Button {
          iconText: root.activePlayer && root.activePlayer.isPlaying ? "󰏤" : "󰐊"
          foreground: Color.accent
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: root.activePlayer && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause)
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("playPause", false, root.mediaService.playerKey(root.activePlayer))
        }

        Button {
          iconText: "󰒭"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoNext
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("next", false, root.mediaService.playerKey(root.activePlayer))
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
      }

      // Source / Player Switcher Section (like Display / Audio Sinks)
      Column {
        width: parent.width
        spacing: Style.space(6)

        Row {
          spacing: Style.space(6)
          Text {
            text: "󱘖"
            color: Color.accent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: "SELECT PLAYER / SOURCE"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Empty state when no players are active
        Text {
          visible: root.sourcePlayers.length === 0
          text: "No active media players found."
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
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
              && root.mediaService.playerKey(root.activePlayer) === root.mediaService.playerKey(player)
            readonly property string name: root.sourceName(player)
            readonly property string icon: root.sourceIcon(player)
            readonly property string track: player ? (player.trackTitle || "Idle") : "Idle"
            readonly property string artistName: player && player.trackArtist ? player.trackArtist : ""

            width: parent.width
            height: Style.space(42)
            radius: Style.spacing.labelGap
            color: selected
              ? Style.selectedFillFor(root.bar.foreground, Color.accent)
              : (sourceCardMouse.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : Style.tint(root.bar.foreground, 0.04))
            borderSpec: selected
              ? Border.controlSpec("normal", root.bar.foreground, Color.accent)
              : (sourceCardMouse.containsMouse ? Border.controlSpec("hover-cursor", root.bar.foreground, Color.accent) : Border.none())

            Row {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              Text {
                text: sourceRow.icon
                color: sourceRow.selected ? Color.accent : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(60)
                spacing: Style.space(1)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: sourceRow.name
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: sourceRow.selected
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: sourceRow.track + (sourceRow.artistName ? " — " + sourceRow.artistName : "")
                  color: sourceRow.selected ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Text {
                text: sourceRow.player && sourceRow.player.isPlaying ? "󰏤" : "󰐊"
                color: sourceRow.selected ? Color.accent : Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: sourceCardMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.mediaService) root.mediaService.selectPlayer(root.mediaService.playerKey(sourceRow.player))
            }
          }
        }
      }
    }
  }
}

