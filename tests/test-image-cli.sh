#!/usr/bin/env bash
# Assertions are evaluated by check, so their referenced variables appear
# unused to ShellCheck.
# shellcheck disable=SC2016,SC2034
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

REPO_ROOT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
SKILL_DIR="$REPO_ROOT/skills/show-image"
IMAGE="$REPO_ROOT/bin/image"
WATCH="$SKILL_DIR/scripts/imgrail-watch.sh"
COMPOSER="$SKILL_DIR/scripts/image-grid.py"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
HOME_DIR="$ROOT/home"
BIN="$ROOT/bin"
mkdir -p "$HOME_DIR/.cache/agent-images" "$BIN" "$ROOT/work"
PYTHON="$(command -v python3)"
PYTHON_SITE="$($PYTHON -c 'import os, PIL; print(os.path.dirname(os.path.dirname(PIL.__file__)))')"
export PYTHONPATH="$PYTHON_SITE${PYTHONPATH:+:$PYTHONPATH}"

make_png() {
  PYTHONDONTWRITEBYTECODE=1 "$PYTHON" - "$1" "$2" "$3" "$4" <<'PY'
import sys
from PIL import Image
Image.new("RGB", (int(sys.argv[2]), int(sys.argv[3])), sys.argv[4]).save(sys.argv[1])
PY
}

make_png "$ROOT/work/older image.png" 80 40 red
make_png "$ROOT/work/newer image.png" 120 60 blue
touch -t 202609170101 "$ROOT/work/older image.png"
touch -t 202609180101 "$ROOT/work/newer image.png"

cat > "$ROOT/backend" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$IMAGE_TEST_ARGS"
if [[ "${1:-}" == grid ]]; then cp "$2" "$IMAGE_TEST_JOB"; fi
if [[ "${1:-}" == show && -n "${2:-}" && -f "$2" ]]; then cp "$2" "$IMAGE_TEST_SHOWN"; fi
SH
chmod +x "$ROOT/backend"
export IMAGE_TEST_ARGS="$ROOT/args" IMAGE_TEST_JOB="$ROOT/job.json" IMAGE_TEST_SHOWN="$ROOT/shown.png"

run_image() {
  HOME="$HOME_DIR" IMAGE_IMG_SH="$ROOT/backend" PYTHONDONTWRITEBYTECODE=1 \
    "$PYTHON" "$IMAGE" "$@"
}

printf 'image cli\n'

out=$(cd "$ROOT/work" && run_image ls); rc=$?
check "ls succeeds with missing Downloads and Desktop" '[[ $rc -eq 0 ]]'
check "ls keeps paths containing spaces intact" '[[ "$out" == *"$ROOT/work/newer image.png"* ]]'
check "ls prints pixel dimensions" '[[ "$out" == *$'"'"'120x60\t'"'"'* ]]'
first=$(printf '%s\n' "$out" | head -n1)
check "ls sorts newest first" '[[ "$first" == *"newer image.png"* ]]'

