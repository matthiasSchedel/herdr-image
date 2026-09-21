---
name: show-image
description: "Show an image to the human in a Herdr side pane over the Kitty graphics protocol, reusing one rail pane. Use when a picture is the answer — a screenshot, a chart, a photo. Requires a Herdr pane and a Kitty-graphics terminal. Not for reading an image's contents."
user_invocable: true
deploy: true
argument-hint: "show <path> [caption] [--zoom N|fit] | grid <job.json> | image grid ... [--dense] | status | close"
trust-level: auto-execute
allowed-tools: [Bash]
skill_kind: wrapper
version: 0.3.0
last-reviewed: 2026-09-20
output_path: "side rail pane + ~/.cache/agent-images"
---

# /show-image — put a picture in front of the human

Safe to auto-execute: local-only and reversible. It writes into a cache
directory, opens one side pane of its own, and closes only that pane.

Claude Code cannot draw images itself: its renderer strips graphics escape
sequences and captures Bash output, so nothing an agent prints ever reaches the
terminal as pixels. A separate pane is the only surface that works, and this
skill owns exactly one of them. Short alias: `/img`.

```bash
scripts/img.sh show <path> [caption] [--zoom N|fit] # cache it, open or reuse the rail
scripts/img.sh grid <job.json> [caption]           # enqueue one pane-sized composited grid
image grid <paths...> [--cols N] [--dense]         # public grid CLI; dense is a text-free image wall
scripts/img.sh status                             # backend, rail pane, cache, renderer
scripts/img.sh close                              # close the rail (refuses anything else)
```

## How it works

`show` copies the image into `~/.cache/agent-images` with an optional caption
sidecar. The first `show` splits one side pane and starts
`scripts/imgrail-watch.sh` there; every later `show` is a file write, and the
rail picks it up on its own. `n` and `p` page through history, `+` and `-`
change zoom in 25% steps from 25% to 400%, `0` returns to fit, `r` redraws,
and `q` quits. Interactive zoom overrides the queued image zoom and stays set
while the rail is open.

Grid pages add the arrow keys or `h`/`j`/`k`/`l` for focus movement. `Enter`
opens the focused source image at the full pane height. The pane title keeps
the image identity and key help without taking image rows. `g` returns to the
same grid page and focus. On a grid, `n` and `p` change grid pages before
moving through rail history.

The cache directory is private to the current user. The skill refuses a
symlinked directory or pane record.

## Requirements

| Thing | Why |
|---|---|
| `$HERDR_PANE_ID` set | there has to be a pane to split; exit 3 without it |
| Herdr `[experimental] kitty_graphics = true` | required for full-detail graphics. Reopen Herdr after enabling it because the client reads this flag at startup |
| A config that parses | A duplicate key makes the whole TOML invalid and Herdr falls back to its defaults without saying so — that is what a pane full of black is, nine times out of ten |
| `chafa` or `kitten` | the renderer; Kitty panes prefer kitten's compact PNG stream, while chafa covers hosts without kitten |
| A Kitty-graphics terminal, or `chafa` | verified graphics terminals: WezTerm, Ghostty, kitty. Without Kitty graphics, chafa renders a lower-detail symbol fallback |

## Mechanics

- **Rendering happens in the pane, never in the agent's shell.** The Kitty
  handshake and the terminal size are only knowable from a process that owns a
  tty, which an agent's shell does not have.
- **Redraws keep the PNG compressed.** When Kitty graphics and `kitten` are
  available, the rail passes its measured pixel geometry to `kitten icat` and
  streams the exact-size composed PNG without asking icat to rescale it.
  Chafa's Kitty renderer remains the no-kitten path, and its symbol renderer
  handles terminals without Kitty graphics.
