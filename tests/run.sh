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

scall() {
  # scall <testhome> <function> [args...] — like call, but also sources
  # providers/steam.sh, whose functions the engine only loads from the real
  # plugin dir (absent in the isolated testhome).
  local testhome="$1" fn="$2"; shift 2
  env -i PATH="/usr/bin:/bin" HOME="$testhome" bash -c '
    scriptpath="$1"; provider="$2"; fn="$3"; shift 3
    args=("$@")
    set -- --help
    source "$scriptpath" >/dev/null 2>&1
    source "$provider" >/dev/null 2>&1
    source "${provider%/*}/workshop.sh" >/dev/null 2>&1
    "$fn" "${args[@]}"
  ' _ "$ENGINE" "$SCRIPT_DIR/providers/steam.sh" "$fn" "$@"
}

scall_rc() {
  scall "$@" >/dev/null 2>&1
}

scall_env() {
  # scall_env "<VAR=val ...>" <testhome> <function> [args...] — scall with
  # extra environment (steam_login's WE_STEAM_PASS panel-login path).
  local extra="$1" testhome="$2" fn="$3"; shift 3
  # shellcheck disable=SC2086
  env -i PATH="/usr/bin:/bin" HOME="$testhome" $extra bash -c '
    scriptpath="$1"; provider="$2"; fn="$3"; shift 3
    args=("$@")
    set -- --help
    source "$scriptpath" >/dev/null 2>&1
    source "$provider" >/dev/null 2>&1
    "$fn" "${args[@]}"
  ' _ "$ENGINE" "$SCRIPT_DIR/providers/steam.sh" "$fn" "$@"
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

# ---- ensure_menu_override never clobbers a user Background entry ----
# Marketplace rule: no overwriting user configuration without consent. A
# customized "style.background" row stays; the plugin's own gallery row is
# added, and a Background row that already points at the plugin refreshes.
th7m=$(new_testhome)
mkdir -p "$th7m/.config/omarchy/extensions"
cat >"$th7m/.config/omarchy/extensions/omarchy-menu.jsonc" <<'JSONC'
{
  "style.background": {"icon":"","label":"My background","action":"my-script"},
}
JSONC
call_rc "$th7m" ensure_menu_override
menu7m="$th7m/.config/omarchy/extensions/omarchy-menu.jsonc"
assert_eq "ensure_menu_override: keeps a user-customized Background row" \
  "1" "$(grep -c '"label":"My background","action":"my-script"' "$menu7m")"
assert_eq "ensure_menu_override: adds the WallHub gallery row" \
  "1" "$(grep -c '"style.wallpaper-engine".*"label":"WallHub"' "$menu7m")"
cat >"$menu7m" <<JSONC
{
  "style.background": {"icon":"","label":"Background","action":"$th7m/.config/omarchy/plugins/sebas.wallpaper-engine/wallpaper-engine.sh --old"},
}
JSONC
call_rc "$th7m" ensure_menu_override
assert_eq "ensure_menu_override: refreshes a Background row from the legacy id" \
  "0" "$(grep -c -- '--old' "$menu7m")"
assert_eq "ensure_menu_override: Background row now points at the current id" \
  "1" "$(grep -c 'plugins/io.github.sebas200702.wallhub/wallpaper-engine.sh' "$menu7m")"
call_rc "$th7m" unwire_menu_override
assert_eq "unwire_menu_override: removes both plugin rows" \
  "0" "$(grep -c 'wallpaper-engine' "$menu7m")"

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

# ---- rank_moe_rows (the 2026-09-21 empty-MoeWalls regression) ----
# A bug here silently empties every online video page: the preview lookup
# indexed the already-built object instead of the row array ("Cannot index
# object with number") → `[]` for all results. These tests pin the fix.
th18=$(new_testhome)
rows18=$(mktemp); out18=$(mktemp)
printf 'stub-frieren\tvideo\thttps://moewalls.com/p1\tFrieren Snow Live Wallpaper\t1\thttps://moewalls.com/p1.webm\n' >"$rows18"
printf 'stub-other\tvideo\thttps://moewalls.com/p2\tSome Unrelated Sunset\t2\t\n' >>"$rows18"
printf 'short\tvideo\n' >>"$rows18"
call "$th18" rank_moe_rows "frieren" "$rows18" "$out18" >/dev/null
ranked=$(cat "$out18")
assert_eq "rank_moe_rows: keeps both valid rows, drops the short one" \
  "2" "$(printf '%s' "$ranked" | jq 'length')"
assert_eq "rank_moe_rows: exact title match ranks first" \
  "stub-frieren" "$(printf '%s' "$ranked" | jq -r '.[0].key')"
assert_eq "rank_moe_rows: strips the Live Wallpaper suffix" \
  "Frieren Snow" "$(printf '%s' "$ranked" | jq -r '.[0].title')"
assert_eq "rank_moe_rows: keeps the preview URL" \
  "https://moewalls.com/p1.webm" "$(printf '%s' "$ranked" | jq -r '.[0].preview')"
assert_eq "rank_moe_rows: empty preview encodes as null" \
  "null" "$(printf '%s' "$ranked" | jq -r '.[1].preview')"
assert_eq "rank_moe_rows: thumb mirrors key" \
  "stub-other" "$(printf '%s' "$ranked" | jq -r '.[1].thumb')"
rows_empty=$(mktemp); out_empty=$(mktemp)
: >"$rows_empty"
call "$th18" rank_moe_rows "frieren" "$rows_empty" "$out_empty" >/dev/null
assert_eq "rank_moe_rows: empty rows yield an empty array, not an error" \
  "0" "$(cat "$out_empty" | jq 'length')"
rm -f "$rows18" "$out18" "$rows_empty" "$out_empty"

# ---- steam_parse_search (fixture HTML, no network) ----
th19=$(new_testhome)
search19=$(mktemp)
cat >"$search19" <<'SEARCHHTML'
<a href="https://steamcommunity.com/sharedfiles/filedetails/?id=1122986705" class="tK5agp5sRy8-"><img src="https://images.steamusercontent.com/ugc/780727677601147484/A933C83749D72BFC96FBC1B72A6EBD5EBBF3974B/?ima=fit&amp;impolicy=Letterbox&amp;imcolor=%23000000&amp;imw=288&amp;imh=288&amp;letterbox=true" alt="Cyberpunk Anime Girl &amp; City" loading="lazy" class=""/>
<a href="https://steamcommunity.com/sharedfiles/filedetails/?id=2048502967" class="tK5agp5sRy8-"><img src="https://images.steamusercontent.com/ugc/2380802761820896233/C66C930AD9AC50487702915BE325DFAC54261328/?ima=fit&amp;impolicy=Letterbox&amp;imcolor=%23000000&amp;imw=288&amp;imh=288&amp;letterbox=true" alt="Neon Drive" loading="lazy" class=""/>
SEARCHHTML
parsed19=$(scall "$th19" steam_parse_search "$search19")
assert_eq "steam_parse_search: extracts both rows" \
  "2" "$(printf '%s' "$parsed19" | grep -c '')"
assert_eq "steam_parse_search: id, decoded title, url, decoded thumb" \
  "1122986705	Cyberpunk Anime Girl & City	https://steamcommunity.com/sharedfiles/filedetails/?id=1122986705	https://images.steamusercontent.com/ugc/780727677601147484/A933C83749D72BFC96FBC1B72A6EBD5EBBF3974B/?ima=fit&impolicy=Letterbox&imcolor=%23000000&imw=288&imh=288&letterbox=true" \
  "$(printf '%s' "$parsed19" | head -n1)"
: >"$search19.empty"
assert_eq "steam_parse_search: empty page yields empty output" \
  "" "$(scall "$th19" steam_parse_search "$search19.empty")"
rm -f "$search19" "$search19.empty"

# ---- steam_parse_detail + steam_size_bytes (fixture HTML, no network) ----
th20=$(new_testhome)
detail20=$(mktemp)
cat >"$detail20" <<'DETAILHTML'
<title>Steam Workshop::Cyberpunk Anime Girl</title>
<meta property="og:image" content="https://images.steamusercontent.com/ugc/780727677601147484/A933C83749D72BFC96FBC1B72A6EBD5EBBF3974B/?imw=512&amp;&amp;ima=fit&amp;impolicy=Letterbox">
<div class="detailsStatRight">126.426 MB</div>
<div data-panel="{&quot;type&quot;:&quot;PanelGroup&quot;}" class="workshopTags"><span class="workshopTagsTitle">Type:&nbsp;</span><a href="https://steamcommunity.com/workshop/browse/?appid=431960">Video</a>
DETAILHTML
det20=$(scall "$th20" steam_parse_detail "$detail20")
assert_eq "steam_parse_detail: title, image, size, type" \
  "Cyberpunk Anime Girl	https://images.steamusercontent.com/ugc/780727677601147484/A933C83749D72BFC96FBC1B72A6EBD5EBBF3974B/?imw=512&&ima=fit&impolicy=Letterbox	126.426 MB	Video" \
  "$det20"
assert_eq "steam_size_bytes: MB to bytes" \
  "132567269" "$(scall "$th20" steam_size_bytes "126.426 MB")"
assert_eq "steam_size_bytes: GB to bytes" \
  "1288490189" "$(scall "$th20" steam_size_bytes "1.2 GB")"
assert_eq "steam_size_bytes: KB to bytes" \
  "870400" "$(scall "$th20" steam_size_bytes "850 KB")"
assert_rc "steam_size_bytes: junk fails" \
  1 "$(scall_rc "$th20" steam_size_bytes "huge"; echo $?)"
rm -f "$detail20"

# ---- steam_find_item_dir (fake tree, no network) ----
th21=$(new_testhome)
mkdir -p "$th21/Steam/steamapps/workshop/content/431960/1122986705"
assert_eq "steam_find_item_dir: finds item under HOME/Steam" \
  "$th21/Steam/steamapps/workshop/content/431960/1122986705" \
  "$(HOME="$th21" scall "$th21" steam_find_item_dir "1122986705")"
assert_rc "steam_find_item_dir: missing item fails" \
  1 "$(HOME="$th21" scall_rc "$th21" steam_find_item_dir "999999999"; echo $?)"
assert_rc "steam_find_item_dir: hostile id fails" \
  1 "$(scall_rc "$th21" steam_find_item_dir "../../etc"; echo $?)"

# ---- steam_status without steamcmd (deterministic here) ----
th22=$(new_testhome)
assert_eq "steam_status: unconfigured without binary or user" \
  "false" "$(scall "$th22" steam_status | jq -r .configured)"

# ---- config_set_key steamUser/steamCmd ----
th23=$(new_testhome)
echo '{}' >"$th23/.config/omarchy/wallpaper-engine.json"
call "$th23" config_set_key steamUser "gamer_01" >/dev/null
assert_eq "config_set_key: steamUser sticks" \
  "gamer_01" "$(call "$th23" cfg .steamUser "")"
assert_rc "config_set_key: steamUser with slash rejected" \
  1 "$(call_rc "$th23" config_set_key steamUser "a/b"; echo $?)"
assert_rc "config_set_key: steamCmd missing binary rejected" \
  1 "$(call_rc "$th23" config_set_key steamCmd "/nonexistent/steamcmd"; echo $?)"

# ---- steam_login (fake steamcmd — env/stdin paths, no network) ----
steam_login_home() {
  # isolated home with a fake steamcmd wired in via config steamCmd.
  # Outcome is selected by <$home>/.fake_steam_outcome (default: success).
  local th
  th=$(new_testhome)
  echo '{}' >"$th/.config/omarchy/wallpaper-engine.json"
  mkdir -p "$th/bin"
  cat >"$th/bin/steamcmd" <<'FAKE'
#!/bin/bash
# fake steamcmd: swallow the piped credentials, replay a canned outcome
cat >/dev/null 2>&1 || :
case "$(cat "$HOME/.fake_steam_outcome" 2>/dev/null)" in
  password)
    echo "Cached credentials not found."
    printf 'password: '
    echo "Logging in user 'test' to Steam Public..."
    echo "ERROR (Invalid Password)"
    exit 5 ;;
  guard)
    echo "Logging in user 'test'..."
    echo "FAILED (Two-factor code mismatch)"
    exit 1 ;;
