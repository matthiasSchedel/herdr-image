#!/usr/bin/env bash
# imgrail-watch — the rail. Runs inside the Herdr side pane img.sh opened and
# redraws the newest image in the cache directory.
#
# It runs here, not in img.sh, for one reason: this process owns a tty. The
# Kitty graphics handshake and the terminal size are only knowable from inside
# the pane, and an agent's shell has neither.
#
# Keys: +/- zoom, 0 fits, n/p page, r redraws, q quits. Grids also use the
# arrow keys or h/j/k/l to move focus, Enter to open a cell, and g to return.
set -uo pipefail

E_USAGE=1; E_NORENDER=4; E_NOGRAPHICS=5

sanitize_text() { LC_ALL=C tr -d '\000-\037\177-\237'; }
die() {
  local code="$1" message
  shift
  message=$(printf '%s' "$*" | sanitize_text)
  printf 'imgrail: %s\n' "$message" >&2
  exit "$code"
}

DIR=""; ZOOM="${IMG_ZOOM:-fit}"; DEFAULT_ZOOM="$ZOOM"; POLL="${IMG_POLL:-1}"; RENDERER=""; OWNER_TOKEN=""
INTERACTIVE_ZOOM=""; CURRENT_ZOOM="fit"
GRID_TIMEOUT="${IMG_GRID_TIMEOUT:-3}"
TERMINAL_BACKGROUND="#111318"
SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
COMPOSER="$SCRIPT_DIR/image-grid.py"

