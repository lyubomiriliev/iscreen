# iScreen

A fast macOS menu-bar screenshot app built for pasting into Claude: small files, reliable copy, quick annotations.

**[Download the latest version](https://github.com/lyubomiriliev/iscreen/releases/latest/download/iScreen.dmg)** · macOS 14 or later · Apple Silicon & Intel

## Install

1. Open `iScreen.dmg` and drag **iScreen** into **Applications**.
2. Open iScreen. The app isn't notarized by Apple, so macOS blocks the first launch: go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Allow **Screen & System Audio Recording** when asked, then relaunch iScreen.

Updates install from inside the app (**Check for Updates…** in the menu-bar menu).

## Use

| Shortcut | Action |
|---|---|
| ⌘3 | Select an area (then annotate) |
| ⌘4 | Full screen — copied, plus a draggable thumbnail for 5 s |

In the selection overlay:

| Key | Action |
|---|---|
| ⌘C / Enter | Copy |
| ⇧⌘C | Copy image + description: first ⌘V pastes the image, second ⌘V the source + on-device AI description |
| ⌘T | Copy text (OCR) |
| ⌘S | Save to Desktop with a smart file name |
| Esc | Cancel |
| V P L A R H T N B | Select, pen, line, arrow, rectangle, highlight, text, numbered step, pixelate |
| 1–6, [ ] | Color, stroke size |
| ⌘Z / ⇧⌘Z | Undo / redo |

Text recognition and AI features run on-device (Apple Vision and Apple Intelligence) — free, no API key.

## Build

Requires the Xcode Command Line Tools.

```sh
./build.sh            # → build/iScreen.app and build/iScreen.dmg
./release.sh "- What changed"   # maintainers: publish an update
```
