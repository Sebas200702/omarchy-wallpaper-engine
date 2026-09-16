# Wallpaper Engine for Omarchy

Rotating wallpaper engine inspired by `tenzin.live-wallpaper`, extended with:

- **Mixed rotation**: local images + videos, shuffle without repeat, timed interval
- **Schedules**: fixed `HH:MM` slots that force a specific file (e.g. night video at 21:00)
- **Online search**: Wallhaven (images, official API) + MoeWalls (live videos, via WP search + direct download) from the same picker
- **CLI + bar widget**: `next / prev / toggle / status / interval / search`

## Install

```bash
omarchy plugin add https://github.com/<tu-usuario>/omarchy-wallpaper-engine.git --enable
```

No extra packages needed beyond Omarchy stock (`ffmpeg`, `curl`, `jq`, `vipsthumbnail`).
Playback uses QtMultimedia like `tenzin.live-wallpaper` — no extra Quickshell process.

## Use

Put files in your theme folder:

```
~/.config/omarchy/backgrounds/<theme>/
```

Then open **Style → Background** (overridden by this plugin) or double-click the desktop.

### Rotation

Config lives in `~/.config/omarchy/wallpaper-engine.json` (created on first run from `config.example.json`):

```json
{
  "enabled": true,
  "intervalMinutes": 10,
  "mode": "shuffle",
  "schedules": [{ "time": "21:00", "pick": "night.mp4" }]
}
```

- `mode`: `"shuffle"` (random, no repeat until queue exhausted) or `"sequential"`.
- `schedules`: `time` is `HH:MM` local 24h, `pick` is a filename present in the theme folders (or an absolute path under allowed roots).
- Queue state: `~/.local/state/omarchy/wallpaper-engine/queue.json`.

### CLI

The plugin script is the CLI (symlink it or call by full path):

```bash
~/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh next
~/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh prev
~/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh toggle
~/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh status
~/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh interval 15
~/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh enable
~/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh disable
```

Online:

```bash
wallpaper-engine.sh search wallhaven "anime sunset"     # browse + pick, downloads to theme folder
wallpaper-engine.sh search moewalls "frieren"           # browse live videos, pick downloads full mp4
wallpaper-engine.sh online-status
wallpaper-engine.sh online-clear                        # prune download cache
```

### Bar widget

Add **Wallpaper Engine** to the bar: left-click = next wallpaper, right-click = pause/resume.
Tooltip shows current file + time to next rotation.

## How online works

- **Wallhaven**: official `api/v1/search` (SFW, no key). Downloads full `path` jpg/png.
- **MoeWalls**: WP REST `wp/v2/search` for title+URL, then detail HTML parse for `og:image` + `preview.webm` + `data-url` token → full mp4 via `https://go.moewalls.com/download.php?video=<token>` (reverse-engineered from their `custom-wall.js`, verified 2026-09-16). No official API — isolated in `providers/moewalls.sh` so breakage doesn't affect local rotation. Files are personal-use, artists keep rights.
- Downloads land in `~/.config/omarchy/backgrounds/<theme>/online/` and enter the normal rotation + picker flow. Size-guarded (`maxVideoBytes`, `onlineCacheMaxBytes` LRU prune).

Steam Wallpaper Engine Workshop is out of scope (proprietary format + DRM).

## Files

- `manifest.json` — service + bar-widget entry points
- `Service.qml` — per-screen video players + rotation/schedule timers + IPC
- `BarWidget.qml` — bar controls
- `wallpaper-engine.sh` — picker, rotation engine, state, CLI
- `providers/wallhaven.sh`, `providers/moewalls.sh` — online sources
- Runtime state: `~/.local/state/omarchy/wallpaper-engine/`
- Thumbs/cache: `~/.cache/omarchy/wallpaper-engine/`

## Remove

```bash
omarchy plugin remove sebas.wallpaper-engine
```

Removal stops playback, restores last static wallpaper, removes menu override and state/cache.