parse_args() {
  while (( $# )); do
    case "$1" in
      --dir) shift; DIR="${1:-}" ;;
      --zoom) shift; ZOOM="${1:-}" ;;
      --owner-token) shift; OWNER_TOKEN="${1:-}" ;;
      *) die "$E_USAGE" "unknown argument: $1" ;;
    esac
    shift
  done
  [[ -n "$DIR" ]] || die "$E_USAGE" "--dir is required"
  [[ "$OWNER_TOKEN" =~ ^imgrail-[0-9]+-[0-9]+-[0-9]+$ ]] \
    || die "$E_USAGE" "--owner-token is required"
  [[ "$ZOOM" == fit || ( "$ZOOM" =~ ^[0-9]+$ && "$ZOOM" -gt 0 ) ]] \
    || die "$E_USAGE" "--zoom must be fit or a positive integer percent"
  DEFAULT_ZOOM="$ZOOM"
  [[ "$POLL" =~ ^[0-9]+$ && "$POLL" -gt 0 ]] || die "$E_USAGE" "IMG_POLL must be a positive integer"
  [[ "$GRID_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "$E_USAGE" "IMG_GRID_TIMEOUT must be a positive integer"
  # chafa first, and that order is load-bearing: `kitten icat` asks the terminal
  # for its size in pixels, which a Herdr pane does not report, and refuses with
  # "Terminal does not support reporting screen sizes in pixels". chafa is told
  # the size in cells and never asks. kitten is still used when chafa is absent,
  # with the window size handed to it explicitly.
  if type -P chafa >/dev/null 2>&1; then RENDERER=chafa
  elif type -P kitten >/dev/null 2>&1; then RENDERER=kitten
  else die "$E_NORENDER" "no renderer: install chafa or kitty (kitten)"; fi
}

# Ask the terminal whether it speaks Kitty graphics, and take silence for a no.
# The DA1 request rides along as the terminator: every terminal answers it, so
# an unsupported one still ends the read instead of burning the timeout.
parse_terminal_background() {
  local response="$1" red green blue color
  if [[ "$response" =~ $'\033]11;rgb:'([[:xdigit:]]{2,4})/([[:xdigit:]]{2,4})/([[:xdigit:]]{2,4}) ]]; then
    red="${BASH_REMATCH[1]:0:2}"; green="${BASH_REMATCH[2]:0:2}"; blue="${BASH_REMATCH[3]:0:2}"
    printf '#%s%s%s' "$red" "$green" "$blue" | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  if [[ "$response" =~ $'\033]11;'(#[[:xdigit:]]{6}) ]]; then
    color="${BASH_REMATCH[1]}"
    printf '%s' "$color" | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  return 1
}

graphics_supported() {
  [[ "${IMG_SKIP_QUERY:-}" == 1 ]] && return 0
  [[ -t 0 && -t 1 ]] || return 0   # no tty: nothing to ask, do not refuse
  local saved resp="" background=""
  saved=$(stty -g 2>/dev/null) || return 0
  stty raw -echo min 0 time 20 2>/dev/null || return 0
  printf '\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\033\\\033]11;?\a\033[c' >/dev/tty
  IFS= read -r -s -t 2 -d c resp </dev/tty || true
  stty "$saved" 2>/dev/null || true
  background=$(parse_terminal_background "$resp" || true)
  [[ -z "$background" ]] || TERMINAL_BACKGROUND="$background"
  [[ "$resp" == *"_Gi=31;OK"* ]]
}

# Cell pixels come from Herdr when it knows them. 8x16 is the same fallback
# Herdr itself uses, and being wrong here only changes the drawn size.
cell_w="${HERDR_CELL_WIDTH_PX:-8}"; cell_h="${HERDR_CELL_HEIGHT_PX:-16}"
[[ "$cell_w" =~ ^[0-9]+$ && "$cell_w" -gt 0 ]] || cell_w=8
[[ "$cell_h" =~ ^[0-9]+$ && "$cell_h" -gt 0 ]] || cell_h=16

# Pixel dimensions, asked of a tool that knows them. `file` is the last resort.
# Its JPEG description puts JFIF density before the encoded dimensions, so the
# final WxH pair is the image size. Choosing the largest pair mistakes 300-DPI
# metadata for the dimensions of a small image.
image_px() {
  local dims w h
  if type -P sips >/dev/null 2>&1; then
    dims=$(sips -g pixelWidth -g pixelHeight -- "$1" 2>/dev/null)
    w=$(printf '%s\n' "$dims" | awk '/pixelWidth/ {print $2}')
    h=$(printf '%s\n' "$dims" | awk '/pixelHeight/ {print $2}')
    if [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]]; then printf '%sx%s' "$w" "$h"; return 0; fi
  fi
  if type -P identify >/dev/null 2>&1; then
    dims=$(identify -format '%wx%h' -- "$1" 2>/dev/null | head -n1)
    [[ "$dims" =~ ^[0-9]+x[0-9]+$ ]] && { printf '%s' "$dims"; return 0; }
  fi
  dims=$(file -b -- "$1" 2>/dev/null | grep -Eo '[0-9]+ ?x ?[0-9]+' | tr -d ' ' | tail -n1)
  [[ -n "$dims" ]] || return 1
  printf '%s' "$dims"
}

# Natural size in cells, scaled by the zoom percent, then clamped to the pane
# with the aspect ratio kept — clamping width and height independently is how a
# tall image ends up stretched.
target_cells_for_area() {
  local px_w="$1" px_h="$2" max_c="$3" max_r="$4"
  local nat_c nat_r want_c want_r
  nat_c=$(( (px_w + cell_w - 1) / cell_w )); (( nat_c > 0 )) || nat_c=1
  nat_r=$(( (px_h + cell_h - 1) / cell_h )); (( nat_r > 0 )) || nat_r=1
  (( max_c > 0 )) || max_c=1
  (( max_r > 0 )) || max_r=1
  if [[ "$ZOOM" == fit ]]; then
    want_c=$max_c
    want_r=$(( nat_r * max_c / nat_c )); (( want_r > 0 )) || want_r=1
    if (( want_r > max_r )); then
      want_c=$(( nat_c * max_r / nat_r )); (( want_c > 0 )) || want_c=1
      want_r=$max_r
    fi
  else
    want_c=$(( nat_c * ZOOM / 100 )); (( want_c > 0 )) || want_c=1
    want_r=$(( nat_r * ZOOM / 100 )); (( want_r > 0 )) || want_r=1
  fi
  if (( want_c > max_c || want_r > max_r )); then
    # Fit against the limiting edge directly. A fixed-point scale factor can
    # truncate to zero for ratios above 1000:1 and collapse a wide image to 1x1.
    if (( want_c * max_r >= want_r * max_c )); then
      want_r=$(( want_r * max_c / want_c )); (( want_r > 0 )) || want_r=1
      want_c=$max_c
    else
      want_c=$(( want_c * max_r / want_r )); (( want_c > 0 )) || want_c=1
      want_r=$max_r
    fi
  fi
  printf '%s %s' "$want_c" "$want_r"
}

target_cells() {
  local cols="$3" rows="$4"
  target_cells_for_area "$1" "$2" "$(( cols - 1 ))" "$(( rows - 3 ))"
}

images() {
  local f name
  for f in "$DIR"/*; do
    if [[ -d "$f" && ! -L "$f" && -f "$f/job.grid.json" && ! -L "$f/job.grid.json" ]]; then
      printf '%s\n' "$f/job.grid.json"
      continue
    fi
    [[ -f "$f" && ! -L "$f" ]] || continue
    name="${f##*/}"
    case "$name" in *.caption|*.zoom|*.pane|.*) continue ;; esac
    printf '%s\n' "$f"
  done | sort
}

caption_of() {
  [[ -f "$1.caption" ]] && head -n1 -- "$1.caption" 2>/dev/null || basename -- "$1"
}

zoom_of() {
  local value="$DEFAULT_ZOOM"
  [[ -f "$1.zoom" ]] && { IFS= read -r value < "$1.zoom"; } 2>/dev/null
  if [[ "$value" == fit || ( "$value" =~ ^[0-9]+$ && "$value" -gt 0 ) ]]; then
    printf '%s' "$value"
  else
    printf 'fit'
  fi
}

GRID_PAGE=0
GRID_TOTAL=1
GRID_FILE=""
GRID_FOCUS=0
GRID_COUNT=0
GRID_NAV_LEFT=0
GRID_NAV_RIGHT=0
GRID_NAV_UP=0
GRID_NAV_DOWN=0
GRID_OPEN=0
KEY_PENDING=()
READ_KEY=""
ESCAPE_TIMEOUT=0.05

# Decode one terminal key without losing bytes that do not form a supported
# escape sequence. The short follow-up reads admit fragmented arrow sequences
# while keeping a lone Escape independent of the rail's poll interval.
read_terminal_char() {
  local timeout="$1" value=""
  if IFS= read -r -s -n1 -t "$timeout" value; then
    if [[ -n "$value" ]]; then READ_KEY="$value"; else READ_KEY=ENTER; fi
    return 0
  fi
  return 1
}

# Bash 3.2 accepts only whole seconds for `read -t`. Python already backs grid
# composition, and select gives its tty or pipe one short, portable byte wait.
read_escape_char() {
  local python encoded
  python=$(type -P python3 2>/dev/null) || return 1
  encoded=$("$python" -c '
import os
import select
import sys
import termios
import tty

fd = 0
saved = None
try:
    if os.isatty(fd):
        saved = termios.tcgetattr(fd)
        tty.setcbreak(fd, termios.TCSANOW)
    ready, _, _ = select.select([fd], [], [], float(sys.argv[1]))
    if ready:
        value = os.read(fd, 1)
        if value:
            sys.stdout.write(value.hex())
finally:
    if saved is not None:
        termios.tcsetattr(fd, termios.TCSANOW, saved)
' "$ESCAPE_TIMEOUT" 2>/dev/null) || return 1
  [[ "$encoded" =~ ^[[:xdigit:]]{2}$ ]] || return 1
  if [[ "$encoded" == 0a || "$encoded" == 0d ]]; then
    READ_KEY=ENTER
  else
    printf -v READ_KEY "\\x$encoded"
  fi
}

pending_key() {
  KEY_PENDING[${#KEY_PENDING[@]}]="$1"
}

read_terminal_key() {
  local timeout="$1" prefix="" final=""
  READ_KEY=""
  if (( ${#KEY_PENDING[@]} )); then
    READ_KEY="${KEY_PENDING[0]}"
    KEY_PENDING=("${KEY_PENDING[@]:1}")
    return 0
  fi
  read_terminal_char "$timeout" || return 1
  [[ "$READ_KEY" == $'\033' ]] || return 0
  read_escape_char || { READ_KEY=ESC; return 0; }
  prefix="$READ_KEY"
  if [[ "$prefix" != "[" && "$prefix" != "O" ]]; then
    pending_key "$prefix"
    READ_KEY=ESC
    return 0
  fi
  if ! read_escape_char; then
    pending_key "$prefix"
    READ_KEY=ESC
    return 0
  fi
  final="$READ_KEY"
  case "$final" in
    A) READ_KEY=UP ;;
    B) READ_KEY=DOWN ;;
    C) READ_KEY=RIGHT ;;
    D) READ_KEY=LEFT ;;
    *) pending_key "$prefix"; pending_key "$final"; READ_KEY=ESC ;;
  esac
}

composer_with_deadline() {
  python3 - "$GRID_TIMEOUT" "$@" <<'PY'
import subprocess, sys

timeout = int(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    stdout, stderr = process.communicate(timeout=timeout)
except subprocess.TimeoutExpired:
    process.kill()
    stdout, stderr = process.communicate()
    sys.stderr.buffer.write(stderr)
    sys.stderr.write("image-grid: composer deadline exceeded\n")
    raise SystemExit(124)
sys.stdout.buffer.write(stdout)
sys.stderr.buffer.write(stderr)
raise SystemExit(process.returncode)
PY
}

compose_grid_page() {
  local job="$1" px_w="$2" px_h="$3" stem out answer actual total focus count left right up down log meta
  local -a command
  [[ -x "$COMPOSER" ]] || { printf 'imgrail: grid composer is missing: %s\n' "$COMPOSER" >&2; return 1; }
  type -P python3 >/dev/null 2>&1 || { printf 'imgrail: python3 is required for grids\n' >&2; return 1; }
  stem=$(basename -- "$job"); stem="${stem//[^A-Za-z0-9._-]/_}"
  out="$DIR/.grid-${stem}-${px_w}x${px_h}-${GRID_PAGE}.png"
  log="$DIR/.render.log"
  command=(python3 "$COMPOSER" "$job" --width "$px_w" --height "$px_h" \
    --page "$GRID_PAGE" --focus "$GRID_FOCUS" --background "$TERMINAL_BACKGROUND" --output "$out" --json)
  (( GRID_OPEN == 0 )) || command+=(--open-focus)
  answer=$(composer_with_deadline "${command[@]}" 2>>"$log") || return 1
  meta=$(printf '%s' "$answer" | python3 -c '
import json, sys
d = json.load(sys.stdin)
n = d["focus_navigation"]
print("\t".join(str(v) for v in (d["page"], d["page_count"], d["focus"],
    d["page_cell_count"], n["left"], n["right"], n["up"], n["down"])))
' 2>>"$log") || return 1
  IFS=$'\t' read -r actual total focus count left right up down <<< "$meta"
  [[ "$actual" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ && "$total" -gt 0 \
    && "$focus" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ && "$count" -gt 0 \
    && "$left" =~ ^[0-9]+$ && "$right" =~ ^[0-9]+$ && "$up" =~ ^[0-9]+$ && "$down" =~ ^[0-9]+$ ]] || return 1
  GRID_PAGE=$((actual - 1)); GRID_TOTAL="$total"
  GRID_FOCUS="$focus"; GRID_COUNT="$count"
  GRID_NAV_LEFT="$left"; GRID_NAV_RIGHT="$right"; GRID_NAV_UP="$up"; GRID_NAV_DOWN="$down"
  GRID_FILE="$out"
}

pane_geometry() {
  local cols rows
  cols=$(tput cols 2>/dev/null || printf 80)
  rows=$(tput lines 2>/dev/null || printf 24)
  [[ "$cols" =~ ^[0-9]+$ && "$cols" -gt 0 ]] || cols=80
  [[ "$rows" =~ ^[0-9]+$ && "$rows" -gt 0 ]] || rows=24
  printf '%s %s' "$cols" "$rows"
}

render_signature() {
  printf '%s:%s:%s:%s:%s:%s' "$1" "$GRID_PAGE" "$GRID_FOCUS" "$GRID_OPEN" "$INTERACTIVE_ZOOM" "$2"
}

draw() {
  local file="$1" idx="$2" total="$3" cols="$4" rows="$5" dims px_w px_h size c r display_file zoom_label keys
  local max_c=$(( cols - 1 )) max_r=$(( rows - 3 )) image_y=2 title=""
  (( max_c > 0 )) || max_c=1
  (( max_r > 0 )) || max_r=1
  printf '\033[2J\033[H'
  if [[ -z "$file" ]]; then
    printf 'imgrail — no images yet in %s\n' "$(printf '%s' "$DIR" | sanitize_text)"
    return 0
  fi
  display_file="$file"; GRID_TOTAL=1
  if [[ "$file" == *.grid.json ]]; then
    if (( GRID_OPEN )); then
      max_r="$rows"; (( max_r > 0 )) || max_r=1
      image_y=0
    fi
    compose_grid_page "$file" "$(( max_c * cell_w ))" "$(( max_r * cell_h ))" \
      || { printf '\033[31mgrid compose failed\033[0m — %s\n' "$(tail -n1 "$DIR/.render.log" 2>/dev/null | sanitize_text)"; return 0; }
    display_file="$GRID_FILE"
    zoom_label="page $((GRID_PAGE + 1))/$GRID_TOTAL, cell $((GRID_FOCUS + 1))/$GRID_COUNT"
    keys="arrows/h/j/k/l move, Enter open, g grid, n/p page, +/- zoom, 0 fit, r redraw, q quit"
    if (( GRID_OPEN )); then
      zoom_label="cell $((GRID_FOCUS + 1))/$GRID_COUNT open"
    fi
  else
    CURRENT_ZOOM=$(zoom_of "$file")
    zoom_label="$CURRENT_ZOOM"; [[ "$CURRENT_ZOOM" == fit ]] || zoom_label="${CURRENT_ZOOM}%"
    keys="n/p history, +/- zoom, 0 fit, r redraw, q quit"
  fi
  if [[ -n "$INTERACTIVE_ZOOM" ]]; then
    CURRENT_ZOOM="$INTERACTIVE_ZOOM"
    zoom_label="$zoom_label, zoom $CURRENT_ZOOM"; [[ "$CURRENT_ZOOM" == fit ]] || zoom_label="${zoom_label}%"
  elif [[ "$file" == *.grid.json ]]; then
    CURRENT_ZOOM=fit
  fi
  ZOOM="$CURRENT_ZOOM"
  if [[ "$file" == *.grid.json ]] && (( GRID_OPEN )); then
    title=$(printf '[%s/%s] %s (%s; %s)' \
      "$idx" "$total" "$(caption_of "$file" | sanitize_text)" "$zoom_label" "$keys" | sanitize_text)
    printf '\033]2;%s\a' "$title"
  else
    printf '\033[1m[%s/%s]\033[0m %s \033[2m(%s; %s)\033[0m\n' \
      "$idx" "$total" "$(caption_of "$file" | sanitize_text)" "$zoom_label" "$keys"
  fi
  dims=$(image_px "$display_file" || printf '')
  if [[ -n "$dims" ]]; then
    px_w="${dims%%x*}"; px_h="${dims##*x}"
    size=$(target_cells_for_area "$px_w" "$px_h" "$max_c" "$max_r")
    c="${size%% *}"; r="${size##* }"
  else
    c="$max_c"; r="$max_r"
  fi
  # Renderer stderr goes to a log rather than /dev/null: "render failed" with no
  # reason is the one failure mode nobody can debug from inside a pane.
  local log="$DIR/.render.log"
  if [[ "$RENDERER" == chafa ]]; then
    chafa -f kitty --size "${c}x${r}" -- "$display_file" 2>>"$log" \
      || printf '\033[31mrender failed\033[0m — %s\n' "$(tail -n1 "$log" 2>/dev/null | sanitize_text)"
  else
    kitten icat --transfer-mode=stream --align=left --scale-up \
      --use-window-size "$cols,$rows,$(( cols * cell_w )),$(( rows * cell_h ))" \
      --place "${c}x${r}@0x${image_y}" "$display_file" 2>>"$log" \
      || printf '\033[31mrender failed\033[0m — %s\n' "$(tail -n1 "$log" 2>/dev/null | sanitize_text)"
  fi
}

adjust_zoom() {
  local delta="$1" base
  base="$INTERACTIVE_ZOOM"
  [[ -n "$base" ]] || base="$CURRENT_ZOOM"
  [[ "$base" =~ ^[0-9]+$ ]] || base=100
  base=$((base + delta))
  (( base < 25 )) && base=25
  (( base > 400 )) && base=400
  INTERACTIVE_ZOOM="$base"
  last_seen=""
}

handle_key() {
  local key="$1" current_file="${2:-}"
  case "$key" in
    q) return 10 ;;
    n)
      if [[ "$current_file" == *.grid.json && $((GRID_PAGE + 1)) -lt $GRID_TOTAL ]]; then
        GRID_PAGE=$((GRID_PAGE + 1)); GRID_FOCUS=0; GRID_OPEN=0
      elif (( cursor > 0 )); then
        cursor=$((cursor - 1)); active_file=""
      fi
      last_seen=""
      ;;
    p)
      if [[ "$current_file" == *.grid.json && $GRID_PAGE -gt 0 ]]; then
        GRID_PAGE=$((GRID_PAGE - 1)); GRID_FOCUS=0; GRID_OPEN=0
      else
        cursor=$((cursor + 1)); active_file=""
      fi
      last_seen=""
      ;;
    r) last_seen="" ;;
    +) adjust_zoom 25 ;;
    -) adjust_zoom -25 ;;
    0) INTERACTIVE_ZOOM=fit; last_seen="" ;;
    h|LEFT) [[ "$current_file" == *.grid.json ]] && { GRID_FOCUS="$GRID_NAV_LEFT"; GRID_OPEN=0; last_seen=""; } ;;
    l|RIGHT) [[ "$current_file" == *.grid.json ]] && { GRID_FOCUS="$GRID_NAV_RIGHT"; GRID_OPEN=0; last_seen=""; } ;;
    k|UP) [[ "$current_file" == *.grid.json ]] && { GRID_FOCUS="$GRID_NAV_UP"; GRID_OPEN=0; last_seen=""; } ;;
    j|DOWN) [[ "$current_file" == *.grid.json ]] && { GRID_FOCUS="$GRID_NAV_DOWN"; GRID_OPEN=0; last_seen=""; } ;;
    ENTER)
      if [[ "$current_file" == *.grid.json && $GRID_COUNT -gt 0 ]]; then
        GRID_OPEN=1; last_seen=""
      fi
      ;;
    g) [[ "$current_file" == *.grid.json ]] && { GRID_OPEN=0; last_seen=""; } ;;
  esac
}

