#!/bin/bash
# Wallpaper Engine for Omarchy — rotating local images+videos + online search.
# Fork-inspired by tenzin.live-wallpaper (picker/IPC/state patterns reused).
set -uo pipefail

readonly plugin_id="sebas.wallpaper-engine"
readonly plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
readonly state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/wallpaper-engine"
readonly cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/wallpaper-engine"
readonly online_dir_name="online"
readonly stock_thumbnail_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/image-selector"
readonly user_config="$HOME/.config/omarchy/wallpaper-engine.json"
readonly video_state="$state_dir/video"
readonly poster_state="$state_dir/poster"
readonly expected_state="$state_dir/expected"
readonly fallback_state="$state_dir/fallback"
readonly queue_state="$state_dir/queue"
readonly history_state="$state_dir/history"
readonly lastchange_state="$state_dir/last-change"
readonly paused_state="$state_dir/paused"
readonly current_state="$state_dir/current"
readonly online_meta="$state_dir/online-meta.tsv"
readonly cleanup_helper="$state_dir/cleanup"
readonly rows_cache="$state_dir/picker-rows"
readonly rows_signature_state="$state_dir/picker-signature"
readonly transition_lock="$state_dir/transition.lock"
readonly rows_lock="$state_dir/picker.lock"
readonly MAX_VIDEO_BYTES=524288000
readonly MAX_ROWS=1200
readonly MAX_ROW_BYTES=2097152
readonly ONLINE_PER_PAGE=24

# run_curl_killable <curl-arg>... — runs curl in the background and forwards
# TERM/INT to it, then waits. A plain foreground `curl ...` does NOT get
# killed when this script does: bash's default disposition for TERM/INT
# while blocked in a foreground wait is to terminate the shell itself
# immediately, orphaning the still-running child — verified empirically.
# That matters here because the Panel's Cancel button works by killing the
# Process running this script (e.g. mid apply-key download): without this,
# Cancel only stops the UI from tracking the download, while curl itself
# keeps running in the background until its own -m timeout. Exit status
# mirrors what a plain `curl "$@"` would have set.
run_curl_killable() {
  curl "$@" &
  local cpid=$! rc
  # shellcheck disable=SC2064 -- intentional: expand $cpid now, not at trap time
  trap "kill -TERM $cpid 2>/dev/null; wait $cpid 2>/dev/null; exit 143" TERM INT
  wait "$cpid"
  rc=$?
  trap - TERM INT
  return "$rc"
}

# shellcheck disable=SC1091
[[ -f "$plugin_dir/providers/wallhaven.sh" ]] && source "$plugin_dir/providers/wallhaven.sh"
[[ -f "$plugin_dir/providers/moewalls.sh" ]] && source "$plugin_dir/providers/moewalls.sh"

ensure_secure_dir() {
  local dir="$1"
  [[ -L "$dir" ]] && { echo "refusing symlinked dir: $dir" >&2; return 1; }
  mkdir -p -m 0700 "$dir" 2>/dev/null || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  [[ -L "$dir" || ! -d "$dir" ]] && return 1
  return 0
}

ensure_secure_dir "$state_dir" || exit 1
ensure_secure_dir "$cache_dir" || exit 1
ensure_secure_dir "$cache_dir/online" 2>/dev/null || true

atomic_write() {
  local dest="$1" content="$2" dir tmp
  dir=$(dirname "$dest")
  ensure_secure_dir "$dir" || return 1
  [[ -L "$dest" ]] && rm -f "$dest" 2>/dev/null || true
  tmp=$(mktemp -p "$dir" .tmp.XXXXXX) || return 1
  chmod 0600 "$tmp" 2>/dev/null || true
  printf '%s\n' "$content" >"$tmp"
  chmod 0600 "$tmp" 2>/dev/null || true
  [[ -L "$dest" || -L "$dir" ]] && { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest"
  chmod 0600 "$dest" 2>/dev/null || true
}

# ---- config ----
ensure_config() {
  if [[ ! -f $user_config ]]; then
    if [[ -f $plugin_dir/config.example.json ]]; then
      mkdir -p "$(dirname "$user_config")"
      cp -f "$plugin_dir/config.example.json" "$user_config"
      chmod 0600 "$user_config" 2>/dev/null || true
    else
      printf '{"enabled":true,"intervalMinutes":10,"mode":"shuffle","includeImages":true,"includeVideos":true,"transitionMs":420,"schedules":[]}\n' >"$user_config"
    fi
  fi
}
ensure_config

cfg() {
  # cfg <jq-filter> <default>
  # Uses an explicit null-check rather than jq's `//` alternative operator:
  # `//` treats `false` as falsy too (0 and "" are not), so
  # "$filter // empty" would silently fall back to the default for a
  # boolean config key the user explicitly set to false (e.g.
  # .enabled:false, .includeVideos:false) — exactly the values callers
  # most need to read back correctly. Only a genuinely missing/null value
  # should use the default.
  local filter="$1" def="${2:-}" val
  val=$(jq -r --arg d "$def" "(${filter}) as \$v | if \$v == null then \$d else \$v end" "$user_config" 2>/dev/null) || val=""
  [[ -z $val ]] && printf '%s' "$def" || printf '%s' "$val"
}

readonly MIN_VIDEO_BYTES_FLOOR=10485760   # 10 MiB — below this, "max video size" is not a sane setting
readonly MAX_VIDEO_BYTES_CEILING=4294967296 # 4 GiB — hard ceiling regardless of user config

effective_max_video_bytes() {
  # honors user config .maxVideoBytes, clamped to a sane range, falling
  # back to the built-in default when unset/invalid.
  local v
  v=$(cfg '.maxVideoBytes' "$MAX_VIDEO_BYTES")
  [[ $v =~ ^[0-9]+$ ]] || v=$MAX_VIDEO_BYTES
  (( v < MIN_VIDEO_BYTES_FLOOR )) && v=$MIN_VIDEO_BYTES_FLOOR
  (( v > MAX_VIDEO_BYTES_CEILING )) && v=$MAX_VIDEO_BYTES_CEILING
  printf '%s' "$v"
}

is_video() {
  local ext="${1##*.}"
  ext="${ext,,}"
  case ",$ext," in
    ,mp4,|,mkv,|,webm,|,mov,|,m4v,) return 0 ;;
  esac
  return 1
}

is_image() {
  local ext="${1##*.}"
  ext="${ext,,}"
  case ",$ext," in
    ,jpg,|,jpeg,|,png,|,gif,|,bmp,|,webp,) return 0 ;;
  esac
  return 1
}

sanitize_theme_name() {
  local raw="$1"
  raw=$(printf '%s' "$raw" | tr -d '\n\r' | head -c 128)
  raw=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -z $raw ]] && return 1
  [[ $raw =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  [[ $raw == *".."* ]] && return 1
  printf '%s' "$raw"
}

theme_dirs() {
  # echoes: theme_dir \n user_dir \n online_dir
  local raw sanitized theme_dir user_dir
  raw=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null | head -c 128)
  sanitized=$(sanitize_theme_name "$raw" 2>/dev/null) || sanitized=""
  theme_dir="$HOME/.local/state/omarchy/current/theme/backgrounds"
  if [[ -n $sanitized ]]; then
    user_dir="$HOME/.config/omarchy/backgrounds/$sanitized"
  else
    user_dir="$HOME/.config/omarchy/backgrounds"
  fi
  [[ $user_dir != "$HOME/.config/omarchy/backgrounds"* ]] && user_dir="$HOME/.config/omarchy/backgrounds"
  printf '%s\n%s\n%s/%s\n' "$theme_dir" "$user_dir" "$user_dir" "$online_dir_name"
}

