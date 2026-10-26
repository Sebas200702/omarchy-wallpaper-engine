#!/bin/bash
# Local Steam Workshop library (Wallpaper Engine, appid 431960) and the
# optional linux-wallpaperengine scene backend. Sourced by
# wallpaper-engine.sh, which provides cfg, theme_dirs, apply_file,
# atomic_write, picker_thumbnail_for_image, write_attribution_sidecar, …
#
# Unlike providers/steam.sh this never logs in or downloads: it only reads
# items the user already has on disk (subscribed in the Steam client or
# fetched earlier through steamcmd).

WORKSHOP_APPID="431960"
# Item ids: numeric Workshop ids, or folder names of the sample scenes the
# Wallpaper Engine app ships in projects/defaultprojects.
WK_ID_RE='^[A-Za-z0-9_]{1,64}$'

# workshop_roots — one item-container dir per line (deduped, canonical):
# Workshop content and the app's bundled sample scenes, for every Steam
# library listed in each known root's libraryfolders.vdf, plus config
# .workshopDirs[] for anything unusual.
workshop_roots() {
  local roots=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    "$HOME/snap/steam/common/.local/share/Steam"
  )
  local root vdf lib dir
  {
    for root in "${roots[@]}"; do
      [[ -d $root ]] || continue
      printf '%s\n' "$root/steamapps/workshop/content/$WORKSHOP_APPID" \
        "$root/steamapps/common/wallpaper_engine/projects/defaultprojects"
      vdf="$root/steamapps/libraryfolders.vdf"
      [[ -f $vdf && ! -L $vdf ]] || continue
      # "path"		"/mnt/games/SteamLibrary"
      while IFS= read -r lib; do
        printf '%s\n' "$lib/steamapps/workshop/content/$WORKSHOP_APPID" \
          "$lib/steamapps/common/wallpaper_engine/projects/defaultprojects"
      done < <(sed -n -E 's/^[[:space:]]*"path"[[:space:]]+"([^"]+)".*$/\1/p' "$vdf" | head -n 32)
    done
    jq -r '.workshopDirs[]? | strings' "$user_config" 2>/dev/null | head -n 32
  } | while IFS= read -r dir; do
    [[ $dir == /* && $dir != *$'\t'* ]] || continue
    dir=$(readlink -f "$dir" 2>/dev/null) || continue
    [[ -d $dir ]] && printf '%s\n' "$dir"
  done | awk '!seen[$0]++'
}

# workshop_item_dir <id> — content dir of one item, searched across roots.
workshop_item_dir() {
  local id="$1" root
  [[ $id =~ $WK_ID_RE ]] || return 1
  while IFS= read -r root; do
    [[ -d $root/$id && ! -L $root/$id && -f $root/$id/project.json ]] && { printf '%s' "$root/$id"; return 0; }
  done < <(workshop_roots)
  return 1
}

# workshop_is_item_dir <path> — true for a canonical item dir under a root
# (used to validate scene paths coming back from state files).
workshop_is_item_dir() {
  local p="$1" root
  [[ $p == /* && $p != *..* && $p != *$'\n'* ]] || return 1
  [[ -d $p && ! -L $p && -f $p/project.json ]] || return 1
  while IFS= read -r root; do
    [[ $p == "$root/"* && ${p#"$root/"} =~ $WK_ID_RE ]] && return 0
  done < <(workshop_roots)
  return 1
}

# lwe_bin — path of linux-wallpaperengine (config .lweBinary wins), or rc 1.
lwe_bin() {
  local b
  b=$(cfg '.lweBinary' '')
  if [[ -n $b ]]; then
    [[ $b == /* && -x $b && ! -d $b ]] && { printf '%s' "$b"; return 0; }
    return 1
  fi
  b=$(command -v linux-wallpaperengine 2>/dev/null) || return 1
  printf '%s' "$b"
}

# workshop_item_json <dir> — one panel item from an item dir's project.json.
# Paths are resolved inside the item dir only (basename of .file/.preview),
# so a crafted project.json cannot point the panel elsewhere.
workshop_item_json() {
  local dir="$1" id has_lwe=false cur=""
  id=$(basename "$dir")
  lwe_bin >/dev/null 2>&1 && has_lwe=true
  [[ -s $scene_state ]] && cur=$(<"$scene_state")
  [[ -s $current_state && -z $cur ]] && cur=$(<"$current_state")
  head -c 262144 "$dir/project.json" | jq -c --arg dir "$dir" --arg id "$id" \
    --argjson lwe "$has_lwe" --arg cur "$cur" '
    def base: tostring | split("/") | last;
    ((.type // "") | ascii_downcase) as $type
    | ((.file // "") | base) as $file
    | ((.preview // "") | base) as $preview
    | {
        key: ("workshop:" + $id),
        workshopId: $id,
        title: ((.title // $id) | tostring | .[0:200]),
        kind: (if $type == "video" then "video" elif $type == "scene" then "scene"
               elif $type == "web" then "web" else "other" end),
        dir: $dir,
        file: (if $file != "" then ($dir + "/" + $file) else null end),
        thumb: (if $preview != "" then ($dir + "/" + $preview) else null end),
        source: "workshop",
        bundled: ($id | test("^[0-9]+$") | not),
        attribution: {provider: (if ($id | test("^[0-9]+$")) then "workshop" else "wallpaper-engine" end),
                      title: ((.title // $id) | tostring),
                      sourceUrl: (if ($id | test("^[0-9]+$"))
                                  then ("https://steamcommunity.com/sharedfiles/filedetails/?id=" + $id) else null end)}
      }
    | .playable = (if .kind == "video" then (.file != null)
                   elif .kind == "scene" or .kind == "web" then $lwe else false end)
    | .reason = (if .playable then null
                 elif .kind == "scene" or .kind == "web" then "needs-lwe"
                 else "unsupported" end)
    | .current = ($cur == $dir or ($cur | endswith("/wk-" + $id + "." + (($file | split(".") | last) // ""))))
  ' 2>/dev/null
}

# workshop_list_json — every local Workshop item as a JSON array.
workshop_list_json() {
  local root d
  {
    while IFS= read -r root; do
      for d in "$root"/*/; do
        d=${d%/}
        [[ -d $d && ! -L $d && -f $d/project.json ]] || continue
        [[ $(basename "$d") =~ $WK_ID_RE ]] || continue
        workshop_item_json "$d"
      done
    done < <(workshop_roots)
  } | jq -s '
    # Bundled samples without a usable type (audio-only demos) are noise.
    map(select(.bundled == false or .kind != "other"))
    | unique_by(.workshopId) | sort_by((if .bundled then 1 else 0 end), (.title | ascii_downcase))'
}