# Sourced with IMG_WATCH_LIB=1, this file is just its functions: the sizing
# arithmetic is the part worth testing, and starting the loop to reach it is not
# a test, it is a hang.
[[ "${IMG_WATCH_LIB:-}" == 1 ]] && return 0

# Anything else that writes to stderr, Bash's own error messages included,
# can quote a file name. Route it through the sanitizer, keeping only newlines.
exec 2> >(LC_ALL=C tr -d '\000-\011\013-\037\177-\237' >&2)

parse_args "$@"

graphics_supported || die "$E_NOGRAPHICS" \
  "this terminal did not answer the Kitty graphics query — in Herdr set [experimental] kitty_graphics = true, then: herdr server reload-config"

cleanup() { printf '\033[?25h\n'; }
trap cleanup EXIT
trap 'exit 0' INT TERM

printf '\033[?25l'
cursor=0        # 0 = follow the newest, >0 = that many entries back
last_seen=""
active_file=""
while :; do
  # Filled by a read loop, not mapfile: this has to run on Apple's bash 3.2.
  files=()
  current=""
  while IFS= read -r line; do files+=("$line"); done < <(images)
  total=${#files[@]}
  geometry=$(pane_geometry); cols="${geometry%% *}"; rows="${geometry##* }"
  if (( total == 0 )); then
    signature="__empty__:$geometry"
    [[ "$last_seen" == "$signature" ]] || { draw "" 0 0 "$cols" "$rows"; last_seen="$signature"; }
  else
    (( cursor >= total )) && cursor=$(( total - 1 ))
    idx=$(( total - 1 - cursor ))
    current="${files[$idx]}"
    if [[ "$current" != "$active_file" ]]; then
      GRID_PAGE=0; GRID_FOCUS=0; GRID_OPEN=0; active_file="$current"
    fi
    signature=$(render_signature "$current" "$geometry")
    if [[ "$signature" != "$last_seen" ]]; then
      draw "$current" "$(( idx + 1 ))" "$total" "$cols" "$rows"
      last_seen=$(render_signature "$current" "$geometry")
    fi
  fi
  # One bounded read is both the key handler and the poll interval: no spin,
  # and no separate sleep that would swallow keystrokes.
  key=""
  if read_terminal_key "$POLL"; then key="$READ_KEY"; fi
  handle_key "$key" "$current" || [[ $? -ne 10 ]] || exit 0
done