validate_wallpaper_path() {
  local p="$1"
  [[ -n $p ]] || return 1
  (( ${#p} > 4096 )) && return 1
  [[ $p == *$'\n'* || $p == *$'\t'* ]] && return 1
  [[ $p == /* ]] || return 1
  local canon
  canon=$(readlink -f "$p" 2>/dev/null) || return 1
  [[ -f $canon ]] || return 1
  local allowed1="$HOME/.config/omarchy/backgrounds/"
  local allowed2="$HOME/.local/state/omarchy/current/theme/backgrounds/"
  local allowed2c
  allowed2c="$(readlink -f "$allowed2" 2>/dev/null || echo "$allowed2")"
  local allowed3="/usr/share/omarchy/"
  local allowed4="$HOME/.local/share/omarchy/"
  local allowed5="$cache_dir/online/"
  if [[ $canon != "$allowed1"* && $canon != "$allowed2"* && $canon != "$allowed2c"* \
     && $canon != "$allowed3"* && $canon != "$allowed4"* && $canon != "$allowed5"* ]]; then
    return 1
  fi
  local sz
  sz=$(stat -Lc '%s' "$canon" 2>/dev/null) || return 1
  if (( sz > $(effective_max_video_bytes) )) && is_video "$canon"; then return 1; fi
  return 0
}

# ---- playlist ----
build_playlist() {
  # stdout: one absolute path per line
  local inc_img inc_vid tdir udir odir
  inc_img=$(cfg '.includeImages' 'true'); inc_vid=$(cfg '.includeVideos' 'true')
  mapfile -t _dirs < <(theme_dirs)
  tdir="${_dirs[0]}" udir="${_dirs[1]}" odir="${_dirs[2]}"
  local args=()
  if [[ $inc_img == true ]]; then
    args+=( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' )
  fi
  if [[ $inc_vid == true ]]; then
    (( ${#args[@]} > 0 )) && args+=( -o )
    args+=( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.mov' -o -iname '*.m4v' )
  fi
  (( ${#args[@]} == 0 )) && return 0
  local d
  for d in "$tdir" "$udir" "$odir"; do
    [[ -L "$d" ]] && continue
    [[ -d "$d" ]] || continue
    find -L "$d" -maxdepth 4 -type f \( "${args[@]}" \) -print 2>/dev/null
  done | sort -u
}

# ---- playlists ----
# Playlists live in the user config: .playlists[] = {name, intervalMinutes, mode, items[]}.
# .activePlaylist = name | null (null = whole Library).
active_playlist_name() {
  jq -r '.activePlaylist // empty' "$user_config" 2>/dev/null
}

effective_interval() {
  local ap m
  ap=$(active_playlist_name)
  if [[ -n $ap ]]; then
    m=$(jq -r --arg n "$ap" '.playlists[]? | select(.name == $n) | .intervalMinutes // empty' "$user_config" 2>/dev/null)
    if [[ $m =~ ^[0-9]+$ && $m -ge 1 && $m -le 1440 ]]; then printf '%s' "$m"; return 0; fi
  fi
  m=$(cfg '.intervalMinutes' '10')
  [[ $m =~ ^[0-9]+$ ]] || m=10
  (( m < 1 )) && m=1
  (( m > 1440 )) && m=1440
  printf '%s' "$m"
}

effective_mode() {
  local ap m
  ap=$(active_playlist_name)
  if [[ -n $ap ]]; then
    m=$(jq -r --arg n "$ap" '.playlists[]? | select(.name == $n) | .mode // empty' "$user_config" 2>/dev/null)
    [[ $m == sequential || $m == shuffle ]] && { printf '%s' "$m"; return 0; }
  fi
  m=$(cfg '.mode' 'shuffle')
  [[ $m == sequential ]] && printf 'sequential' || printf 'shuffle'
}

# current_source_items: playlist items (existing files) or full library
current_source_items() {
  local ap f
  ap=$(active_playlist_name)
  if [[ -n $ap ]]; then
    jq -r --arg n "$ap" '.playlists[]? | select(.name == $n) | .items[]?' "$user_config" 2>/dev/null \
      | while IFS= read -r f; do [[ -f $f ]] && printf '%s\n' "$f"; done | sort -u
  else
    build_playlist
  fi
}

valid_playlist_name() {
  local n="$1"
  [[ -n $n ]] || return 1
  (( ${#n} <= 64 )) || return 1
  [[ $n == *$'\n'* || $n == *$'\t'* ]] && return 1
  n=$(printf '%s' "$n" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -n $n ]] || return 1
  printf '%s' "$n"
}

save_config_filtered() {
  # save_config_filtered <jq-filter> [jq-args...] — atomic config rewrite
  local filter="$1"; shift
  local tmp
  tmp=$(mktemp) || return 1
  if jq "$@" "$filter" "$user_config" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$user_config"
    chmod 0600 "$user_config" 2>/dev/null || true
  else
    rm -f "$tmp"; return 1
  fi
}

# ---- favorites ----
# A flat list (.favorites in the config) — unlike playlists, no name,
# interval or mode; just a quick star toggle available from any view.
favorite_toggle() {
  local path="${1:-}" canon was_fav
  [[ -n $path ]] || { echo "usage: favorite-toggle <path>" >&2; return 1; }
  validate_wallpaper_path "$path" || { echo "invalid or not an allowed wallpaper path: $path" >&2; return 1; }
  canon=$(readlink -f "$path") || return 1
  was_fav=$(jq -r --arg f "$canon" '((.favorites // []) | index($f)) != null' "$user_config" 2>/dev/null)
  if [[ $was_fav == true ]]; then
    save_config_filtered '.favorites = ((.favorites // []) | map(select(. != $f)))' --arg f "$canon" || return 1
  else
    save_config_filtered '.favorites = ((.favorites // []) + [$f] | unique)' --arg f "$canon" || return 1
  fi
  jq -n --arg p "$canon" --argjson wasFav "${was_fav:-false}" '{path: $p, favorite: ($wasFav | not)}'
}

favorites_count() {
  jq '(.favorites // []) | length' "$user_config" 2>/dev/null || printf '0'
}

playlists_json() {
  local ap
  ap=$(active_playlist_name)
  jq --arg ap "$ap" '
    { active: (if $ap == "" then null else $ap end),
      playlists: [(.playlists // [])[] | {name, intervalMinutes, mode, count: (.items | length)}] }' "$user_config"
}

playlist_create() {
  local name
  name=$(valid_playlist_name "${1:-}") || { echo "invalid playlist name (1-64 chars)" >&2; return 1; }
  if jq -e --arg n "$name" '.playlists[]? | select(.name == $n)' "$user_config" >/dev/null 2>&1; then
    echo "playlist exists: $name" >&2; return 1
  fi
  local iv md
  iv=$(cfg '.intervalMinutes' '10'); md=$(cfg '.mode' 'shuffle')
  [[ $md == sequential ]] || md="shuffle"
  save_config_filtered '.playlists = ((.playlists // []) + [{name: $n, intervalMinutes: $iv, mode: $m, items: []}])' \
    --arg n "$name" --argjson iv "$iv" --arg m "$md" || return 1
  playlists_json
}

playlist_delete() {
  [[ -n ${1:-} ]] || { echo "usage: playlist-delete <name>" >&2; return 1; }
  save_config_filtered '(.playlists // []) |= map(select(.name != $n)) | if .activePlaylist == $n then .activePlaylist = null else . end' \
    --arg n "$1" || return 1
  reset_rotation_state
  playlists_json
}

playlist_add() {
  local name="$1"; shift
  [[ -n $name ]] || { echo "usage: playlist-add <name> <file...>" >&2; return 1; }
  jq -e --arg n "$name" '.playlists[]? | select(.name == $n)' "$user_config" >/dev/null 2>&1 \
    || { echo "no such playlist: $name" >&2; return 1; }
  local f added=0 tmp_list
  tmp_list=$(mktemp) || return 1
  jq -r --arg n "$name" '.playlists[]? | select(.name == $n) | .items[]?' "$user_config" >"$tmp_list" 2>/dev/null
  for f in "$@"; do
    validate_wallpaper_path "$f" 2>/dev/null || continue
    grep -Fxq "$f" "$tmp_list" 2>/dev/null && continue
    printf '%s\n' "$f" >>"$tmp_list"; added=$((added + 1))
  done
  if (( added > 0 )); then
    local items_json
    items_json=$(jq -R -s '[split("\n")[] | select(length > 0)]' "$tmp_list")
    save_config_filtered '(.playlists[] | select(.name == $n) | .items) = $items' \
      --arg n "$name" --argjson items "$items_json" || { rm -f "$tmp_list"; return 1; }
    reset_rotation_state
  fi
  rm -f "$tmp_list"
  jq -n --argjson added "$added" '{added: $added}'
}

playlist_remove() {
  [[ -n ${1:-} && -n ${2:-} ]] || { echo "usage: playlist-remove <name> <file>" >&2; return 1; }
  save_config_filtered '(.playlists[] | select(.name == $n) | .items) |= map(select(. != $f))' \
    --arg n "$1" --arg f "$2" || return 1
  reset_rotation_state
  playlists_json
}

delete_wallpaper_file() {
  # delete_wallpaper_file <path> — removes the file (+ its attribution
  # sidecar, if any) from disk, drops it from every playlist that
  # references it, and — if it was the one currently showing — advances
  # rotation so no state is left pointing at a file that no longer exists.
  local path="${1:-}" canon
  [[ -n $path ]] || { echo "usage: delete-file <path>" >&2; return 1; }
  validate_wallpaper_path "$path" || { echo "invalid or not an allowed wallpaper path: $path" >&2; return 1; }
  canon=$(readlink -f "$path") || return 1
  [[ -f $canon ]] || { echo "not found: $canon" >&2; return 1; }
  rm -f -- "$canon" "${canon}.attribution.json" || { echo "could not delete: $canon" >&2; return 1; }
  save_config_filtered '.playlists[]? |= (.items |= map(select(. != $f))) | .favorites = ((.favorites // []) | map(select(. != $f)))' --arg f "$canon" || true
  reset_rotation_state
  if [[ -s $current_state && $(<"$current_state") == "$canon" ]]; then
    do_next >/dev/null 2>&1 || true
  fi
  jq -n --arg deleted "$canon" '{deleted: $deleted}'
}

playlist_activate() {
  if [[ ${1:-__all__} == __all__ ]]; then
    save_config_filtered '.activePlaylist = null' || return 1
  else
    jq -e --arg n "$1" '.playlists[]? | select(.name == $n)' "$user_config" >/dev/null 2>&1 \
      || { echo "no such playlist: $1" >&2; return 1; }
    save_config_filtered '.activePlaylist = $n' --arg n "$1" || return 1
  fi
  reset_rotation_state
  config_get_json
}

playlist_set_interval() {
  [[ -n ${1:-} ]] || { echo "usage: playlist-interval <name> <minutes>" >&2; return 1; }
  [[ ${2:-} =~ ^[0-9]+$ && $2 -ge 1 && $2 -le 1440 ]] || { echo "interval must be 1-1440" >&2; return 1; }
  save_config_filtered '(.playlists[] | select(.name == $n) | .intervalMinutes) = $m' \
    --arg n "$1" --argjson m "$2" || return 1
  reset_rotation_state
  config_get_json
}

playlist_set_mode() {
  [[ -n ${1:-} ]] || { echo "usage: playlist-mode <name> <shuffle|sequential>" >&2; return 1; }
  [[ ${2:-} == shuffle || ${2:-} == sequential ]] || { echo "mode must be shuffle|sequential" >&2; return 1; }
  save_config_filtered '(.playlists[] | select(.name == $n) | .mode) = $m' \
    --arg n "$1" --arg m "$2" || return 1
  reset_rotation_state
  config_get_json
}

reset_rotation_state() {
  rm -f "$queue_state"
  date +%s >"$lastchange_state"
}

refill_queue() {
  local mode tmp
  mode=$(effective_mode)
  tmp=$(mktemp) || return 1
  if [[ $mode == sequential ]]; then
    current_source_items >"$tmp"
  else
    current_source_items | shuf >"$tmp"
  fi
  # drop current so we don't repeat immediately
  if [[ -s $current_state ]]; then
    local cur
    cur=$(<"$current_state")
    grep -Fxv "$cur" "$tmp" >"$tmp.new" 2>/dev/null && mv -f "$tmp.new" "$tmp" || true
  fi
  head -n "$MAX_ROWS" "$tmp" >"$queue_state"
  chmod 0600 "$queue_state" 2>/dev/null || true
  rm -f "$tmp"
}

pop_queue() {
  [[ -s $queue_state ]] || refill_queue
  [[ -s $queue_state ]] || return 1
  local next
  next=$(head -n 1 "$queue_state")
  tail -n +2 "$queue_state" >"$queue_state.new" && mv -f "$queue_state.new" "$queue_state"
  printf '%s' "$next"
}

push_history() {
  local f="$1"
  [[ -n $f ]] || return 0
  touch "$history_state" 2>/dev/null
  { printf '%s\n' "$f"; cat "$history_state" 2>/dev/null; } | head -n 20 >"$history_state.new"
  mv -f "$history_state.new" "$history_state"
}

# ---- IPC / apply ----
play_video_ipc() {
  local video="$1" transition_ms="${2:-0}" i
  [[ $transition_ms =~ ^[0-9]+$ ]] || transition_ms=0
  (( transition_ms > 4000 )) && transition_ms=4000
  for i in {1..10}; do
    if omarchy-shell -q "$plugin_id" play "$video" "$transition_ms" >/dev/null 2>&1; then return 0; fi
    if omarchy-shell -q "$plugin_id" playSimple "$video" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 &
  sleep 0.9
  for i in {1..20}; do
    if omarchy-shell -q "$plugin_id" play "$video" "$transition_ms" >/dev/null 2>&1; then return 0; fi
    if omarchy-shell -q "$plugin_id" playSimple "$video" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  return 1
}

stop_video_ipc() {
  omarchy-shell -q "$plugin_id" stop >/dev/null 2>&1 || true
}

thumbnail_for_video() {
  local media="$1" signature hash thumbnail tmp fsize
  [[ -f "$media" ]] || return 1
  fsize=$(stat -Lc '%s' "$media" 2>/dev/null) || return 1
  (( fsize > $(effective_max_video_bytes) || fsize == 0 )) && return 1
  signature=$(stat -Lc '%s:%Y' "$media") || return 1
  hash=$(printf 'ffmpeg-v2:%s:%s' "$media" "$signature" | md5sum); hash="${hash%% *}"
  thumbnail="$cache_dir/$hash.jpg"
  [[ -L "$thumbnail" ]] && rm -f "$thumbnail"
  if [[ ! -f $thumbnail ]]; then
    ensure_secure_dir "$cache_dir" || return 1
    tmp=$(mktemp -p "$cache_dir" ".${hash}.XXXXXX.jpg") || return 1
    chmod 0600 "$tmp" 2>/dev/null || true
    if ! timeout 12 ffmpeg -nostdin -hide_banner -loglevel error -threads 1 -i "$media" -an \
      -frames:v 1 -vf "scale=1536:-2:force_original_aspect_ratio=decrease" -q:v 3 -y "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      tmp=$(mktemp -p "$cache_dir" ".${hash}.XXXXXX.jpg") || return 1
      chmod 0600 "$tmp" 2>/dev/null || true
      timeout 12 ffmpeg -nostdin -hide_banner -loglevel error -ss 1 -threads 1 -i "$media" -an \
        -frames:v 1 -vf "scale=1536:-2:force_original_aspect_ratio=decrease" -q:v 3 -y "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    fi
    [[ -f "$tmp" ]] || return 1
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$thumbnail"
    chmod 0644 "$thumbnail" 2>/dev/null || true
  fi
  printf '%s' "$thumbnail"
}

picker_thumbnail_for_image() {
  local media="$1" signature hash thumbnail tmp fsize
  [[ -f "$media" ]] || return 1
  fsize=$(stat -Lc '%s' "$media" 2>/dev/null) || return 1
  (( fsize == 0 )) && return 1
  if [[ -s $stock_thumbnail_dir/index.tsv && ! -L $stock_thumbnail_dir/index.tsv ]]; then
    signature=$(stat -Lc '%s:%Y' "$media") || return 1
    hash=$(awk -F '\t' -v path="$media" -v sig="$signature" '$1 == path && $2 == sig { print $3; exit }' "$stock_thumbnail_dir/index.tsv")
    if [[ $hash =~ ^[a-f0-9]+$ && -f $stock_thumbnail_dir/$hash.jpg && ! -L $stock_thumbnail_dir/$hash.jpg ]]; then
      printf '%s' "$stock_thumbnail_dir/$hash.jpg"; return 0
    fi
  fi
  signature=$(stat -Lc '%s:%Y' "$media") || return 1
  hash=$(printf 'picker-v3:%s:%s' "$media" "$signature" | md5sum); hash="${hash%% *}"
  thumbnail="$cache_dir/$hash.jpg"
  [[ -L "$thumbnail" ]] && rm -f "$thumbnail"
  if [[ ! -f $thumbnail ]]; then
    ensure_secure_dir "$cache_dir" || return 1
    tmp=$(mktemp -p "$cache_dir" ".${hash}.XXXXXX.jpg") || return 1
    chmod 0600 "$tmp" 2>/dev/null || true
    timeout 12 bash -c 'VIPS_CONCURRENCY=1 vipsthumbnail "$1" --size 1536x864 --smartcrop=centre --path "$2[Q=82,strip]" >/dev/null 2>&1' _ "$media" "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$thumbnail"
    chmod 0644 "$thumbnail" 2>/dev/null || true
  fi
  printf '%s' "$thumbnail"
}

first_static_background() {
  mapfile -t _dirs < <(theme_dirs)
  find -L "${_dirs[0]}" "${_dirs[1]}" -maxdepth 4 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' \
       -o -iname '*.bmp' -o -iname '*.webp' \) -print -quit 2>/dev/null
}

remember_static_background() {
  local current_background
  current_background=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)
  [[ -L "$fallback_state" ]] && rm -f "$fallback_state"
  if [[ -s $fallback_state ]]; then return 0; fi
  local fallback="$current_background"
  if [[ -z $fallback || ! -f $fallback || $fallback == "$cache_dir/"* ]]; then
    fallback=$(first_static_background)
  fi
  [[ -n $fallback && -f $fallback ]] && atomic_write "$fallback_state" "$fallback"
}

apply_file() {
  # apply_file <path> [transition_ms] — image or video, updates all state
  local file="$1" transition_ms="${2:-}" poster prev
  [[ -z $transition_ms ]] && transition_ms=$(cfg '.transitionMs' '420')
  validate_wallpaper_path "$file" || return 1
  # canonicalize once we know $file is a valid, allowed path — everything
  # downstream (state files, `omarchy theme bg set`) stores/compares this
  # exact string, and stop_if_changed compares it against a readlink -f
  # of the live background symlink; keeping both sides canonical avoids
  # a spurious "manual change" detection when a background file is
  # itself reached through a symlink.
  file=$(readlink -f "$file") || return 1
  [[ -s $current_state ]] && prev=$(<"$current_state") || prev=""
  [[ -n $prev && $prev != "$file" ]] && push_history "$prev"
  if is_video "$file"; then
    poster=$(thumbnail_for_video "$file") || { omarchy-notification-send "Could not read video file" -t 2000; return 1; }
    [[ -L "$state_dir" ]] && return 1
    exec 9>"$transition_lock"
    flock -n 9 2>/dev/null || flock 9
    remember_static_background
    atomic_write "$video_state" "$file"
    atomic_write "$poster_state" "$poster"
    atomic_write "$expected_state" "$poster"
    atomic_write "$current_state" "$file"
    date +%s >"$lastchange_state"
    if ! timeout 15 omarchy theme bg set "$poster" || ! play_video_ipc "$file" "$transition_ms"; then
      restore_static_background
      omarchy-notification-send "Could not set video wallpaper" -t 2000
      return 1
    fi
  else
    [[ -f $file ]] || return 1
    stop_video_ipc
    rm -f "$video_state" "$poster_state"
    atomic_write "$expected_state" "$file"
    atomic_write "$current_state" "$file"
    date +%s >"$lastchange_state"
    timeout 15 omarchy theme bg set "$file" || true
  fi
}

restore_static_background() {
  local fallback=""
  stop_video_ipc
  [[ -L "$fallback_state" ]] && rm -f "$fallback_state" || { [[ -s $fallback_state ]] && fallback=$(<"$fallback_state"); }
  [[ -z $fallback || ! -f $fallback ]] && fallback=$(first_static_background)
  [[ -n $fallback && -f $fallback ]] && omarchy theme bg set "$fallback" || true
  rm -f "$video_state" "$poster_state" "$expected_state"
}

resume_engine() {
  [[ -L "$video_state" || -L "$poster_state" ]] && { rm -f "$video_state" "$poster_state"; return 0; }
  if [[ -s $video_state && -s $poster_state ]]; then
    local video poster
    video=$(<"$video_state"); poster=$(<"$poster_state")
    if validate_wallpaper_path "$video" 2>/dev/null && [[ -f $poster ]]; then
      [[ -s $expected_state ]] || atomic_write "$expected_state" "$poster"
      [[ -s $current_state ]] || atomic_write "$current_state" "$video"
      play_video_ipc "$video" 0
      return 0
    fi
  fi
  if [[ -s $current_state ]]; then
    local cur
    cur=$(<"$current_state")
    if is_image "$cur" && [[ -f $cur ]]; then
      [[ -s $expected_state ]] || atomic_write "$expected_state" "$cur"
      return 0
    fi
  fi
  # adopt whatever is on screen so rotation continues from here
  local now_bg
  now_bg=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)
  if [[ -n $now_bg && -f $now_bg ]]; then
    atomic_write "$expected_state" "$now_bg"
    atomic_write "$current_state" "$now_bg"
    date +%s >"$lastchange_state"
  fi
}

stop_if_changed() {
  # Manual change adoption: user picked something outside the engine.
  [[ -s $expected_state ]] || return 0
  [[ -L "$expected_state" ]] && { rm -f "$expected_state"; return 0; }
  exec 9>"$transition_lock"
  flock -n 9 || return 0
  local current expected
  current=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)
  expected=$(<"$expected_state")
  [[ -n $current && $current == "$expected" ]] && return 0
  # manual override → stop video if poster changed, adopt new current, reset timer
  stop_video_ipc
  rm -f "$video_state" "$poster_state"
  atomic_write "$expected_state" "$current"
  atomic_write "$current_state" "$current"
  date +%s >"$lastchange_state"
}

resolve_schedule_pick() {
  # resolve_schedule_pick <pick> -> absolute path or empty
  local pick="$1"
  [[ -n $pick ]] || return 1
  if [[ $pick == /* ]]; then
    validate_wallpaper_path "$pick" 2>/dev/null && printf '%s' "$pick" && return 0
    return 1
  fi
  local base f
  mapfile -t _dirs < <(theme_dirs)
  for base in "${_dirs[0]}" "${_dirs[1]}" "${_dirs[2]}"; do
    [[ -d "$base" ]] || continue
    f=$(find -L "$base" -maxdepth 4 -type f -name "$pick" -print -quit 2>/dev/null)
    if [[ -n $f ]]; then printf '%s' "$f"; return 0; fi
    [[ -f "$base/$pick" ]] && { printf '%s' "$base/$pick"; return 0; }
  done
  return 1
}

schedules_json() {
  jq -c '.schedules // []' "$user_config" 2>/dev/null || printf '[]'
}

schedule_add() {
  local time="${1:-}" pick="${2:-}"
  [[ -n $time && -n $pick ]] || { echo "usage: schedule-add <HH:MM> <pick>" >&2; return 1; }
  [[ $time =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "time must be HH:MM, 00:00-23:59" >&2; return 1; }
  # must resolve to something right now — otherwise it's a silently-dead
  # schedule the user has no way of knowing failed until it doesn't fire.
  resolve_schedule_pick "$pick" >/dev/null || { echo "pick not found in any theme/backgrounds folder: $pick" >&2; return 1; }
  save_config_filtered '.schedules = ((.schedules // []) + [{time: $t, pick: $p}])' --arg t "$time" --arg p "$pick" || return 1
  schedules_json
}

schedule_remove() {
  local time="${1:-}" pick="${2:-}"
  [[ -n $time ]] || { echo "usage: schedule-remove <HH:MM> [pick]" >&2; return 1; }
  if [[ -n $pick ]]; then
    save_config_filtered '.schedules = ((.schedules // []) | map(select(.time != $t or .pick != $p)))' --arg t "$time" --arg p "$pick" || return 1
  else
    save_config_filtered '.schedules = ((.schedules // []) | map(select(.time != $t)))' --arg t "$time" || return 1
  fi
  schedules_json
}

advance_if_due() {
  local enabled paused now last interval sched_time sched_pick sched_epoch
  enabled=$(cfg '.enabled' 'true')
  [[ $enabled == true ]] || return 0
  [[ -f $paused_state && $(<"$paused_state") == 1 ]] && return 0
  now=$(date +%s)
  [[ -s $lastchange_state ]] || { printf '%s' "$now" >"$lastchange_state"; return 0; }
  last=$(<"$lastchange_state"); [[ $last =~ ^[0-9]+$ ]] || last=$now
  # 1) schedules win over interval
  # A schedule slot repeats daily; look at both today's and yesterday's
  # occurrence and take whichever already happened (closest to now), so a
  # slot missed while the machine was off/suspended (or one whose time has
  # since crossed midnight relative to "now") still fires once on resume
  # instead of being silently skipped until the next calendar day.
  local sched_epoch_today sched_epoch_yesterday
  while IFS=$'\t' read -r sched_time sched_pick; do
    [[ -n $sched_time && -n $sched_pick ]] || continue
    [[ $sched_time =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || continue
    sched_epoch_today=$(date -d "today $sched_time" +%s 2>/dev/null) || continue
    if (( sched_epoch_today <= now )); then
      sched_epoch=$sched_epoch_today
    else
      sched_epoch_yesterday=$(date -d "yesterday $sched_time" +%s 2>/dev/null) || continue
      (( sched_epoch_yesterday <= now )) || continue
      sched_epoch=$sched_epoch_yesterday
    fi
    (( last < sched_epoch )) || continue
    local resolved
    if resolved=$(resolve_schedule_pick "$sched_pick"); then
      [[ -s $current_state && $(<"$current_state") == "$resolved" ]] && { printf '%s' "$now" >"$lastchange_state"; return 0; }
      apply_file "$resolved" && return 0
      return 1
    fi
  done < <(jq -r '.schedules[]? | [.time, .pick] | @tsv' "$user_config" 2>/dev/null)
  # 2) interval (playlist-specific when one is active)
  interval=$(effective_interval)
  if (( now - last >= interval * 60 )); then
    local next
    if next=$(pop_queue) && [[ -n $next ]]; then
      apply_file "$next" || return 1
    fi
  fi
}

do_next() {
  local next
  next=$(pop_queue) || { omarchy-notification-send "No wallpapers found" -t 2000; return 1; }
  apply_file "$next"
}

do_prev() {
  [[ -s $history_state ]] || { omarchy-notification-send "No previous wallpaper" -t 2000; return 1; }
  local prev cur
  prev=$(head -n 1 "$history_state")
  tail -n +2 "$history_state" >"$history_state.new" && mv -f "$history_state.new" "$history_state"
  [[ -s $current_state ]] && cur=$(<"$current_state") || cur=""
  # put current back at queue front
  if [[ -n $cur ]]; then
    { printf '%s\n' "$cur"; cat "$queue_state" 2>/dev/null; } >"$queue_state.new" && mv -f "$queue_state.new" "$queue_state"
  fi
  # apply without pushing history again
  local file="$prev" transition_ms
  transition_ms=$(cfg '.transitionMs' '420')
  validate_wallpaper_path "$file" || return 1
  file=$(readlink -f "$file") || return 1
  if is_video "$file"; then
    local poster
    poster=$(thumbnail_for_video "$file") || return 1
    remember_static_background
    atomic_write "$video_state" "$file"
    atomic_write "$poster_state" "$poster"
    atomic_write "$expected_state" "$poster"
    atomic_write "$current_state" "$file"
    date +%s >"$lastchange_state"
    timeout 15 omarchy theme bg set "$poster" && play_video_ipc "$file" "$transition_ms"
  else
    stop_video_ipc
    rm -f "$video_state" "$poster_state"
    atomic_write "$expected_state" "$file"
    atomic_write "$current_state" "$file"
    date +%s >"$lastchange_state"
    timeout 15 omarchy theme bg set "$file" || true
  fi
}

do_status() {
  local cur="" kind="none" active=false paused=false next_in="" queue_len=0 last now interval next_sched="" playlist=""
  [[ -s $current_state ]] && cur=$(<"$current_state")
  if [[ -n $cur ]]; then is_video "$cur" && kind="video" || kind="image"; active=true; fi
  [[ -f $paused_state && $(<"$paused_state") == 1 ]] && paused=true
  [[ $(cfg '.enabled' 'true') != true ]] && paused=true
  queue_len=0
  [[ -f $queue_state ]] && queue_len=$(wc -l <"$queue_state" 2>/dev/null || echo 0)
  now=$(date +%s); last=$(cat "$lastchange_state" 2>/dev/null || echo "$now")
  [[ $last =~ ^[0-9]+$ ]] || last=$now
  interval=$(effective_interval)
  next_in=$(( interval * 60 - (now - last) ))
  (( next_in < 0 )) && next_in=0
  next_sched=$(jq -r '.schedules[]? | .time' "$user_config" 2>/dev/null | sort | awk -v now="$(date +%H:%M)" '$1 > now {print $1; exit}')
  playlist=$(active_playlist_name)
  jq -n --arg cur "$cur" --arg kind "$kind" --argjson active "$active" --argjson paused "$paused" \
    --argjson nextIn "$next_in" --argjson queue "$queue_len" --arg sched "$next_sched" \
    --arg playlist "$playlist" --argjson interval "$interval" \
    '{active:$active, file:$cur, kind:$kind, paused:$paused, nextInSec:$nextIn, queueLen:$queue, nextSchedule:$sched, playlist:$playlist, intervalMinutes:$interval}'
}

# ---- online ----
safe_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g' | cut -c1-60 | sed 's/^-*//;s/-*$//'
}

online_search_wallhaven() {
  local query="$1" categories purity sorting atleast ratios i id page full thumb title slug stub
  categories=$(cfg '.wallhaven.categories' '111'); purity=$(cfg '.wallhaven.purity' '100')
  sorting=$(cfg '.wallhaven.sorting' 'random'); atleast=$(cfg '.wallhaven.atleast' '1920x1080')
  ratios=$(cfg '.wallhaven.ratios' '16x9')
  rm -f "$online_meta"
  local rows tmp_rows
  tmp_rows=$(mktemp) || return 1
  i=0
  while IFS=$'\t' read -r id page full thumb; do
    [[ -n $id && -n $full ]] || continue
    (( i++ )); (( i > ONLINE_PER_PAGE )) && break
    title="$id"
    slug="wh-$(safe_slug "$query")-$id"
    stub="$cache_dir/online/${slug}.jpg"
    if [[ ! -s $stub ]]; then
      curl -sSL --proto '=https' --max-redirs 3 -m 30 -A "omarchy-wallpaper-engine/0.1" -o "$stub.tmp" "$thumb" 2>/dev/null \
        && mv -f "$stub.tmp" "$stub" || continue
    fi
    printf '%s\t%s\n' "$stub" "$stub" >>"$tmp_rows"
    printf '%s\twallhaven\t%s\t%s\t%s\n' "$stub" "$full" "$page" "$title" >>"$online_meta"
  done < <(wallhaven_search "$query" "$categories" "$purity" "$sorting" "$atleast" "$ratios" 1)
  [[ -s $tmp_rows ]] || { rm -f "$tmp_rows"; omarchy-notification-send "No Wallhaven results" -t 2000; return 1; }
  open_picker_rows "$tmp_rows" "online"
  rm -f "$tmp_rows"
}

online_search_moewalls() {
  local query="$1" i id title page_url thumb preview token dtitle slug stub
  rm -f "$online_meta"
  local tmp_rows
  tmp_rows=$(mktemp) || return 1
  i=0
  while IFS=$'\t' read -r id title page_url; do
    [[ -n $page_url ]] || continue
    (( i++ )); (( i > ONLINE_PER_PAGE )) && break
    local detail
    detail=$(moewalls_detail "$page_url" 2>/dev/null) || continue
    IFS=$'\t' read -r thumb preview token dtitle <<<"$detail"
    [[ -n $token ]] || continue
    [[ -n $dtitle ]] && title="$dtitle"
    slug="moe-$(safe_slug "$title")-$id"
    stub="$cache_dir/online/${slug}.jpg"
    if [[ ! -s $stub ]]; then
      if [[ -n $thumb ]]; then
        curl -sSL --proto '=https' --max-redirs 3 -m 30 -A "Mozilla/5.0" -o "$stub.tmp" "$thumb" 2>/dev/null && mv -f "$stub.tmp" "$stub" || continue
      elif [[ -n $preview ]]; then
        # fallback: frame from preview webm
        curl -sSL --proto '=https' --max-redirs 3 -m 30 -A "Mozilla/5.0" -o "$cache_dir/online/${slug}.webm" "$preview" 2>/dev/null || continue
        timeout 12 ffmpeg -nostdin -hide_banner -loglevel error -i "$cache_dir/online/${slug}.webm" -frames:v 1 -q:v 3 -y "$stub" 2>/dev/null || continue
      else
        continue
      fi
    fi
    printf '%s\t%s\n' "$stub" "$stub" >>"$tmp_rows"
    printf '%s\tmoewalls\t%s\t%s\t%s\n' "$stub" "$token" "$page_url" "$title" >>"$online_meta"
  done < <(moewalls_search "$query" "$ONLINE_PER_PAGE")
  [[ -s $tmp_rows ]] || { rm -f "$tmp_rows"; omarchy-notification-send "No MoeWalls results" -t 2000; return 1; }
  open_picker_rows "$tmp_rows" "online"
  rm -f "$tmp_rows"
}

# write_attribution_sidecar <downloaded-file> <provider> <source-page-url> <title>
# Keeps track of where a downloaded wallpaper came from — the artist's
# original page — next to the file itself, so the Panel can show it (and so
# it survives online-meta.tsv being wiped on the next search). Sits outside
# the media-extension allowlist every find/build_playlist uses, so it never
# ends up in rotation.
write_attribution_sidecar() {
  local dest="$1" provider="$2" source_url="$3" title="$4" sidecar json
  sidecar="${dest}.attribution.json"
  json=$(jq -n --arg provider "$provider" --arg source "$source_url" --arg title "$title" \
    --arg downloadedAt "$(date -Is)" \
    '{provider: $provider, sourceUrl: $source, title: $title, downloadedAt: $downloadedAt}') || return 1
  atomic_write "$sidecar" "$json"
}

online_apply_stub() {
  # online_apply_stub <stub-path> — downloads full file to online dir + applies
  local stub="$1" line provider a b c max_bytes udir online_dir fname dest ext
  [[ -f $online_meta ]] || return 1
  # exact match on field 1 only — grep -F "$stub"$'\t' would also match if
  # $stub ever occurred as a substring later in the line (e.g. inside a
  # title), not just as the key.
  line=$(awk -F '\t' -v key="$stub" '$1 == key { print; exit }' "$online_meta")
  [[ -n $line ]] || return 1
  IFS=$'\t' read -r _stub provider a b c <<<"$line"
  mapfile -t _dirs < <(theme_dirs)
  udir="${_dirs[1]}"; online_dir="${_dirs[2]}"
  ensure_secure_dir "$online_dir" || return 1
  max_bytes=$(effective_max_video_bytes)
  if [[ $provider == wallhaven ]]; then
    ext="${a##*.}"; ext="${ext%%\?*}"; [[ $ext =~ ^(jpg|jpeg|png|webp)$ ]] || ext="jpg"
    fname="wh-$(safe_slug "$(basename "$stub" .jpg)")-${RANDOM}.${ext}"
    dest="$online_dir/$fname"
    omarchy-notification-send "Downloading wallpaper…" -t 1500
    wallhaven_download "$a" "$dest" "$max_bytes" || { omarchy-notification-send "Download failed" -t 2000; return 1; }
    write_attribution_sidecar "$dest" "wallhaven" "$b" "$c"
    apply_file "$dest"
  elif [[ $provider == moewalls ]]; then
    fname="moe-$(safe_slug "$(basename "$stub" .jpg)")-${RANDOM}.mp4"
    dest="$online_dir/$fname"
    omarchy-notification-send "Downloading live wallpaper (50-100 MB)…" -t 2500
    moewalls_download "$a" "$dest" "$max_bytes" || { omarchy-notification-send "Download failed" -t 2000; return 1; }
    write_attribution_sidecar "$dest" "moewalls" "$b" "$c"
    apply_file "$dest"
  else
    return 1
  fi
}

online_cache_bytes() {
  du -sb "$cache_dir/online" 2>/dev/null | cut -f1
}

online_clear() {
  local max_bytes keep
  max_bytes=$(cfg '.onlineCacheMaxBytes' '536870912')
  # prune LRU to half of max when over budget, or everything with --all
  if [[ ${1:-} == --all ]]; then
    rm -rf "$cache_dir/online"; ensure_secure_dir "$cache_dir/online"; return 0
  fi
  local cur
  cur=$(online_cache_bytes); [[ $cur =~ ^[0-9]+$ ]] || cur=0
  if (( cur > max_bytes )); then
    find "$cache_dir/online" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n 50 | cut -d' ' -f2- | xargs -r rm -f
  fi
  printf '%s\n' "$cur"
}

# ---- panel backend (JSON for Panel.qml) ----
grid_local_json() {
  local limit="${1:-120}" source="${2:-}" tmp cur list_tmp workers total_count
  tmp=$(mktemp) || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  export cache_dir stock_thumbnail_dir MAX_VIDEO_BYTES MIN_VIDEO_BYTES_FLOOR MAX_VIDEO_BYTES_CEILING user_config
  export -f is_video is_image thumbnail_for_video picker_thumbnail_for_image prewarm_media ensure_secure_dir cfg effective_max_video_bytes
  workers=$(nproc 2>/dev/null || echo 4); (( workers > 6 )) && workers=6; (( workers < 1 )) && workers=1
  if [[ $source == __favorites__ ]]; then
    list_tmp=$(mktemp) || return 1
    jq -r '.favorites[]?' "$user_config" 2>/dev/null \
      | while IFS= read -r f; do [[ -f $f ]] && printf '%s\n' "$f"; done | sort -u >"$list_tmp"
    total_count=$(wc -l <"$list_tmp")
    head -n "$limit" "$list_tmp" \
      | timeout 30 xargs -d '\n' -r -n 1 -P "$workers" bash -c 'prewarm_media "$1"' _ >"$tmp" 2>/dev/null
    rm -f "$list_tmp"
  elif [[ -n $source && $source != __all__ ]]; then
    list_tmp=$(mktemp) || return 1
    jq -r --arg n "$source" '.playlists[]? | select(.name == $n) | .items[]?' "$user_config" 2>/dev/null \
      | while IFS= read -r f; do [[ -f $f ]] && printf '%s\n' "$f"; done | sort -u >"$list_tmp"
    total_count=$(wc -l <"$list_tmp")
    head -n "$limit" "$list_tmp" \
      | timeout 30 xargs -d '\n' -r -n 1 -P "$workers" bash -c 'prewarm_media "$1"' _ >"$tmp" 2>/dev/null
    rm -f "$list_tmp"
  else
    list_tmp=$(mktemp) || return 1
    build_playlist 2>/dev/null >"$list_tmp"
    total_count=$(wc -l <"$list_tmp")
    head -n "$limit" "$list_tmp" \
      | timeout 30 xargs -d '\n' -r -n 1 -P "$workers" bash -c 'prewarm_media "$1"' _ >"$tmp" 2>/dev/null
    rm -f "$list_tmp"
  fi
  # surface truncation on stderr (not part of the JSON contract) so the
  # panel can tell the user "showing 150 of 812" instead of silently
  # hiding the rest of a large library/playlist.
  if [[ $total_count =~ ^[0-9]+$ && $limit =~ ^[0-9]+$ ]] && (( total_count > limit )); then
    printf 'TRUNCATED total=%s shown=%s\n' "$total_count" "$limit" >&2
  fi
  # Attribution (where a downloaded online wallpaper came from) is kept in
  # a sidecar next to the file, not in prewarm_media's own output — that
  # TSV format is also consumed as-is by the native image-selector picker,
  # so it must not gain a third field. Enrich only here, building a
  # {path: attribution} map from whichever rows actually have a sidecar.
  local attrs_tmp attrs_json media sc
  attrs_tmp=$(mktemp) || return 1
  while IFS=$'\t' read -r media _thumb; do
    [[ -n $media ]] || continue
    sc="${media}.attribution.json"
    [[ -s $sc && ! -L $sc ]] || continue
    jq -c --arg k "$media" '{key: $k, value: .}' "$sc" 2>/dev/null
  done <"$tmp" >"$attrs_tmp"
  attrs_json=$(jq -s 'map({(.key): .value}) | add // {}' "$attrs_tmp" 2>/dev/null) || attrs_json='{}'
  rm -f "$attrs_tmp"
  local favs_json
  favs_json=$(jq -c '.favorites // []' "$user_config" 2>/dev/null) || favs_json='[]'
  cur=""; [[ -s $current_state ]] && cur=$(<"$current_state")
  jq -R -s --arg cur "$cur" --argjson attrs "$attrs_json" --argjson favs "$favs_json" '
    [split("\n")[] | select(length > 0) | split("\t")
     | select(length >= 2)
     | (.[0] | split("/") | last | sub("\\.[^./]+$"; "") | gsub("[-_]+"; " ")) as $t
     | (if $t | test("^(moe|wh) ") then ($t | sub("^(moe|wh) +"; "") | sub("( [0-9]+)+$"; "") | sub(" moewalls$"; "") | sub(" live wallpaper$"; "")) else $t end) as $h
     | {key: .[0], title: $h,
        thumb: .[1],
        kind: (if .[0] | test("\\.(mp4|mkv|webm|mov|m4v)$"; "i") then "video" else "image" end),
        current: (.[0] == $cur),
        attribution: ($attrs[.[0]] // null),
        favorite: ((.[0] as $k | $favs | index($k)) != null)}]' "$tmp"
}

grid_search_json() {
  local provider="$1"; shift
  local page_num=1
  if [[ ${1:-} == --page=* ]]; then
    page_num="${1#--page=}"
    [[ $page_num =~ ^[0-9]+$ && $page_num -ge 1 ]] || page_num=1
    shift
  fi
  local query="${*:-anime}"
  # Wallhaven's API returns a fixed page size (not adjustable via a
  # per_page-style param) larger than the old cap=12 — capping below a
  # full provider page here means each "page" would silently discard
  # some of it, and paging would skip those discarded items forever.
  # Match cap to a full page for both providers instead (moewalls_search
  # is given this same value as its own per_page, so it always returns
  # up to exactly cap items too — nothing left over to skip).
  local cap=24 i=0
  : >"$online_meta"
  local rows
  rows=$(mktemp) || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$rows'" RETURN
  if [[ $provider == wallhaven ]]; then
    local categories purity sorting atleast ratios
    categories=$(cfg '.wallhaven.categories' '111'); purity=$(cfg '.wallhaven.purity' '100')
    sorting=$(cfg '.wallhaven.sorting' 'random'); atleast=$(cfg '.wallhaven.atleast' '1920x1080')
    ratios=$(cfg '.wallhaven.ratios' '16x9')
    local id page full thumb slug stub
    while IFS=$'\t' read -r id page full thumb; do
      [[ -n $id && -n $full && -n $thumb ]] || continue
      (( i++ )); (( i > cap )) && break
      slug="wh-$(safe_slug "$query")-$id"
      stub="$cache_dir/online/${slug}.jpg"
      if [[ ! -s $stub ]]; then
        curl -sSL --proto '=https' --max-redirs 3 -m 25 -A "omarchy-wallpaper-engine/0.1" -o "$stub.tmp" "$thumb" 2>/dev/null \
          && mv -f "$stub.tmp" "$stub" || continue
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$stub" "image" "$page" "$id" "$id" >>"$rows"
      printf '%s\twallhaven\t%s\t%s\t%s\n' "$stub" "$full" "$page" "$id" >>"$online_meta"
    done < <(wallhaven_search "$query" "$categories" "$purity" "$sorting" "$atleast" "$ratios" "$page_num")
  elif [[ $provider == moewalls ]]; then
    local id title page_url thumb preview token dtitle slug stub detail
    while IFS=$'\t' read -r id title page_url; do
      [[ -n $page_url ]] || continue
      (( i++ )); (( i > cap )) && break
      detail=$(moewalls_detail "$page_url" 2>/dev/null) || continue
      IFS=$'\t' read -r thumb preview token dtitle <<<"$detail"
      [[ -n $token ]] || continue
      [[ -n $dtitle ]] && title="$dtitle"
      slug="moe-$(safe_slug "$title")-$id"
      stub="$cache_dir/online/${slug}.jpg"
      if [[ ! -s $stub ]]; then
        if [[ -n $thumb ]]; then
          curl -sSL --proto '=https' --max-redirs 3 -m 25 -A "Mozilla/5.0" -o "$stub.tmp" "$thumb" 2>/dev/null && mv -f "$stub.tmp" "$stub" || continue
        elif [[ -n $preview ]]; then
          curl -sSL --proto '=https' --max-redirs 3 -m 25 -A "Mozilla/5.0" -o "$cache_dir/online/${slug}.webm" "$preview" 2>/dev/null || continue
          timeout 12 ffmpeg -nostdin -hide_banner -loglevel error -i "$cache_dir/online/${slug}.webm" -frames:v 1 -q:v 3 -y "$stub" 2>/dev/null || continue
        else
          continue
        fi
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$stub" "video" "$page_url" "$title" "$id" >>"$rows"
      printf '%s\tmoewalls\t%s\t%s\t%s\n' "$stub" "$token" "$page_url" "$title" >>"$online_meta"
    done < <(moewalls_search "$query" "$cap" "$page_num")
  else
    return 1
  fi
  jq -R -s '
    [split("\n")[] | select(length > 0) | split("\t")
     | select(length >= 5)
     | {key: .[0], kind: .[1], page: .[2],
        title: (.[3] | sub(" - MoeWalls$"; "") | sub(" Live Wallpaper$"; "")),
        thumb: .[0]}]' "$rows"
}

config_get_json() {
  do_status | jq --slurpfile cfg "$user_config" '{status: ., config: $cfg[0]}'
}

config_set_key() {
  local key="$1" val="$2" tmp
  tmp=$(mktemp) || return 1
  case "$key" in
    interval)
      [[ $val =~ ^[0-9]+$ && $val -ge 1 && $val -le 1440 ]] || { echo "interval must be 1-1440" >&2; rm -f "$tmp"; return 1; }
      jq --argjson m "$val" '.intervalMinutes = $m' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    mode)
      [[ $val == shuffle || $val == sequential ]] || { echo "mode must be shuffle|sequential" >&2; rm -f "$tmp"; return 1; }
      jq --arg m "$val" '.mode = $m' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    enabled)
      [[ $val == true || $val == false ]] || { echo "enabled must be true|false" >&2; rm -f "$tmp"; return 1; }
      jq --argjson b "$val" '.enabled = $b' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    includeImages|includeVideos|pauseOnBattery|pauseWhenIdle)
      [[ $val == true || $val == false ]] || { echo "$key must be true|false" >&2; rm -f "$tmp"; return 1; }
      jq --argjson b "$val" --arg k "$key" '.[$k] = $b' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    transitionMs)
      [[ $val =~ ^[0-9]+$ && $val -le 4000 ]] || { echo "transitionMs must be 0-4000" >&2; rm -f "$tmp"; return 1; }
      jq --argjson m "$val" '.transitionMs = $m' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    idlePauseSeconds)
      [[ $val =~ ^[0-9]+$ && $val -ge 10 && $val -le 3600 ]] || { echo "idlePauseSeconds must be 10-3600" >&2; rm -f "$tmp"; return 1; }
      jq --argjson m "$val" '.idlePauseSeconds = $m' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    maxVideoBytes|onlineCacheMaxBytes)
      [[ $val =~ ^[0-9]+$ && $val -ge 1048576 ]] || { echo "$key must be a byte count >= 1MiB" >&2; rm -f "$tmp"; return 1; }
      jq --argjson m "$val" --arg k "$key" '.[$k] = $m' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    wallhaven.categories|wallhaven.purity)
      [[ $val =~ ^[01]{3}$ ]] || { echo "$key must be 3 digits of 0/1 (e.g. 111)" >&2; rm -f "$tmp"; return 1; }
      jq --arg v "$val" --arg k "${key#wallhaven.}" '.wallhaven[$k] = $v' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    wallhaven.sorting)
      case "$val" in
        date_added|relevance|random|views|favorites|toplist) ;;
        *) echo "wallhaven.sorting must be one of date_added|relevance|random|views|favorites|toplist" >&2; rm -f "$tmp"; return 1 ;;
      esac
      jq --arg v "$val" '.wallhaven.sorting = $v' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    wallhaven.atleast)
      [[ -z $val || $val =~ ^[0-9]{2,5}x[0-9]{2,5}$ ]] || { echo "wallhaven.atleast must be WIDTHxHEIGHT (e.g. 1920x1080) or empty" >&2; rm -f "$tmp"; return 1; }
      jq --arg v "$val" '.wallhaven.atleast = $v' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    wallhaven.ratios)
      if [[ -n $val ]]; then
        local seg ok=1
        IFS=',' read -ra _ratio_segs <<<"$val"
        for seg in "${_ratio_segs[@]}"; do [[ $seg =~ ^[0-9]{1,2}x[0-9]{1,2}$ ]] || ok=0; done
        (( ok )) || { echo "wallhaven.ratios must be comma-separated WxH (e.g. 16x9,16x10) or empty" >&2; rm -f "$tmp"; return 1; }
      fi
      jq --arg v "$val" '.wallhaven.ratios = $v' "$user_config" >"$tmp" || { rm -f "$tmp"; return 1; } ;;
    *) echo "unknown key: $key" >&2; rm -f "$tmp"; return 1 ;;
  esac
  mv -f "$tmp" "$user_config"
  config_get_json
}