esac
echo "Welcome to Steam!"
exit 0
FAKE
  chmod +x "$th/bin/steamcmd"
  call "$th" config_set_key steamCmd "$th/bin/steamcmd" >/dev/null
  printf '%s' "$th"
}

th24=$(steam_login_home)
out24=$(scall_env "WE_STEAM_PASS=s3cret WE_STEAM_CODE=12345" "$th24" steam_login "alice") || true
assert_eq "steam_login: env login returns steamUser" \
  "alice" "$(printf '%s' "$out24" | jq -r .steamUser 2>/dev/null)"
assert_eq "steam_login: env login stores steamUser" \
  "alice" "$(call "$th24" cfg .steamUser "")"

th25=$(steam_login_home)
echo password >"$th25/.fake_steam_outcome"
rc25=0; msg25=$(scall_env "WE_STEAM_PASS=nope" "$th25" steam_login "bob" 2>&1 1>/dev/null) || rc25=$?
assert_rc "steam_login: wrong password fails" 1 "$rc25"
assert_eq "steam_login: wrong password message" \
  "wrong Steam password — retry" "$msg25"
assert_eq "steam_login: failure stores nothing" \
  "" "$(call "$th25" cfg .steamUser "")"

th26=$(steam_login_home)
echo guard >"$th26/.fake_steam_outcome"
rc26=0; msg26=$(scall_env "WE_STEAM_PASS=s3cret" "$th26" steam_login "bob" 2>&1 1>/dev/null) || rc26=$?
assert_rc "steam_login: missing guard code fails" 1 "$rc26"
assert_eq "steam_login: guard hint asks for the code" \
  "Steam Guard code required — check your email/app, then retry with the code (or run steam-login in a terminal)" "$msg26"

