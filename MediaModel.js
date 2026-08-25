// ==============================================================================
// MediaModel.js - Music Flow Intelligent Media & Metadata Resolver
// ==============================================================================

function isProxyPlayer(player) {
  var dbusName = String(player && player.dbusName || "").toLowerCase()
  var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
  return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
}

function hasMetadata(player) {
  if (!player || isProxyPlayer(player)) return false
  if (player.trackTitle || player.trackArtist || player.identity || player.desktopEntry) return true
  if (player.metadata && (player.metadata["xesam:title"] || player.metadata["xesam:artist"])) return true
  return false
}

function hasTrackMetadata(player) {
  if (!player || isProxyPlayer(player)) return false
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
  return !!(player && hasMetadata(player) && (player.isPlaying || player.canPlay))
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
  var p = nodeProps(node)

  // 1. Filter out notification/event/alert/system sound effects
  var role = String(p["media.role"] || p["node.role"] || "").toLowerCase()
  if (role === "event" || role === "notification" || role === "alert" || role === "test" || role === "sound-effect") {
    return false
  }

  // 2. Filter out Discord & transient message notification sounds
  var mediaName = String(p["media.name"] || "").toLowerCase()
  if (mediaName.indexOf("notification") !== -1 || mediaName.indexOf("alert") !== -1 || mediaName.indexOf("message") !== -1 || mediaName.indexOf("ping") !== -1) {
    return false
  }

  var appName = String(p["application.name"] || p["application.process.binary"] || "").toLowerCase()
  if (appName.indexOf("discord") !== -1 && role !== "music" && mediaName.indexOf("music") === -1) {
    return false
  }

  if (node.isSink === true) return true

  var mediaClass = String(node.type || p["media.class"] || "")
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
  "chromium": ["chromium", "chrome", "google-chrome", "google-chrome-stable", "brave", "brave-browser", "edge", "microsoft-edge", "opera", "vivaldi", "electron"],
  "chrome": ["chrome", "google-chrome", "google-chrome-stable", "chromium"],
  "brave": ["brave", "brave-browser", "chromium"],
  "spotify": ["spotify", "spotify-launcher", "spotify-client"],
  "mpv": ["mpv", "mpv-mpris", "celluloid"],
  "vlc": ["vlc"]
}

