#!/usr/bin/env bash
# Assertions travel to `check` as strings and are evaluated there: single
# quotes are deliberate, and their variables look unused to shellcheck.
# shellcheck disable=SC2016,SC2034
set -uo pipefail

PYTHON_SITE="$(python3 -c 'import os, PIL; print(os.path.dirname(os.path.dirname(PIL.__file__)))')"
export PYTHONPATH="$PYTHON_SITE${PYTHONPATH:+:$PYTHONPATH}"

REPO_ROOT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
SKILL_DIR="$REPO_ROOT/skills/show-image"
IMG="$SKILL_DIR/scripts/img.sh"
IMG_ALIAS="$REPO_ROOT/skills/img/scripts/img.sh"
WATCH="$SKILL_DIR/scripts/imgrail-watch.sh"
COMPOSER="$SKILL_DIR/scripts/image-grid.py"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
has_capture_file() {
  local file
  for file in "$1"/.herdr-out-*; do [[ -e "$file" ]] && return 0; done
  return 1
}
has_bounded_temp_file() {
  local file
  for file in "$1"/.herdr-out-* "$1"/.herdr-gate-*; do
    [[ -e "$file" ]] && return 0
  done
  return 1
}
has_launch_dir() {
  local dir
  for dir in "$1"/.launch-*; do [[ -d "$dir" ]] && return 0; done
  return 1
}
private_dirs() {
  local dir
  for dir in "$@"; do mkdir -p "$dir" && chmod 700 "$dir"; done
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
LOG="$ROOT/calls.log"
TEST_HOME="$ROOT/home"
CACHE="$TEST_HOME/.cache/agent-images"
FAKE="$ROOT/fake"
mkdir -p "$BIN" "$CACHE" "$FAKE"
: >"$LOG"

# A valid 64x64 PNG, so `file` reports real pixel dimensions.
printf '\x89PNG\r\n\x1a\n' >"$ROOT/pic.png"
python3 - "$ROOT/pic.png" <<'PY'
import struct, sys, zlib
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
w = h = 64
raw = b''.join(b'\x00' + b'\xff\x00\x00' * w for _ in range(h))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open(sys.argv[1], 'wb').write(png)
PY

cat >"$BIN/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >>"$IMG_TEST_LOG"
if [[ -n "${IMG_FAKE_STALL_ON:-}" && "$*" == *"$IMG_FAKE_STALL_ON"* ]]; then
  if [[ "${IMG_FAKE_STALL_ONCE:-0}" != 1 || ! -f "$IMG_FAKE_STATE/stalled" ]]; then
    : > "$IMG_FAKE_STATE/stalled"
    sleep "${IMG_FAKE_STALL_SECONDS:-3}"
  fi
fi
case "$1 $2" in
  "pane split")
    if [[ "${IMG_FAKE_SPLIT_TIMEOUT_AFTER_CREATE:-0}" == 1 ]]; then
      prev=""
      for arg in "$@"; do
        [[ "$prev" == --cwd ]] && printf '%s\n' "$arg" > "$IMG_FAKE_STATE/split-cwd"
        prev="$arg"
      done
      sleep "${IMG_FAKE_STALL_SECONDS:-3}"
      exit 124
    fi
    printf '{"result":{"pane":{"pane_id":"wT:p9"}}}\n' ;;
  "pane list")
    if [[ -f "$IMG_FAKE_STATE/split-cwd" ]]; then
      cwd=$(cat "$IMG_FAKE_STATE/split-cwd")
      printf '{"result":{"panes":[{"pane_id":"wT:p9","workspace_id":"wT","tab_id":"wT:t1","cwd":"%s"}]}}\n' "$cwd"
    else
      printf '{"result":{"panes":[]}}\n'
    fi ;;
  "pane get")
    case " ${IMG_FAKE_PANES:-} " in
      *" $3 "*) printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
      *) printf '{"error":{"code":"pane_not_found"}}\n'; exit 1 ;;
    esac ;;
  "pane process-info")
    if [[ -n "${IMG_FAKE_FG:-}" ]]; then
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"%s","argv":["%s"],"pid":1}]}}}\n' \
        "$IMG_FAKE_FG" "$IMG_FAKE_FG"
    elif [[ -f "$IMG_FAKE_STATE/watcher" ]]; then
      token=$(cat "$IMG_FAKE_STATE/watcher")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"bash","argv":["bash"],"pid":1},{"name":"imgrail-watch.sh","argv":["%s","--dir","%s","--owner-token","%s"],"pid":2}]}}}\n' \
        "$IMG_TEST_WATCH" "$HOME/.cache/agent-images" "$token"
    else
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"bash","argv":["bash"],"pid":1}]}}}\n'
    fi ;;
  "pane wait-output")
    match="$5"
    [[ -f "$IMG_FAKE_STATE/output" ]] && grep -Fqx -- "$match" "$IMG_FAKE_STATE/output" \
      || exit 1
    : > "$IMG_FAKE_STATE/proved" ;;
  "pane run")
    cmd="$4"
    case "$cmd" in
      *"imgready "*)
        nonce="${cmd##*imgready }"
        [[ "${IMG_FAKE_NO_PROBE_OUTPUT:-0}" == 1 ]] \
          || printf 'imgready-%s\n' "$nonce" > "$IMG_FAKE_STATE/output"
        ;;
      *imgrail-watch.sh*)
        [[ -f "$IMG_FAKE_STATE/proved" ]] || exit 9
        if [[ "${IMG_FAKE_WATCH_START:-ok}" == ok ]]; then
          token="${cmd##*--owner-token }"; token="${token%% *}"
          printf '%s\n' "$token" > "$IMG_FAKE_STATE/watcher"
        fi
        ;;
    esac ;;
  "pane rename") printf '{"result":{}}\n' ;;
  "pane close")
    [[ "${IMG_FAKE_CLOSE:-ok}" == ok ]] || exit 7
    rm -f "$IMG_FAKE_STATE/watcher"
    printf '{"result":{}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
SH
chmod +x "$BIN/herdr"

