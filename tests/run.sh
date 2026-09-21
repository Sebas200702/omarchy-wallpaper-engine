#!/bin/bash
# Lightweight test suite for wallpaper-engine.sh's pure/mostly-pure helper
# functions — the ones a bug in silently breaks something security- or
# correctness-critical (path validation, slug/name sanitizing, schedule
# resolution, config reads) without ever showing an error, exactly the
# class of bug this plugin has actually had (see git log: the cfg() false/0
# bug, the index() scoping bug). No mocking framework, no dependency beyond
# what the plugin itself already requires (bash, jq, coreutils).
#
# Every test runs against a fresh, isolated $HOME (a fresh mktemp -d each
# time) — never the real one — via `call`, which sources
# wallpaper-engine.sh with its dispatch neutralized (positional params
# forced to --help, a harmless no-op branch, before sourcing) and then
# invokes exactly one function directly.
#
# Usage: bash tests/run.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$SCRIPT_DIR/wallpaper-engine.sh"
PASS=0
FAIL=0
CURRENT_TESTHOMES=()

cleanup() {
  local d
  for d in "${CURRENT_TESTHOMES[@]:-}"; do
    [[ -n $d && -d $d ]] && rm -rf "$d"
  done
}
trap cleanup EXIT

new_testhome() {
  local dir
  dir=$(mktemp -d) || exit 1
  mkdir -p "$dir/.config/omarchy" "$dir/.local/state/omarchy/current/theme/backgrounds" "$dir/.local/state/omarchy/current"
  CURRENT_TESTHOMES+=("$dir")
  printf '%s' "$dir"
}

call() {
  # call <testhome> <function> [args...] — stdout is the function's stdout.
  local testhome="$1" fn="$2"; shift 2
  env -i PATH="/usr/bin:/bin" HOME="$testhome" bash -c '
    scriptpath="$1"; fn="$2"; shift 2
    args=("$@")
    set -- --help
    source "$scriptpath" >/dev/null 2>&1
    "$fn" "${args[@]}"
  ' _ "$ENGINE" "$fn" "$@"
}

call_stdin() {
  # call_stdin <stdin_file> <testhome> <function> [args...] — like call,
  # but feeds <stdin_file> to the function's stdin (for stdin filters).
  local stdin_file="$1" testhome="$2" fn="$3"; shift 3
  env -i PATH="/usr/bin:/bin" HOME="$testhome" bash -c '
    scriptpath="$1"; fn="$2"; shift 2
    args=("$@")
    set -- --help
    source "$scriptpath" >/dev/null 2>&1
    "$fn" "${args[@]}"
  ' _ "$ENGINE" "$fn" "$@" <"$stdin_file"
}

