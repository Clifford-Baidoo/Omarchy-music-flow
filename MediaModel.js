// ==============================================================================
// MediaModel.js - Music Flow Intelligent Media & Stream Resolver
// ==============================================================================

function isProxyPlayer(player) {
  var dbusName = String(player && player.dbusName || "").toLowerCase()
  var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
  return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
}

function hasMetadata(player) {
  if (!player) return false
  if (player.trackTitle || player.trackArtist || player.identity || player.desktopEntry) return true
  if (player.metadata && (player.metadata["xesam:title"] || player.metadata["xesam:artist"])) return true
  return false
}

function hasTrackMetadata(player) {
  if (!player) return false
  if (player.trackTitle || player.trackArtist || player.trackAlbum || player.trackArtUrl) return true
  if (player.metadata && (player.metadata["xesam:title"] || player.metadata["xesam:artist"] || player.metadata["mpris:artUrl"])) return true
  return false
}

function playerCanControl(player) {
  return !!(player && (player.canTogglePlaying || player.canPlay || player.canPause || player.canGoNext || player.canGoPrevious))
}

function canHandleAction(player, action) {
  if (!player) return false
  if (action === "next") return !!player.canGoNext
  if (action === "previous") return !!player.canGoPrevious
  if (action === "play") return !!(player.canPlay || player.canTogglePlaying)
  if (action === "pause") return !!(player.canPause || player.canTogglePlaying)
  if (action === "playPause") return !!(player.canTogglePlaying || player.canPlay || player.canPause)
  return false
}

function canCycleSource(player) {
  return !!(player && (hasMetadata(player) || player.isStreamPlayer) && (player.isPlaying || player.canPlay))
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : (node && node.properties ? node.properties : {})
}

function isBlacklistedStream(node) {
  if (!node) return true
  var p = nodeProps(node)
  var raw = [
    p["application.name"] || "",
    p["application.process.binary"] || "",
    p["node.name"] || "",
    node.name || "",
    node.description || ""
  ].join(" ").toLowerCase()

  var blacklisted = [
    "speech-dispatcher",
    "speech-dispatcher-dummy",
    "sd_dummy",
    "speechd",
    "spdsend",
    "omarchy_speaker_tuning",
    "quickshell",
    "cava",
    "easyeffects",
    "pulseeffects",
    "rtkit-daemon"
  ]

  return blacklisted.some(function(b) {
    return raw.indexOf(b) !== -1
  })
}

function isPlaybackStream(node) {
  if (!node || !node.isStream || isBlacklistedStream(node)) return false
  if (node.isSink === true) return true

  var mediaClass = String(node.type || (node.properties && node.properties["media.class"]) || "")
  return mediaClass.indexOf("Stream/Output/Audio") !== -1
    || mediaClass.indexOf("AudioOutStream") !== -1
    || mediaClass.indexOf("Output") !== -1
}