- **Input reaches only a fresh pane.** Herdr is selected by `$HERDR_PANE_ID`,
  never by asking which pane is "current" (with the variable unset that answers
  with the globally focused pane — someone else's live work). Input goes only
  to the pane the immediately preceding `pane split` created, after a
  prompt-readiness proof, because a pane that did not exist a moment ago cannot
  hold a human's draft. These are nv's rules, kept for nv's reasons.
- **Reuse types nothing at all.** Once the rail is recorded and alive, `show`
  only writes a file. That is the whole point of the watcher design.
- **The live watcher proves ownership.** A record contains the pane id and the
  random token passed to the watcher. Reuse and close require that exact script
  path and token in the live process argv. A plausible record or shell process
  is not enough.
- **Bounded everywhere.** Every Herdr call has an outer deadline
  (`IMG_HERDR_TIMEOUT`, default 3 seconds) implemented without `timeout(1)`.
  Startup waits also use counted ticks (`IMG_HERDR_WAIT`, default 100 ticks of
  0.1 seconds). A fresh private working directory tags each split, so a pane
  created before a timed-out response can be recovered by id instead of
  orphaned. The rail's poll interval doubles as its key read.
- **Default sizing is fit.** The image fills the available rail while keeping
  its aspect ratio. `--zoom N` and per-image `.zoom` sidecars select a natural
  size percentage, so a reused rail can switch between fit, 100%, and 200%.
  Interactive zoom takes precedence across image and grid page changes. The
  rail also redraws when its pane dimensions change.
- **Grid composition happens inside the rail.** The watcher knows its real cell
  and pane dimensions from CSI 16/14/18, with the old 8x16 fallback when those
  replies stay silent. It asks `image-grid.py` for one PNG at that pixel
  geometry and renders only that PNG. The composer marks the focused cell. Focus
  navigation and opening a source stay within the immutable staged grid job.
  Focused open mode reads through the composer's no-follow file descriptor and
  atomically publishes a full-height pane-sized PNG; the watcher never renders
  the source path itself. Grid identity and key help stay in the terminal title
  while every grid view occupies every renderer row.
- **Queued grids own immutable source copies.** `grid` copies every source with
  symlink following disabled, rewrites the job to those private copies, and
  publishes the complete job directory with one rename. Later deletion or
  retargeting of an input path cannot change the queued page.
- **The terminal supplies the page color.** The rail asks OSC 11 under the same
  deadline as the Kitty handshake. Valid replies become the exact PNG
  background with contrasting text. Silence or malformed replies use the dark
  default.
- **Grid work is bounded.** Jobs cap JSON bytes, rows, cells, text, and decoded
  pixels. Composition runs under `IMG_GRID_TIMEOUT`, and PNG publication always
  goes through a verified exclusive temp file followed by an atomic replace.
- **`close` refuses a pane it no longer owns.** If the rail pane is running
  something other than the watcher or a bare shell, it stays open.

## Exit codes

| Code | Meaning |
|---|---|
| 1 | usage, unreadable path, non-image extension, bad zoom |
| 2 | pane busy: not at a prompt, or the rail was taken over |
| 3 | no `$HERDR_PANE_ID`, no herdr, no jq, or the split failed |
| 4 | no renderer binary (`kitten` / `chafa`) |
| 5 | the terminal lacks Kitty graphics and only `kitten` is installed; install `chafa` for the symbol fallback |

## Examples

```bash
scripts/img.sh show /tmp/chart.png "Signup conversion by week" --zoom 150
scripts/img.sh grid /tmp/normalized-grid-job.json "Evaluation grid"
image grid --manifest /tmp/evaluations.json --dense
scripts/img.sh status
scripts/img.sh close
```

## Failure Modes

| Symptom | Meaning |
|---|---|
| `no HERDR_PANE_ID` | Run from the Herdr pane that should own the rail |
| `does not run this img rail` | The recorded pane is live but its watcher path or token does not match; the skill leaves it alone |
| `rail ... did not stay alive` | The watcher exited during startup; inspect the pane output and renderer availability |
| `pane record is a symlink` | Remove the unsafe record after checking its target; the skill will not follow it |

## Environment

`IMG_ZOOM` (default `fit`), `IMG_POLL` (rail poll seconds, default 1), `IMG_HERDR_WAIT`,
`IMG_HERDR_TIMEOUT` (outer Herdr deadline in whole seconds, default 3),
`IMG_GRID_TIMEOUT` (grid compositor deadline in whole seconds, default 3),
`IMG_HERDR_DIRECTION` (default `right`), `IMG_HERDR_LABEL` (default `img`),
`IMG_SKIP_QUERY=1` to skip the graphics handshake in tests.