# ---- picker ----
prewarm_media() {
  local media="$1" thumbnail
  [[ $media == *$'\n'* || $media == *$'\t'* ]] && return 1
  (( ${#media} > 4096 )) && return 1
  [[ -f "$media" ]] || return 1
  if is_video "$media"; then thumbnail=$(thumbnail_for_video "$media")
  else thumbnail=$(picker_thumbnail_for_image "$media"); fi || return 1
  printf '%s\t%s\n' "$media" "$thumbnail"
}

open_picker_rows() {
  # open_picker_rows <rows_file> [mode] — mode=local|online
  local rows_file="$1" mode="${2:-local}"
  local selection_file done_file rows_b64 wallpaper
  selection_file=$(mktemp); done_file=$(mktemp)
  rm -f "$done_file"
  # shellcheck disable=SC2064
  trap "rm -f '$selection_file' '$done_file'" RETURN
  rows_b64=$(base64 -w 0 <"$rows_file")
  local selected=""
  [[ -s $current_state ]] && selected=$(<"$current_state")
  local open_result
  open_result=$(timeout 30 omarchy-shell image-selector open "" "$rows_b64" "$selected" "$selection_file" "$done_file" false false 2>/dev/null)
  [[ $open_result == ok ]] || return 1
  local waited=0
  while [[ ! -e $done_file ]]; do
    sleep 0.05; waited=$((waited+1)); (( waited > 6000 )) && return 1
  done
  [[ -s $selection_file ]] || return 0
  wallpaper=$(<"$selection_file")
  wallpaper=$(printf '%s' "$wallpaper" | tr -d '\r' | head -c 4096)
  wallpaper=$(printf '%s' "$wallpaper" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -n $wallpaper ]] || return 0
  if [[ $mode == online ]]; then
    online_apply_stub "$wallpaper"
    return $?
  fi
  # local mode: must be in rows (protect against injection)
  grep -Fxq "$wallpaper" <(cut -f1 "$rows_file" 2>/dev/null) 2>/dev/null || {
    validate_wallpaper_path "$wallpaper" 2>/dev/null || return 1
  }
  # online stubs inside local picker (downloaded previews dir is local anyway) — plain apply
  apply_file "$wallpaper"
}

local_picker() {
  local media_args=() media_signature selection_file done_file rows_file
  mapfile -t _dirs < <(theme_dirs)
  local tdir="${_dirs[0]}" udir="${_dirs[1]}"
  while IFS= read -r ext; do
    (( ${#media_args[@]} > 0 )) && media_args+=(-o)
    media_args+=(-iname "*.$ext")
  done <<'EOF_EXTS'
jpg
jpeg
png
gif
bmp
webp
mp4
mkv
webm
mov
m4v
EOF_EXTS
  media_signature=$(
    {
      printf 'engine-v1\0'
      find -L "$tdir" "$udir" -maxdepth 4 -type f \( "${media_args[@]}" \) -printf '%p:%s:%T@\0' 2>/dev/null | sort -z
    } | md5sum | cut -d ' ' -f 1
  )
  rows_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$rows_file'" RETURN
  [[ -L "$rows_cache" ]] && rm -f "$rows_cache"
  [[ -L "$rows_signature_state" ]] && rm -f "$rows_signature_state"
  if [[ -s $rows_cache && -s $rows_signature_state && $(<"$rows_signature_state") == "$media_signature" ]]; then
    cp "$rows_cache" "$rows_file"
  else
    [[ -L "$rows_lock" ]] && rm -f "$rows_lock"
    exec 8>"$rows_lock"
    if ! flock -n 8; then
      [[ -s $rows_cache ]] && cp "$rows_cache" "$rows_file" || flock 8
    fi
    if [[ ! -s $rows_file ]]; then
      if [[ -s $rows_cache && -s $rows_signature_state && $(<"$rows_signature_state") == "$media_signature" ]]; then
        cp "$rows_cache" "$rows_file"
      else
        local workers
        workers=$(nproc); (( workers > 6 )) && workers=6
        export cache_dir stock_thumbnail_dir MAX_VIDEO_BYTES MIN_VIDEO_BYTES_FLOOR MAX_VIDEO_BYTES_CEILING user_config
        export -f is_video is_image thumbnail_for_video picker_thumbnail_for_image prewarm_media ensure_secure_dir cfg effective_max_video_bytes
        find -L "$tdir" "$udir" -maxdepth 4 -type f \( "${media_args[@]}" \) -print0 2>/dev/null \
          | timeout 30 xargs -0 -r -n 1 -P "$workers" bash -c 'prewarm_media "$1"' _ 2>/dev/null \
          | head -n $MAX_ROWS | sort >"$rows_file" || true
        if [[ -s $rows_file ]]; then
          local rows_tmp sig_tmp rsz
          rows_tmp=$(mktemp -p "$state_dir" .rows.XXXXXX) || true
          sig_tmp=$(mktemp -p "$state_dir" .sig.XXXXXX) || true
          if [[ -n $rows_tmp && -n $sig_tmp ]]; then
            cp "$rows_file" "$rows_tmp" 2>/dev/null || true
            rsz=$(stat -Lc '%s' "$rows_tmp" 2>/dev/null || echo 0)
            if (( rsz <= MAX_ROW_BYTES )); then
              chmod 0600 "$rows_tmp" 2>/dev/null || true
              mv -f "$rows_tmp" "$rows_cache"
              printf '%s\n' "$media_signature" >"$sig_tmp"
              mv -f "$sig_tmp" "$rows_signature_state"
            else
              rm -f "$rows_tmp" "$sig_tmp"
            fi
          fi
        fi
      fi
    fi
  fi
  [[ -s $rows_file ]] || { omarchy-notification-send "No wallpaper was found for theme" -t 2000; return 0; }
  open_picker_rows "$rows_file" "local"
}

prepare_picker() {
  local media_args=()
  mapfile -t _dirs < <(theme_dirs)
  while IFS= read -r ext; do
    (( ${#media_args[@]} > 0 )) && media_args+=(-o)
    media_args+=(-iname "*.$ext")
  done <<'EOF_EXTS'
jpg
jpeg
png
gif
bmp
webp
mp4
mkv
webm
mov
m4v
EOF_EXTS
  local rows_file selected rows_b64
  rows_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$rows_file'" RETURN
  export cache_dir stock_thumbnail_dir MAX_VIDEO_BYTES MIN_VIDEO_BYTES_FLOOR MAX_VIDEO_BYTES_CEILING user_config
  export -f is_video is_image thumbnail_for_video picker_thumbnail_for_image prewarm_media ensure_secure_dir cfg effective_max_video_bytes
  find -L "${_dirs[0]}" "${_dirs[1]}" -maxdepth 4 -type f \( "${media_args[@]}" \) -print0 2>/dev/null \
    | timeout 30 xargs -0 -r -n 1 -P 4 bash -c 'prewarm_media "$1"' _ 2>/dev/null \
    | head -n $MAX_ROWS | sort >"$rows_file" || true
  [[ -s $rows_file ]] || return 0
  rows_b64=$(base64 -w 0 <"$rows_file")
  selected=""; [[ -s $current_state ]] && selected=$(<"$current_state")
  timeout 10 omarchy-shell image-selector preload "$rows_b64" "$selected" false false >/dev/null 2>&1 || true
}

# ---- menu ----
# omarchy-menu.jsonc is shared with every other plugin's menu entries, and
# it's JSONC (// line comments), which jq can't parse directly. Our own
# sed-based line edits assume each managed entry stays on a single line —
# true for what we write, but not guaranteed if the user hand-reformats the
# file. strip_jsonc_comments + validate_jsonc let us refuse to write back a
# result that isn't valid JSON once comments are stripped, so a shape we
# didn't anticipate fails safely (original file untouched) instead of
# corrupting a file every other plugin's menu entry also lives in.
strip_jsonc_comments() {
  # stdout: $1 with // line-comments removed, string-literal aware (does
  # not handle /* */ block comments — omarchy's own generator doesn't
  # emit them, so their presence just means validation conservatively
  # fails closed rather than silently mis-stripping inside a string).
  awk '
    {
      line = $0; out = ""; in_str = 0; esc = 0; n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (in_str) {
          out = out c
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { in_str = 0 }
          continue
        }
        if (c == "\"") { in_str = 1; out = out c; continue }
        if (c == "/" && substr(line, i + 1, 1) == "/") { break }
        out = out c
      }
      print out
    }
  ' "$1" 2>/dev/null
}

validate_jsonc() {
  local file="$1"
  [[ -f $file ]] || return 1
  # Omarchy's own JSONC template ships with trailing commas before a
  # closing brace/bracket (common when the last real member is followed
  # by a block of // comments), so the tolerance level to match is
  # "comments + trailing commas", not strict JSON — otherwise this
  # validation would reject the file omarchy itself ships.
  strip_jsonc_comments "$file" \
    | sed -E ':a;N;$!ba;s/,([[:space:]]*[]}])/\1/g' \
    | jq empty >/dev/null 2>&1
}

menu_upsert_row() {
  # menu_upsert_row <file> <key> <entry-json>
  local file="$1" key="$2" entry="$3" tmp esc_entry
  # escape for sed replacement: backslashes first, then &
  esc_entry=$(printf '%s' "$entry" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g')
  tmp=$(mktemp -p "$(dirname "$file")" .menu.XXXXXX) || return 1
  cp -f "$file" "$tmp"
  if grep -qE "^[[:space:]]*\"${key}\"[[:space:]]*:" "$file"; then
    sed -i -E "s|^([[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*).*$|\1$esc_entry,|" "$tmp"
  else
    sed -i "0,/^[[:space:]]*{/a\  \"${key}\": $entry," "$tmp"
  fi
  if ! validate_jsonc "$tmp"; then
    echo "wallpaper-engine: refusing to write $file — edit would break JSON (leaving it untouched)" >&2
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
}

ensure_menu_override() {
  local file="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  local action="$HOME/.config/omarchy/plugins/$plugin_id/wallpaper-engine.sh"
  local entry="{\"icon\":\"\",\"label\":\"Background\",\"aliases\":[\"background\",\"wallpaper\"],\"action\":\"$action\"}"
  local gallery="{\"icon\":\"\\uf03e\",\"label\":\"Wallpaper Engine\",\"aliases\":[\"wallpaper engine\",\"wallpapers\"],\"action\":\"omarchy-shell shell summon $plugin_id\"}"
  mkdir -p "$(dirname "$file")"
  chmod 0700 "$(dirname "$file")" 2>/dev/null || true
  [[ -L "$file" ]] && rm -f "$file"
  local tmp
  if [[ ! -f $file ]]; then
    tmp=$(mktemp -p "$(dirname "$file")" .menu.XXXXXX) || return 1
    printf '{\n  "style.background": %s,\n  "style.wallpaper-engine": %s\n}\n' "$entry" "$gallery" >"$tmp"
    if ! validate_jsonc "$tmp"; then
      echo "wallpaper-engine: refusing to write $file — generated JSON was invalid" >&2
      rm -f "$tmp"
      return 1
    fi
    mv -f "$tmp" "$file"
  else
    menu_upsert_row "$file" "style.background" "$entry" || return 1
    menu_upsert_row "$file" "style.wallpaper-engine" "$gallery" || return 1
  fi
  omarchy menu refresh >/dev/null 2>&1 || true
}

unwire_menu_override() {
  local file="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  [[ -f $file ]] || return 0
  [[ -L "$file" ]] && { rm -f "$file"; return 0; }
  local tmp
  tmp=$(mktemp -p "$(dirname "$file")" .menu.XXXXXX) || return 1
  cp -f "$file" "$tmp"
  sed -i -E '\|^[[:space:]]*"style\.background".*sebas\.wallpaper-engine/wallpaper-engine\.sh.*$|d' "$tmp"
  sed -i -E '\|^[[:space:]]*"style\.wallpaper-engine".*sebas\.wallpaper-engine.*$|d' "$tmp"
  if ! validate_jsonc "$tmp"; then
    echo "wallpaper-engine: refusing to write $file — edit would break JSON (leaving it untouched)" >&2
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
  omarchy menu refresh >/dev/null 2>&1 || true
}

prepare_cleanup_helper() {
  ensure_secure_dir "$state_dir" || return 1
  [[ -L "$state_dir" ]] && return 1
  [[ -L "$cleanup_helper" ]] && rm -f "$cleanup_helper" 2>/dev/null || true
  [[ -f "$plugin_dir/wallpaper-engine.sh" ]] || return 1
  local tmp
  tmp=$(mktemp -p "$state_dir" .cleanup.XXXXXX) || return 1
  chmod 0600 "$tmp" 2>/dev/null || true
  cp -f "$plugin_dir/wallpaper-engine.sh" "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0755 "$tmp"
  [[ -L "$cleanup_helper" || -L "$state_dir" ]] && { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$cleanup_helper"
  chmod 0755 "$cleanup_helper" 2>/dev/null || true
}

uninstall_plugin_state() {
  local fallback=""
  if [[ ! -L "$video_state" && ! -L "$fallback_state" ]] && [[ -s $video_state || -s $fallback_state ]]; then
    [[ -s $fallback_state ]] && fallback=$(<"$fallback_state")
    [[ -z $fallback || ! -f $fallback || $fallback == "$cache_dir/"* ]] && fallback=$(first_static_background)
  fi
  stop_video_ipc
  if [[ -n $fallback && -f $fallback && ! -L $fallback ]]; then
    omarchy theme bg set "$fallback" || true
  fi
  unwire_menu_override
  rm -rf "$state_dir" "$cache_dir"
}

cleanup_after_unload() {
  local enabled=""
  for _ in {1..200}; do
    if [[ ! -d $plugin_dir ]]; then
      uninstall_plugin_state
      return 0
    fi
    sleep 0.01
  done
  enabled=$(omarchy plugin list --json 2>/dev/null \
    | jq -r --arg id "$plugin_id" '.[] | select(.id == $id) | .enabled' 2>/dev/null || true)
  [[ $enabled == false ]] && unwire_menu_override
}

usage() {
  cat <<'EOF'
Wallpaper Engine — usage:
  wallpaper-engine.sh                  open local picker (images+videos)
  wallpaper-engine.sh next|prev|toggle|status
  wallpaper-engine.sh set <file>
  wallpaper-engine.sh interval <min> | enable | disable
  wallpaper-engine.sh search wallhaven|moewalls <query>
  wallpaper-engine.sh grid-local [limit] [playlist] | grid-search wallhaven|moewalls <query>
  wallpaper-engine.sh apply-key <key> | config-get | config-set <key> <value>
  wallpaper-engine.sh playlists | playlist-create <n> | playlist-delete <n>
  wallpaper-engine.sh playlist-add <n> <files...> | playlist-remove <n> <file>
  wallpaper-engine.sh playlist-activate <n|__all__> | playlist-interval <n> <min> | playlist-mode <n> <mode>
  wallpaper-engine.sh delete-file <path> | favorite-toggle <path>
  wallpaper-engine.sh schedules | schedule-add <HH:MM> <pick> | schedule-remove <HH:MM> [pick]
  wallpaper-engine.sh online-status | online-clear [--all]
  wallpaper-engine.sh --resume | --prepare-picker | --stop-if-changed | --advance-if-due
  wallpaper-engine.sh --wire-menu | --unwire-menu | --uninstall | --cleanup-after-unload
EOF
}

case "${1:-}" in
  --resume) prepare_cleanup_helper || true; resume_engine; exit $? ;;
  --stop-if-changed) stop_if_changed; exit 0 ;;
  --advance-if-due) advance_if_due; exit $? ;;
  --stop) stop_video_ipc; rm -f "$video_state" "$poster_state" "$expected_state"; exit 0 ;;
  --wire-menu) ensure_menu_override; exit 0 ;;
  --unwire-menu) unwire_menu_override; exit 0 ;;
  --cleanup-after-unload) cleanup_after_unload; exit 0 ;;
  --uninstall) uninstall_plugin_state; exit 0 ;;
  --prepare-picker) prepare_picker; exit 0 ;;
  next) do_next ;;
  prev) do_prev ;;
  set)
    [[ -n ${2:-} ]] || { echo "usage: set <file>" >&2; exit 1; }
    apply_file "$2" ;;
  toggle)
    cur=0; [[ -f $paused_state ]] && cur=$(<"$paused_state")
    if [[ $cur == 1 ]]; then printf '0' >"$paused_state"; omarchy-notification-send "Wallpaper rotation on" -t 1500
    else printf '1' >"$paused_state"; omarchy-notification-send "Wallpaper rotation paused" -t 1500; fi
    ;;
  status) do_status ;;
  interval)
    [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "usage: interval <minutes>" >&2; exit 1; }
    tmp=$(mktemp) && jq --argjson m "${2}" '.intervalMinutes = $m' "$user_config" >"$tmp" && mv -f "$tmp" "$user_config"
    date +%s >"$lastchange_state"
    ;;
  enable) tmp=$(mktemp) && jq '.enabled = true' "$user_config" >"$tmp" && mv -f "$tmp" "$user_config"; printf '0' >"$paused_state" 2>/dev/null || true ;;
  disable) tmp=$(mktemp) && jq '.enabled = false' "$user_config" >"$tmp" && mv -f "$tmp" "$user_config" ;;
  search)
    case "${2:-}" in
      wallhaven) shift 2; online_search_wallhaven "${*:-anime}" ;;
      moewalls|moe|moewalls.com) shift 2; online_search_moewalls "${*:-anime}" ;;
      *) echo "usage: search wallhaven|moewalls <query>" >&2; exit 1 ;;
    esac
    ;;
  online-status)
    cur=$(online_cache_bytes); max=$(cfg '.onlineCacheMaxBytes' '536870912')
    count=$(find "$cache_dir/online" -type f 2>/dev/null | wc -l)
    jq -n --argjson bytes "${cur:-0}" --argjson max "${max:-0}" --argjson files "$count" \
      '{cacheBytes:$bytes, maxBytes:$max, files:$files}' ;;
  online-clear) online_clear "${2:-}" ;;
  grid-local) grid_local_json "${2:-120}" "${3:-}" ;;
  playlists) playlists_json ;;
  playlist-create) playlist_create "${2:-}" ;;
  playlist-delete) playlist_delete "${2:-}" ;;
  playlist-add) playlist_add "${2:-}" "${@:3}" ;;
  playlist-remove) playlist_remove "${2:-}" "${3:-}" ;;
  playlist-activate) playlist_activate "${2:-__all__}" ;;
  playlist-interval) playlist_set_interval "${2:-}" "${3:-}" ;;
  playlist-mode) playlist_set_mode "${2:-}" "${3:-}" ;;
  delete-file) delete_wallpaper_file "${2:-}" ;;
  favorite-toggle) favorite_toggle "${2:-}" ;;
  schedules) schedules_json ;;
  schedule-add) schedule_add "${2:-}" "${3:-}" ;;
  schedule-remove) schedule_remove "${2:-}" "${3:-}" ;;
  grid-search)
    case "${2:-}" in
      wallhaven) shift 2; grid_search_json wallhaven "$@" ;;
      moewalls|moe|moewalls.com) shift 2; grid_search_json moewalls "$@" ;;
      *) echo "usage: grid-search wallhaven|moewalls [--page=N] <query>" >&2; exit 1 ;;
    esac
    ;;
  apply-key)
    [[ -n ${2:-} ]] || { echo "usage: apply-key <key>" >&2; exit 1; }
    online_apply_stub "$2" && cat "$current_state" ;;
  config-get) config_get_json ;;
  config-set)
    [[ -n ${2:-} && -n ${3:-} ]] || { echo "usage: config-set interval|mode|enabled <value>" >&2; exit 1; }
    config_set_key "$2" "$3" ;;
  -h|--help|help) usage ;;
  "") local_picker ;;
  *) echo "unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