function streamLabelKey(label) {
  var key = String(label || "").toLowerCase()
  key = key.replace(/^pipewire alsa \[/, "")
  key = key.replace(/\]$/, "")
  key = key.replace(/^alsa playback \[/, "")
  key = key.replace(/[^a-z0-9]+/g, "")
  return key
}

function rawStreamLabel(node) {
  if (!node) return ""
  var p = nodeProps(node)
  return p["application.name"]
    || node.description
    || p["media.name"]
    || p["application.process.binary"]
    || p["node.name"]
    || node.name
    || ""
}

// Known browser & application families for cross-matching MPRIS & Pipewire
var APP_FAMILY_MAP = {
  "firefox": ["firefox", "zen", "zen-bin", "librewolf", "floorp", "waterfox", "tor-browser", "gecko"],
  "zen": ["zen", "zen-bin", "firefox", "gecko"],
  "librewolf": ["librewolf", "firefox", "gecko"],
  "chromium": ["chromium", "chrome", "google-chrome", "google-chrome-stable", "brave", "brave-browser", "edge", "microsoft-edge", "opera", "vivaldi", "electron", "seanime", "seanime-denshi"],
  "chrome": ["chrome", "google-chrome", "google-chrome-stable", "chromium"],
  "brave": ["brave", "brave-browser", "chromium"],
  "seanime": ["seanime", "seanime-denshi", "seanime-server", "denshi", "electron", "chromium"],
  "spotify": ["spotify", "spotify-launcher", "spotify-client"],
  "mpv": ["mpv", "mpv-mpris", "celluloid"],
  "vlc": ["vlc"]
}

function normalizeAppName(name) {
  var s = String(name || "").toLowerCase()
  s = s.replace(/^org\.mpris\.mediaplayer2\./, "")
  s = s.replace(/\.instance.*$/, "")
  s = s.replace(/[^a-z0-9]/g, "")
  return s
}

function areAppsInSameFamily(nameA, nameB) {
  var a = normalizeAppName(nameA)
  var b = normalizeAppName(nameB)
  if (!a || !b) return false
  if (a === b || a.indexOf(b) !== -1 || b.indexOf(a) !== -1) return true

  for (var family in APP_FAMILY_MAP) {
    var members = APP_FAMILY_MAP[family]
    var aInFamily = members.some(function(m) { return a.indexOf(normalizeAppName(m)) !== -1 })
    var bInFamily = members.some(function(m) { return b.indexOf(normalizeAppName(m)) !== -1 })
    if (aInFamily && bInFamily) return true
  }

  return false
}

function playerAppLabel(player) {
  if (!player) return ""
  var dbus = String(player.dbusName || "")
  dbus = dbus.replace(/^org\.mpris\.MediaPlayer2\./, "")
  dbus = dbus.replace(/\.instance.*$/, "")
  return player.desktopEntry || player.identity || dbus
}

function playerHasPlaybackStream(player, playbackStreams) {
  if (!player) return false
  var pLabel = playerAppLabel(player)
  var pKey = streamLabelKey(pLabel)
  var pDbus = String(player.dbusName || "")

  var streams = Array.isArray(playbackStreams) ? playbackStreams : []
  for (var i = 0; i < streams.length; i++) {
    var sNode = streams[i]
    if (!sNode) continue
    var sLabel = rawStreamLabel(sNode)
    var sKey = streamLabelKey(sLabel)
    if (!sKey) continue

    if (sKey === pKey || sKey.indexOf(pKey) !== -1 || pKey.indexOf(sKey) !== -1) return true
    if (areAppsInSameFamily(pLabel, sLabel) || areAppsInSameFamily(pDbus, sLabel)) return true

    var p = nodeProps(sNode)
    var binary = String(p["application.process.binary"] || "")
    if (binary && (areAppsInSameFamily(pLabel, binary) || areAppsInSameFamily(pDbus, binary))) return true
  }

  return false
}

function playerKey(player) {
  if (!player) return ""
  return String(player.dbusName || player.desktopEntry || player.identity || player.streamId || "")
}

function trackSignature(player) {
  if (!player) return ""
  return [
    player.trackTitle || "",
    player.trackArtist || "",
    player.trackAlbum || "",
    player.trackArtUrl || ""
  ].join("\u001f")
}

function trackChanged(previousSignature, player) {
  return trackSignature(player) !== String(previousSignature || "")
}

// Cleans up common ugly tags from web/video players (e.g. YouTube, anime filenames, web sites)
function cleanTitle(rawTitle, rawArtist) {
  var title = String(rawTitle || "").trim()
  if (!title) return ""

  // 1. Remove browser / app suffixes
  title = title.replace(/\s*[-—|•]\s*(?:Zen Browser|Mozilla Firefox|Firefox|Google Chrome|Chromium|Brave|Seanime|Dulo TV)$/i, "")
  title = title.replace(/\s*[-—|•]\s*(?:YouTube|Twitch|SoundCloud|Spotify|Netflix|Crunchyroll|Coursera|Bandcamp|Vimeo|Reddit|Bilibili)$/i, "")
  title = title.replace(/\s*[-—|•]\s*Watch on [A-Za-z0-9 ]+$/i, "")

  // 2. Remove Anime Release Group tags: [SubsPlease], [Erai-raws], [Judas], etc.
  title = title.replace(/^\[[^\]]+\]\s*/g, "")
  title = title.replace(/\s*\[[0-9a-fA-F]{8}\]/g, "") // CRC32 hashes like [ABCD1234]
  title = title.replace(/\s*\[(?:1080p|720p|480p|2160p|4k|aac|hevc|x264|x265|dvd|bd|bluray|vostfr|sub)\]/gi, "")
  title = title.replace(/\s*\((?:1080p|720p|480p|2160p|4k|aac|hevc|x264|x265|dvd|bd|bluray|vostfr|sub)\)/gi, "")

  // 3. Remove file extensions
  title = title.replace(/\.(mkv|mp4|avi|webm|mp3|flac|wav|m4a|ogg|opus)$/i, "")

  // 4. If title is a generic placeholder like "AudioStream" or "playback", return empty so window title can be used
  if (/^(?:AudioStream|playback|Stream|Audio|Default|Playback|Video)$/i.test(title)) {
    return ""
  }

  // 5. If title is "Artist - Song", but NOT an episode number like "Anime - 01" or "Show - Ep 2"
  if (!rawArtist && title.indexOf(" - ") !== -1) {
    var parts = title.split(" - ")
    if (parts.length === 2) {
      var left = parts[0].trim()
      var right = parts[1].trim()
      var isEpisode = /^(?:ep|episode|part|vol|v)?\s*[0-9]+(?:\.[0-9]+)?$/i.test(right)
      if (!isEpisode && left.length > 1 && right.length > 1) {
        return right
      }
    }
  }

  return title.trim()
}