th27=$(steam_login_home)
echo guard >"$th27/.fake_steam_outcome"
rc27=0; msg27=$(scall_env "WE_STEAM_PASS=s3cret WE_STEAM_CODE=999" "$th27" steam_login "bob" 2>&1 1>/dev/null) || rc27=$?
assert_rc "steam_login: wrong guard code fails" 1 "$rc27"
assert_eq "steam_login: rejected code message" \
  "Steam Guard code rejected — use the latest code from your app/email and retry" "$msg27"

th28=$(steam_login_home)
rc28=0; out28=$(printf 'pw1\ncode9\n' | scall "$th28" steam_login "carol" 2>/dev/null) || rc28=$?
assert_rc "steam_login: stdin pipe login succeeds" 0 "$rc28"
assert_eq "steam_login: stdin pipe stores steamUser" \
  "carol" "$(call "$th28" cfg .steamUser "")"

th29=$(steam_login_home)
rc29=0; msg29=$(scall "$th29" steam_login "bad/name" 2>&1 1>/dev/null) || rc29=$?
assert_rc "steam_login: hostile username rejected" 1 "$rc29"

# ---- local Workshop library (providers/workshop.sh) ----
# Fixture: two Steam libraries (the second only reachable through
# libraryfolders.vdf), one item of each type, plus a hostile project.json
# whose "file" tries to escape the item dir.
wk_home() {
  local th lib1 lib2
  th=$(new_testhome)
  lib1="$th/.local/share/Steam/steamapps/workshop/content/431960"
  lib2="$th/games/SteamLibrary/steamapps/workshop/content/431960"
  mkdir -p "$lib1/111111" "$lib1/222222" "$lib2/333333" "$lib2/444444" "$th/.local/share/Steam/steamapps"
  printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' \
    "$th/.local/share/Steam" "$th/games/SteamLibrary" >"$th/.local/share/Steam/steamapps/libraryfolders.vdf"
  printf 'fakevideo' >"$lib1/111111/clip one.mp4"; printf 'img' >"$lib1/111111/preview.jpg"
  printf '{"title":"Video One","type":"Video","file":"clip one.mp4","preview":"preview.jpg"}' >"$lib1/111111/project.json"
  printf '{"title":"Scene Two","type":"scene","file":"scene.json","preview":"preview.gif"}' >"$lib1/222222/project.json"
  printf '{"title":"Web Three","type":"web","file":"index.html"}' >"$lib2/333333/project.json"
  printf '{"title":"Evil","type":"video","file":"../../../../etc/passwd","preview":"../x.jpg"}' >"$lib2/444444/project.json"
  printf '%s' "$th"
}
thw=$(wk_home)
wl=$(scall "$thw" workshop_list_json)
assert_eq "workshop_list_json: finds items across libraryfolders.vdf libraries" "4" "$(jq 'length' <<<"$wl")"
assert_eq "workshop_list_json: maps types to kinds" "video,scene,web,video" \
  "$(jq -r '. as $all | ["111111","222222","333333","444444"] | map(. as $i | $all[] | select(.workshopId == $i) | .kind) | join(",")' <<<"$wl")"