# A renderer must exist for `show` to get past its refusal; the fake is never
# executed, only found on PATH.
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/kitten"
chmod +x "$BIN/kitten"

export IMG_TEST_LOG="$LOG"
export IMG_TEST_WATCH="$WATCH"
export IMG_FAKE_STATE="$FAKE"
export PATH="$BIN:$PATH"
export HOME="$TEST_HOME"
export HERDR_PANE_ID="wT:p1"
export HERDR_TAB_ID="wT:t1"
export IMG_HERDR_WAIT=5
BOUNDED_BASH="${IMG_TEST_BASH32:-/bin/bash}"
bounded_bash_version=$("$BOUNDED_BASH" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')
if [[ -n "${IMG_TEST_BASH32:-}" ]]; then
  check "the requested bounded-call runtime is Bash 3.2" '[[ "$bounded_bash_version" == 3.2 ]]'
fi

printf 'img\n'

# --- refusals -----------------------------------------------------------
out=$(env -u HERDR_PANE_ID "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
check "no HERDR_PANE_ID refuses with exit 3" '[[ $rc -eq 3 ]]'
check "and says why" '[[ "$out" == *HERDR_PANE_ID* ]]'

# A PATH with herdr and jq but no renderer: the refusal must be about the
# renderer, not about herdr being missing.
mkdir -p "$ROOT/norender"
ln -sf "$BIN/herdr" "$ROOT/norender/herdr"
ln -sf "$(type -P jq)" "$ROOT/norender/jq"
for tool in dirname mkdir chmod; do ln -sf "$(type -P "$tool")" "$ROOT/norender/$tool"; done
out=$(PATH="$ROOT/norender" "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
check "no renderer refuses with exit 4" '[[ $rc -eq 4 ]]'
check "and names the renderer" '[[ "$out" == *renderer* ]]'

out=$("$IMG" show "$ROOT/missing.png" 2>&1); rc=$?
check "missing file refuses with exit 1" '[[ $rc -eq 1 ]]'

out=$("$IMG" show "$ROOT/pic.png" --zoom 0 2>&1); rc=$?
check "zoom 0 refuses with exit 1" '[[ $rc -eq 1 ]]'

out=$(printf 'not an image' >"$ROOT/notes.txt"; "$IMG" show "$ROOT/notes.txt" 2>&1); rc=$?
check "non-image extension refuses with exit 1" '[[ $rc -eq 1 ]]'

out=$(IMG_ZOOM=wat "$IMG" status 2>&1); rc=$?
check "status refuses an invalid IMG_ZOOM in the main shell" '[[ $rc -eq 1 && "$out" == *"positive integer"* ]]'

# A direct invocation must ignore exported functions, and `bash img.sh` must
# re-exec cleanly before BASH_ENV can redirect command lookup.
POISON="$ROOT/poisoned"
type() { : > "$POISON"; builtin type "$@"; }
export -f type
out=$("$IMG" status 2>&1); rc=$?
unset -f type
check "bash -p ignores an inherited function that shadows type" '[[ $rc -eq 0 && ! -e "$POISON" ]]'

cat > "$ROOT/bash-env" <<'SH'
type() { : > "$IMG_POISON_MARK"; builtin type "$@"; }
SH
out=$(IMG_POISON_MARK="$POISON" BASH_ENV="$ROOT/bash-env" bash "$IMG" status 2>&1); rc=$?
check "bash invocation strips BASH_ENV before resolving herdr" '[[ $rc -eq 0 && ! -e "$POISON" ]]'

# Pin the reported sink too: Bash permits a function whose name is the absolute
# Herdr path. Without the privileged re-exec, command lookup calls that function
# even though img cached an absolute binary path.
printf 'function %s { : > "$IMG_POISON_MARK"; return 91; }\n' "$BIN/herdr" > "$ROOT/bash-env-herdr"
POISON_HOME="$ROOT/poison-home"; POISON_CACHE="$POISON_HOME/.cache/agent-images"; POISON_FAKE="$ROOT/poison-fake"
private_dirs "$POISON_CACHE" "$POISON_FAKE"
out=$(IMG_POISON_MARK="$POISON" BASH_ENV="$ROOT/bash-env-herdr" \
  HOME="$POISON_HOME" IMG_FAKE_STATE="$POISON_FAKE" \
  bash "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
check "BASH_ENV cannot shadow the absolute Herdr binary" '[[ $rc -eq 0 && ! -e "$POISON" ]]'

# Refuse the predictable record path before opening a pane. The symlink target
# is the behavioral assertion: a truncate-through-symlink bug destroys it.
SYMLINK_HOME="$ROOT/symlink-home"; SYMLINK_CACHE="$SYMLINK_HOME/.cache/agent-images"
private_dirs "$SYMLINK_CACHE"
printf 'keep me\n' > "$ROOT/victim"
ln -s "$ROOT/victim" "$SYMLINK_CACHE/rail-wT_t1.pane"
: > "$LOG"
out=$(HOME="$SYMLINK_HOME" "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
check "a symlinked pane record is refused" '[[ $rc -eq 1 ]]'
check "the symlink target survives unchanged" '[[ "$(cat "$ROOT/victim")" == "keep me" ]]'
check "the symlink refusal happens before a pane is split" '! grep -q "pane split" "$LOG"'

# Magic plus a plausible pane id is not ownership. The live process must carry
# the token that img passed to its watcher.
SHAPED_HOME="$ROOT/shaped-home"; SHAPED_CACHE="$SHAPED_HOME/.cache/agent-images"
private_dirs "$SHAPED_CACHE"
printf 'img-pane-2\nwT:p9\nimgrail-1-2-3\n' > "$SHAPED_CACHE/rail-wT_t1.pane"
: > "$LOG"
out=$(HOME="$SHAPED_HOME" IMG_FAKE_PANES=wT:p9 "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
check "show refuses a shaped record for an unrelated live pane" '[[ $rc -eq 2 ]]'
check "show does not type into or split beside the unrelated pane" '! grep -qE "pane (run|split)" "$LOG"'
out=$(HOME="$SHAPED_HOME" IMG_FAKE_PANES=wT:p9 "$IMG" close 2>&1); rc=$?
check "close refuses the unrelated live pane even when it runs bash" '[[ $rc -eq 2 ]]'

# --- first show opens the rail -----------------------------------------
: >"$LOG"
out=$("$IMG" show "$ROOT/pic.png" "first caption" --zoom 50 2>&1); rc=$?
check "first show succeeds" '[[ $rc -eq 0 ]]'
check "first show reports a new rail" '[[ "$out" == *"new rail wT:p9"* ]]'
check "first show reports the applied zoom" '[[ "$out" == *"zoom 50%"* ]]'
check "image landed in the cache" '[[ $(find "$CACHE" -name "*pic.png" | wc -l) -eq 1 ]]'
check "caption landed next to it" '[[ $(find "$CACHE" -name "*pic.png.caption" | wc -l) -eq 1 ]]'
check "zoom landed next to the image" '[[ "$(cat "$CACHE"/*pic.png.zoom)" == 50 ]]'
check "the state directory is private" '[[ "$(LC_ALL=C ls -ld "$CACHE")" == drwx------* ]]'
check "the split is addressed at this pane" 'grep -q "pane split --pane wT:p1" "$LOG"'
check "the split never uses --current" '! grep -q -- "--current" "$LOG"'
check "the rail command is the watcher" 'grep -q "imgrail-watch.sh" "$LOG"'
check "the watcher is aimed at the just-split pane" \
  '[[ $(grep "pane run wT:p9 exec" "$LOG" | wc -l) -eq 1 ]]'

# The load-bearing assertion, same shape as nv's: input goes to exactly one
# pane, and it is the one the split created.
runs=$(grep -c "^herdr pane run " "$LOG")
probe_runs=$(grep -c "^herdr pane run wT:p9 printf" "$LOG")
real_runs=$(grep -c "^herdr pane run wT:p9 exec" "$LOG")
check "every pane run targets wT:p9" '[[ $runs -eq $((probe_runs + real_runs)) ]]'
check "exactly one of them is the rail command" '[[ $real_runs -eq 1 ]]'

# `pane run` succeeding only means the line was accepted. If the watcher exits,
# show must close the fresh pane and leave no ownership record.
DEAD_HOME="$ROOT/dead-home"; DEAD_CACHE="$DEAD_HOME/.cache/agent-images"; DEAD_FAKE="$ROOT/dead-fake"
private_dirs "$DEAD_CACHE" "$DEAD_FAKE"
: > "$LOG"
out=$(HOME="$DEAD_HOME" IMG_FAKE_STATE="$DEAD_FAKE" \
  IMG_FAKE_WATCH_START=exit "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
check "show refuses when the watcher never becomes the foreground process" '[[ $rc -eq 3 ]]'
check "a dead watcher is never recorded" '[[ ! -e "$DEAD_CACHE/rail-wT_t1.pane" ]]'
check "the fresh pane is closed after watcher startup fails" 'grep -q "pane close wT:p9" "$LOG"'

# Herdr may create the pane and then stall before its CLI returns the id. The
# unique launch cwd lets img recover that exact pane instead of losing it.
SPLIT_HOME="$ROOT/split-home"; SPLIT_CACHE="$SPLIT_HOME/.cache/agent-images"; SPLIT_FAKE="$ROOT/split-fake"
private_dirs "$SPLIT_CACHE" "$SPLIT_FAKE"
: > "$LOG"; started=$(date +%s)
out=$(HOME="$SPLIT_HOME" IMG_FAKE_STATE="$SPLIT_FAKE" \
  IMG_FAKE_SPLIT_TIMEOUT_AFTER_CREATE=1 IMG_HERDR_TIMEOUT=1 \
  "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
elapsed=$(( $(date +%s) - started ))
check "show recovers a pane created before a split timeout" \
  '[[ $rc -eq 0 && $elapsed -lt 3 && -f "$SPLIT_CACHE/rail-wT_t1.pane" ]]'
check "split timeout recovery identifies the pane through Herdr" 'grep -q "pane list --workspace wT" "$LOG"'
close_rc=99
if [[ -f "$SPLIT_CACHE/rail-wT_t1.pane" ]]; then
  HOME="$SPLIT_HOME" IMG_FAKE_STATE="$SPLIT_FAKE" \
    IMG_FAKE_PANES=wT:p9 "$IMG" close >/dev/null 2>&1
  close_rc=$?
fi
check "the recovered split stays owned and can be closed" \
  '[[ $close_rc -eq 0 && ! -e "$SPLIT_CACHE/rail-wT_t1.pane" ]]'

# The fake only allows the watcher command after wait-output matched the exact
# nonce emitted by the probe. This fails if prompt proof is removed or reduced
# to trusting wait-output's exit code.
NOPROOF_HOME="$ROOT/noproof-home"; NOPROOF_CACHE="$NOPROOF_HOME/.cache/agent-images"; NOPROOF_FAKE="$ROOT/noproof-fake"
private_dirs "$NOPROOF_CACHE" "$NOPROOF_FAKE"
: > "$LOG"
out=$(HOME="$NOPROOF_HOME" IMG_FAKE_STATE="$NOPROOF_FAKE" \
  IMG_FAKE_NO_PROBE_OUTPUT=1 "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
check "a prompt probe without matching output is refused" '[[ $rc -eq 2 ]]'
check "the watcher command is never sent without prompt proof" '! grep -q "pane run wT:p9 exec" "$LOG"'

# --- reuse types nothing ------------------------------------------------
export IMG_FAKE_PANES="wT:p9"
: >"$LOG"
out=$("$IMG" show "$ROOT/pic.png" "second caption" --zoom 350 2>&1); rc=$?
check "second show succeeds" '[[ $rc -eq 0 ]]'
check "second show reuses the rail" '[[ "$out" == *"-> rail wT:p9"* ]]'
check "reuse does not claim an unapplied zoom" '[[ "$out" != *"zoom 350"* ]]'
check "reuse sends no input at all" '! grep -q "pane run" "$LOG"'
check "reuse does not split" '! grep -q "pane split" "$LOG"'
check "both images are in the cache" '[[ $(find "$CACHE" -name "*pic.png" | wc -l) -eq 2 ]]'
check "reuse records the new image zoom without typing into the pane" \
  '[[ "$(cat "$CACHE"/*pic.png.zoom | sort | tr "\n" " ")" == "350 50 " ]]'

ln -s "$ROOT/pic.png" "$ROOT/symlink-grid-source.png"
printf '{"layout":"grid","cells":[{"path":"%s","label":"pic"}]}' "$ROOT/symlink-grid-source.png" > "$ROOT/symlink-grid.json"
out=$("$IMG" grid "$ROOT/symlink-grid.json" "unsafe grid" 2>&1); rc=$?
check "grid staging refuses to follow a source-image symlink" \
  '[[ $rc -eq 1 && "$out" == *"without following links"* && $(find "$CACHE" -name "job.grid.json" | wc -l) -eq 0 ]]'

cp "$ROOT/pic.png" "$ROOT/grid-source.png"
printf '{"layout":"grid","cells":[{"path":"%s","label":"pic"}]}' "$ROOT/grid-source.png" > "$ROOT/grid.json"
: > "$LOG"
out=$("$IMG" grid "$ROOT/grid.json" "test grid" 2>&1); rc=$?
check "a grid job reuses the live rail" '[[ $rc -eq 0 && "$out" == *"-> rail wT:p9"* ]]'
staged_job=$(find "$CACHE" -name "job.grid.json" | head -n1)
staged_image=$(find "$CACHE" -path "*/sources/*" -type f | head -n1)
check "a grid job is published with private staged sources" \
  '[[ -f "$staged_job" && -f "$staged_image" && "$(LC_ALL=C ls -ld "$(dirname "$staged_job")")" == drwx------* ]]'
before_stage=$(python3 - "$staged_image" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)
rm -f "$ROOT/grid-source.png"
ln -s "$ROOT/victim" "$ROOT/grid-source.png"
stage_meta=$(python3 "$COMPOSER" "$staged_job" --width 320 --height 240 --output "$ROOT/staged.png" --json 2>&1); stage_rc=$?
after_stage=$(python3 - "$staged_image" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)
check "retargeting an accepted source cannot change or break the queued page" \
  '[[ $stage_rc -eq 0 && -f "$ROOT/staged.png" && "$before_stage" == "$after_stage" ]]'
check "grid reuse sends no pane input and opens no pane" '! grep -qE "pane (run|split)" "$LOG"'

# --- status / close ----------------------------------------------------
out=$("$IMG" status 2>&1)
check "status names the rail" '[[ "$out" == *"wT:p9 (alive)"* ]]'
check "status names the cache" '[[ "$out" == *"$CACHE"* ]]'
check "status names the renderer" '[[ "$out" == *"chafa"* || "$out" == *"kitten"* ]]'
check "status does not claim an unobserved watcher zoom" '[[ "$out" != *"zoom:"* ]]'

# Every Herdr path has an outer deadline. The fake sleeps longer than the
# deadline; elapsed time and retained state prove the caller did not just wait.
started=$(date +%s)
out=$(IMG_FAKE_STALL_ON="pane get" IMG_HERDR_TIMEOUT=1 "$IMG" status 2>&1); rc=$?
elapsed=$(( $(date +%s) - started ))
check "a stalled JSON Herdr query is bounded" '[[ $rc -eq 0 && $elapsed -lt 3 ]]'

# Process startup makes twenty 0.05-second sleeps take about two seconds on
# macOS. Model that overhead so the test proves the deadline uses wall time,
# not a count of sleep calls.
SLOW_BIN="$ROOT/slow-bin"; BOUND_HOME="$ROOT/bound-home"; BOUND_CACHE="$BOUND_HOME/.cache/agent-images"
private_dirs "$SLOW_BIN" "$BOUND_CACHE"
cat > "$SLOW_BIN/sleep" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == 0.05 ]]; then
  exec /bin/sleep 0.10
fi
exec /bin/sleep "$@"
SH
chmod +x "$SLOW_BIN/sleep"
started=$(python3 -c 'import time; print(time.monotonic())')
PATH="$SLOW_BIN:$PATH" HOME="$BOUND_HOME" \
  "$BOUNDED_BASH" -p -c 'source "$1" status >/dev/null; run_bounded_for 1 sleep 10 >/dev/null' \
  _ "$IMG"
rc=$?
elapsed=$(python3 -c 'import sys, time; print(time.monotonic() - float(sys.argv[1]))' "$started")
check "a one-second bound does not fire before 0.8 seconds" \
  '[[ $rc -eq 124 ]] && awk -v elapsed="$elapsed" "BEGIN { exit !(elapsed >= 0.8) }"'
check "a one-second bound returns in under 1.5 seconds" \
  'awk -v elapsed="$elapsed" "BEGIN { exit !(elapsed < 1.5) }"'
check "a timed-out bounded call removes its output and FIFO paths" \
  '! has_bounded_temp_file "$BOUND_CACHE"'

# Production captures Herdr output through a command substitution. Put that
# exact shape in its own process group, interrupt the group, and require the
# substitution subshell to remove its own output and FIFO paths.
INT_HOME="$ROOT/interrupt-home"; INT_CACHE="$INT_HOME/.cache/agent-images"
private_dirs "$INT_CACHE"
HOME="$INT_HOME" python3 -c '
import os, sys
os.setsid()
script = "source \"$1\" status >/dev/null; answer=$(run_bounded_for 10 sleep 10); printf %s \"$answer\" >/dev/null"
os.execv(sys.argv[1], [sys.argv[1], "-p", "-c", script, "_", sys.argv[2]])
' "$BOUNDED_BASH" "$IMG" &
bounded_pid=$!
i=0
while [[ $i -lt 100 ]] && ! has_capture_file "$INT_CACHE"; do
  sleep 0.01
  i=$((i + 1))
done
kill -TERM "-$bounded_pid" 2>/dev/null || true
wait "$bounded_pid" 2>/dev/null || true
i=0
while [[ $i -lt 100 ]] && has_bounded_temp_file "$INT_CACHE"; do
  sleep 0.01
  i=$((i + 1))
done
check "an interrupted bounded command substitution removes its output and FIFO paths" \
  '! has_bounded_temp_file "$INT_CACHE"'

# No answer is not evidence that a pane is gone. Reuse and close must preserve
# the record and refuse instead of opening a replacement or forgetting a live
# rail whose pane query timed out.
UNKNOWN_HOME="$ROOT/unknown-home"; UNKNOWN_CACHE="$UNKNOWN_HOME/.cache/agent-images"; UNKNOWN_FAKE="$ROOT/unknown-fake"
private_dirs "$UNKNOWN_CACHE" "$UNKNOWN_FAKE"
cp "$CACHE/rail-wT_t1.pane" "$UNKNOWN_CACHE/rail-wT_t1.pane"
cp "$FAKE/watcher" "$UNKNOWN_FAKE/watcher"
: > "$LOG"; started=$(date +%s)
out=$(HOME="$UNKNOWN_HOME" IMG_FAKE_STATE="$UNKNOWN_FAKE" \
  IMG_FAKE_STALL_ON="pane get" IMG_HERDR_TIMEOUT=1 \
  "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
elapsed=$(( $(date +%s) - started ))
check "show refuses when pane liveness is unknown" '[[ $rc -eq 2 && $elapsed -lt 3 ]]'
check "unknown liveness does not split or replace the record" \
  '! grep -q "pane split" "$LOG" && [[ -f "$UNKNOWN_CACHE/rail-wT_t1.pane" ]]'
: > "$LOG"; started=$(date +%s)
out=$(HOME="$UNKNOWN_HOME" IMG_FAKE_STATE="$UNKNOWN_FAKE" \
  IMG_FAKE_STALL_ON="pane get" IMG_HERDR_TIMEOUT=1 \
  "$IMG" close 2>&1); rc=$?
elapsed=$(( $(date +%s) - started ))
check "close refuses when pane liveness is unknown" '[[ $rc -eq 2 && $elapsed -lt 3 ]]'
check "unknown liveness keeps the pane and ownership record" \
  '! grep -q "pane close" "$LOG" && [[ -f "$UNKNOWN_CACHE/rail-wT_t1.pane" ]]'

WAIT_HOME="$ROOT/wait-home"; WAIT_CACHE="$WAIT_HOME/.cache/agent-images"; WAIT_FAKE="$ROOT/wait-fake"
private_dirs "$WAIT_CACHE" "$WAIT_FAKE"
started=$(date +%s)
out=$(HOME="$WAIT_HOME" IMG_FAKE_STATE="$WAIT_FAKE" \
  IMG_FAKE_STALL_ON="pane wait-output" IMG_FAKE_STALL_ONCE=1 \
  IMG_HERDR_TIMEOUT=1 "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
elapsed=$(( $(date +%s) - started ))
check "a stalled wait-output is bounded and retried" '[[ $rc -eq 0 && $elapsed -lt 3 ]]'

RUN_HOME="$ROOT/run-home"; RUN_CACHE="$RUN_HOME/.cache/agent-images"; RUN_FAKE="$ROOT/run-fake"
private_dirs "$RUN_CACHE" "$RUN_FAKE"
: > "$LOG"; started=$(date +%s)
out=$(HOME="$RUN_HOME" IMG_FAKE_STATE="$RUN_FAKE" \
  IMG_FAKE_STALL_ON="pane run wT:p9 exec" IMG_HERDR_TIMEOUT=1 \
  "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
elapsed=$(( $(date +%s) - started ))
check "a stalled watcher pane run is bounded" '[[ $rc -eq 3 && $elapsed -lt 3 ]]'
check "a timed-out watcher start closes the fresh pane" 'grep -q "pane close wT:p9" "$LOG" && [[ ! -e "$RUN_CACHE/rail-wT_t1.pane" ]]'

# A direct bounded call owns the script's outer pending-pane EXIT trap. If the
# process group is interrupted during rename, bounded cleanup must run first,
# then chain to that outer cleanup so the fresh pane and launch tag are removed.
DIRECT_HOME="$ROOT/direct-home"; DIRECT_CACHE="$DIRECT_HOME/.cache/agent-images"; DIRECT_FAKE="$ROOT/direct-fake"
private_dirs "$DIRECT_CACHE" "$DIRECT_FAKE"
: > "$LOG"
HOME="$DIRECT_HOME" IMG_FAKE_STATE="$DIRECT_FAKE" \
  IMG_FAKE_STALL_ON="pane rename" IMG_FAKE_STALL_SECONDS=10 \
  python3 -c '
import os, sys
os.setsid()
os.execv(sys.argv[1], [sys.argv[1], "show", sys.argv[2]])
' "$IMG" "$ROOT/pic.png" &
direct_pid=$!
i=0
while [[ $i -lt 200 ]] && ! grep -q "pane rename wT:p9" "$LOG"; do
  sleep 0.01
  i=$((i + 1))
done
kill -TERM "-$direct_pid" 2>/dev/null || true
wait "$direct_pid" 2>/dev/null; direct_rc=$?
i=0
while [[ $i -lt 100 ]] && { has_bounded_temp_file "$DIRECT_CACHE" || has_launch_dir "$DIRECT_CACHE"; }; do
  sleep 0.01
  i=$((i + 1))
done
check "direct interruption reaches the split-pane rename" \
  'grep -q "pane split --pane wT:p1" "$LOG" && grep -q "pane rename wT:p9" "$LOG"'
check "direct interruption preserves exit 143 and closes the pending pane" \
  '[[ $direct_rc -eq 143 ]] && grep -q "pane close wT:p9" "$LOG"'
check "direct interruption removes bounded and launch temp state" \
  '! has_bounded_temp_file "$DIRECT_CACHE" && ! has_launch_dir "$DIRECT_CACHE"'
check "direct interruption never records the unfinished rail" \
  '[[ ! -e "$DIRECT_CACHE/rail-wT_t1.pane" ]]'

out=$(IMG_FAKE_FG=vim "$IMG" close 2>&1); rc=$?
check "close refuses a pane taken over" '[[ $rc -eq 2 ]]'

: > "$LOG"; started=$(date +%s)
out=$(IMG_FAKE_STALL_ON="pane close" IMG_HERDR_TIMEOUT=1 "$IMG" close 2>&1); rc=$?
elapsed=$(( $(date +%s) - started ))
check "a stalled Herdr close is bounded and reported" '[[ $rc -eq 3 && $elapsed -lt 3 ]]'
check "a timed-out close keeps the ownership record" '[[ -f "$CACHE/rail-wT_t1.pane" ]]'

: > "$LOG"
out=$(IMG_FAKE_CLOSE=fail "$IMG" close 2>&1); rc=$?
check "close surfaces a failed Herdr close" '[[ $rc -eq 3 ]]'
check "a failed close keeps the ownership record" '[[ -f "$CACHE/rail-wT_t1.pane" ]]'

out=$("$IMG" close 2>&1); rc=$?
check "close closes the rail it opened" '[[ $rc -eq 0 && "$out" == *"closed rail wT:p9"* ]]'
check "close forgets the rail" '[[ ! -f "$CACHE/rail-wT_t1.pane" ]]'

# The alias is a symlink to show-image. Launch through it, then prove the
# canonical entrypoint recognizes and closes the same watcher.
MIXED_HOME="$ROOT/mixed-home"; MIXED_CACHE="$MIXED_HOME/.cache/agent-images"; MIXED_FAKE="$ROOT/mixed-fake"
private_dirs "$MIXED_CACHE" "$MIXED_FAKE"
: > "$LOG"
out=$(HOME="$MIXED_HOME" IMG_FAKE_STATE="$MIXED_FAKE" \
  "$IMG_ALIAS" show "$ROOT/pic.png" 2>&1); rc=$?
check "alias launch starts a rail" '[[ $rc -eq 0 && "$out" == *"new rail wT:p9"* ]]'
out=$(HOME="$MIXED_HOME" IMG_FAKE_STATE="$MIXED_FAKE" \
  "$IMG" show "$ROOT/pic.png" 2>&1); rc=$?
check "canonical show reuses an alias-launched rail" \
  '[[ $rc -eq 0 && "$out" == *"-> rail wT:p9"* && $(grep -c "pane split" "$LOG") -eq 1 ]]'
out=$(HOME="$MIXED_HOME" IMG_FAKE_STATE="$MIXED_FAKE" "$IMG" status 2>&1); rc=$?
check "canonical status owns an alias-launched rail" '[[ $rc -eq 0 && "$out" == *"wT:p9 (alive)"* ]]'
out=$(HOME="$MIXED_HOME" IMG_FAKE_STATE="$MIXED_FAKE" "$IMG" close 2>&1); rc=$?
check "canonical close closes an alias-launched rail" '[[ $rc -eq 0 && ! -e "$MIXED_CACHE/rail-wT_t1.pane" ]]'

# `clear` used to accept an arbitrary directory and unlink every regular file
# in it. The command and override are intentionally gone rather than guarded.
FOREIGN_DIR="$ROOT/foreign-state"
mkdir -m 700 "$FOREIGN_DIR"
printf 'keep me\n' > "$FOREIGN_DIR/keep-me.txt"
out=$(IMG_STATE_DIR="$FOREIGN_DIR" "$IMG" clear 2>&1); rc=$?
check "clear is unavailable" '[[ $rc -eq 1 ]]'
check "clear never removes a file the skill did not write" \
  '[[ "$(cat "$FOREIGN_DIR/keep-me.txt")" == "keep me" ]]'
check "IMG_STATE_DIR cannot redirect the skill cache" '[[ "$out" != *"$FOREIGN_DIR"* ]]'

# Stock macOS find has no -maxdepth. A shim that rejects it must be irrelevant
# to status, and the actual files are the source of truth.
BSD_BIN="$ROOT/bsd-bin"; BSD_HOME="$ROOT/bsd-home"; BSD_CACHE="$BSD_HOME/.cache/agent-images"
mkdir -p "$BSD_BIN" "$BSD_CACHE"
cat > "$BSD_BIN/chmod" <<'SH'
#!/usr/bin/env bash
printf 'chmod %s\n' "$*" >> "$IMG_BSD_CHMOD_LOG"
for arg in "$@"; do
  [[ "$arg" != -- ]] || exit 64
done
exec /bin/chmod "$@"
SH
cat > "$BSD_BIN/find" <<'SH'
#!/usr/bin/env bash
printf 'find %s\n' "$*" >> "$IMG_BSD_FIND_LOG"
[[ " $* " != *" -maxdepth "* ]] || exit 64
exec /usr/bin/find "$@"
SH
chmod +x "$BSD_BIN/chmod" "$BSD_BIN/find"
printf image > "$BSD_CACHE/one.png"
printf caption > "$BSD_CACHE/one.png.caption"
: > "$ROOT/bsd-chmod.log"; : > "$ROOT/bsd-find.log"
out=$(PATH="$BSD_BIN:$PATH" IMG_BSD_CHMOD_LOG="$ROOT/bsd-chmod.log" \
  IMG_BSD_FIND_LOG="$ROOT/bsd-find.log" \
  HOME="$BSD_HOME" "$IMG" status 2>&1); rc=$?
check "status works with BSD chmod that rejects --" '[[ $rc -eq 0 ]]'
check "the portable state path gives chmod no GNU option marker" \
  '! grep -q -- " --" "$ROOT/bsd-chmod.log"'
check "status counts images without GNU find" '[[ $rc -eq 0 && "$out" == *"(1 images)"* ]]'
check "the portable image path never invokes find" '[[ ! -s "$ROOT/bsd-find.log" ]]'

# Audit only shipped scripts. The fixture proves every detector fires without
# making its deliberately non-portable examples match the real source audit.
portable_source() {
  python3 - "$@" <<'PY'
import pathlib
import re
import sys

checks = (
    ("chmod/chown --", re.compile(r"\b(?:chmod|chown)\b[^\n;|&]*?(?<!\S)--(?=\s|$)")),
    ("find -maxdepth", re.compile(r"\bfind\b[^\n;|&]*?(?<!\S)-maxdepth(?=\s|$)")),
    ("stat -c", re.compile(r"\bstat\b[^\n;|&]*?(?<!\S)-c(?=\s|$)")),
    ("readlink -f", re.compile(r"\breadlink\b[^\n;|&]*?(?<!\S)-f(?=\s|$)")),
    ("sed -i without an argument", re.compile(r"\bsed\b[^\n;|&]*?(?<!\S)-i(?=\s|$)(?![ \t]+(?:''|\"\"))")),
    ("date -d", re.compile(r"\bdate\b[^\n;|&]*?(?<!\S)-d(?=\s|$)")),
    ("grep -P", re.compile(r"\bgrep\b[^\n;|&]*?(?<!\S)-P(?=\s|$)")),
)

found = []
for name in sys.argv[1:]:
    source = pathlib.Path(name).read_text()
    source = re.sub(r"\\\n", " ", source)
    source = "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("#")
    )
    for label, pattern in checks:
        for _ in pattern.finditer(source):
            found.append(f"{name}: {label}")

print("\n".join(found))
sys.exit(bool(found))
PY
}

BAD_PORTABILITY="$ROOT/bad-portability.sh"
cat > "$BAD_PORTABILITY" <<'SH'
chmod 700 -- cache
chown user -- cache
find cache -maxdepth 1
stat -c %U cache
readlink -f cache
sed -i 's/a/b/' file
date -d yesterday
grep -P pattern file
SH
portability_out=$(portable_source "$BAD_PORTABILITY"); portability_rc=$?
check "the source audit recognizes every forbidden portability form" \
  '[[ $portability_rc -ne 0 && $(printf "%s\n" "$portability_out" | grep -c .) -eq 8 ]]'
portability_out=$(portable_source "$SKILL_DIR/scripts/"*.sh); portability_rc=$?
check "skill scripts contain no forbidden GNU-only forms" \
  '[[ $portability_rc -eq 0 && -z "$portability_out" ]]'

# --- zoom arithmetic ----------------------------------------------------
# target_cells is where the zoom percent becomes cells, so it is called for
# real against a fixed cell size, not re-derived here.
cells() {
  IMG_WATCH_LIB=1 HERDR_CELL_WIDTH_PX=8 HERDR_CELL_HEIGHT_PX=16 \
  bash -c 'source "$1"; ZOOM="$2"; target_cells "$3" "$4" "$5" "$6"' _ "$WATCH" "$@"
}
check "200%% doubles a 64x64 image (8x4 cells -> 16x8)" '[[ "$(cells 200 64 64 200 200)" == "16 8" ]]'
check "100%% keeps natural size" '[[ "$(cells 100 64 64 200 200)" == "8 4" ]]'
check "50%% halves it" '[[ "$(cells 50 64 64 200 200)" == "4 2" ]]'
check "a wide image is clamped to the pane" '[[ "$(cells 200 1600 200 41 40)" == "40 2" ]]'
check "clamping keeps the aspect ratio" \
  '[[ "$(cells 200 640 640 21 40)" == "20 10" ]]'
check "an extreme wide ratio uses the pane width instead of collapsing to 1x1" \
  '[[ "$(cells 200 1000000000 1 41 40)" == "40 1" ]]'
check "an extreme tall ratio uses the pane height instead of collapsing to 1x1" \
  '[[ "$(cells 200 1 1000000000 41 40)" == "1 37" ]]'
check "a tiny pane still gets one cell" '[[ "$(cells 200 640 640 1 1)" == "1 1" ]]'
check "fit uses the pane while preserving aspect" '[[ "$(cells fit 64 64 41 40)" == "40 20" ]]'
default_cells=$(env -u IMG_ZOOM IMG_WATCH_LIB=1 HERDR_CELL_WIDTH_PX=8 HERDR_CELL_HEIGHT_PX=16 \
  bash -c 'source "$1"; target_cells 64 64 41 40' _ "$WATCH")
check "the watcher defaults to fit behavior" '[[ "$default_cells" == "40 20" ]]'
rm -f "$CACHE"/*pic.png.zoom 2>/dev/null || true
out=$("$IMG" show "$ROOT/staged.png" 2>&1); rc=$?
default_zoom=$(find "$CACHE" -name "*staged.png.zoom" -exec cat {} \; | tail -n1)
check "img.sh defaults to fit behavior" '[[ $rc -eq 0 && "$default_zoom" == fit ]]'

# A command substitution gives tput a pipe rather than the rail tty. A
# terminfo implementation may then return its 80x24 default, which must not
# override the pane's real size from stty. If both live queries are silent,
# the geometry learned from the terminal handshake remains usable.
GEOMETRY_BIN="$ROOT/geometry-bin"
mkdir -p "$GEOMETRY_BIN"
cat > "$GEOMETRY_BIN/tput" <<'SH'
#!/usr/bin/env bash
if [[ "${IMG_TEST_TPUT_SILENT:-0}" == 1 ]]; then exit 1; fi
case "${1:-}" in
  cols) printf '80\n' ;;
  lines) printf '24\n' ;;
  *) exit 1 ;;
esac
SH
cat > "$GEOMETRY_BIN/stty" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == size ]] || exit 1
[[ -n "${IMG_TEST_STTY_SIZE:-}" ]] || exit 1
printf '%s\n' "$IMG_TEST_STTY_SIZE"
SH
chmod +x "$GEOMETRY_BIN/tput" "$GEOMETRY_BIN/stty"
geometry=$(PATH="$GEOMETRY_BIN:$PATH" IMG_WATCH_LIB=1 IMG_TEST_STTY_SIZE='40 164' \
  bash -c 'source "$1"; pane_geometry' _ "$WATCH")
check "the pane tty size beats tput's 80x24 terminfo default" '[[ "$geometry" == "164 40" ]]'
geometry=$(PATH="$GEOMETRY_BIN:$PATH" IMG_WATCH_LIB=1 IMG_TEST_STTY_SIZE='' \
  IMG_TEST_TPUT_SILENT=1 bash -c \
  'source "$1"; terminal_cols=100; terminal_rows=30; pane_geometry' _ "$WATCH")
check "silent live geometry falls back to the terminal handshake" '[[ "$geometry" == "100 30" ]]'

# Every string derived from a file or child process is scrubbed before it can
# reach the rail tty. OSC 52 and line-control bytes must become inert text.
osc_name=$(printf 'bad\tline\rspoof\n\033]52;c;SGVsbG8=\a.png')
touch "$CACHE/$osc_name"
safe_name=$(IMG_WATCH_LIB=1 bash -c 'source "$1"; caption_of "$2" | sanitize_text' _ "$WATCH" "$CACHE/$osc_name")
check "rail diagnostics strip every C0 byte and OSC 52 introducer" \
  '[[ "$safe_name" == "badlinespoof]52;c;SGVsbG8=.png" && "$safe_name" != *[$'"'"'\001'"'"'-$'"'"'\037'"'"']* ]]'
rm -f "$CACHE/$osc_name"

# An unreadable sidecar makes Bash print an error that quotes the file name.
# That error must not carry the name's control bytes to the rail tty.
osc_base="$CACHE/$(printf 'side\033]52;c;SGVsbG8=\a')"
touch "$osc_base.zoom" "$osc_base.caption"; chmod 000 "$osc_base.zoom" "$osc_base.caption"
sidecar_err=$(IMG_WATCH_LIB=1 bash -c 'source "$1"; zoom_of "$2" >/dev/null; caption_of "$2" >/dev/null' _ "$WATCH" "$osc_base" 2>&1)
chmod 600 "$osc_base.zoom" "$osc_base.caption"; rm -f "$osc_base.zoom" "$osc_base.caption"
check "unreadable sidecars never echo control bytes to the rail" '[[ "$sidecar_err" != *$'"'"'\033'"'"'* ]]'

dark_bg=$(IMG_WATCH_LIB=1 bash -c 'source "$1"; parse_terminal_background "$2"' _ "$WATCH" $'\033]11;rgb:1111/2222/3333\033\\')
light_bg=$(IMG_WATCH_LIB=1 bash -c 'source "$1"; parse_terminal_background "$2"' _ "$WATCH" $'\033]11;#fefdfc\a')
bad_bg=$(IMG_WATCH_LIB=1 bash -c 'source "$1"; parse_terminal_background "$2" || true' _ "$WATCH" $'\033]11;rgb:nope\a')
check "OSC 11 background responses normalize to exact RGB" '[[ "$dark_bg" == "#112233" && "$light_bg" == "#fefdfc" ]]'
check "malformed OSC 11 responses fall back without a color" '[[ -z "$bad_bg" ]]'

SLOW_COMPOSER="$ROOT/slow-composer"
cat > "$SLOW_COMPOSER" <<'SH'
#!/usr/bin/env bash
sleep 10
SH
chmod +x "$SLOW_COMPOSER"
started=$(date +%s)
slow_rc=0
IMG_WATCH_LIB=1 IMG_GRID_TIMEOUT=1 bash -c \
  'source "$1"; DIR="$2"; COMPOSER="$3"; compose_grid_page "$4" 640 480' \
  _ "$WATCH" "$CACHE" "$SLOW_COMPOSER" "$staged_job" >/dev/null 2>&1 || slow_rc=$?
elapsed=$(( $(date +%s) - started ))
check "a pathological composer is killed before it can stall the rail" '[[ $slow_rc -ne 0 && $elapsed -lt 3 ]]'

# --- pixel dimensions ---------------------------------------------------
# `file` prints a JPEG's JFIF density BEFORE its real size ("density 1x1, ...,
# 496x651"), so taking the first WxH match drew every photo as a 2x2 dot. This
# pins the real dimensions against exactly such a file.
if python3 -c 'import PIL' 2>/dev/null; then
  python3 -c 'import sys; from PIL import Image; Image.new("RGB", (96, 64), (200, 30, 30)).save(sys.argv[1], "JPEG")' "$ROOT/dense.jpg"
  px=$(IMG_WATCH_LIB=1 bash -c 'source "$1"; image_px "$2"' _ "$WATCH" "$ROOT/dense.jpg")
  check "a JPEG's real size wins over its density field" '[[ "$px" == "96x64" ]]'
  check "the fixture really has the density trap" \
    '[[ "$(file -b -- "$ROOT/dense.jpg")" == *"density 1x1"* ]]'
else
  printf '  skip pixel dimensions (no PIL)\n'
fi

# Force the `file` fallback and model the stock JPEG description where 300-DPI
# metadata is numerically larger than the encoded 96x64 pixel dimensions.
DENSITY_BIN="$ROOT/density-bin"
mkdir -p "$DENSITY_BIN"
cat > "$DENSITY_BIN/sips" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$DENSITY_BIN/identify" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$DENSITY_BIN/file" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'JPEG image data, JFIF standard 1.01, resolution (DPI), density 300x300, segment length 16, baseline, precision 8, 96x64, components 3'
SH
chmod +x "$DENSITY_BIN/sips" "$DENSITY_BIN/identify" "$DENSITY_BIN/file"
px=$(PATH="$DENSITY_BIN:$PATH" IMG_WATCH_LIB=1 \
  bash -c 'source "$1"; image_px "$2"' _ "$WATCH" "$ROOT/pic.png")
check "file fallback reads pixels rather than a larger 300-DPI density" '[[ "$px" == "96x64" ]]'

# --- watcher guards -----------------------------------------------------
out=$("$WATCH" --dir "$CACHE" --zoom abc 2>&1); rc=$?
check "watcher refuses a non-numeric zoom" '[[ $rc -eq 1 ]]'
out=$("$WATCH" --zoom 200 2>&1); rc=$?
check "watcher requires --dir" '[[ $rc -eq 1 ]]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