// Derives a clean artist or source badge
function cleanArtist(rawArtist, rawTitle, player) {
  var artist = ""
  if (rawArtist) {
    if (Array.isArray(rawArtist)) artist = rawArtist.join(", ")
    else artist = String(rawArtist).trim()
  }

  if (artist && artist !== "Unknown" && artist !== "undefined" && artist !== "Playback") return artist

  // If artist is missing, check if title had "Artist - Title"
  var title = String(rawTitle || "").trim()
  title = title.replace(/\s*[-—|•]\s*(?:Zen Browser|Mozilla Firefox|Firefox|Google Chrome|Chromium|Brave|Seanime|Dulo TV)$/i, "")
  title = title.replace(/\s*[-—|•]\s*(?:YouTube|Twitch|SoundCloud|Spotify|Netflix|Crunchyroll|Coursera|Bandcamp|Vimeo|Reddit|Bilibili)$/i, "")
  title = title.replace(/\s*[-—|•]\s*Watch on [A-Za-z0-9 ]+$/i, "")

  if (title.indexOf(" - ") !== -1) {
    var parts = title.split(" - ")
    if (parts.length === 2) {
      var left = parts[0].trim()
      var right = parts[1].trim()
      var isEpisode = /^(?:ep|episode|part|vol|v)?\s*[0-9]+(?:\.[0-9]+)?$/i.test(right)
      if (!isEpisode && left.length > 1 && right.length > 1) {
        return left
      }
    }
  }

  // Fallback to app source name
  var src = sourceName(player)
  if (src && src !== "Player" && src !== "Media" && src !== "Unknown" && src !== "Playback") return src

  return ""
}

function sourceName(player) {
  if (!player) return "Media"
  var id = String(player.identity || player.desktopEntry || player.dbusName || player.appName || "").toLowerCase()
  if (id.indexOf("spotify") !== -1) return "Spotify"
  if (id.indexOf("seanime") !== -1 || id.indexOf("denshi") !== -1) return "Seanime"
  if (id.indexOf("mpv") !== -1) return "MPV"
  if (id.indexOf("vlc") !== -1) return "VLC"
  if (id.indexOf("zen") !== -1) return "Zen Browser"
  if (id.indexOf("firefox") !== -1) return "Firefox"
  if (id.indexOf("brave") !== -1) return "Brave"
  if (id.indexOf("chrome") !== -1) return "Chrome"
  if (id.indexOf("chromium") !== -1 || id.indexOf("electron") !== -1) {
    if (id.indexOf("seanime") !== -1) return "Seanime"
    return "Chromium"
  }
  if (id.indexOf("edge") !== -1) return "Edge"
  if (id.indexOf("cliamp") !== -1) return "cliamp"
  if (id.indexOf("stremio") !== -1) return "Stremio"
  if (id.indexOf("celluloid") !== -1) return "Celluloid"
  if (id.indexOf("discord") !== -1) return "Discord"
  if (id.indexOf("twitch") !== -1) return "Twitch"
  if (id.indexOf("soundcloud") !== -1) return "SoundCloud"
  if (player.identity && player.identity !== "undefined") return player.identity
  if (player.desktopEntry && player.desktopEntry !== "undefined") return player.desktopEntry
  return "Player"
}

function sourceIcon(player) {
  if (!player) return "󰝚"
  var id = String(player.identity || player.desktopEntry || player.dbusName || player.appName || "").toLowerCase()
  if (id.indexOf("spotify") !== -1) return "󰓇"
  if (id.indexOf("seanime") !== -1 || id.indexOf("denshi") !== -1) return "󰚩"
  if (id.indexOf("mpv") !== -1) return "󰐹"
  if (id.indexOf("vlc") !== -1) return "󰕼"
  if (id.indexOf("zen") !== -1 || id.indexOf("firefox") !== -1) return "󰈹"
  if (id.indexOf("chrome") !== -1 || id.indexOf("chromium") !== -1 || id.indexOf("brave") !== -1 || id.indexOf("edge") !== -1) return "󰊯"
  if (id.indexOf("cliamp") !== -1) return "󰎆"
  if (id.indexOf("stremio") !== -1 || id.indexOf("celluloid") !== -1) return "󰐹"
  if (id.indexOf("discord") !== -1) return "󰙯"
  if (id.indexOf("twitch") !== -1) return "󰕧"
  if (id.indexOf("soundcloud") !== -1) return "󰝚"
  return "󰝚"
}