EMPTY_HOME="$ROOT/empty-home"; mkdir -p "$EMPTY_HOME"
out=$(cd "$ROOT" && HOME="$EMPTY_HOME" IMAGE_IMG_SH="$ROOT/backend" PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$IMAGE" ls); rc=$?
check "ls succeeds with an empty cache and missing directories" '[[ $rc -eq 0 && -z "$out" ]]'
mkdir -p "$ROOT/empty-work"
out=$(cd "$ROOT/empty-work" && HOME="$EMPTY_HOME" IMAGE_IMG_SH="$ROOT/backend" PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$IMAGE" last 2>&1); rc=$?
check "last refuses clearly when all image directories are empty or missing" \
  '[[ $rc -eq 1 && "$out" == *"no images found"* ]]'

(cd "$ROOT/work" && run_image last >/dev/null); rc=$?
args=$("$PYTHON" - "$ROOT/args" <<'PY'
import sys
print("\n".join(open(sys.argv[1], "rb").read().decode().split("\0")))
PY
)
check "last selects the newest image with spaces" '[[ $rc -eq 0 && "$args" == *"$ROOT/work/newer image.png"* ]]'
check "last uses fit" '[[ "$args" == *$'"'"'--zoom\nfit'"'"'* ]]'

run_image "$ROOT/work/older image.png" >/dev/null
args=$(tr '\0' '\n' < "$ROOT/args")
check "show defaults to fit" '[[ "$args" == *$'"'"'--zoom\nfit'"'"'* ]]'
run_image -l "$ROOT/work/older image.png" >/dev/null
args=$(tr '\0' '\n' < "$ROOT/args")
check "-l selects 200 percent" '[[ "$args" == *$'"'"'--zoom\n200'"'"'* ]]'
run_image -l --zoom 175 "$ROOT/work/older image.png" >/dev/null
args=$(tr '\0' '\n' < "$ROOT/args")
check "--zoom overrides a size shortcut" '[[ "$args" == *$'"'"'--zoom\n175'"'"'* ]]'

run_image grid "$ROOT/work/older image.png" "$ROOT/work/newer image.png" --cols 2 >/dev/null
direct_grid=$("$PYTHON" - "$ROOT/job.json" <<'PY'
import json, sys
job=json.load(open(sys.argv[1]))
print(job["layout"], job["cols"], len(job["cells"]))
PY
)
check "grid accepts direct image paths and an explicit column count" '[[ "$direct_grid" == "grid 2 2" ]]'

cells() {
  IMG_WATCH_LIB=1 HERDR_CELL_WIDTH_PX=8 HERDR_CELL_HEIGHT_PX=16 \
    bash -c 'source "$1"; ZOOM="$2"; target_cells "$3" "$4" "$5" "$6"' _ "$WATCH" "$@"
}
check "fit fills the pane while preserving aspect" '[[ "$(cells fit 64 64 41 40)" == "40 20" ]]'
check "100 percent keeps natural cell size" '[[ "$(cells 100 64 64 41 40)" == "8 4" ]]'
check "200 percent doubles natural cell size" '[[ "$(cells 200 64 64 41 40)" == "16 8" ]]'

for n in 1 2 3; do make_png "$ROOT/cell$n.png" 100 80 "rgb($((n * 40)),20,20)"; done
cat > "$ROOT/manifest.json" <<EOF
[{"row_id":"eye:e003:1024","cells":[
  {"path":"$ROOT/cell1.png","label":"CLEAN ORIGINAL"},
  {"path":"$ROOT/cell2.png","label":"INPUT MARKED CROP"},
  {"path":"$ROOT/cell3.png","label":"OUTPUT"}],
  "note":"Human: clean. Grader: not clean (1.381)","badge":"human clean"}]
EOF
# The composer consumes normalized jobs. Exercise the public CLI to produce one.
run_image grid --manifest "$ROOT/manifest.json" >/dev/null
meta=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/job.json" --width 900 --height 600 --output "$ROOT/composite.png" --json); rc=$?
check "a three-cell manifest composes successfully" '[[ $rc -eq 0 && -f "$ROOT/composite.png" ]]'
size=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" - "$ROOT/composite.png" <<'PY'
import sys
from PIL import Image
print("x".join(map(str, Image.open(sys.argv[1]).size)))
PY
)
check "the composite matches pane pixel geometry" '[[ "$size" == 900x600 ]]'
check "the composer reports every rendered manifest text" \
  '[[ "$meta" == *'"'"'eye:e003:1024'"'"'* && "$meta" == *'"'"'human clean'"'"'* && "$meta" == *'"'"'CLEAN ORIGINAL'"'"'* && "$meta" == *'"'"'INPUT MARKED CROP'"'"'* && "$meta" == *'"'"'OUTPUT'"'"'* && "$meta" == *'"'"'Human: clean. Grader: not clean (1.381)'"'"'* ]]'
occupancy=$(printf '%s' "$meta" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["image_area_ratio"])')
check "a 3x3-style comparison row gives images about 75 percent of the page" \
  'python3 -c "raise SystemExit(0 if float('$occupancy') >= 0.74 else 1)"'
first_image_pixel=$("$PYTHON" - "$ROOT/composite.png" <<'PY'
import sys
from PIL import Image
print(Image.open(sys.argv[1]).getpixel((16, 38)))
PY
)
check "comparison images crop to fill their boxes without letterboxing" '[[ "$first_image_pixel" == "(40, 20, 20)" ]]'

run_image grid --dense --manifest "$ROOT/manifest.json" >/dev/null
dense_flag=$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["dense"])' "$ROOT/job.json")
dense_meta=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/job.json" --width 900 --height 600 --output "$ROOT/dense-grid.png" --json)
check "--dense reaches the normalized job and removes all card text" \
  '[[ "$dense_flag" == True && "$dense_meta" == *'"'"'"rendered_text":[]'"'"'* ]]'