# workshop_import_video <dir> <file> <id> <title> — hard-links (or copies)
# the item's video into the theme's backgrounds/workshop/ folder so it
# rotates, gets favorited and validated like any other wallpaper.
workshop_import_video() {
  local dir="$1" src="$2" id="$3" title="$4" udir wdir ext dest
  [[ -f $src && ! -L $src && $src == "$dir/"* ]] || return 1
  ext="${src##*.}"; ext="${ext,,}"
  [[ $ext =~ ^(mp4|mkv|webm|mov|m4v)$ ]] || return 1
  mapfile -t _dirs < <(theme_dirs)
  udir="${_dirs[1]}"; wdir="$udir/workshop"
  ensure_secure_dir "$wdir" || return 1
  dest="$wdir/wk-$id.$ext"
  if [[ ! -f $dest ]]; then
    ln "$src" "$dest" 2>/dev/null || cp --reflink=auto "$src" "$dest" || return 1
  fi
  write_attribution_sidecar "$dest" "workshop" \
    "https://steamcommunity.com/sharedfiles/filedetails/?id=$id" "$title" || true
  printf '%s' "$dest"
}

# workshop_apply <id> — videos are imported then applied as files; scenes
# and web wallpapers go to linux-wallpaperengine through the service.
workshop_apply() {
  local id="$1" dir item kind title file dest poster
  dir=$(workshop_item_dir "$id") || { omarchy-notification-send "Workshop item not found" -t 2000; return 1; }
  item=$(workshop_item_json "$dir") || return 1
  kind=$(jq -r '.kind' <<<"$item"); title=$(jq -r '.title' <<<"$item")
  case $kind in
    video)
      file=$(jq -r '.file // empty' <<<"$item")
      dest=$(workshop_import_video "$dir" "$file" "$id" "$title") || {
        omarchy-notification-send "Could not import Workshop video" -t 2500; return 1; }
      apply_file "$dest"
      ;;
    scene|web)
      lwe_bin >/dev/null 2>&1 || {
        omarchy-notification-send "Scenes need linux-wallpaperengine (see WallHub doctor)" -t 3500; return 1; }
      poster=$(jq -r '.thumb // empty' <<<"$item")
      [[ -n $poster ]] && poster=$(picker_thumbnail_for_image "$poster" 2>/dev/null) || poster=""
      apply_scene "$dir" "$poster"
      ;;
    *)
      omarchy-notification-send "Unsupported Workshop type (application)" -t 2500; return 1 ;;
  esac
}