function labelFor(player) {
  if (!player) return ""
  return player.trackTitle || player.identity || player.desktopEntry || sourceName(player) || ""
}

function osdMessage(player, fallback) {
  if (!player) return fallback
  var label = labelFor(player)
  if (label && player.trackArtist) return label + " - " + player.trackArtist
  return label || fallback
}

function findWindowTitleForPid(pid, appClass, toplevels) {
  if (!toplevels || toplevels.length === 0) return ""
  var pStr = String(pid || "")
  for (var i = 0; i < toplevels.length; i++) {
    var t = toplevels[i]
    if (!t) continue
    if (pStr && String(t.pid || "") === pStr && t.title) {
      return t.title
    }
    if (appClass && (t.waylandAppId === appClass || t.cls === appClass || t.class === appClass) && t.title) {
      return t.title
    }
  }
  return ""
}

// Virtual player wrapper created from an active Pipewire audio stream when no MPRIS player exists
function createVirtualStreamPlayer(node, toplevels) {
  if (!node || isBlacklistedStream(node)) return null
  var p = nodeProps(node)
  var pid = p["application.process.id"] || ""
  var binary = p["application.process.binary"] || ""
  var rawApp = p["application.name"] || node.description || p["node.name"] || node.name || "Audio Stream"
  
  // Resolve accurate app name (e.g. seanime-denshi / Chromium -> Seanime)
  var appName = rawApp
  if (rawApp.toLowerCase().indexOf("seanime") !== -1 || binary.toLowerCase().indexOf("seanime") !== -1) {
    appName = "Seanime"
  } else if (rawApp === "Zen" || binary === "zen-bin") {
    appName = "Zen Browser"
  }

  // Look up actual window title from Hyprland
  var winTitle = findWindowTitleForPid(pid, binary || rawApp, toplevels)
  var mediaName = p["media.name"] || node.description || ""
  
  // Prefer window title if mediaName is generic (like "AudioStream", "playback", etc.)
  var resolvedTitle = cleanTitle(mediaName, appName)
  if (!resolvedTitle && winTitle) {
    resolvedTitle = cleanTitle(winTitle, appName)
  }
  if (!resolvedTitle) {
    resolvedTitle = winTitle || mediaName || appName
  }

  var isMuted = Boolean(node.audio && node.audio.muted)

  return {
    isStreamPlayer: true,
    streamId: String(node.id || node.name || appName),
    dbusName: "pipewire.stream." + (node.id || node.name || appName),
    identity: appName,
    desktopEntry: binary || rawApp,
    appName: appName,
    trackTitle: resolvedTitle,
    trackArtist: cleanArtist("", resolvedTitle, { appName: appName, identity: appName }),
    trackAlbum: "",
    trackArtUrl: "",
    isPlaying: !isMuted,
    canPlay: true,
    canPause: true,
    canTogglePlaying: true,
    canGoNext: false,
    canGoPrevious: false,
    play: function() { if (node.audio) node.audio.muted = false },
    pause: function() { if (node.audio) node.audio.muted = true },
    togglePlaying: function() { if (node.audio) node.audio.muted = !node.audio.muted }
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    isProxyPlayer: isProxyPlayer,
    hasMetadata: hasMetadata,
    hasTrackMetadata: hasTrackMetadata,
    playerCanControl: playerCanControl,
    canHandleAction: canHandleAction,
    canCycleSource: canCycleSource,
    nodeProps: nodeProps,
    isBlacklistedStream: isBlacklistedStream,
    isPlaybackStream: isPlaybackStream,
    streamLabelKey: streamLabelKey,
    rawStreamLabel: rawStreamLabel,
    normalizeAppName: normalizeAppName,
    areAppsInSameFamily: areAppsInSameFamily,
    playerAppLabel: playerAppLabel,
    playerHasPlaybackStream: playerHasPlaybackStream,
    playerKey: playerKey,
    trackSignature: trackSignature,
    trackChanged: trackChanged,
    cleanTitle: cleanTitle,
    cleanArtist: cleanArtist,
    sourceName: sourceName,
    sourceIcon: sourceIcon,
    labelFor: labelFor,
    osdMessage: osdMessage,
    findWindowTitleForPid: findWindowTitleForPid,
    createVirtualStreamPlayer: createVirtualStreamPlayer
  }
}
