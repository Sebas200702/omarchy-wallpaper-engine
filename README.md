# Wallpaper Engine for Omarchy

Rotating wallpaper engine inspired by `tenzin.live-wallpaper`, extended with:

- **Mixed rotation**: local images + videos, shuffle without repeat, timed interval
- **Playlists + Favorites**: named playlists with their own interval/mode, plus a flat favorites star available from any view
- **Schedules**: fixed `HH:MM` slots that force a specific file (e.g. night video at 21:00), managed from the CLI or the panel sidebar
- **Battery/idle-aware playback**: video decoding pauses on battery and after a period of inactivity, resumes instantly
- **Online search**: Wallhaven (images, official API, filters exposed in the panel) + MoeWalls (live videos, via WP search + direct download) from the same gallery, in 20-item pages with result totals ("showing X of N", "More (X of N)") and per-item attribution. Entering a source starts with an empty search — no default query, results reset on every source switch.
- **Panel gallery**: keyboard-navigable grid (arrows + Enter), delete-from-disk with inline confirm, favorite toggle per cell
- **CLI + bar widget**: `next / prev / toggle / status / interval / search / delete-file / favorite-toggle / schedule-add …`

## Install

```bash
omarchy plugin add <this repo's URL> --enable
```

(Replace with wherever you publish this — it isn't hosted anywhere yet.)

No extra packages needed beyond Omarchy stock (`ffmpeg`, `curl`, `jq`, `vipsthumbnail`).
Playback uses QtMultimedia like `tenzin.live-wallpaper` — no extra Quickshell process.

## Use

Put files in your theme folder:

```
~/.config/omarchy/backgrounds/<theme>/
```

Then open **Style → Background** (overridden by this plugin), double-click the
desktop, or summon the panel gallery (`omarchy-shell shell summon
sebas.wallpaper-engine`, or click the bar widget) for the full UI: library,
playlists, favorites, schedules, online search, and settings.

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
- `schedules`: `time` is `HH:MM` local 24h, `pick` is a filename present in the theme folders (or an absolute path under allowed roots). Manage from the panel sidebar or `schedule-add`/`schedule-remove`.
- `playlists`: named lists with their own `intervalMinutes`/`mode`, built from the panel's Select mode ("Select" → mark items → add to a playlist).
- `favorites`: a flat list of paths, toggled with the star on any grid cell or `favorite-toggle <path>`.
- Queue state: `~/.local/state/omarchy/wallpaper-engine/queue`.

### Battery/idle-aware playback

A video wallpaper only decodes while it can actually be seen:

- `pauseOnBattery` (default `false`): pause while on battery power.
- `pauseWhenIdle` (default `true`): pause after `idlePauseSeconds` (default
  `120`) of no keyboard/mouse activity — covers "away from the desk" and
  "screen locked", since both stop input.
- `muteVideos` (default `true`): videos play silent. Unmute from the panel's
  PLAYBACK section if you want sound (one player per screen, so unmuted
  audio stacks on multi-monitor).

This only pauses/resumes the video player; rotation and the engine's own
pause (bar widget, `toggle`) are unaffected. The bar tooltip tells them
apart: `(paused)` is your manual rotation pause, `video paused — on
battery / idle` is the automatic player freeze. Changes to these keys
take effect live (no restart needed), and the panel's PLAYBACK section
edits them without touching JSON.

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

Playlists, favorites, schedules:

```bash
wallpaper-engine.sh playlist-create "Evenings"
wallpaper-engine.sh playlist-add "Evenings" ~/.config/omarchy/backgrounds/dark/1.jpg
wallpaper-engine.sh playlist-activate "Evenings"       # or __all__ for the whole library
wallpaper-engine.sh favorite-toggle ~/.config/omarchy/backgrounds/dark/1.jpg
wallpaper-engine.sh schedule-add 21:00 night.mp4
wallpaper-engine.sh schedule-remove 21:00
wallpaper-engine.sh delete-file <path>                  # removes from disk + playlists/favorites; advances rotation if it was current
```

Online (native picker; the panel's own search UI calls `grid-search`/`apply-key` instead):

```bash
wallpaper-engine.sh search wallhaven "anime sunset"     # browse + pick, downloads to theme folder
wallpaper-engine.sh search moewalls "frieren"           # browse live videos, pick downloads full mp4
wallpaper-engine.sh grid-search wallhaven --page=2 "sunset"   # 20-item pages as {items,total,page,pageSize,hasMore}
wallpaper-engine.sh online-status
wallpaper-engine.sh online-clear                        # prune download cache
```

### Bar widget

Add **Wallpaper Engine** to the bar: left-click = open the panel gallery, right-click = next wallpaper, middle-click = pause/resume.
Tooltip shows current file + time to next rotation + automatic video-freeze
reason (`video paused — on battery / idle`) when the player — not the
rotation — is paused.

### Panel gallery

Summon with the bar widget or `omarchy-shell shell summon sebas.wallpaper-engine`:

- **Library / Playlists / Favorites** in the sidebar, each a grid of thumbnails.
- **Keyboard navigation**: arrow keys move the selection, Enter applies it.
- **Star** on every cell (or the Favorite button) toggles favorites; **×** removes an item from the playlist you're viewing.
- **Delete from disk**: two-step inline confirm (click once to arm, again to confirm) — permanently removes the file, drops it from any playlist/favorites, and advances rotation if it was the current wallpaper.
- **Attribution**: a downloaded online wallpaper shows its source (Wallhaven/MoeWalls) and the artist's page.
- **Online search**: Wallhaven filters (purity, sorting, minimum resolution, categories) are editable right there; results load in 20-item pages ("More (X of N)" while more exists).
  Typing in an online view searches live (700ms debounce; clearing the box
  clears the results, stale searches are killed together with their
  background downloads); thumbnail/detail fetches run up to 6-way parallel
  with a shared thumbnail cache plus a 24h MoeWalls detail cache, so repeat
  searches are near-instant. Typed Wallhaven queries use relevance order
  even when the saved sort is `random`;
  MoeWalls results rank exact title matches first.
- **Schedules**: add/remove `HH:MM` slots from the sidebar without touching the config file.

## How online works

- **Wallhaven**: official `api/v1/search` (filters configurable — see `wallhaven.*` in the config, or the panel's filter row). Downloads full `path` jpg/png.
- **MoeWalls**: WP REST `wp/v2/search` for title+URL, then detail HTML parse for `og:image` + `preview.webm` + `data-url` token → full mp4 via `https://go.moewalls.com/download.php?video=<token>` (reverse-engineered from their `custom-wall.js`, verified 2026-09-16). No official API — isolated in `providers/moewalls.sh` so breakage doesn't affect local rotation. Files are personal-use, artists keep rights.
- Downloads land in `~/.config/omarchy/backgrounds/<theme>/online/` and enter the normal rotation + picker flow, with a `<file>.attribution.json` sidecar recording where they came from. Size-guarded (`maxVideoBytes`, `onlineCacheMaxBytes` LRU prune).

Steam Wallpaper Engine Workshop is out of scope (proprietary format + DRM).

## Files

- `manifest.json` — service + bar-widget entry points
- `Service.qml` — per-screen video players + rotation/schedule timers + battery/idle pause + IPC
- `Panel.qml` — the gallery UI (library/playlists/favorites/online/schedules)
- `BarWidget.qml` — bar controls
- `wallpaper-engine.sh` — picker, rotation engine, state, CLI
- `providers/wallhaven.sh`, `providers/moewalls.sh` — online sources
- `tests/run.sh` — regression tests for the bash helper functions (`bash tests/run.sh`)
- Runtime state: `~/.local/state/omarchy/wallpaper-engine/`
- Thumbs/cache: `~/.cache/omarchy/wallpaper-engine/`

## Testing

```bash
bash tests/run.sh
```

Sources the real script against a fresh, isolated `$HOME` per test (never
touches your actual config/state) and exercises the pure/mostly-pure helper
functions directly — path validation, slug/name sanitizing, config reads,
schedule resolution. No network calls, no external dependencies beyond what
the plugin itself requires.

## Remove

```bash
omarchy plugin remove sebas.wallpaper-engine
```

Removal stops playback, restores last static wallpaper, removes menu override and state/cache.

## Known limitations

- **Single wallpaper for all monitors.** The video player is one shared
  `videoPath` replicated to every screen; there's no per-monitor selection
  or per-monitor fit mode yet. Untested beyond a single-monitor setup.
- **No live download progress bar** — the panel shows elapsed time, not a
  percentage, while a download is in flight.
- **No hover preview** for MoeWalls search results before downloading.
