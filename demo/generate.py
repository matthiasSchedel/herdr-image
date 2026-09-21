#!/usr/bin/env python3
"""Regenerate the light and dark README grids from synthetic source images."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "source"
COMPOSER = ROOT.parent / "skills" / "show-image" / "scripts" / "image-grid.py"


def make_source(name: str, background: str, accent: str, offset: int) -> None:
    image = Image.new("RGB", (480, 320), background)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((50 + offset, 45, 315 + offset, 270), radius=30, fill=accent)
    draw.ellipse((255 - offset, 85, 430 - offset, 260), fill="#f5c451")
    draw.line((40, 280 - offset, 440, 70 + offset), fill="#ffffff", width=12)
    image.save(SOURCE / name)


def main() -> None:
    SOURCE.mkdir(exist_ok=True)
    make_source("alpha-input.png", "#31465f", "#3fb8af", 0)
    make_source("alpha-edit.png", "#31465f", "#f06c5b", 22)
    make_source("alpha-output.png", "#31465f", "#7a6ff0", 40)
    make_source("beta-input.png", "#563a52", "#ef8354", 42)
    make_source("beta-edit.png", "#563a52", "#5db7de", 18)
    make_source("beta-output.png", "#563a52", "#65b96e", 0)

    rows = []
    for group, badge, note in (
        ("alpha", "reviewed", "Shape and crop comparison"),
        ("beta", "approved", "Color and position comparison"),
    ):
        rows.append(
            {
                "row_id": f"sample-{group}",
                "badge": badge,
                "note": note,
                "cells": [
                    {"path": f"source/{group}-input.png", "label": "Input"},
                    {"path": f"source/{group}-edit.png", "label": "Edit"},
                    {"path": f"source/{group}-output.png", "label": "Output"},
                ],
            }
        )
    job = ROOT / ".demo-job.json"
    job.write_text(json.dumps({"layout": "cards", "rows": rows}), encoding="utf-8")
    try:
        for name, background in (("dark.png", "#111318"), ("light.png", "#f6f3ed")):
            subprocess.run(
                [
                    sys.executable,
                    str(COMPOSER),
                    str(job),
                    "--width",
                    "1200",
                    "--height",
                    "900",
                    "--background",
                    background,
                    "--output",
                    str(ROOT / name),
                ],
                check=True,
            )
    finally:
        job.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