printf 'do not overwrite\n' > "$ROOT/output-victim"
ln -s "$ROOT/output-victim" "$ROOT/symlink-output.png"
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/job.json" --width 320 --height 240 --output "$ROOT/symlink-output.png" >/dev/null; rc=$?
check "the composer atomically replaces a pre-created output symlink" \
  '[[ $rc -eq 0 && -f "$ROOT/symlink-output.png" && ! -L "$ROOT/symlink-output.png" ]]'
check "a pre-created output symlink never damages its target" \
  '[[ "$(cat "$ROOT/output-victim")" == "do not overwrite" ]]'

mkdir "$ROOT/job-publish-victim"
printf 'keep this directory unchanged\n' > "$ROOT/job-publish-victim/sentinel"
ln -s "$ROOT/job-publish-victim" "$ROOT/published.grid-job"
staged_out=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/job.json" \
  --stage-dir "$ROOT/published.grid-job" --caption "staged grid" 2>&1); rc=$?
check "job publication refuses a raced symlink-to-directory" \
  '[[ $rc -eq 1 && "$staged_out" == *"cannot publish staged grid job"* && -L "$ROOT/published.grid-job" ]]'
check "a refused job publication leaves no moved data or private temp directory" \
  '[[ "$(cat "$ROOT/job-publish-victim/sentinel")" == "keep this directory unchanged" && ! -e "$ROOT/job-publish-victim/job.grid.json" ]] && ! compgen -G "$ROOT/.grid-job-*" >/dev/null'

"$PYTHON" - "$ROOT/job.json" "$ROOT/light-job.json" <<'PY'
import json, sys
job = json.load(open(sys.argv[1]))
job["dense"] = False
json.dump(job, open(sys.argv[2], "w"))
PY
light_meta=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/light-job.json" --width 320 --height 240 \
  --background '#fefdfc' --output "$ROOT/light.png" --json)
light_pixel=$("$PYTHON" - "$ROOT/light.png" <<'PY'
import sys
from PIL import Image
print(Image.open(sys.argv[1]).getpixel((0, 0)))
PY
)
check "the compositor paints the exact OSC 11 background and selects dark text" \
  '[[ "$light_pixel" == "(254, 253, 252)" && "$light_meta" == *'"'"'"text_color":"#111318"'"'"'* ]]'

PYTHONDONTWRITEBYTECODE=1 "$PYTHON" - "$ROOT/long-note.json" "$ROOT/cell1.png" <<'PY'
import json, sys
json.dump({"layout":"cards","rows":[{"row_id":"row","badge":"ok","note":"word " * 200,"cells":[{"path":sys.argv[2],"label":"image"}]}]}, open(sys.argv[1], "w"))
PY
long_meta=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/long-note.json" --width 500 --height 400 --output "$ROOT/long-note.png" --json)
check "card notes clamp to two lines with an ellipsis" \
  '[[ "$long_meta" == *'"'"'"note_line_counts":[2]'"'"'* && "$long_meta" == *"..."* ]]'

"$PYTHON" - "$ROOT/too-many.json" "$ROOT/cell1.png" <<'PY'
import json, sys
json.dump({"layout":"grid","cells":[{"path":sys.argv[2],"label":str(i)} for i in range(1001)]}, open(sys.argv[1], "w"))
PY
out=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/too-many.json" --width 320 --height 240 --output "$ROOT/too-many.png" 2>&1); rc=$?
check "the compositor bounds manifest cells" '[[ $rc -eq 1 && "$out" == *"too many cells"* ]]'

