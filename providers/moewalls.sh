#!/bin/bash
# MoeWalls provider (unofficial: WP REST search + detail HTML parse + direct download).
# No API key needed. Fragile by nature — isolated here so breakage never
# affects local rotation. Verified 2026-09-16.
#
# Search API:  GET https://moewalls.com/wp-json/wp/v2/search?search=<q>&per_page=20
#   -> [{id, title, url}]
# Detail HTML contains:
#   og:image ......... thumb jpg
#   <source src="...-preview.webm"> .. low-res preview (~2MB, hotlink OK)
#   <a id="moe-download" data-url="<token>"> .. full mp4 token
# Full file: GET https://go.moewalls.com/download.php?video=<token>
#   (reversed from custom-wall.js: "https://go.moewalls.com" + "/download.php?video=")
# Requires: curl, jq
# shellcheck disable=SC2155

MOEWALLS_BASE="https://moewalls.com"
MOEWALLS_DL_BASE="https://go.moewalls.com/download.php?video="

# moewalls_search <query> [per_page] [page] -> TSV: post_id \t title \t page_url
moewalls_search() {
  local query="$1" per_page="${2:-20}" page="${3:-1}" resp
  [[ -n $query ]] || return 1
  [[ $page =~ ^[0-9]+$ && $page -ge 1 ]] || page=1
  resp=$(curl -sS --proto '=https' --max-redirs 3 -m 20 -A "Mozilla/5.0 (X11; Linux x86_64) omarchy-wallpaper-engine/0.1" \
    "${MOEWALLS_BASE}/wp-json/wp/v2/search?search=$(printf '%s' "$query" | jq -sRr @uri)&per_page=${per_page}&page=${page}&type=post&subtype=post") || return 1
  printf '%s' "$resp" | jq -r '.[]? | [.id, (.title // ""), (.url // "")] | @tsv' || return 1
}

# moewalls_detail <page_url> -> TSV single line: thumb_url \t preview_url \t dl_token \t title
moewalls_detail() {
  local page_url="$1" html thumb preview token title
  case "$page_url" in
    https://moewalls.com/*) ;;
    *) return 1 ;;
  esac
  html=$(curl -sSL --proto '=https' --max-redirs 3 -m 25 -A "Mozilla/5.0 (X11; Linux x86_64) omarchy-wallpaper-engine/0.1" "$page_url") || return 1
  [[ -n $html ]] || return 1
  thumb=$(printf '%s' "$html" | grep -o '<meta property="og:image" content="[^"]*"' | head -n1 | sed 's/.*content="//;s/"$//')
  preview=$(printf '%s' "$html" | grep -o '<source src="[^"]*preview[^"]*\.webm"' | head -n1 | sed 's/.*src="//;s/"$//')
  token=$(printf '%s' "$html" | grep -o '<a id="moe-download"[^>]*data-url="[^"]*"' | head -n1 | sed 's/.*data-url="//;s/"$//')
  title=$(printf '%s' "$html" | grep -o '<meta property="og:title" content="[^"]*"' | head -n1 | sed 's/.*content="//;s/"$//')
  # relativize preview
  if [[ $preview == /* ]]; then preview="${MOEWALLS_BASE}${preview}"; fi
  # the token comes straight out of third-party HTML (data-url="...") and
  # gets interpolated into a download URL below — constrain it to a plain
  # opaque-identifier charset before it ever leaves this function, so a
  # malformed/hostile page can't inject query params, path segments, or
  # other URL structure into moewalls_download_url.
  [[ -n $token && $token =~ ^[A-Za-z0-9_.=-]{1,256}$ ]] || return 1
  printf '%s\t%s\t%s\t%s\n' "${thumb:-}" "${preview:-}" "$token" "${title:-}"
}

moewalls_download_url() {
  local token="$1" encoded
  encoded=$(printf '%s' "$token" | jq -sRr @uri) || return 1
  printf '%s%s' "$MOEWALLS_DL_BASE" "$encoded"
}

# moewalls_download <token> <dest> <max_bytes> — full mp4 via go.moewalls.com
moewalls_download() {
  local token="$1" dest="$2" max_bytes="${3:-524288000}"
  local tmp ctype size
  # re-validate at the trust boundary: this function is also reachable
  # directly, and the token may have crossed a state file since detail
  # parsing.
  [[ -n $token && $token =~ ^[A-Za-z0-9_.=-]{1,256}$ ]] || return 1
  tmp=$(mktemp -p "$(dirname "$dest")" .moe.XXXXXX) || return 1
  if ! run_curl_killable -sSL --proto '=https' --max-redirs 3 -m 120 -A "Mozilla/5.0 (X11; Linux x86_64)" \
      -o "$tmp" "$(moewalls_download_url "$token")"; then
    rm -f "$tmp"; return 1
  fi
  ctype=$(file -b --mime-type "$tmp" 2>/dev/null)
  case "$ctype" in
    video/mp4|video/webm|video/x-matroska|application/octet-stream) ;;
    *) rm -f "$tmp"; return 1 ;;
  esac
  # application/octet-stream from moewalls is mp4 — verify with ffprobe when present
  if command -v ffprobe >/dev/null 2>&1; then
    ffprobe -v error -show_entries format=format_name -of csv=p=0 "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  fi
  size=$(stat -Lc '%s' "$tmp" 2>/dev/null || echo 0)
  if (( size == 0 || size > max_bytes )); then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dest"
}

# moewalls_preview <preview_url> <dest> — small webm for fast picker preview
moewalls_preview() {
  local preview_url="$1" dest="$2"
  case "$preview_url" in
    https://moewalls.com/*) ;;
    *) return 1 ;;
  esac
  curl -sSL --proto '=https' --max-redirs 3 -m 60 -A "Mozilla/5.0 (X11; Linux x86_64)" -o "$dest" "$preview_url"
}
