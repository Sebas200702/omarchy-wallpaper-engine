#!/bin/bash
# Wallhaven provider (official API, images only).
# Usage: wallhaven_search <query> <categories> <purity> <sorting> <atleast> <ratios> <page>
# Output: TSV rows: id \t title \t page_url \t full_url \t thumb_url
# Requires: curl, jq

wallhaven_search() {
  local query="${1:-}" categories="${2:-111}" purity="${3:-100}"
  local sorting="${4:-random}" atleast="${5:-1920x1080}" ratios="${6:-16x9}" page="${7:-1}"
  local url resp total last

  url="https://wallhaven.cc/api/v1/search?q=$(printf '%s' "$query" | jq -sRr @uri)"
  url+="&categories=${categories}&purity=${purity}&sorting=${sorting}&order=desc"
  [[ -n $atleast ]] && url+="&atleast=${atleast}"
  [[ -n $ratios ]] && url+="&ratios=${ratios}"
  url+="&page=${page}"

  resp=$(curl -sS --proto '=https' --max-redirs 3 -m 20 -A "omarchy-wallpaper-engine/0.1" "$url") || return 1
  # Result totals (for pagination UI) go to stderr so stdout stays pure TSV.
  total=$(printf '%s' "$resp" | jq -r '.meta.total // empty' 2>/dev/null)
  last=$(printf '%s' "$resp" | jq -r '.meta.last_page // empty' 2>/dev/null)
  [[ -n $total ]] && printf 'META total=%s pages=%s\n' "$total" "${last:-}" >&2
  printf '%s' "$resp" | jq -r '.data[]? | [.id, (.url // ""), (.path // ""), (.thumbs.large // .thumbs.small // "")] | @tsv' || return 1
}

# Download a wallhaven full image to dest (validates content-type + size).
# Usage: wallhaven_download <full_url> <dest> <max_bytes>
wallhaven_download() {
  local full_url="$1" dest="$2" max_bytes="${3:-52428800}"
  local tmp ctype size
  [[ $full_url == https://w.wallhaven.cc/* ]] || return 1
  tmp=$(mktemp -p "$(dirname "$dest")" .wh.XXXXXX) || return 1
  if ! run_curl_killable -sSL --proto '=https' --max-redirs 3 -m 60 -A "omarchy-wallpaper-engine/0.1" -o "$tmp" "$full_url"; then
    rm -f "$tmp"; return 1
  fi
  ctype=$(file -b --mime-type "$tmp" 2>/dev/null)
  case "$ctype" in
    image/jpeg|image/png|image/webp) ;;
    *) rm -f "$tmp"; return 1 ;;
  esac
  size=$(stat -Lc '%s' "$tmp" 2>/dev/null || echo 0)
  if (( size == 0 || size > max_bytes )); then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dest"
}
