#!/bin/bash -p
# img — put an image in front of the human, in a Herdr side pane.
#
# The agent never renders anything itself. `show` writes the image into a cache
# directory and, the first time, opens ONE rail pane running imgrail-watch.sh.
# Every later `show` is a file write: the rail notices it. That is the whole
# safety argument — after the rail exists, nothing is ever typed into a pane
# that a human might be using, because nothing is typed at all.
#
# Herdr is selected by $HERDR_PANE_ID and never by asking which pane is
# "current", every call is addressed by id, and every input call targets only
# the pane the preceding `pane split` created.
#
# The shebang blocks exported shell functions and BASH_ENV before any command
# lookup. This fallback covers `bash img.sh`, which bypasses the shebang. The
# array expansion is a shell-level refusal that an environment variable cannot
# satisfy if a shadowed exec prevents the clean re-exec.
if [[ -n "${BASH_ENV:-}" || -n "${ENV:-}" ]] || case $- in *p*) false ;; *) true ;; esac; then
  exec /usr/bin/env -u BASH_ENV -u ENV -u POSIXLY_CORRECT "${BASH:-/bin/bash}" -p "$0" "$@"
fi
case $- in
  *p*) ;;
  *) : "${_img_guard[99]:?img: refusing to run because inherited shell functions could shadow commands}" ;;
esac

set -euo pipefail
umask 077

E_USAGE=1; E_BUSY=2; E_NOPANE=3; E_NORENDER=4   # exit 5 (no Kitty graphics) comes from the rail

die() { local code="$1"; shift; printf 'img: %s\n' "$*" >&2; exit "$code"; }

usage() {
  cat >&2 <<'USAGE'
usage: img.sh show <path> [caption] [--zoom N|fit]
       img.sh grid <job.json> [caption]
       img.sh status
       img.sh close

  show    cache the image and make sure the rail pane is up
  grid    cache a normalized grid job for pane-sized composition in the rail
  status  backend, rail pane, cache dir, renderer
  close   close the rail pane (refuses anything it did not open)

env: IMG_ZOOM (default fit, or percent of natural size), IMG_HERDR_WAIT,
     IMG_HERDR_TIMEOUT, IMG_POLL
USAGE
  exit "$E_USAGE"
}

STATE_DIR="${HOME:?img: HOME is required}/.cache/agent-images"
SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
WATCH_BIN="$SCRIPT_DIR/imgrail-watch.sh"
COMPOSER="$SCRIPT_DIR/image-grid.py"
HERDR_ID_RE='^[A-Za-z0-9]+:[A-Za-z0-9]+$'
IMG_HERDR_TIMEOUT="${IMG_HERDR_TIMEOUT:-3}"

ensure_state_dir() {
  [[ ! -L "$STATE_DIR" ]] || die "$E_USAGE" "state path is a symlink: $STATE_DIR"
  mkdir -p -- "$STATE_DIR" 2>/dev/null || true
  [[ -d "$STATE_DIR" && -O "$STATE_DIR" ]] \
    || die "$E_USAGE" "state dir is not a directory owned by this user: $STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null \
    || die "$E_USAGE" "cannot make state dir private: $STATE_DIR"
  STATE_DIR=$(cd -- "$STATE_DIR" && pwd -P)
}