"$PYTHON" - "$ROOT/too-many-rows.json" "$ROOT/cell1.png" <<'PY'
import json, sys
rows = [{"row_id":str(i),"badge":"","note":"","cells":[{"path":sys.argv[2],"label":"x"}]} for i in range(501)]
json.dump({"layout":"cards","rows":rows}, open(sys.argv[1], "w"))
PY
out=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/too-many-rows.json" --width 320 --height 240 --output "$ROOT/too-many-rows.png" 2>&1); rc=$?
check "the compositor bounds manifest rows" '[[ $rc -eq 1 && "$out" == *"too many rows"* ]]'

"$PYTHON" - "$ROOT/too-long.json" "$ROOT/cell1.png" <<'PY'
import json, sys
json.dump({"layout":"grid","cells":[{"path":sys.argv[2],"label":"x" * 5000}]}, open(sys.argv[1], "w"))
PY
out=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/too-long.json" --width 320 --height 240 --output "$ROOT/too-long.png" 2>&1); rc=$?
check "the compositor bounds manifest text" '[[ $rc -eq 1 && "$out" == *"text is too long"* ]]'

"$PYTHON" - "$ROOT/large.png" <<'PY'
import sys
from PIL import Image
Image.new("RGB", (4100, 4100), "red").save(sys.argv[1])
PY
printf '{"layout":"grid","cells":[{"path":"%s","label":"large"}]}' "$ROOT/large.png" > "$ROOT/large-job.json"
out=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/large-job.json" --width 320 --height 240 --output "$ROOT/large-out.png" 2>&1); rc=$?
check "the compositor bounds decoded pixels before loading an image" '[[ $rc -eq 1 && "$out" == *"pixel limit"* ]]'

"$PYTHON" - "$ROOT/oversized-manifest.json" <<'PY'
import sys
open(sys.argv[1], "w").write("[" + " " * 1048577 + "]")
PY
out=$(run_image grid --manifest "$ROOT/oversized-manifest.json" 2>&1); rc=$?
check "the public CLI bounds manifest JSON bytes" '[[ $rc -eq 1 && "$out" == *"too large"* ]]'

printf '\377' > "$ROOT/invalid-utf8.json"
out=$(run_image grid --manifest "$ROOT/invalid-utf8.json" 2>&1); rc=$?
check "the public CLI rejects invalid UTF-8 without a traceback" \
  '[[ $rc -eq 1 && "$out" == *"cannot read manifest"* && "$out" != *"Traceback"* ]]'
out=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/invalid-utf8.json" \
  --width 320 --height 240 --output "$ROOT/invalid-utf8.png" 2>&1); rc=$?
check "the compositor rejects invalid UTF-8 without a traceback" \
  '[[ $rc -eq 1 && "$out" == *"cannot read grid job"* && "$out" != *"Traceback"* ]]'

PYTHONDONTWRITEBYTECODE=1 "$PYTHON" - "$ROOT/job24.json" "$ROOT/cell1.png" <<'PY'
import json, sys
rows=[]
for i in range(24):
    rows.append({"row_id": f"row-{i:02}", "badge": "checked", "note": "A readable note", "cells": [{"path": sys.argv[2], "label": "OUTPUT"}]})
