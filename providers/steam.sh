#!/bin/bash
# Steam Workshop provider (Wallpaper Engine, appid 431960).
# Search/detail scrape the public workshop HTML (no auth, no key); FILES
# come from Valve's own CDN via steamcmd (official tool). Fragile by nature
# — isolated here so breakage never affects local rotation.
# Verified 2026-09-26 (anonymous downloads are REFUSED by Valve for this
# app — 3/3 items failed — so a one-time terminal login owning Wallpaper
# Engine is required; see steam_login).
#
# Scope: VIDEO wallpapers only (plain mp4/webm on disk). The Workshop is
# mostly .pkg scenes needing the proprietary runtime — those are detected
# (no playable video inside) and skipped with a clear message, never
# downloaded blindly into the library.
# Requires: curl, jq (for @uri), steamcmd (Valve; AUR `steamcmd`, needs
# multilib lib32), file, ffprobe (optional but recommended)
# shellcheck disable=SC2155

STEAM_APPID="431960"
STEAM_BASE="https://steamcommunity.com"
STEAM_UA="Mozilla/5.0 (X11; Linux x86_64) omarchy-wallpaper-engine/0.1"
# Workshop browse serves fixed 30-item pages (?p=N, zero overlap).
STEAM_PAGE_SIZE=30

# steam_cmd — resolved steamcmd binary (config override or PATH).
steam_cmd() {
  local cfg
  cfg=$(cfg '.steamCmd' '')
  if [[ -n $cfg && -x $cfg && ! -L $cfg ]]; then printf '%s' "$cfg"; return 0; fi
  command -v steamcmd || return 1
}

# steam_user — configured Steam username (empty = not set up yet).
steam_user() {
  cfg '.steamUser' ''
}

# steam_parse_search <htmlfile> — pure HTML -> TSV: item_id \t title \t page_url \t thumb.
# workshopItems render as <a href="...filedetails/?id=N"...><img src thumb alt="Title">.
# No network: unit-testable.
steam_parse_search() {
  local html="$1"
  [[ -f $html && ! -L $html ]] || return 1
  grep -o '<a href="https://steamcommunity\.com/sharedfiles/filedetails/?id=[0-9][0-9]*"[^>]*>\|<img src="[^"]*" alt="[^"]*"' "$html" 2>/dev/null \
  | awk '
    /<a / {
      if (match($0, /id=[0-9]+/)) id = substr($0, RSTART + 3, RLENGTH - 3)
      else id = ""
      if (match($0, /href="[^"]*"/)) href = substr($0, RSTART + 6, RLENGTH - 7)
      else href = ""
      next
    }
    /<img / {
      thumb = ""; title = ""
      if (match($0, /src="[^"]*"/)) thumb = substr($0, RSTART + 5, RLENGTH - 6)
      if (match($0, /alt="[^"]*"/)) title = substr($0, RSTART + 5, RLENGTH - 6)
      if (id != "" && href != "" && title != "" && thumb != "") {
        gsub(/\t/, " ", title)
        print id "\t" title "\t" href "\t" thumb
      }
      id = ""; href = ""
    }' | sed -e 's/&amp;/\&/g; s/&#0*39;/'"'"'/g; s/&quot;/"/g; s/&#8217;/'"'"'/g; s/&#8211;/-/g'
}

# steam_search <query> [site_page] — one 30-row site page as
# TSV: item_id \t title \t page_url \t thumb. Video type pre-filtered
# server-side (requiredtags[]=Video). rc 1 + no stdout on failure; empty
# page prints nothing with rc 0 (clean pagination end).
steam_search() {
  local query="$1" page="${2:-1}" url tmp rc=0
  [[ -n $query ]] || return 1
  [[ $page =~ ^[0-9]+$ && $page -ge 1 ]] || page=1
  query=$(printf '%s' "$query" | jq -sRr @uri) || return 1
  url="${STEAM_BASE}/workshop/browse/?appid=${STEAM_APPID}&searchtext=${query}&browsesort=textsearch&section=readytouseitems&requiredtags%5B%5D=Video&p=${page}"
  tmp=$(mktemp) || return 1
  if ! run_curl_killable -sSL --compressed --proto '=https' --max-redirs 3 -m 25 \
      -A "$STEAM_UA" -H "Referer: ${STEAM_BASE}/" -o "$tmp" "$url" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  [[ -s $tmp ]] || { rm -f "$tmp"; return 1; }
  steam_parse_search "$tmp"
  rc=$?
  rm -f "$tmp"
  return $rc
}

# steam_parse_detail <htmlfile> — pure HTML -> TSV: title \t image \t size_text \t type
# (size like "126.426 MB", type like "Video"). No network: unit-testable.
steam_parse_detail() {
  local html="$1" title image size type
  [[ -f $html && ! -L $html ]] || return 1
  title=$(grep -o -m1 '<title>[^<]*' "$html" 2>/dev/null | sed 's/^<title>//;s/^Steam Workshop:://;s/^ *//;s/ *$//')
  image=$(grep -o -m1 '<meta[^>]*property="og:image"[^>]*>' "$html" 2>/dev/null \
    | grep -o 'content="[^"]*"' | head -n1 | sed 's/^content="//;s/"$//;s/&amp;/\&/g')
  size=$(grep -o -m1 'detailsStatRight">[0-9][0-9.,]*\s*\(MB\|GB\|KB\)' "$html" 2>/dev/null \
    | sed 's/^detailsStatRight">//')
  type=$(grep -o -m1 'Type:&nbsp;</span><a[^>]*>[^<]*' "$html" 2>/dev/null | sed 's/.*>//')
  [[ -n $title ]] || return 1
  title=${title//$'\t'/ }
  printf '%s\t%s\t%s\t%s\n' "$title" "${image:-}" "${size:-}" "${type:-}"
}

# steam_detail <item_id> — fetch + parse one filedetails page.
steam_detail() {
  local id="$1" tmp rc
  [[ $id =~ ^[0-9]{5,20}$ ]] || return 1
  tmp=$(mktemp) || return 1
  if ! run_curl_killable -sSL --compressed --proto '=https' --max-redirs 3 -m 25 \
      -A "$STEAM_UA" -H "Referer: ${STEAM_BASE}/" \
      -o "$tmp" "${STEAM_BASE}/sharedfiles/filedetails/?id=${id}" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  [[ -s $tmp ]] || { rm -f "$tmp"; return 1; }
  steam_parse_detail "$tmp"
  rc=$?
  rm -f "$tmp"
  return $rc
}

# steam_size_bytes <"126.426 MB"> — human size to integer bytes (rc 1 junk).
steam_size_bytes() {
  local txt="${1:-}" num unit
  txt=$(printf '%s' "$txt" | tr -d ' ,' | tr '[:lower:]' '[:upper:]')
  [[ $txt =~ ^([0-9]+(\.[0-9]+)?)(KB|MB|GB)$ ]] || return 1
  num=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[3]}
  case "$unit" in
    KB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}' ;;
    MB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1048576}' ;;
    GB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1073741824}' ;;
  esac
}