assert_eq "workshop_list_json: video is playable" "true" "$(jq -r '.[] | select(.workshopId=="111111") | .playable' <<<"$wl")"
assert_eq "workshop_list_json: scene without linux-wallpaperengine is blocked" "needs-lwe" \
  "$(jq -r '.[] | select(.workshopId=="222222") | .reason' <<<"$wl")"
assert_eq "workshop_list_json: hostile file path stays inside the item dir" \
  "$thw/games/SteamLibrary/steamapps/workshop/content/431960/444444/passwd" \
  "$(jq -r '.[] | select(.workshopId=="444444") | .file' <<<"$wl")"
assert_eq "workshop_list_json: hostile preview path stays inside the item dir" \
  "$thw/games/SteamLibrary/steamapps/workshop/content/431960/444444/x.jpg" \
  "$(jq -r '.[] | select(.workshopId=="444444") | .thumb' <<<"$wl")"
assert_rc "workshop_item_dir: rejects a non-numeric id" 1 "$(scall "$thw" workshop_item_dir "../111111" >/dev/null 2>&1; echo $?)"
lib1w="$thw/.local/share/Steam/steamapps/workshop/content/431960"
imp=$(scall "$thw" workshop_import_video "$lib1w/111111" "$lib1w/111111/clip one.mp4" 111111 "Video One")
assert_eq "workshop_import_video: lands in backgrounds/workshop as wk-<id>" \
  "$thw/.config/omarchy/backgrounds/workshop/wk-111111.mp4" "$imp"
