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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