# steam_find_item_dir <item_id> — locate steamcmd's download dir for an item
# across the usual roots (steamcmd installs relative to its own root, which
# varies: AUR package vs Valve tarball vs custom path).
steam_find_item_dir() {
  local id="$1" scmd root cand
  [[ $id =~ ^[0-9]{5,20}$ ]] || return 1
  scmd=$(steam_cmd 2>/dev/null) || scmd=""
  local roots=("$HOME/Steam" "$HOME/.steam" "$HOME/.local/share/Steam")
  if [[ -n $scmd ]]; then
    roots+=("$(dirname "$(dirname "$scmd")")" "$(dirname "$scmd")" "$PWD")
  fi
  for root in "${roots[@]}"; do
    [[ -n $root ]] || continue
    cand="$root/steamapps/workshop/content/${STEAM_APPID}/${id}"
    [[ -d $cand ]] && { printf '%s' "$cand"; return 0; }
    cand="$root/Steam/steamapps/workshop/content/${STEAM_APPID}/${id}"
    [[ -d $cand ]] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

# steam_check_login — fast non-interactive gate: cached credentials let
# `+login USER +quit` finish in seconds; a password/Steam-Guard prompt
# hangs instead, so stdin is closed and a short timeout turns that into a
# clean rc 1 ("run steam-login in a terminal first").
steam_check_login() {
  local user scmd out
  user=$(steam_user); scmd=$(steam_cmd 2>/dev/null) || return 1
  [[ -n $user ]] || return 1
  out=$(mktemp) || return 1
  if ! timeout 25 "$scmd" +login "$user" +quit </dev/null >"$out" 2>&1; then
    rm -f "$out"; return 1
  fi
  rm -f "$out"
  return 0
}

# steam_login <username> — first-time login; steamcmd caches credentials
# for later downloads. Saves steamUser to the config ONLY on success.
#   interactive (tty): streams steamcmd's prompts (password, Guard code).
#   non-interactive: creds from env WE_STEAM_PASS / WE_STEAM_CODE — the
#   panel's sign-in form (env is owner-only under /proc, never argv) — or
#   from two stdin lines (password, optional code) when piped.
steam_login() {
  local user="${1:-}" scmd pass="${WE_STEAM_PASS:-}" code="${WE_STEAM_CODE:-}" out="" rc=0 err=""
  [[ $user =~ ^[A-Za-z0-9_.-]{2,64}$ ]] || { echo "usage: steam-login <username>" >&2; return 1; }
  scmd=$(steam_cmd 2>/dev/null) || { echo "steamcmd not found — install it first (AUR 'steamcmd' + multilib lib32)" >&2; return 1; }
  if [[ -n $pass ]]; then
    out=$({ printf '%s\n' "$pass"; [[ -n $code ]] && printf '%s\n' "$code"; } | timeout 300 "$scmd" +login "$user" +quit 2>&1)
    rc=$?
  elif [[ -t 0 ]]; then
    timeout 300 "$scmd" +login "$user" +quit; rc=$?
  else
    IFS= read -r pass || { echo "steam-login: no password on stdin" >&2; return 1; }
    IFS= read -r code || code=""
    out=$(printf '%s\n%s\n' "$pass" "$code" | timeout 300 "$scmd" +login "$user" +quit 2>&1)
    rc=$?
  fi
  if (( rc != 0 )) || grep -qE 'ERROR \(|FAILED|Invalid [Pp]assword' <<<"$out"; then
    err=$(grep -E 'ERROR \(|FAILED|Invalid [Pp]assword' <<<"$out" | tail -n1)
    if [[ -n $err ]]; then
      if grep -qiE 'password' <<<"$err"; then
        err="wrong Steam password — retry"
      elif grep -qiE 'two.?factor|guard|logon denied|authenticator|email' <<<"$err"; then
        if [[ -z $code ]]; then
          err="Steam Guard code required — check your email/app, then retry with the code (or run steam-login in a terminal)"
        else
          err="Steam Guard code rejected — use the latest code from your app/email and retry"
        fi
      fi
      echo "$err" >&2
    elif (( rc != 0 )); then
      echo "steam login failed (steamcmd rc $rc)" >&2
    else
      echo "steam login failed" >&2
    fi
    return 1
  fi
  save_config_filtered '.steamUser = $u' --arg u "$user" || return 1
  jq -n --arg u "$user" '{steamUser: $u}'
}

# steam_status — {hasSteamCmd, steamCmd, steamUser, configured}.
steam_status() {
  local scmd="" user=""
  scmd=$(steam_cmd 2>/dev/null) || scmd=""
  user=$(steam_user)
  jq -n --arg cmd "$scmd" --arg user "$user" \
    '{hasSteamCmd: ($cmd != ""), steamCmd: $cmd, steamUser: $user, configured: ($cmd != "" and $user != "")}'
}

# steam_download <item_id> <dest> <max_bytes> [size_bytes] — full item via
# steamcmd, then promote the largest playable video. Scenes without video
# fail with a clear message (nothing unplayable lands in the library).
steam_download() {
  local id="$1" dest="$2" max_bytes="${3:-524288000}" total="${4:-}"
  local scmd user log itemdir video size ctype
  [[ $id =~ ^[0-9]{5,20}$ ]] || return 1
  scmd=$(steam_cmd 2>/dev/null) || { echo "steamcmd not found" >&2; return 1; }
  user=$(steam_user); [[ -n $user ]] || { echo "Steam login required — use the sign-in form in the panel (or: wallpaper-engine.sh steam-login <user>)" >&2; return 1; }
  log=$(mktemp) || return 1
  # Backgrounded so the progress poller below can watch the item dir grow;
  # stdin closed so an unexpected password prompt fails fast instead of
  # hanging the panel until timeout.
  timeout 900 "$scmd" +login "$user" +workshop_download_item "$STEAM_APPID" "$id" validate +quit </dev/null >"$log" 2>&1 &
  local dlpid=$!
  # shellcheck disable=SC2064
  trap "kill -TERM $dlpid 2>/dev/null; rm -f '$log'" RETURN
  local done_b=0
  write_download_progress 0 "$total" "steam"
  while kill -0 "$dlpid" 2>/dev/null; do
    sleep 1
    itemdir=$(steam_find_item_dir "$id" 2>/dev/null) || itemdir=""
    if [[ -n $itemdir ]]; then
      done_b=$(du -sb "$itemdir" 2>/dev/null | cut -f1)
      [[ $done_b =~ ^[0-9]+$ ]] || done_b=0
    fi
    write_download_progress "$done_b" "$total" "steam"
    # Real failures only ("ERROR! ..." is steamcmd's own failure prefix;
    # note: NOT bare "failed" — the harmless setlocale warning contains it).
    if grep -qa "ERROR!\|Login Failure\|Access Denied\|Invalid password\|Steam Guard" "$log" 2>/dev/null; then
      break
    fi
  done
  wait "$dlpid"
  local rc=$?
  trap "rm -f '$log'" RETURN
  if ! grep -qa "Success" "$log" 2>/dev/null; then
    if grep -qa "Access Denied\|Invalid password\|Login Failure\|Steam Guard" "$log" 2>/dev/null; then
      echo "Steam download refused — sign in again from the panel (or: wallpaper-engine.sh steam-login <user>)" >&2
    fi
    return 1
  fi
  (( rc == 0 )) || return 1
  itemdir=$(steam_find_item_dir "$id") || return 1
  # Largest playable video wins (previews/trailers lose to the main file).
  video=$(find -L "$itemdir" -type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.m4v' \) -printf '%s %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
  if [[ -z $video || ! -f $video ]]; then
    echo "item $id has no playable video (scene-only wallpaper)" >&2
    return 1
  fi
  size=$(stat -Lc '%s' "$video" 2>/dev/null || echo 0)
  if [[ ! $size =~ ^[0-9]+$ ]] || (( size == 0 || size > max_bytes )); then
    echo "video size out of bounds" >&2; return 1
  fi
  ctype=$(file -b --mime-type "$video" 2>/dev/null)
  case "$ctype" in video/*|application/octet-stream) ;; *) echo "not a video file" >&2; return 1 ;; esac
  cp -f "$video" "$dest" || return 1
}