assert_eq "workshop_import_video: writes a workshop attribution sidecar" "workshop" \
  "$(jq -r '.provider' "$imp.attribution.json" 2>/dev/null)"
assert_rc "workshop_import_video: refuses a file outside the item dir" 1 \
  "$(scall "$thw" workshop_import_video "$lib1w/111111" "/etc/hostname" 111111 "x" >/dev/null 2>&1; echo $?)"
assert_rc "workshop_is_item_dir: accepts a real item dir" 0 "$(scall "$thw" workshop_is_item_dir "$lib1w/222222"; echo $?)"
assert_rc "workshop_is_item_dir: rejects a path outside Workshop roots" 1 "$(scall "$thw" workshop_is_item_dir "$thw"; echo $?)"

# ---- linux-wallpaperengine --list-properties parser (README sample) ----
props_sample=$'barcount - slider\n\tDescription: Bar Count\n\tValue: 64\n\tMinimum value: 16\n\tMaximum value: 64\n\tStep: 1\n\nbloom - boolean\n\tDescription: Bloom\n\tValue: 0\nfrequency - combolist\n\tDescription: Frequency\n\tValue: 2\n\t\tPosible values:\n\t\t16 -> 1\n\t\t32 -> 2\n\t\t64 -> 3\n\nschemecolor - color\n\tDescription: ui_browse_properties_scheme_color\n\tR: 0.14902 G: 0.23137 B: 0.4 A: 1\nvisualizer - boolean\n\tDescription: <hr>Add Visualizer<hr>\n\tValue: 1'
pj=$(printf '%s\n' "$props_sample" | scall "$(new_testhome)" parse_lwe_properties)
assert_eq "parse_lwe_properties: one entry per property" "5" "$(jq 'length' <<<"$pj")"
assert_eq "parse_lwe_properties: slider range" "16 64 1" "$(jq -r '.[0] | "\(.min) \(.max) \(.step)"' <<<"$pj")"
assert_eq "parse_lwe_properties: combolist options" "32=2" "$(jq -r '.[2].options[1] | "\(.label)=\(.value)"' <<<"$pj")"
assert_eq "parse_lwe_properties: color components" "R: 0.14902 G: 0.23137 B: 0.4 A: 1" "$(jq -r '.[3].color' <<<"$pj")"
assert_eq "parse_lwe_properties: strips markup from labels" "Add Visualizer" "$(jq -r '.[4].label' <<<"$pj")"

thp=$(new_testhome)
assert_rc "scene_prop_set: stores a plain override" 0 "$(scall "$thp" scene_prop_set 222222 bloom 1; echo $?)"
assert_eq "scene_prop_set: override saved under the item id" "1" "$(jq -r '.sceneProperties["222222"].bloom' "$thp/.config/omarchy/wallpaper-engine.json")"
assert_rc "scene_prop_set: rejects shell metacharacters" 1 "$(scall "$thp" scene_prop_set 222222 bloom '$(reboot)'; echo $?)"
assert_rc "scene_prop_set: rejects a hostile property name" 1 "$(scall "$thp" scene_prop_set 222222 'a=b' 1; echo $?)"
scall "$thp" scene_prop_reset 222222 >/dev/null 2>&1
assert_eq "scene_prop_reset: drops the item's overrides" "null" "$(jq -r '.sceneProperties["222222"]' "$thp/.config/omarchy/wallpaper-engine.json")"

# ---- doctor ----
dj=$(scall "$thw" doctor_json 2>/dev/null)
assert_eq "doctor_json: reports every check with a known status" "true" \
  "$(jq '(length >= 8) and all(.[]; .status | IN("ok","warn","fail","info"))' <<<"$dj")"
assert_eq "doctor_json: warns that scenes need linux-wallpaperengine" "warn" "$(jq -r '.[] | select(.id=="lwe") | .status' <<<"$dj")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