call_rc() {
  # same as call, but prints nothing — just returns the function's exit code.
  call "$@" >/dev/null 2>&1
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
  fi
}

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [[ $expected -eq $actual ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected rc: %s\n  actual rc:   %s\n' "$desc" "$expected" "$actual" >&2
  fi
}

# ---- safe_slug ----
assert_eq "safe_slug: lowercases and hyphenates" \
  "hello-world" "$(call "$(new_testhome)" safe_slug "Hello World")"
assert_eq "safe_slug: strips punctuation" \
  "hello-world-test" "$(call "$(new_testhome)" safe_slug "Hello, World! -- Test")"
assert_eq "safe_slug: trims leading/trailing hyphens" \
  "abc" "$(call "$(new_testhome)" safe_slug "!!!abc!!!")"
long_slug="$(call "$(new_testhome)" safe_slug "$(printf 'a%.0s' {1..200})")"
assert_eq "safe_slug: truncates to 60 chars" "60" "${#long_slug}"

# ---- sanitize_theme_name ----
assert_eq "sanitize_theme_name: accepts plain name" \
  "catppuccin-dark" "$(call "$(new_testhome)" sanitize_theme_name "catppuccin-dark")"
assert_rc "sanitize_theme_name: rejects path traversal" \
  1 "$(call_rc "$(new_testhome)" sanitize_theme_name "../../etc"; echo $?)"
assert_rc "sanitize_theme_name: rejects embedded slash" \
  1 "$(call_rc "$(new_testhome)" sanitize_theme_name "foo/bar"; echo $?)"
assert_rc "sanitize_theme_name: rejects empty" \
  1 "$(call_rc "$(new_testhome)" sanitize_theme_name ""; echo $?)"

# ---- validate_wallpaper_path ----
th=$(new_testhome)
convert -size 8x8 xc:red "$th/.config/omarchy/backgrounds_test_img.png" 2>/dev/null || touch "$th/.config/omarchy/backgrounds_test_img.png"
mkdir -p "$th/.config/omarchy/backgrounds/sometheme"
convert -size 8x8 xc:red "$th/.config/omarchy/backgrounds/sometheme/ok.png" 2>/dev/null || touch "$th/.config/omarchy/backgrounds/sometheme/ok.png"
assert_rc "validate_wallpaper_path: accepts file under allowed backgrounds dir" \
  0 "$(call_rc "$th" validate_wallpaper_path "$th/.config/omarchy/backgrounds/sometheme/ok.png"; echo $?)"
assert_rc "validate_wallpaper_path: rejects file outside allowed prefixes" \
  1 "$(call_rc "$th" validate_wallpaper_path "$th/.config/omarchy/backgrounds_test_img.png"; echo $?)"
assert_rc "validate_wallpaper_path: rejects nonexistent file" \
  1 "$(call_rc "$th" validate_wallpaper_path "$th/.config/omarchy/backgrounds/sometheme/nope.png"; echo $?)"
assert_rc "validate_wallpaper_path: rejects relative path" \
  1 "$(call_rc "$th" validate_wallpaper_path "backgrounds/sometheme/ok.png"; echo $?)"
assert_rc "validate_wallpaper_path: rejects embedded newline" \
  1 "$(call_rc "$th" validate_wallpaper_path $'/tmp/x\ny'; echo $?)"
assert_rc "validate_wallpaper_path: rejects a directory (not a regular file)" \
  1 "$(call_rc "$th" validate_wallpaper_path "$th/.config/omarchy/backgrounds/sometheme"; echo $?)"

# path-traversal-via-symlink: a symlink inside an allowed dir pointing
# outside every allowed prefix must still be rejected (canonicalized
# check, not a textual one).
th2=$(new_testhome)
mkdir -p "$th2/.config/omarchy/backgrounds/sometheme" "$th2/outside"
convert -size 8x8 xc:blue "$th2/outside/secret.png" 2>/dev/null || touch "$th2/outside/secret.png"
ln -s "$th2/outside/secret.png" "$th2/.config/omarchy/backgrounds/sometheme/escape.png"
assert_rc "validate_wallpaper_path: rejects symlink escaping allowed prefixes" \
  1 "$(call_rc "$th2" validate_wallpaper_path "$th2/.config/omarchy/backgrounds/sometheme/escape.png"; echo $?)"

# ---- effective_max_video_bytes ----
th3=$(new_testhome)
echo '{"maxVideoBytes": 5}' >"$th3/.config/omarchy/wallpaper-engine.json"
assert_eq "effective_max_video_bytes: clamps tiny value to floor" \
  "10485760" "$(call "$th3" effective_max_video_bytes)"
echo '{"maxVideoBytes": 999999999999}' >"$th3/.config/omarchy/wallpaper-engine.json"
assert_eq "effective_max_video_bytes: clamps huge value to ceiling" \
  "4294967296" "$(call "$th3" effective_max_video_bytes)"
echo '{"maxVideoBytes": 2000000000}' >"$th3/.config/omarchy/wallpaper-engine.json"
assert_eq "effective_max_video_bytes: sane value passes through" \
  "2000000000" "$(call "$th3" effective_max_video_bytes)"
echo '{}' >"$th3/.config/omarchy/wallpaper-engine.json"
assert_eq "effective_max_video_bytes: missing key falls back to default" \
  "524288000" "$(call "$th3" effective_max_video_bytes)"

# ---- cfg (the false/0-vs-missing regression) ----
th4=$(new_testhome)
echo '{"enabled": false, "includeVideos": false, "transitionMs": 0}' >"$th4/.config/omarchy/wallpaper-engine.json"
assert_eq "cfg: explicit false is NOT replaced by the default" \
  "false" "$(call "$th4" cfg .enabled true)"
assert_eq "cfg: explicit false (second key) is NOT replaced by the default" \
  "false" "$(call "$th4" cfg .includeVideos true)"
assert_eq "cfg: explicit 0 is NOT replaced by the default" \
  "0" "$(call "$th4" cfg .transitionMs 420)"
echo '{}' >"$th4/.config/omarchy/wallpaper-engine.json"
assert_eq "cfg: missing key falls back to the default" \
  "true" "$(call "$th4" cfg .enabled true)"

# ---- resolve_schedule_pick ----
th5=$(new_testhome)
echo -n "sometheme" >"$th5/.local/state/omarchy/current/theme.name"
mkdir -p "$th5/.config/omarchy/backgrounds/sometheme"
convert -size 8x8 xc:red "$th5/.config/omarchy/backgrounds/sometheme/night.mp4" 2>/dev/null || touch "$th5/.config/omarchy/backgrounds/sometheme/night.mp4"
assert_eq "resolve_schedule_pick: finds a bare filename in the theme dir" \
  "$th5/.config/omarchy/backgrounds/sometheme/night.mp4" "$(call "$th5" resolve_schedule_pick "night.mp4")"
assert_rc "resolve_schedule_pick: fails for a nonexistent filename" \
  1 "$(call_rc "$th5" resolve_schedule_pick "nope.mp4"; echo $?)"
assert_rc "resolve_schedule_pick: rejects an absolute path outside allowed prefixes" \
  1 "$(call_rc "$th5" resolve_schedule_pick "/etc/passwd"; echo $?)"

# ---- favorite_toggle + grid_local_json's favorite field ----
# Regression test for a real bug: $favs | index(.[0]) evaluated .[0]
# against $favs (index/1's argument runs with "." = whatever it was
# piped, i.e. the favorites array itself), not the row being built, so
# every row's "favorite" flag came out identical — whatever
# favorites[0] happened to be. Fixed as
# (.[0] as $k | $favs | index($k)); this test exists so that fix can't
# silently regress.
th6=$(new_testhome)
echo -n "sometheme" >"$th6/.local/state/omarchy/current/theme.name"
mkdir -p "$th6/.config/omarchy/backgrounds/sometheme"
convert -size 8x8 xc:red "$th6/.config/omarchy/backgrounds/sometheme/a.png" 2>/dev/null || touch "$th6/.config/omarchy/backgrounds/sometheme/a.png"
convert -size 8x8 xc:blue "$th6/.config/omarchy/backgrounds/sometheme/b.png" 2>/dev/null || touch "$th6/.config/omarchy/backgrounds/sometheme/b.png"
echo '{"enabled":true,"intervalMinutes":10,"mode":"shuffle","includeImages":true,"includeVideos":true,"transitionMs":420,"schedules":[],"playlists":[],"activePlaylist":null}' >"$th6/.config/omarchy/wallpaper-engine.json"
call "$th6" favorite_toggle "$th6/.config/omarchy/backgrounds/sometheme/b.png" >/dev/null
grid_out=$(call "$th6" grid_local_json 10)
a_fav=$(printf '%s' "$grid_out" | jq -r '.[] | select(.key | endswith("/a.png")) | .favorite')
b_fav=$(printf '%s' "$grid_out" | jq -r '.[] | select(.key | endswith("/b.png")) | .favorite')
assert_eq "grid_local_json: non-favorited item reports favorite=false" "false" "$a_fav"
assert_eq "grid_local_json: favorited item reports favorite=true" "true" "$b_fav"

# ---- validate_jsonc / strip_jsonc_comments ----
# Must match the tolerance level omarchy's own menu.jsonc template
# actually ships with (// comments + a trailing comma before a closing
# brace once those comments are stripped), or every future menu edit
# would refuse to write against a completely untouched, valid file.
th7=$(new_testhome)
cat >"$th7/menu.jsonc" <<'JSONC'
{
  "style.background": {"icon":"","label":"Background"},
  // a trailing comment block, as omarchy's own template ships
  // more comments
}
JSONC
assert_rc "validate_jsonc: accepts comments + trailing comma (omarchy's own shape)" \
  0 "$(call_rc "$th7" validate_jsonc "$th7/menu.jsonc"; echo $?)"
printf '{\n  "a": 1\n  "b": 2\n}\n' >"$th7/broken.jsonc"
assert_rc "validate_jsonc: rejects genuinely invalid JSON (missing comma)" \
  1 "$(call_rc "$th7" validate_jsonc "$th7/broken.jsonc"; echo $?)"

# ---- slice_lines ----
th8=$(new_testhome)
seq -f 'r%.0f' 1 50 >"$th8/ranks.txt"
slice_out=$(call_stdin "$th8/ranks.txt" "$th8" slice_lines 21 20)
assert_eq "slice_lines: window starts at rank 21" \
  "r21" "$(printf '%s' "$slice_out" | head -n1)"
assert_eq "slice_lines: window ends at rank 40" \
  "r40" "$(printf '%s' "$slice_out" | tail -n1)"
assert_eq "slice_lines: window holds 20 lines" \
  "20" "$(printf '%s' "$slice_out" | grep -c '')"
assert_eq "slice_lines: start past EOF yields empty output" \
  "" "$(call_stdin "$th8/ranks.txt" "$th8" slice_lines 100 20)"
short_out=$(call_stdin "$th8/ranks.txt" "$th8" slice_lines 46 20)
assert_eq "slice_lines: short tail is not padded" \
  "5" "$(printf '%s' "$short_out" | grep -c '')"

# ---- wh_api_pages (20-item UI pages over fixed 24-item API pages) ----
th9=$(new_testhome)
assert_eq "wh_api_pages: UI page 1 fits in API page 1" \
  "1 1 1 20" "$(call "$th9" wh_api_pages 1 20 24)"
assert_eq "wh_api_pages: UI page 2 straddles API pages 1-2" \
  "1 2 21 40" "$(call "$th9" wh_api_pages 2 20 24)"
assert_eq "wh_api_pages: UI page 3 straddles API pages 2-3" \
  "2 3 41 60" "$(call "$th9" wh_api_pages 3 20 24)"
assert_eq "wh_api_pages: UI page 6 aligns exactly with API page 5" \
  "5 5 101 120" "$(call "$th9" wh_api_pages 6 20 24)"
assert_eq "wh_api_pages: invalid page falls back to page 1" \
  "1 1 1 20" "$(call "$th9" wh_api_pages 0 20 24)"

# ---- meta_total ----
th10=$(new_testhome)
printf 'curl: noise on stderr\nMETA total=137 pages=6\nMETA total=137 pages=6\n' >"$th10/meta.txt"
assert_eq "meta_total: first META total wins" \
  "137" "$(call "$th10" meta_total "$th10/meta.txt")"
printf 'no meta here\n' >"$th10/empty-meta.txt"
assert_eq "meta_total: missing META yields empty" \
  "" "$(call "$th10" meta_total "$th10/empty-meta.txt")"

# ---- moe_detail_valid ----
th11=$(new_testhome)
assert_rc "moe_detail_valid: well-formed detail line passes" \
  0 "$(call_rc "$th11" moe_detail_valid "$(printf 't\tp\tabcXYZ_123.-=\ttitle')"; echo $?)"
assert_rc "moe_detail_valid: hostile token chars fail" \
  1 "$(call_rc "$th11" moe_detail_valid "$(printf 't\tp\ta&b?c\ttitle')"; echo $?)"
assert_rc "moe_detail_valid: empty token fails" \
  1 "$(call_rc "$th11" moe_detail_valid "$(printf 't\tp\t\ttitle')"; echo $?)"
# Regression: with an empty leading field (missing thumb), IFS-read shifts
# every field left and would validate the title as the token — cut-based
# parsing must read the real third field instead.
assert_rc "moe_detail_valid: empty thumb still validates the real token" \
  0 "$(call_rc "$th11" moe_detail_valid "$(printf '\tpreview\ttok-1.2=x\ttitle here')"; echo $?)"
# MoeWalls now emits URL-encoded tokens (e.g. %2F) that must travel
# verbatim — % passes, but anything that could break out of the download
# URL's query value still fails.
assert_rc "moe_detail_valid: URL-encoded token passes" \
  0 "$(call_rc "$th11" moe_detail_valid "$(printf 't\tp\tWTX7OeKp99iW1QDO9q%%2FyuLe%%2FqZ4g\ttitle')"; echo $?)"
for bad in 'a&b' 'a?b' 'a#b' 'a/b' 'a b' 'a+b'; do
  assert_rc "moe_detail_valid: token with '$bad' fails" \
    1 "$(call_rc "$th11" moe_detail_valid "$(printf 't\tp\t%s\ttitle' "$bad")"; echo $?)"
done

# ---- emit_search_envelope ----
th12=$(new_testhome)
python3 -c "import json; print(json.dumps([{'key': str(i)} for i in range(20)]))" >"$th12/full.json"
printf '[{"key":"a"},{"key":"b"}]' >"$th12/partial.json"
env_out=$(call "$th12" emit_search_envelope "$th12/full.json" 1 20 45)
assert_eq "emit_search_envelope: total passes through" \
  "45" "$(printf '%s' "$env_out" | jq -r .total)"
assert_eq "emit_search_envelope: full first page of 45 has more" \
  "true" "$(printf '%s' "$env_out" | jq -r .hasMore)"
assert_eq "emit_search_envelope: items preserved" \
  "20" "$(printf '%s' "$env_out" | jq -r '.items | length')"
assert_eq "emit_search_envelope: page/pageSize echoed" \
  "1 20" "$(printf '%s' "$env_out" | jq -r '"\(.page) \(.pageSize)"')"
env_last=$(call "$th12" emit_search_envelope "$th12/full.json" 3 20 45)
assert_eq "emit_search_envelope: page ending past total has no more" \
  "false" "$(printf '%s' "$env_last" | jq -r .hasMore)"
env_exact=$(call "$th12" emit_search_envelope "$th12/full.json" 1 20 20)
assert_eq "emit_search_envelope: page ending exactly at total has no more" \
  "false" "$(printf '%s' "$env_exact" | jq -r .hasMore)"
env_nototal_full=$(call "$th12" emit_search_envelope "$th12/full.json" 1 20 "")
assert_eq "emit_search_envelope: unknown total + full page assumes more" \
  "true" "$(printf '%s' "$env_nototal_full" | jq -r .hasMore)"
assert_eq "emit_search_envelope: unknown total encodes as null" \
  "null" "$(printf '%s' "$env_nototal_full" | jq -r .total)"
env_nototal_short=$(call "$th12" emit_search_envelope "$th12/partial.json" 1 20 "")
assert_eq "emit_search_envelope: unknown total + short page has no more" \
  "false" "$(printf '%s' "$env_nototal_short" | jq -r .hasMore)"

# ---- valid_monitor_fit ----
th13=$(new_testhome)
assert_rc "valid_monitor_fit: crop passes" \
  0 "$(call_rc "$th13" valid_monitor_fit crop; echo $?)"
assert_rc "valid_monitor_fit: fit passes" \
  0 "$(call_rc "$th13" valid_monitor_fit fit; echo $?)"
assert_rc "valid_monitor_fit: stretch passes" \
  0 "$(call_rc "$th13" valid_monitor_fit stretch; echo $?)"
assert_rc "valid_monitor_fit: zoom fails" \
  1 "$(call_rc "$th13" valid_monitor_fit zoom; echo $?)"
assert_rc "valid_monitor_fit: empty fails" \
  1 "$(call_rc "$th13" valid_monitor_fit ""; echo $?)"

# ---- monitor_set / monitor_fit / monitor_clear / monitors_json ----
th14=$(new_testhome)
mkdir -p "$th14/.config/omarchy/backgrounds/dark"
touch "$th14/.config/omarchy/backgrounds/dark/a.jpg" "$th14/.config/omarchy/backgrounds/dark/b.mp4"
mon_set=$(call "$th14" monitor_set "DP-1" "$th14/.config/omarchy/backgrounds/dark/a.jpg")
assert_eq "monitor_set: pin stored with default crop fit" \
  "crop" "$(printf '%s' "$mon_set" | jq -r '.stale[0].fit')"
assert_eq "monitor_set: unconnected output reported as stale" \
  "DP-1" "$(printf '%s' "$mon_set" | jq -r '.stale[0].name')"
assert_eq "monitor_set: stale pin keeps the file" \
  "$th14/.config/omarchy/backgrounds/dark/a.jpg" "$(printf '%s' "$mon_set" | jq -r '.stale[0].file')"
mon_fit=$(call "$th14" monitor_fit "DP-1" "fit")
assert_eq "monitor_fit: fit change sticks" \
  "fit" "$(printf '%s' "$mon_fit" | jq -r '.stale[0].fit')"
assert_rc "monitor_fit: invalid mode rejected" \
  1 "$(call_rc "$th14" monitor_fit "DP-1" "zoom"; echo $?)"
assert_rc "monitor_fit: pin required before fit" \
  1 "$(call_rc "$th14" monitor_fit "HDMI-1" "fit"; echo $?)"
assert_rc "monitor_set: hostile output name rejected" \
  1 "$(call_rc "$th14" monitor_set 'a;b' "$th14/.config/omarchy/backgrounds/dark/a.jpg"; echo $?)"
assert_rc "monitor_set: missing file rejected" \
  1 "$(call_rc "$th14" monitor_set "DP-1" "$th14/.config/omarchy/backgrounds/dark/nope.jpg"; echo $?)"
assert_rc "monitor_set: file outside allowed prefixes rejected" \
  1 "$(call_rc "$th14" monitor_set "DP-1" "/etc/hostname"; echo $?)"
mon_clear=$(call "$th14" monitor_clear "DP-1")
assert_eq "monitor_clear: stale pin removed" \
  "0" "$(printf '%s' "$mon_clear" | jq -r '.stale | length')"
# video pin keeps its fit across re-set
call "$th14" monitor_set "DP-1" "$th14/.config/omarchy/backgrounds/dark/b.mp4" >/dev/null
call "$th14" monitor_fit "DP-1" "stretch" >/dev/null
mon_reset=$(call "$th14" monitor_set "DP-1" "$th14/.config/omarchy/backgrounds/dark/a.jpg")
assert_eq "monitor_set: re-set preserves existing fit" \
  "stretch" "$(printf '%s' "$mon_reset" | jq -r '.stale[0].fit')"
# delete-file drops monitor pins pointing at the removed file
call "$th14" delete_wallpaper_file "$th14/.config/omarchy/backgrounds/dark/a.jpg" >/dev/null
mon_after_del=$(call "$th14" monitors_json)
assert_eq "delete-file: monitor pin for deleted file is gone" \
  "0" "$(printf '%s' "$mon_after_del" | jq -r '.stale | length')"
assert_eq "monitors_json: imageFit defaults to crop" \
  "crop" "$(printf '%s' "$mon_after_del" | jq -r '.imageFit')"

# ---- config_set_key imageFit ----
th15=$(new_testhome)
echo '{}' >"$th15/.config/omarchy/wallpaper-engine.json"
call "$th15" config_set_key imageFit fit >/dev/null
assert_eq "config_set_key: imageFit fit sticks" \
  "fit" "$(call "$th15" cfg .imageFit crop)"
assert_rc "config_set_key: imageFit zoom rejected" \
  1 "$(call_rc "$th15" config_set_key imageFit zoom; echo $?)"

# ---- download progress roundtrip ----
th16=$(new_testhome)
assert_eq "download_status: idle without progress file" \
  "false" "$(call "$th16" download_status | jq -r .active)"
call "$th16" write_download_progress 500 1000 "moewalls" >/dev/null
dl_mid=$(call "$th16" download_status)
assert_eq "download_status: active while downloading" \
  "true" "$(printf '%s' "$dl_mid" | jq -r .active)"
assert_eq "download_status: percent math (500/1000 -> 50)" \
  "50" "$(printf '%s' "$dl_mid" | jq -r .percent)"
assert_eq "download_status: downloaded bytes tracked" \
  "500" "$(printf '%s' "$dl_mid" | jq -r .downloaded)"
call "$th16" write_download_progress 250 "" "wallhaven" >/dev/null
dl_unknown=$(call "$th16" download_status)
assert_eq "download_status: unknown total encodes as null" \
  "null" "$(printf '%s' "$dl_unknown" | jq -r .total)"
call "$th16" finish_download_progress true >/dev/null
assert_eq "finish_download_progress: download marked done" \
  "true" "$(call "$th16" download_status | jq -r .ok)"

# ---- preview_fetch (offline paths) ----
th17=$(new_testhome)
assert_rc "preview_fetch: missing meta fails" \
  1 "$(call_rc "$th17" preview_fetch "/cache/moe-x.jpg"; echo $?)"
mkdir -p "$th17/.local/state/omarchy/wallpaper-engine"
printf 'stub\tmoewalls\ttok\tpage\ttitle\t\n' >"$th17/.local/state/omarchy/wallpaper-engine/online-meta.tsv"
assert_rc "preview_fetch: empty preview column fails" \
  1 "$(call_rc "$th17" preview_fetch "stub"; echo $?)"
printf 'stub2\tmoewalls\ttok\tpage\ttitle\thttps://evil.example/x.webm\n' >>"$th17/.local/state/omarchy/wallpaper-engine/online-meta.tsv"
assert_rc "preview_fetch: off-host preview rejected" \
  1 "$(call_rc "$th17" preview_fetch "stub2"; echo $?)"
# cache hit: pre-seeded preview is returned without network
mkdir -p "$th17/.cache/omarchy/wallpaper-engine/online/previews"
printf 'fake-webm-bytes' >"$th17/.cache/omarchy/wallpaper-engine/online/previews/moe-abc.webm"
printf '/c/moe-abc.jpg\tmoewalls\ttok\tpage\ttitle\thttps://moewalls.com/pv.webm\n' >>"$th17/.local/state/omarchy/wallpaper-engine/online-meta.tsv"
assert_eq "preview_fetch: cache hit returns the webm path" \
  "$th17/.cache/omarchy/wallpaper-engine/online/previews/moe-abc.webm" \
  "$(call "$th17" preview_fetch "/c/moe-abc.jpg")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