check_herdr_timeout() {
  [[ "$IMG_HERDR_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
    || die "$E_USAGE" "IMG_HERDR_TIMEOUT must be a positive whole number of seconds: $IMG_HERDR_TIMEOUT"
}

# Absolute and cached: the calls that create a pane run before any
# argument is validated, and a relative PATH entry would resolve elsewhere.
HERDR_BIN=$(type -P herdr || true)
JQ_BIN=$(type -P jq || true)
[[ -z "$HERDR_BIN" || "$HERDR_BIN" == /* ]] || HERDR_BIN="$PWD/$HERDR_BIN"
[[ -z "$JQ_BIN" || "$JQ_BIN" == /* ]] || JQ_BIN="$PWD/$JQ_BIN"

# Zoom is either fit or a percentage of the image's natural cell size.
ZOOM_VALUE=""
set_zoom_value() {
  local z="${1:-${IMG_ZOOM:-fit}}"
  [[ "$z" == fit || ( "$z" =~ ^[0-9]+$ && "$z" -gt 0 ) ]] \
    || die "$E_USAGE" "zoom must be fit or a positive integer percent: $z"
  ZOOM_VALUE="$z"
}

# --- herdr plumbing -----------------------------------------------------
# Every Herdr call gets an outer deadline. The command wrapper writes its exit
# status into a FIFO, so an integer Bash `read -t` wakes immediately for fast
# calls and expires stalled calls without timeout(1). Bash 3.2 supports this.
run_bounded_for() {
  local seconds="$1"; shift
  local out="$STATE_DIR/.herdr-out-$$-$RANDOM"
  local gate="$STATE_DIR/.herdr-gate-$$-$RANDOM"
  local wrapper="" rc=0 child_rc="" fd_open=0
  local old_exit="" old_int="" old_term=""
  # Bash reports parent traps from inside a command substitution even though
  # it reset them for that subshell. Restoring those reported traps would make
  # the parent's EXIT cleanup run at the end of every substitution.
  if (( ${BASH_SUBSHELL:-0} == 0 )); then
    old_exit=$(trap -p EXIT || true)
    old_int=$(trap -p INT || true)
    old_term=$(trap -p TERM || true)
  fi

  bounded_cleanup() {
    if [[ -n "$wrapper" ]]; then
      kill -TERM "$wrapper" 2>/dev/null || true
      wait "$wrapper" 2>/dev/null || true
      wrapper=""
    fi
    if (( fd_open )); then exec 9>&-; fd_open=0; fi
    [[ -z "$gate" ]] || command rm -f -- "$gate"
    [[ -z "$out" ]] || command rm -f -- "$out"
  }
  bounded_abort() {
    local code="$1"
    trap - EXIT INT TERM
    bounded_cleanup
    # A direct call may sit inside a larger mutation guarded by the caller's
    # EXIT trap. Chain it only after bounded temp cleanup. In command
    # substitutions old_exit is deliberately empty, so no parent trap leaks in.
    [[ -z "$old_exit" ]] || eval "$old_exit"
    exit "$code"
  }
  bounded_restore_traps() {
    trap - EXIT INT TERM
    [[ -z "$old_exit" ]] || eval "$old_exit"
    [[ -z "$old_int" ]] || eval "$old_int"
    [[ -z "$old_term" ]] || eval "$old_term"
  }
  trap 'bounded_abort $?' EXIT
  trap 'bounded_abort 130' INT
  trap 'bounded_abort 143' TERM

  : > "$out"
  mkfifo -m 600 "$gate"
  exec 9<> "$gate"
  fd_open=1
  command rm -f -- "$gate"
  gate=""
  (
    trap - EXIT
    bounded_child=""; bounded_rc=0
    wrapper_abort() {
      trap - INT TERM
      if [[ -n "$bounded_child" ]]; then
        kill -TERM "$bounded_child" 2>/dev/null || true
        kill -KILL "$bounded_child" 2>/dev/null || true
        wait "$bounded_child" 2>/dev/null || true
      fi
      exit 143
    }
    trap wrapper_abort INT TERM
    command "$@" >"$out" 2>/dev/null </dev/null & bounded_child=$!
    wait "$bounded_child" || bounded_rc=$?
    trap - INT TERM
    printf '%s\n' "$bounded_rc" >&9
    exit "$bounded_rc"
  ) & wrapper=$!
  if IFS= read -r -t "$seconds" -u 9 child_rc; then
    wait "$wrapper" 2>/dev/null || true
    wrapper=""
    [[ "$child_rc" =~ ^[0-9]+$ ]] || bounded_abort 1
    rc="$child_rc"
  else
    kill -TERM "$wrapper" 2>/dev/null || true
    wait "$wrapper" 2>/dev/null || true
    wrapper=""
    rc=124
  fi
  exec 9>&-; fd_open=0
  command cat -- "$out"
  command rm -f -- "$out"
  out=""
  bounded_restore_traps
  unset -f bounded_cleanup bounded_abort bounded_restore_traps
  return "$rc"
}

herdr_call() {
  run_bounded_for "$IMG_HERDR_TIMEOUT" "$HERDR_BIN" "$@"
}

herdr_json() { herdr_call "$@" || true; }

# Once split returns an id, every refusal closes that fresh pane. This remains
# armed through the watcher proof and state write, then cmd_show disarms it.
IMG_PENDING_PANE=""
IMG_LAUNCH_DIR=""
cleanup_launch_dir() {
  local dir="$IMG_LAUNCH_DIR"
  IMG_LAUNCH_DIR=""
  [[ -z "$dir" ]] || rmdir -- "$dir" 2>/dev/null || true
}
cleanup_pending_pane() {
  local rc=$?
  trap - EXIT
  if [[ -n "$IMG_PENDING_PANE" && -n "$HERDR_BIN" ]]; then
    herdr_call pane close "$IMG_PENDING_PANE" >/dev/null || true
  fi
  cleanup_launch_dir
  exit "$rc"
}
trap cleanup_pending_pane EXIT

json_field() {
  [[ -n "$JQ_BIN" ]] || return 0
  printf '%s\n' "$1" | "$JQ_BIN" -r --arg f "$2" '
    [.. | objects | select(has($f)) | .[$f] | strings] | first // empty
  ' 2>/dev/null || true
}

require_pane() {
  [[ -n "$HERDR_BIN" ]] || die "$E_NOPANE" "herdr is not in PATH"
  [[ -n "$JQ_BIN" ]] || die "$E_NOPANE" "jq is required to read herdr answers"
  [[ "${HERDR_PANE_ID:-}" =~ $HERDR_ID_RE ]] \
    || die "$E_NOPANE" "no HERDR_PANE_ID — there is no pane to split"
}

PANE_LIVE=0; PANE_GONE=1; PANE_UNKNOWN=2
pane_state() {
  [[ -n "${1:-}" ]] || return $PANE_UNKNOWN
  local out rc=0
  out=$(herdr_call pane get "$1") || rc=$?
  # Herdr's payload is the authority because missing-pane errors do not always
  # have a reliable exit status. A wrapper timeout is different: even a partial
  # payload cannot prove the final result of a call that never completed.
  [[ $rc -ne 124 ]] || return $PANE_UNKNOWN
  [[ "$(json_field "$out" pane_id)" == "$1" ]] && return $PANE_LIVE
  [[ "$out" == *'"error"'* ]] && return $PANE_GONE
  return $PANE_UNKNOWN
}

# Outermost-first; the last name is what the pane is doing right now. A missing
# field and an empty array both yield nothing, so "unknown" never reads as idle.
herdr_fg_names() {
  local raw
  [[ -n "$JQ_BIN" ]] || return 0
  raw=$(herdr_json pane process-info --pane "$1")
  printf '%s\n' "$raw" | "$JQ_BIN" -r '
    .result.process_info
    | if type != "object" then error("process_info is not an object")
      elif (has("foreground_processes") | not) then empty
      else .foreground_processes
        | if type != "array" then error("foreground_processes is not an array")
          else map(
            if type == "object" and has("name") and (.name | type == "string")
               and (.name | test("^[A-Za-z0-9_.-]+$"))
            then .name else error("invalid foreground process") end
          ) | .[]
          end
      end
  ' 2>/dev/null || true
}

# Counted ticks, never a condition loop: the bound holds whether or not the
# thing being waited for ever happens. Validated in the main shell so a bad
# override cannot become an unbounded wait inside a subshell.
HERDR_TICKS=0
herdr_ticks() {
  HERDR_TICKS="${IMG_HERDR_WAIT:-100}"
  [[ "$HERDR_TICKS" =~ ^[0-9]+$ && "$HERDR_TICKS" -gt 0 ]] \
    || die "$E_USAGE" "IMG_HERDR_WAIT must be a positive integer: $HERDR_TICKS"
}

# Readiness fails closed: exactly one foreground process, and that one a login
# shell. Anything else is a pane still running its init, where a typed line is
# read by that process instead of the prompt.
herdr_wait_shell() {
  local i=0 names="" fg="" n=0; herdr_ticks; local max=$HERDR_TICKS
  while (( i < max )); do
    names=$(herdr_fg_names "$1")
    if [[ -n "$names" ]]; then
      n=$(printf '%s\n' "$names" | grep -c .)
      fg=$(printf '%s\n' "$names" | tail -n1)
      if (( n == 1 )); then
        case "$fg" in zsh|bash|sh|dash|ksh|fish) return 0 ;; esac
      fi
    fi
    sleep 0.1; i=$((i+1))
  done
  die "$E_BUSY" "new pane $1 is not at a shell prompt (foreground: ${names:-unknown}) — not typing into it"
}

# The process shape is a filter, not a proof: a shell builtin reading stdin
# (`read`, a passphrase prompt in an rc file) presents exactly the accepted
# shape. Only running something proves a prompt. The nonce is assembled by the
# command from two arguments, so the terminal's echo of the typed line cannot
# forge the match.
IMG_PROBE_ATTEMPTS=5
herdr_prove_prompt() {
  local id="$1" nonce ms attempt=0
  herdr_ticks
  ms=$((HERDR_TICKS * 100 / IMG_PROBE_ATTEMPTS)); (( ms > 0 )) || ms=100
  while (( attempt < IMG_PROBE_ATTEMPTS )); do
    nonce="$$-${RANDOM}${RANDOM}-$attempt"
    herdr_call pane run "$id" "printf '%s-%s\n' imgready $nonce" >/dev/null \
      || die "$E_NOPANE" "herdr could not probe pane $id"
    herdr_call pane wait-output "$id" --match "imgready-$nonce" \
      --source visible --timeout "$ms" >/dev/null && return 0
    attempt=$((attempt+1))
  done
  die "$E_BUSY" "pane $id never ran the probe ($IMG_PROBE_ATTEMPTS attempts) — something in it is reading input"
}

# --- rail state ---------------------------------------------------------
# The recorded id is validated, not trusted: the state dir is a cache path, and
# a corrupted record holding a pattern would otherwise aim `pane close` at
# whatever it matched.
PANE_MAGIC="img-pane-2"
pane_file() {
  local key="${HERDR_TAB_ID:-${HERDR_PANE_ID:-none}}"
  printf '%s/rail-%s.pane' "$STATE_DIR" "${key//[^A-Za-z0-9_-]/_}"
}

PANE_RECORD_ID=""
PANE_RECORD_TOKEN=""
load_pane_record() {
  PANE_RECORD_ID=""; PANE_RECORD_TOKEN=""
  local f; f=$(pane_file)
  [[ ! -L "$f" ]] || die "$E_USAGE" "pane record is a symlink: $f"
  [[ -e "$f" ]] || return 1
  [[ -f "$f" && -O "$f" ]] || die "$E_USAGE" "pane record is not a regular file owned by this user: $f"
  local magic="" p="" token="" extra=""
  { IFS= read -r magic || true; IFS= read -r p || true; IFS= read -r token || true; IFS= read -r extra || true; } < "$f"
  [[ "$magic" == "$PANE_MAGIC" && -z "$extra" ]] \
    || die "$E_USAGE" "pane record is not an img rail record: $f"
  p=$(printf '%s' "$p" | tr -d '[:space:]')
  [[ "$p" =~ $HERDR_ID_RE ]] || die "$E_USAGE" "pane record has an invalid pane id: $f"
  [[ "$token" =~ ^imgrail-[0-9]+-[0-9]+-[0-9]+$ ]] \
    || die "$E_USAGE" "pane record has an invalid ownership token: $f"
  PANE_RECORD_ID="$p"; PANE_RECORD_TOKEN="$token"
}

record_pane() {
  local id="$1" token="$2" f tmp
  f=$(pane_file); tmp="$STATE_DIR/.rail-record-$$-$RANDOM"
  [[ ! -L "$f" ]] || die "$E_USAGE" "pane record is a symlink: $f"
  printf '%s\n%s\n%s\n' "$PANE_MAGIC" "$id" "$token" > "$tmp"
  mv -f -- "$tmp" "$f"
}

# The record is only a lookup key. Ownership comes from the live process: the
# watcher must have the absolute script path and the record's unguessable token
# in the same argv. A shell name or a shaped state file proves nothing.
pane_owned() {
  local id="$1" token="$2" raw rc=0
  raw=$(herdr_call pane process-info --pane "$id") || rc=$?
  [[ $rc -ne 124 ]] || return 1
  printf '%s\n' "$raw" | "$JQ_BIN" -e --arg watch "$WATCH_BIN" --arg token "$token" '
    .result.process_info.foreground_processes
    | select(type == "array")
    | any(.[];
        (.argv? // null) as $argv
        | (($argv | type) == "array")
          and ($argv | all(.[]; type == "string"))
          and (($argv | index($watch)) != null)
          and (($argv | index("--owner-token")) as $token_i
               | $token_i != null and $argv[$token_i + 1] == $token))
  ' >/dev/null 2>&1
}

# chafa first: `kitten icat` needs the terminal to report its size in pixels,
# and a Herdr pane does not. Same order as the rail, so `status` never names a
# renderer the rail would not pick.
renderer() {
  local r
  r=$(type -P chafa || true);  [[ -n "$r" ]] && { printf 'chafa'; return 0; }
  r=$(type -P kitten || true); [[ -n "$r" ]] && { printf 'kitten'; return 0; }
  return 1
}

# --- cache --------------------------------------------------------------
# Entries sort by name, so the watcher's "newest" is a plain `ls | tail -1` and
# never a stat parade. The nonce keeps two shows in the same millisecond apart.
cache_put() {
  local src="$1" caption="$2" zoom="$3" ext base stamp dest
  [[ -f "$src" ]] || die "$E_USAGE" "no such file: $src"
  [[ -r "$src" ]] || die "$E_USAGE" "cannot read: $src"
  ext="${src##*.}"
  case "$ext" in
    png|PNG|jpg|JPG|jpeg|JPEG|gif|GIF|webp|WEBP|bmp|BMP|tif|TIF|tiff|TIFF) ;;
    *) die "$E_USAGE" "not an image extension: .$ext" ;;
  esac
  stamp=$(date -u +%Y%m%d-%H%M%S)
  base=$(basename -- "$src"); base="${base//[^A-Za-z0-9._-]/_}"
  dest="$STATE_DIR/${stamp}-$$-${base}"
  cp -- "$src" "$dest"
  [[ -n "$caption" ]] && printf '%s\n' "$caption" > "${dest}.caption"
  printf '%s\n' "$zoom" > "${dest}.zoom"
  printf '%s' "$dest"
}

cache_put_grid() {
  local src="$1" caption="$2" stamp dest staged
  [[ -f "$src" && -r "$src" ]] || die "$E_USAGE" "cannot read grid job: $src"
  stamp=$(date -u +%Y%m%d-%H%M%S)
  dest="$STATE_DIR/${stamp}-$$-$RANDOM.grid-job"
  if ! staged=$(python3 "$COMPOSER" "$src" --stage-dir "$dest" --caption "$caption" 2>&1); then
    die "$E_USAGE" "$staged"
  fi
  [[ "$staged" == "$dest/job.grid.json" && -f "$staged" && ! -L "$staged" ]] || {
    die "$E_USAGE" "grid staging did not produce a regular job"
  }
  printf '%s' "$staged"
}

# --- verbs --------------------------------------------------------------
cmd_show() {
  local path="" caption="" zoom=""
  while (( $# )); do
    case "$1" in
      --zoom) shift; [[ $# -gt 0 ]] || usage; zoom="$1" ;;
      --zoom=*) zoom="${1#--zoom=}" ;;
      -*) usage ;;
      *) if [[ -z "$path" ]]; then path="$1"; else caption="$caption${caption:+ }$1"; fi ;;
    esac
    shift
  done
  [[ -n "$path" ]] || usage
  set_zoom_value "$zoom"; zoom="$ZOOM_VALUE"
  ensure_state_dir
  check_herdr_timeout
  require_pane
  renderer >/dev/null || die "$E_NORENDER" "no renderer: install chafa or kitty (kitten)"

  local dest; dest=$(cache_put "$path" "$caption" "$zoom")

  ensure_rail "$dest" "$zoom"
}

cmd_grid() {
  local path="${1:-}" caption="${2:-image grid}"
  [[ $# -le 2 && -n "$path" ]] || usage
  set_zoom_value fit
  ensure_state_dir
  check_herdr_timeout
  require_pane
  renderer >/dev/null || die "$E_NORENDER" "no renderer: install chafa or kitty (kitten)"
  type -P python3 >/dev/null 2>&1 || die "$E_NORENDER" "python3 is required for image grids"
  [[ -x "$COMPOSER" ]] || die "$E_NORENDER" "grid composer is missing or not executable: $COMPOSER"

  local dest; dest=$(cache_put_grid "$path" "$caption")
  ensure_rail "$dest" fit
}

ensure_rail() {
  local dest="$1" zoom="$2"

  local rail="" token="" pane_status=0
  if load_pane_record; then
    rail="$PANE_RECORD_ID"; token="$PANE_RECORD_TOKEN"
    pane_state "$rail" || pane_status=$?
    if [[ $pane_status -eq $PANE_LIVE ]]; then
      pane_owned "$rail" "$token" \
        || die "$E_BUSY" "pane $rail is alive but does not run this img rail"
      # The reuse path. No herdr input call of any kind: the rail is watching
      # the cache directory and picks the new file up on its own.
      printf 'img: %s -> rail %s\n' "$(basename -- "$dest")" "$rail"
      return 0
    elif [[ $pane_status -eq $PANE_UNKNOWN ]]; then
      die "$E_BUSY" "could not determine whether recorded pane $rail is alive — record kept"
    fi
  fi

  [[ -x "$WATCH_BIN" ]] || die "$E_NORENDER" "watcher is missing or not executable: $WATCH_BIN"
  token="imgrail-$$-$RANDOM-$RANDOM"
  local cmd
  cmd="exec $(printf '%q' "$WATCH_BIN") --dir $(printf '%q' "$STATE_DIR") --zoom $(printf '%q' "$zoom") --owner-token $(printf '%q' "$token")"
  pane_split "$cmd" "$token"
  record_pane "$IMG_NEW_PANE" "$token"
  cleanup_launch_dir
  IMG_PENDING_PANE=""
  if [[ "$zoom" == fit ]]; then
    printf 'img: %s -> new rail %s (fit)\n' "$(basename -- "$dest")" "$IMG_NEW_PANE"
  else
    printf 'img: %s -> new rail %s (zoom %s%%)\n' "$(basename -- "$dest")" "$IMG_NEW_PANE" "$zoom"
  fi
}

# Result by global, not by stdout: a `die` inside $( … ) exits only the
# substitution subshell, and the caller would carry on with an empty pane id —
# a refusal that refuses nothing.
IMG_NEW_PANE=""
IMG_RECOVERED_PANE=""
make_launch_dir() {
  local i=0 candidate
  while (( i < 5 )); do
    candidate="$STATE_DIR/.launch-$$-$RANDOM-$RANDOM"
    if mkdir -m 700 -- "$candidate" 2>/dev/null; then
      IMG_LAUNCH_DIR="$candidate"
      return 0
    fi
    i=$((i + 1))
  done
  die "$E_USAGE" "could not create a private launch directory in $STATE_DIR"
}

# `pane split` can create its pane and then stall before the CLI prints the id.
# A fresh private cwd tags that mutation before the call. If the response has
# no id, pane list can recover exactly the pane with that cwd; no pre-existing
# pane could have entered a directory that did not exist before this split.
recover_split_pane() {
  IMG_RECOVERED_PANE=""
  local workspace="${HERDR_PANE_ID%%:*}" raw ids id n
  raw=$(herdr_json pane list --workspace "$workspace")
  ids=$(printf '%s\n' "$raw" | "$JQ_BIN" -r --arg cwd "$IMG_LAUNCH_DIR" '
    .result.panes
    | if type != "array" then error("panes is not an array")
      else .[]
        | select(type == "object" and .cwd? == $cwd)
        | .pane_id
        | select(type == "string")
      end
  ' 2>/dev/null || true)
  n=$(printf '%s\n' "$ids" | grep -c . || true)
  [[ $n -eq 1 ]] || return 1
  id=$(printf '%s\n' "$ids" | head -n1)
  [[ "$id" =~ $HERDR_ID_RE && "$id" != "$HERDR_PANE_ID" ]] || return 1
  IMG_RECOVERED_PANE="$id"
}

pane_split() {
  IMG_NEW_PANE=""
  make_launch_dir
  local cmd="$1" token="$2" out id
  out=$(herdr_json pane split --pane "$HERDR_PANE_ID" \
        --direction "${IMG_HERDR_DIRECTION:-right}" --cwd "$IMG_LAUNCH_DIR" --no-focus)
  id=$(json_field "$out" pane_id)
  if [[ ! "$id" =~ $HERDR_ID_RE || "$id" == "$HERDR_PANE_ID" ]]; then
    recover_split_pane \
      || die "$E_NOPANE" "herdr pane split returned no new pane id and no tagged pane could be recovered"
    id="$IMG_RECOVERED_PANE"
  fi
  IMG_PENDING_PANE="$id"
  herdr_json pane rename "$id" "${IMG_HERDR_LABEL:-img}" >/dev/null
  herdr_wait_shell "$id"
  herdr_prove_prompt "$id"
  # The only non-probe line img sends. It is safe because this pane did not
  # exist a moment ago, so it cannot hold a human's draft. Never widen this to
  # a pane that came from anywhere but the split above.
  herdr_call pane run "$id" "$cmd" >/dev/null \
    || die "$E_NOPANE" "herdr could not start the rail in $id"
  # `pane run` only proves that Herdr accepted the line. Wait until process-info
  # shows the exact watcher and ownership token before recording or succeeding.
  local i=0; herdr_ticks; local max=$HERDR_TICKS
  while (( i < max )); do
    pane_owned "$id" "$token" && { IMG_NEW_PANE="$id"; return 0; }
    sleep 0.1; i=$((i+1))
  done
  die "$E_NOPANE" "rail in pane $id did not stay alive"
}

cmd_status() {
  local rail="" token="" state="none" r="none" pane_status=0
  set_zoom_value ""
  ensure_state_dir
  check_herdr_timeout
  if load_pane_record; then
    rail="$PANE_RECORD_ID"; token="$PANE_RECORD_TOKEN"
    if [[ -n "$HERDR_BIN" && -n "$JQ_BIN" ]]; then
      pane_state "$rail" || pane_status=$?
      if [[ $pane_status -eq $PANE_LIVE ]]; then
        if pane_owned "$rail" "$token"; then state="alive"; else state="foreign"; fi
      elif [[ $pane_status -eq $PANE_GONE ]]; then
        state="stale"
      else
        state="unknown"
      fi
    else
      state="unknown"
    fi
  fi
  r=$(renderer || printf 'none')
  printf 'backend:    %s\n' "${HERDR_BIN:-missing}"
  printf 'this pane:  %s\n' "${HERDR_PANE_ID:-unset}"
  printf 'rail pane:  %s (%s)\n' "${rail:-none}" "$state"
  printf 'cache dir:  %s (%s images)\n' "$STATE_DIR" "$(list_images | grep -c . || true)"
  printf 'renderer:   %s\n' "$r"
}

list_images() {
  [[ -d "$STATE_DIR" ]] || return 0
  local f name
  for f in "$STATE_DIR"/*; do
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

cmd_close() {
  ensure_state_dir
  check_herdr_timeout
  require_pane
  local rail="" token="" pane_status=0
  load_pane_record || die "$E_USAGE" "no rail pane recorded — nothing to close"
  rail="$PANE_RECORD_ID"; token="$PANE_RECORD_TOKEN"
  pane_state "$rail" || pane_status=$?
  if [[ $pane_status -eq $PANE_GONE ]]; then
    rm -f -- "$(pane_file)"
    printf 'img: rail %s was already gone\n' "$rail"
    return 0
  elif [[ $pane_status -eq $PANE_UNKNOWN ]]; then
    die "$E_BUSY" "could not determine whether recorded pane $rail is alive — record kept"
  fi
  pane_owned "$rail" "$token" \
    || die "$E_BUSY" "pane $rail is alive but does not run this img rail"
  herdr_call pane close "$rail" >/dev/null \
    || die "$E_NOPANE" "herdr could not close rail $rail"
  rm -f -- "$(pane_file)"
  printf 'img: closed rail %s\n' "$rail"
}

main() {
  (( $# )) || usage
  local verb="$1"; shift
  case "$verb" in
    show)   cmd_show "$@" ;;
    grid)   cmd_grid "$@" ;;
    status) cmd_status ;;
    close)  cmd_close ;;
    -h|--help|help) usage ;;
    *) usage ;;
  esac
}

main "$@"