# apply_scene <dir> [poster] — records the scene and hands it to the
# service; the poster becomes the static background underneath.
apply_scene() {
  local dir="$1" poster="${2:-}" prev
  workshop_is_item_dir "$dir" || return 1
  [[ -L "$state_dir" ]] && return 1
  exec 9>"$transition_lock"
  flock -n 9 2>/dev/null || flock 9
  [[ -s $current_state ]] && prev=$(<"$current_state") || prev=""
  [[ -n $prev && -f $prev ]] && push_history "$prev"
  stop_video_ipc
  rm -f "$video_state" "$poster_state"
  atomic_write "$scene_state" "$dir"
  atomic_write "$current_state" "$dir"
  date +%s >"$lastchange_state"
  if [[ -n $poster && -f $poster ]]; then
    atomic_write "$expected_state" "$poster"
    timeout 15 omarchy theme bg set "$poster" || true
  else
    rm -f "$expected_state"
  fi
  play_scene_ipc "$dir" || { clear_scene_state; omarchy-notification-send "Could not start the scene" -t 2500; return 1; }
}

play_scene_ipc() {
  local dir="$1" i
  for i in {1..10}; do
    omarchy-shell -q "$plugin_id" playScene "$dir" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  return 1
}

# ---- scene properties (linux-wallpaperengine --list-properties) ----