function normalizeAppName(name) {
  var s = String(name || "").toLowerCase()
  s = s.replace(/^org\.mpris\.mediaplayer2\./, "")
  s = s.replace(/[\._]instance.*$/, "")
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
  dbus = dbus.replace(/[\._]instance.*$/, "")
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

function playerHasActiveStream(player, playbackStreams) {
  if (!player) return false
  var pLabel = playerAppLabel(player)
  var pDbus = String(player.dbusName || "")

  var streams = Array.isArray(playbackStreams) ? playbackStreams : []
  for (var i = 0; i < streams.length; i++) {
    var sNode = streams[i]
    if (!sNode) continue
    var p = nodeProps(sNode)
    var isCorked = p["pulse.corked"] === "true" || p["pulse.corked"] === true
    var isMuted = sNode.audio && sNode.audio.muted
    if (isCorked || isMuted) continue

    var sLabel = rawStreamLabel(sNode)
    if (areAppsInSameFamily(pLabel, sLabel) || areAppsInSameFamily(pDbus, sLabel)) return true
    var binary = String(p["application.process.binary"] || "")
    if (binary && (areAppsInSameFamily(pLabel, binary) || areAppsInSameFamily(pDbus, binary))) return true
  }

  return false
}

function playerKey(player) {
  if (!player) return ""
  return String(player.dbusName || player.desktopEntry || player.identity || "")
}

function playerCanonicalKey(player) {
  if (!player) return ""
  var dbus = String(player.dbusName || "").toLowerCase()
  var desktop = String(player.desktopEntry || "").toLowerCase()
  var identity = String(player.identity || "").toLowerCase()
  var appName = String(player.appName || "").toLowerCase()

  var base = dbus.replace(/^org\.mpris\.mediaplayer2\./, "")
  base = base.replace(/[\._]instance.*$/, "")
  base = base.replace(/[^a-z0-9]/g, "")

  if (base) return base
  if (desktop) return desktop.replace(/[^a-z0-9]/g, "")
  if (identity) return identity.replace(/[^a-z0-9]/g, "")
  if (appName) return appName.replace(/[^a-z0-9]/g, "")
  return playerKey(player)
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

// Cleans up common ugly tags from media titles (e.g. YouTube, Animepahe, movie/music titles)
function cleanTitle(rawTitle, rawArtist) {
  var title = String(rawTitle || "").trim()
  if (!title) return ""

  // 1. Remove browser suffixes
  title = title.replace(/\s*[-—|•]\s*(?:Zen Browser|Mozilla Firefox|Firefox|Google Chrome|Chromium|Brave|Microsoft Edge|Vivaldi|Opera)$/i, "")

  // 2. Remove site branding suffixes
  title = title.replace(/\s*(?:[-—|•]|on|::|\|)\s*(?:YouTube|Twitch|SoundCloud|Spotify|Netflix|Crunchyroll|Coursera|Bandcamp|Vimeo|Reddit|Bilibili|Animepahe|HiAnime|AniWave|Gogoanime|FMovies|Dulo TV|Dulo)(?:\.[a-z]{2,4})?$/i, "")
  title = title.replace(/\s*[-—|•]\s*Watch on [A-Za-z0-9 ]+$/i, "")
  title = title.replace(/\s*::\s*.*$/i, "")

  // 3. Remove streaming filler phrases
  title = title.replace(/\s*(?:Full Movie|Full Show|Full HD|HD Free|Online Free HD|Online Free|Watch Free Online|Watch Online Free|Watch Online|Free Online|Online HD|Free HD|HD Online|Free Stream|Streaming Online)\s*/gi, " ")
  title = title.replace(/^Watch\s+/i, "")

  // 4. Remove anime release group tags and video quality brackets
  title = title.replace(/^\[[^\]]+\]\s*/g, "")
  title = title.replace(/\s*\[[0-9a-fA-F]{8}\]/g, "") // CRC32 hashes
  title = title.replace(/\s*\[(?:1080p|720p|480p|2160p|4k|aac|hevc|x264|x265|dvd|bd|bluray|vostfr|sub)\]/gi, "")
  title = title.replace(/\s*\((?:1080p|720p|480p|2160p|4k|aac|hevc|x264|x265|dvd|bd|bluray|vostfr|sub)\)/gi, "")

  // 5. Remove file extensions
  title = title.replace(/\.(mkv|mp4|avi|webm|mp3|flac|wav|m4a|ogg|opus)$/i, "")

  // 6. Strip duplicate artist prefix if present
  if (rawArtist && title.toLowerCase().indexOf(String(rawArtist).toLowerCase() + " - ") === 0) {
    title = title.substring(String(rawArtist).length + 3).trim()
  }

  // 7. Clean up multiple consecutive spaces
  title = title.replace(/\s{2,}/g, " ").trim()

  // 8. If title had "Artist - Title", split it unless right side is episode/season
  if (!rawArtist && title.indexOf(" - ") !== -1) {
    var parts = title.split(" - ")
    if (parts.length === 2) {
      var left = parts[0].trim()
      var right = parts[1].trim()
      var isEpisode = /^(?:ep|episode|season|part|vol|v|s[0-9]+|e[0-9]+)?\s*[0-9]+(?:\.[0-9]+)?$/i.test(right)
      if (!isEpisode && left.length > 1 && right.length > 1 && !/^(?:Season|Episode|Chapter)/i.test(right)) {
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

  if (artist && artist !== "Unknown" && artist !== "undefined") return artist

  // If artist is missing, check if title had "Artist - Title"
  var title = String(rawTitle || "").trim()
  title = title.replace(/\s*[-—|•]\s*(?:Zen Browser|Mozilla Firefox|Firefox|Google Chrome|Chromium|Brave|YouTube|Twitch|SoundCloud|Spotify|Netflix|Crunchyroll|Coursera|Bandcamp|Vimeo|Reddit|Bilibili)$/i, "")
  title = title.replace(/\s*[-—|•]\s*Watch on [A-Za-z0-9 ]+$/i, "")

  if (title.indexOf(" - ") !== -1) {
    var parts = title.split(" - ")
    if (parts.length === 2) {
      var left = parts[0].trim()
      var right = parts[1].trim()
      var isEpisode = /^(?:ep|episode|season|part|vol|v)?\s*[0-9]+(?:\.[0-9]+)?$/i.test(right)
      if (!isEpisode && left.length > 1 && right.length > 1) {
        return left
      }
    }
  }

  // Fallback to detected platform name
  var src = sourceName(player)
  if (src && src !== "Player" && src !== "Media" && src !== "Unknown") return src

  return ""
}

// Robust artwork extraction with YouTube thumbnail fallback
function extractArtUrl(player) {
  if (!player) return ""
  if (player.trackArtUrl) return String(player.trackArtUrl)

  var meta = player.metadata || {}
  if (meta["mpris:artUrl"]) return String(meta["mpris:artUrl"])
  if (meta["xesam:artUrl"]) return String(meta["xesam:artUrl"])

  var url = String(meta["xesam:url"] || player.url || "")
  if (url) {
    var ytMatch = url.match(/(?:youtube\.com\/watch\?v=|youtu\.be\/)([a-zA-Z0-9_-]{11})/)
    if (ytMatch && ytMatch[1]) {
      return "https://i.ytimg.com/vi/" + ytMatch[1] + "/hqdefault.jpg"
    }
  }
  return ""
}

// Identifies the exact playing website / streaming service or native desktop app
function detectPlatform(player) {
  if (!player) return { name: "Media", icon: "󰝚" }

  var meta = (player && player.metadata) ? player.metadata : {}
  var url = String(meta["xesam:url"] || player.url || "").toLowerCase()
  var rawTitle = String(player.trackTitle || meta["xesam:title"] || "").toLowerCase()
  var artUrl = String(player.trackArtUrl || meta["mpris:artUrl"] || meta["xesam:artUrl"] || "").toLowerCase()
  var id = String(player.identity || player.desktopEntry || player.dbusName || player.appName || "").toLowerCase()

  // 1. Spotify
  if (id.indexOf("spotify") !== -1 || url.indexOf("spotify.com") !== -1) {
    return { name: "Spotify", icon: "󰓇" }
  }

  // 2. YouTube
  if (url.indexOf("youtube.com") !== -1 || url.indexOf("youtu.be") !== -1 || artUrl.indexOf("ytimg.com") !== -1 || rawTitle.indexOf("youtube") !== -1) {
    return { name: "YouTube", icon: "󰗃" }
  }

  // 3. Twitch
  if (url.indexOf("twitch.tv") !== -1 || rawTitle.indexOf("twitch") !== -1) {
    return { name: "Twitch", icon: "󰕧" }
  }

  // 4. SoundCloud & Bandcamp
  if (url.indexOf("soundcloud.com") !== -1 || rawTitle.indexOf("soundcloud") !== -1) {
    return { name: "SoundCloud", icon: "󰝚" }
  }
  if (url.indexOf("bandcamp.com") !== -1 || rawTitle.indexOf("bandcamp") !== -1) {
    return { name: "Bandcamp", icon: "󰝚" }
  }

  // 5. Anime streaming sites (Animepahe, HiAnime, 9anime, Gogoanime)
  if (rawTitle.indexOf("animepahe") !== -1 || url.indexOf("animepahe") !== -1) return { name: "Animepahe", icon: "󰚩" }
  if (rawTitle.indexOf("hianime") !== -1 || url.indexOf("hianime") !== -1) return { name: "HiAnime", icon: "󰚩" }
  if (rawTitle.indexOf("9anime") !== -1 || rawTitle.indexOf("aniwave") !== -1) return { name: "AniWave", icon: "󰚩" }
  if (rawTitle.indexOf("gogoanime") !== -1 || rawTitle.indexOf("anitaku") !== -1) return { name: "Gogoanime", icon: "󰚩" }

  // 6. Movie streaming sites (FMovies, Dulo TV, Netflix, Crunchyroll)
  if (rawTitle.indexOf("fmovies") !== -1 || url.indexOf("fmovies") !== -1) return { name: "FMovies", icon: "󰐹" }
  if (rawTitle.indexOf("dulo.gd") !== -1 || rawTitle.indexOf("dulo tv") !== -1 || rawTitle.indexOf("dulo") !== -1 || url.indexOf("dulo") !== -1) return { name: "Dulo TV", icon: "󰐹" }
  if (url.indexOf("crunchyroll.com") !== -1 || rawTitle.indexOf("crunchyroll") !== -1) return { name: "Crunchyroll", icon: "󰚩" }
  if (url.indexOf("netflix.com") !== -1 || rawTitle.indexOf("netflix") !== -1) return { name: "Netflix", icon: "󰝆" }

  // 7. Dedicated desktop media players
  if (id.indexOf("mpv") !== -1) return { name: "MPV", icon: "󰐹" }
  if (id.indexOf("vlc") !== -1) return { name: "VLC", icon: "󰕼" }
  if (id.indexOf("cliamp") !== -1) return { name: "cliamp", icon: "󰎆" }
  if (id.indexOf("stremio") !== -1) return { name: "Stremio", icon: "󰐹" }
  if (id.indexOf("celluloid") !== -1) return { name: "Celluloid", icon: "󰐹" }

  // 8. Fallback to browser application name
  if (id.indexOf("zen") !== -1) return { name: "Zen Browser", icon: "󰈹" }
  if (id.indexOf("firefox") !== -1) return { name: "Firefox", icon: "󰈹" }
  if (id.indexOf("brave") !== -1) return { name: "Brave", icon: "󰊯" }
  if (id.indexOf("chrome") !== -1 || id.indexOf("chromium") !== -1) return { name: "Chrome", icon: "󰊯" }
  if (id.indexOf("edge") !== -1) return { name: "Edge", icon: "󰊯" }

  var fallbackName = (player && (player.identity || player.desktopEntry)) || "Media"
  return { name: fallbackName, icon: "󰝚" }
}

function sourceName(player) {
  return detectPlatform(player).name
}

function sourceIcon(player) {
  return detectPlatform(player).icon
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
    playerHasActiveStream: playerHasActiveStream,
    playerKey: playerKey,
    playerCanonicalKey: playerCanonicalKey,
    trackSignature: trackSignature,
    trackChanged: trackChanged,
    cleanTitle: cleanTitle,
    cleanArtist: cleanArtist,
    extractArtUrl: extractArtUrl,
    detectPlatform: detectPlatform,
    sourceName: sourceName,
    sourceIcon: sourceIcon,
    labelFor: labelFor,
    osdMessage: osdMessage
  }
}