json.dump({"layout":"cards", "rows":rows}, open(sys.argv[1], "w"))
PY
meta=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/job24.json" --width 700 --height 500 --page 0 --output "$ROOT/page1.png" --json)
pages=$(printf '%s' "$meta" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["page_count"])')
check "a 24-image manifest pages into multiple screenfuls" '[[ $pages -gt 1 ]]'
watch_compose=$(IMG_WATCH_LIB=1 bash -c 'source "$1"; DIR="$2"; COMPOSER="$3"; GRID_PAGE=1; compose_grid_page "$4" 640 480; printf "%s %s %s" "$GRID_PAGE" "$GRID_TOTAL" "$GRID_FILE"' _ "$WATCH" "$ROOT" "$COMPOSER" "$ROOT/job24.json")
watch_file="${watch_compose#* * }"
watch_size=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" - "$watch_file" <<'PY'
import sys
from PIL import Image
print("x".join(map(str, Image.open(sys.argv[1]).size)))
PY
)
check "the watcher composes a grid at its exact pane geometry" '[[ "$watch_compose" == "1 "* && "$watch_size" == 640x480 ]]'
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" - "$ROOT/job50.json" "$ROOT/cell1.png" <<'PY'
import json, sys
json.dump({"layout":"grid", "cols":None, "cells":[{"path":sys.argv[2], "label":f"image-{i:02}"} for i in range(50)]}, open(sys.argv[1], "w"))
PY
meta50=$(PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$COMPOSER" "$ROOT/job50.json" --width 700 --height 500 --page 99 --output "$ROOT/page-last.png" --json)
pages50=$(printf '%s' "$meta50" | "$PYTHON" -c 'import json,sys; data=json.load(sys.stdin); print(data["page"], data["page_count"])')
check "a 50-image grid renders through its final screenful" '[[ "${pages50%% *}" -eq "${pages50##* }" && "${pages50##* }" -gt 1 ]]'
nav=$(IMG_WATCH_LIB=1 bash -c 'source "$1"; cursor=0; active_file=x; last_seen=x; GRID_PAGE=0; GRID_TOTAL=3; handle_key n deck.grid.json; printf "%s " "$GRID_PAGE"; handle_key p deck.grid.json; printf "%s" "$GRID_PAGE"' _ "$WATCH")
check "n and p move forward and back inside a grid" '[[ "$nav" == "1 0" ]]'

mkdir -p "$ROOT/runs/a" "$ROOT/runs/b"
for run in a b; do cp "$ROOT/cell1.png" "$ROOT/runs/$run/clean.png"; cp "$ROOT/cell2.png" "$ROOT/runs/$run/input.png"; cp "$ROOT/cell3.png" "$ROOT/runs/$run/output.png"; done
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" - "$IMAGE" "$ROOT/runs/*/{clean,input,output}.png" "$ROOT/pattern.json" "$ROOT/equivalent.json" <<'PY'
import importlib.machinery, importlib.util, json, os, pathlib, sys
loader=importlib.machinery.SourceFileLoader("image_cli", sys.argv[1])
spec=importlib.util.spec_from_loader(loader.name, loader)
module=importlib.util.module_from_spec(spec); loader.exec_module(module)
pattern=module._pattern_job(sys.argv[2], "CLEAN ORIGINAL,INPUT MARKED CROP,OUTPUT")
json.dump(pattern, open(sys.argv[3], "w"), sort_keys=True)
rows=[]
for run in ("a", "b"):
    base=pathlib.Path(sys.argv[2].split("/*/")[0]) / run
    rows.append({"row_id": os.path.relpath(base, pathlib.Path.cwd()), "cells":[
      module._cell(base / "clean.png", "CLEAN ORIGINAL"),
      module._cell(base / "input.png", "INPUT MARKED CROP"),
      module._cell(base / "output.png", "OUTPUT")], "note":"", "badge":""})
json.dump({"layout":"cards", "rows":rows}, open(sys.argv[4], "w"), sort_keys=True)
PY
check "pattern expansion matches an equivalent manifest structure" \
  'cmp -s "$ROOT/pattern.json" "$ROOT/equivalent.json"'
(cd "$ROOT" && run_image grid --pattern "$ROOT/runs/*/{clean,input,output}.png" --labels "CLEAN ORIGINAL,INPUT MARKED CROP,OUTPUT" >/dev/null); rc=$?
public_pattern=$("$PYTHON" - "$ROOT/job.json" <<'PY'
import json, sys
job=json.load(open(sys.argv[1]))
print(job["layout"], len(job["rows"]), len(job["rows"][0]["cells"]))
PY
)
check "the public pattern command enqueues the expanded rows" '[[ $rc -eq 0 && "$public_pattern" == "cards 2 3" ]]'

NO_TOOL_HOME="$ROOT/no-tool-home"; mkdir -p "$NO_TOOL_HOME"
out=$(HOME="$NO_TOOL_HOME" PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$IMAGE" shot 2>&1); rc=$?
check "shot refuses clearly when no capture tool exists" '[[ $rc -eq 1 && "$out" == *"no screen capture tool"* ]]'

cat > "$BIN/peekaboo" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == permissions ]]; then printf '%s\n' '{"screenRecording":"denied"}'; exit 0; fi
: > "$IMAGE_WALLPAPER_MARK"
cp "$IMAGE_WALLPAPER_SOURCE" "${8}"
SH
chmod +x "$BIN/peekaboo"
out=$(HOME="$HOME_DIR" PATH="$BIN:/usr/bin:/bin" IMAGE_IMG_SH="$ROOT/backend" IMAGE_WALLPAPER_MARK="$ROOT/wallpaper-called" IMAGE_WALLPAPER_SOURCE="$ROOT/cell1.png" PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$IMAGE" shot 2>&1); rc=$?
check "shot names the Screen Recording permission problem" '[[ $rc -eq 1 && "$out" == *"Screen Recording permission"* ]]'
check "shot never displays wallpaper after a denied permission check" '[[ ! -e "$ROOT/wallpaper-called" ]]'

nested_permission=$($PYTHON - "$IMAGE" <<'PY'
import importlib.machinery, importlib.util, json, sys
loader=importlib.machinery.SourceFileLoader("image_cli", sys.argv[1])
spec=importlib.util.spec_from_loader(loader.name, loader)
module=importlib.util.module_from_spec(spec); loader.exec_module(module)
payload={"data":{"permissions":[{"name":"Screen Recording","isGranted":False}]},"success":True}
print(module._permission_denied(json.dumps(payload)))
PY
)
check "shot recognizes Peekaboo's nested permission response" '[[ "$nested_permission" == True ]]'

# The helper checks the grant inside the WezTerm process and exits 3 without
# it. A granted capture is shown; a refused one never reaches the backend.
cat > "$BIN/agent-shot" <<'SH'
#!/usr/bin/env bash
[[ $# -eq 3 && "$1" == *.png && "$2" == --mode && "$3" == screen ]] || exit 9
: > "$IMAGE_HELPER_MARK"
[[ "${IMAGE_HELPER_DENY:-0}" == 1 ]] && exit 3
cp "$IMAGE_HELPER_SOURCE" "$1"
SH
chmod +x "$BIN/agent-shot"
make_png "$ROOT/helper-capture.png" 200 150 purple
rm -f "$ROOT/shown.png"
out=$(HOME="$HOME_DIR" PATH=/usr/bin:/bin IMAGE_AGENT_SHOT="$BIN/agent-shot" IMAGE_IMG_SH="$ROOT/backend" IMAGE_HELPER_MARK="$ROOT/helper-called" IMAGE_HELPER_SOURCE="$ROOT/helper-capture.png" PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$IMAGE" shot 2>&1); rc=$?
check "shot fallback uses agent-shot's output-and-mode contract" '[[ -f "$ROOT/helper-called" && $rc -eq 0 ]]'
check "shot shows a granted helper capture" '[[ -s "$ROOT/shown.png" ]] && cmp -s "$ROOT/shown.png" "$ROOT/helper-capture.png"'
rm -f "$ROOT/shown.png" "$ROOT/helper-called"
out=$(HOME="$HOME_DIR" PATH=/usr/bin:/bin IMAGE_AGENT_SHOT="$BIN/agent-shot" IMAGE_IMG_SH="$ROOT/backend" IMAGE_HELPER_MARK="$ROOT/helper-called" IMAGE_HELPER_SOURCE="$ROOT/helper-capture.png" IMAGE_HELPER_DENY=1 PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$IMAGE" shot 2>&1); rc=$?
check "shot refuses when the helper reports no Screen Recording grant" '[[ $rc -eq 1 && "$out" == *"not granted to WezTerm"* && ! -e "$ROOT/shown.png" ]]'

cat > "$BIN/peekaboo" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == permissions ]]; then printf '%s\n' '{"screenRecording":"granted"}'; exit 0; fi
prev=""; mode=""; output=""
for arg in "$@"; do
  [[ "$prev" == --mode ]] && mode="$arg"
  [[ "$prev" == --path ]] && output="$arg"
  prev="$arg"
done
if [[ "$mode" == window ]]; then cp "$IMAGE_WINDOW_SOURCE" "$output"; else cp "$IMAGE_CAPTURE_SOURCE" "$output"; fi
printf '%s\n' '{"success":true}'
SH
chmod +x "$BIN/peekaboo"
make_png "$ROOT/real-capture.png" 200 150 green
make_png "$ROOT/window-capture.png" 180 120 orange
out=$(HOME="$HOME_DIR" PATH="$BIN:/usr/bin:/bin" IMAGE_IMG_SH="$ROOT/backend" IMAGE_CAPTURE_SOURCE="$ROOT/real-capture.png" IMAGE_WINDOW_SOURCE="$ROOT/real-capture.png" PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$IMAGE" shot 2>&1); rc=$?
check "shot refuses when screen and window capture both return wallpaper" '[[ $rc -eq 1 && "$out" == *"desktop wallpaper"* ]]'
HOME="$HOME_DIR" PATH="$BIN:/usr/bin:/bin" IMAGE_IMG_SH="$ROOT/backend" IMAGE_CAPTURE_SOURCE="$ROOT/real-capture.png" IMAGE_WINDOW_SOURCE="$ROOT/window-capture.png" PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$IMAGE" shot "fresh screen" >/dev/null; rc=$?
check "shot shows a valid capture when permission is granted" '[[ $rc -eq 0 && -f "$ROOT/shown.png" ]]'
check "the shown capture contains the captured pixels" 'cmp -s "$ROOT/shown.png" "$ROOT/real-capture.png"'

check "the zsh completion ships with the command" '[[ -x "$REPO_ROOT/completions/_image" ]]'
mkdir -p "$HOME_DIR/.oh-my-zsh"
run_image ls >/dev/null
check "the command registers completion in Oh My Zsh's fpath" \
  '[[ -L "$HOME_DIR/.oh-my-zsh/completions/_image" && "$(readlink "$HOME_DIR/.oh-my-zsh/completions/_image")" == "$REPO_ROOT/completions/_image" ]]'
help=$(run_image --help 2>&1)
check "help and completion expose --dense" \
  '[[ "$help" == *"--dense"* ]] && grep -q -- "--dense" "$REPO_ROOT/completions/_image"'

INSTALL_HOME="$ROOT/install-home"
mkdir -p "$INSTALL_HOME"
install_out=$(HOME="$INSTALL_HOME" bash "$REPO_ROOT/install.sh" 2>&1); rc=$?
check "the installer links both commands and the zsh completion" \
  '[[ $rc -eq 0 && -L "$INSTALL_HOME/.local/bin/image" && -L "$INSTALL_HOME/.local/bin/agent-shot" && -L "$INSTALL_HOME/.local/share/zsh/site-functions/_image" ]]'
check "installed links point into this checkout" \
  '[[ "$(readlink "$INSTALL_HOME/.local/bin/image")" == "$REPO_ROOT/bin/image" && "$(readlink "$INSTALL_HOME/.local/share/zsh/site-functions/_image")" == "$REPO_ROOT/completions/_image" ]]'
NO_HERDR_BIN="$ROOT/no-herdr-bin"
mkdir -p "$NO_HERDR_BIN"
for command_name in python3 dirname mkdir chmod; do
  ln -s "$(type -P "$command_name")" "$NO_HERDR_BIN/$command_name"
done
out=$(env -u HERDR_PANE_ID HOME="$INSTALL_HOME" PATH="$NO_HERDR_BIN" PYTHONDONTWRITEBYTECODE=1 \
  "$INSTALL_HOME/.local/bin/image" "$ROOT/work/older image.png" 2>&1); rc=$?
check "the installed image symlink resolves its backend relative to its real path" \
  '[[ $rc -eq 3 && "$out" == *"herdr is not in PATH"* && "$out" != *"backend is missing"* ]]'
install_out=$(HOME="$INSTALL_HOME" bash "$REPO_ROOT/install.sh" 2>&1); rc=$?
check "installing the same checkout twice is safe" '[[ $rc -eq 0 && "$install_out" == *"already linked"* ]]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