# parse_lwe_properties — stdin: --list-properties text; stdout: JSON array
# of {name, type, label, value, min, max, step, options[{label,value}], color}.
parse_lwe_properties() {
  awk '
    function flush() {
      if (name == "") return
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", name, type, label, value, min, max, step, opts, color
      name = ""; type = ""; label = ""; value = ""; min = ""; max = ""; step = ""; opts = ""; color = ""
    }
    /^[A-Za-z0-9_]+ - [a-z]+[[:space:]]*$/ {
      flush(); split($0, p, " - "); name = p[1]; type = p[2]; sub(/[[:space:]]+$/, "", type); inopts = 0; next
    }
    name == "" { next }
    /^[[:space:]]+Description:/ { sub(/^[[:space:]]+Description:[[:space:]]*/, ""); label = $0; next }
    /^[[:space:]]+Value:/ { sub(/^[[:space:]]+Value:[[:space:]]*/, ""); value = $0; next }
    /^[[:space:]]+Minimum value:/ { sub(/^[[:space:]]+Minimum value:[[:space:]]*/, ""); min = $0; next }
    /^[[:space:]]+Maximum value:/ { sub(/^[[:space:]]+Maximum value:[[:space:]]*/, ""); max = $0; next }
    /^[[:space:]]+Step:/ { sub(/^[[:space:]]+Step:[[:space:]]*/, ""); step = $0; next }
    /^[[:space:]]+Pos+ible values:/ { inopts = 1; next }
    /^[[:space:]]+R: / { c = $0; sub(/^[[:space:]]+/, "", c); color = c; next }
    inopts && /->/ { o = $0; sub(/^[[:space:]]+/, "", o); opts = opts (opts == "" ? "" : "|") o; next }
    END { flush() }
  ' | jq -R -s '
    [split("\n")[] | select(length > 0) | split("\t") | {
      name: .[0], type: .[1],
      label: (.[2] | gsub("<[^>]*>"; "") | if . == "" then null else . end),
      value: (.[3] | if . == "" then null else . end),
      min: (.[4] | tonumber? // null), max: (.[5] | tonumber? // null), step: (.[6] | tonumber? // null),
      options: (.[7] | if . == "" then [] else (split("|") | map(split(" -> ") | {label: .[0], value: .[1]})) end),
      color: (.[8] | if . == "" then null else . end)
    }]'
}

# workshop_properties <id> — scene properties merged with saved overrides.
workshop_properties() {
  local id="$1" dir bin out saved
  dir=$(workshop_item_dir "$id") || return 1
  bin=$(lwe_bin) || return 1
  out=$(timeout 20 "$bin" --list-properties "$dir" 2>/dev/null) || true
  saved=$(jq -c --arg id "$id" '.sceneProperties[$id] // {}' "$user_config" 2>/dev/null) || saved='{}'
  printf '%s\n' "$out" | parse_lwe_properties \
    | jq -c --argjson saved "$saved" 'map(. + {override: ($saved[.name] // null)})'
}

# scene_prop_set <id> <name> <value> / scene_prop_reset <id> — overrides
# passed as --set-property; values limited to plain numbers/words/colors.
scene_prop_set() {
  local id="$1" name="$2" value="$3"
  [[ $id =~ $WK_ID_RE && $name =~ ^[A-Za-z0-9_]{1,64}$ ]] || return 1
  [[ $value =~ ^[A-Za-z0-9_.,\ -]{1,64}$ ]] || return 1
  save_config_filtered '.sceneProperties[$id][$n] = $v' --arg id "$id" --arg n "$name" --arg v "$value"
}

scene_prop_reset() {
  local id="$1"
  [[ $id =~ $WK_ID_RE ]] || return 1
  save_config_filtered 'del(.sceneProperties[$id])' --arg id "$id"
}

# ---- doctor ----

# doctor_json — environment checks as [{id, label, status, detail}]
# (status: ok | warn | fail | info).
doctor_json() {
  local rows=() bin assets n roots items scenes svc tool
  add() { rows+=("$(jq -cn --arg id "$1" --arg label "$2" --arg status "$3" --arg detail "$4" \
    '{id:$id, label:$label, status:$status, detail:$detail}')"); }
  for tool in jq curl ffmpeg vipsthumbnail; do
    if command -v "$tool" >/dev/null 2>&1; then add "dep-$tool" "$tool" ok "$(command -v "$tool")"
    else add "dep-$tool" "$tool" fail "missing — install it with pacman"; fi
  done
  if jq empty "$user_config" >/dev/null 2>&1; then add config "Config" ok "$user_config"
  elif [[ -e $user_config ]]; then add config "Config" fail "invalid JSON: $user_config"
  else add config "Config" info "not created yet (defaults in use)"; fi
  svc=$(timeout 5 omarchy-shell "$plugin_id" status 2>/dev/null) || svc=""
  if [[ $svc == \{* ]]; then add service "Service" ok "player running ($(jq -r '.screens | length' <<<"$svc" 2>/dev/null) screens)"
  else add service "Service" fail "not responding — run: omarchy plugin enable $plugin_id"; fi
  n=$(build_playlist 2>/dev/null | wc -l)
  if (( n > 0 )); then add library "Library" ok "$n wallpapers"
  else add library "Library" warn "no wallpapers in ~/.config/omarchy/backgrounds/<theme>/"; fi
  roots=$(workshop_roots | wc -l)
  items=0; scenes=0
  if (( roots > 0 )); then
    items=$(workshop_list_json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    scenes=$(workshop_list_json 2>/dev/null | jq '[.[] | select(.kind == "scene" or .kind == "web")] | length' 2>/dev/null || echo 0)
    add workshop "Steam Workshop" ok "$items local items ($scenes scenes/web) in $roots folder(s)"
  else
    add workshop "Steam Workshop" info "no local Workshop folder found"
  fi
  if bin=$(lwe_bin 2>/dev/null); then
    add lwe "linux-wallpaperengine" ok "$bin"
    assets=$(cfg '.lweAssetsDir' '')
    if [[ -n $assets && -d $assets ]] || compgen -G "$HOME/.local/share/Steam/steamapps/common/wallpaper_engine/assets" >/dev/null \
       || compgen -G "$HOME/.steam/steam/steamapps/common/wallpaper_engine/assets" >/dev/null; then
      add lwe-assets "Wallpaper Engine assets" ok "found"
    else
      add lwe-assets "Wallpaper Engine assets" warn "not found — install Wallpaper Engine in Steam or set lweAssetsDir"
    fi
  elif (( scenes > 0 )); then
    add lwe "linux-wallpaperengine" warn "$scenes scenes need it — AUR: linux-wallpaperengine-git"
  else
    add lwe "linux-wallpaperengine" info "optional — only needed for scenes and web wallpapers"
  fi
  if bin=$(steam_cmd 2>/dev/null); then add steamcmd "steamcmd" ok "$bin (user: $(cfg '.steamUser' '—'))"
  else add steamcmd "steamcmd" info "optional — only needed to download from the Workshop"; fi
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || pgrep -x Hyprland >/dev/null 2>&1; then add hyprland "Hyprland" ok "running (fullscreen pause available)"
  else add hyprland "Hyprland" info "not detected — fullscreen pause disabled"; fi
  printf '%s\n' "${rows[@]}" | jq -s '.'
}

doctor_text() {
  doctor_json | jq -r '.[] | "\(if .status == "ok" then "✓" elif .status == "fail" then "✗" elif .status == "warn" then "!" else "·" end) \(.label): \(.detail)"'
}
