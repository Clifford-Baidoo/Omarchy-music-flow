# 🌊 Omarchy Music Flow

A sleek, ricer-styled **Music Flow** widget and floating **Media Controller** for [Omarchy Linux](https://omarchy.org/) (Quickshell / Hyprland).

Featuring a smooth, borderless **dual-harmonic sound wave visualizer** on your status bar and a **dedicated floating Player & Source Selector** panel window.

---

## ✨ Features

- 🎵 **Pure Soundwave Visualizer Flow**: Dual-layer harmonic wave oscillating horizontally across the status bar in real-time with your theme's accent color.
- 🎨 **Minimalist & Borderless**: Clean, transparent integration that seamlessly blends with your top bar without visual clutter.
- 📜 **Smooth Marquee Scroll**: Track title and artist (`Title · Artist`) with initial pause and smooth scrolling when names are long.
- 🎛️ **Dedicated Floating Media Player Panel**:
  - High-resolution album artwork preview.
  - Track metadata (Title, Artist, Album, Source).
  - Comfortable playback controls (**Previous**, **Play / Pause**, **Next**).
  - **Multi-Source Selector (`󱘖 SELECT PLAYER / SOURCE`)**: Instantly switch between running players (**Spotify**, **YouTube / Browser**, **cliamp**, **VLC**, etc.) with one click.
- 🗕 **Minimizable Compact Mode**: Collapses smoothly into a clean standalone status bar icon (**`󰝚`**) matching the battery and speaker widgets.
- 🖱️ **Intuitive Gestures**:
  - **Left-Click**: Open/close the dedicated floating Player & Source Selector window.
  - **Middle-Click**: Toggle Play / Pause.
  - **Scroll Wheel**: Scroll up/down over the widget to skip backward/forward tracks.
  - **Right-Click**: Direct access to the source menu.

---

## 🚀 Installation

Clone this repository and run the install script:

```bash
git clone https://github.com/<your-username>/omarchy-music-flow.git
cd omarchy-music-flow
chmod +x install.sh
./install.sh
```

The installer will:
1. Copy the plugin files to `~/.config/omarchy/plugins/<username>.media/`.
2. Automatically configure your bar layout in `~/.config/omarchy/shell.json`.
3. Restart `omarchy-shell` to apply changes instantly.

---

## 🕹️ Controls & Shortcuts

| Action | Bar Widget Gesture | Floating Player Window |
| :--- | :--- | :--- |
| **Open / Close Panel** | `Left-Click` | `Click Outside` / `ESC` |
| **Play / Pause** | `Middle-Click` | Center Button (`󰏤` / `󰐊`) |
| **Next Track** | `Scroll Down` | Forward Button (`󰒭`) |
| **Previous Track** | `Scroll Up` | Back Button (`󰒮`) |
| **Switch Player / Source** | Via Floating Panel | Click any player card in list |

---

## 📂 File Structure

```
omarchy-music-flow/
├── BarWidget.qml     # Status bar music flow & floating PopupCard panel
├── Service.qml       # MPRIS audio service & multi-source coordinator
├── MediaModel.js     # DBus player detection & metadata formatting
├── manifest.json     # Omarchy shell plugin manifest
├── install.sh        # Automated installer script
└── README.md         # Documentation
```

---

## 🛠️ Requirements

- [Omarchy](https://omarchy.org/) (Arch Linux + Hyprland + Quickshell)
- Any MPRIS-compatible media player (Spotify, Firefox / Zen / Chromium / Chrome, cliamp, VLC, Amberol, MPD, etc.)

---

## 📄 License

MIT License. Feel free to use, modify, and rice to your heart's content!
