---
name: show-image
description: "Show a local image, image grid, or macOS screen capture in a Herdr side pane. Use when a picture is the answer and the human should see it. Requires Herdr with Kitty graphics enabled. Not for inspecting image contents."
argument-hint: "<path> [caption] | grid <paths...> | shot [caption]"
allowed-tools: Bash
---

# Show an image

Use the installed `image` command. It owns one Herdr side pane and reuses it for later images.

```bash
image /absolute/path/to/image.png "Optional caption"
image grid /absolute/path/to/first.png /absolute/path/to/second.png --cols 2
image grid --manifest /absolute/path/to/manifest.json
image shot "Current screen"
```

Use absolute paths. Report command failures verbatim. A missing `HERDR_PANE_ID` means the command did not run from a Herdr pane. Exit code 4 means no renderer is installed. Exit code 5 means the terminal did not confirm Kitty graphics support.

The rail accepts `n` and `p` for navigation, `+` and `-` for zoom in 25% steps, `0` to return to fit, `r` to redraw, and `q` to close. Interactive zoom stays set while the rail is open. Grid pages also accept the arrow keys or `h`, `j`, `k`, and `l` to move focus. `Enter` opens the focused source at the full pane height while the pane title keeps its identity and key help. `g` returns to the same grid page and focus. The rail redraws after pane resizes. Leave those keys to the human. The command sends input only to a pane it just created and proves ownership before it reuses or closes that pane.
