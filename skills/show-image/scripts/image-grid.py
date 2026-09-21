#!/usr/bin/env python3
"""Validate, stage, and compose image-grid jobs."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import stat
import sys
import tempfile
import textwrap
from pathlib import Path
from typing import Any, BinaryIO

from PIL import Image, ImageDraw, ImageFont, ImageOps


DEFAULT_BG = "#111318"
DEFAULT_TEXT = "#f4f6fb"
DEFAULT_MUTED = "#b7bfce"
MAX_JSON_BYTES = 1024 * 1024
MAX_ROWS = 500
MAX_CELLS = 1000
MAX_TEXT = 4096
MAX_IMAGE_PIXELS = 16_000_000
MAX_TOTAL_PIXELS = 64_000_000
MAX_OUTPUT_PIXELS = 40_000_000
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")


class GridError(ValueError):
    pass


def _font(size: int, mono: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    names = (
        ["/System/Library/Fonts/Menlo.ttc", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]
        if mono
        else [
            "/System/Library/Fonts/SFNS.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        ]
    )
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def _text_width(draw: ImageDraw.ImageDraw, value: str, font: ImageFont.ImageFont) -> int:
    box = draw.textbbox((0, 0), value, font=font)
    return box[2] - box[0]


def _bounded_text(value: Any, field: str) -> str:
    text = str(value)
    if len(text) > MAX_TEXT:
        raise GridError(f"{field} text is too long (max {MAX_TEXT} characters)")
    return text


def _ellipsize(draw: ImageDraw.ImageDraw, value: str, font: ImageFont.ImageFont, width: int) -> str:
    if _text_width(draw, value, font) <= width:
        return value
    shortened = value
    while shortened and _text_width(draw, shortened + "...", font) > width:
        shortened = shortened[:-1]
    return shortened.rstrip() + "..." if shortened else "..."


def _wrap(
    draw: ImageDraw.ImageDraw,
    value: str,
    font: ImageFont.ImageFont,
    width: int,
    limit: int | None = None,
) -> list[str]:
    if not value or width < 1:
        return []
    words = value.split()
    lines: list[str] = []
    current = ""
    consumed = 0
    for word in words:
        candidate = f"{current} {word}".strip()
        if not current or _text_width(draw, candidate, font) <= width:
            current = candidate
            consumed += 1
        else:
            lines.append(current)
            if limit is not None and len(lines) == limit:
                break
            current = word
            consumed += 1
    else:
        if current:
            lines.append(current)
    truncated = consumed < len(words)
    if limit is not None and len(lines) > limit:
        lines = lines[:limit]
        truncated = True
    if limit is not None and len(lines) == limit and " ".join(lines) != " ".join(words):
        truncated = True
    if truncated and lines:
        last = lines[-1]
        while last and _text_width(draw, last + "...", font) > width:
            last = last[:-1]
        lines[-1] = last.rstrip() + "..." if last else "..."
    lines = [_ellipsize(draw, line, font, width) for line in lines]
    return lines


def _nofollow_fd(path: str, label: str) -> int:
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY") or os.open not in os.supports_dir_fd:
        raise GridError(f"cannot open {label} without following links: secure path traversal is unavailable")
    absolute = os.path.abspath(path)
    parts = Path(absolute).parts
    if len(parts) < 2 or parts[0] != os.path.sep:
        raise GridError(f"cannot open {label} without following links: invalid absolute path {path}")
    directory_fd = -1
    file_fd = -1
    try:
        directory_fd = os.open(os.path.sep, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        for component in parts[1:-1]:
            next_fd = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )
            os.close(directory_fd)
            directory_fd = next_fd
        file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
        info = os.fstat(file_fd)
        if not stat.S_ISREG(info.st_mode):
            raise GridError(f"{label} is not a regular file: {path}")
        return file_fd
    except OSError as exc:
        if file_fd >= 0:
            os.close(file_fd)
            file_fd = -1
        raise GridError(f"cannot open {label} without following links {path}: {exc}") from exc
    except BaseException:
        if file_fd >= 0:
            os.close(file_fd)
            file_fd = -1
        raise
    finally:
        if directory_fd >= 0:
            os.close(directory_fd)


def _canonical_leaf_path(path: str) -> str:
    absolute = os.path.abspath(path)
    name = os.path.basename(absolute)
    if not name:
        raise GridError(f"path does not name a file: {path}")
    return os.path.join(os.path.realpath(os.path.dirname(absolute)), name)


def _nofollow_open(path: str) -> BinaryIO:
    fd = _nofollow_fd(path, "image")
    try:
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise


def _image_dimensions(path: str) -> tuple[int, int]:
    try:
        with _nofollow_open(path) as handle, Image.open(handle) as image:
            width, height = image.size
    except (OSError, ValueError, GridError) as exc:
        if isinstance(exc, GridError):
            raise
        raise GridError(f"cannot read image {path}: {exc}") from exc
    pixels = width * height
    if width < 1 or height < 1 or pixels > MAX_IMAGE_PIXELS:
        raise GridError(f"image pixel limit exceeded: {path} ({pixels} > {MAX_IMAGE_PIXELS})")
    return width, height


def _open_image(path: str) -> Image.Image:
    try:
        with _nofollow_open(path) as handle, Image.open(handle) as src:
            src.load()
            return ImageOps.exif_transpose(src).convert("RGB")
    except (OSError, ValueError, GridError) as exc:
        if isinstance(exc, GridError):
            raise
        raise GridError(f"cannot read image {path}: {exc}") from exc


def _cover(src: Image.Image, width: int, height: int) -> Image.Image:
    return ImageOps.fit(src, (max(1, width), max(1, height)), Image.Resampling.LANCZOS)


def _validate_cell(cell: Any, base_dir: str | None = None) -> tuple[dict[str, str], int]:
    if not isinstance(cell, dict) or not isinstance(cell.get("path"), str):
        raise GridError("every cell needs a string path")
    expanded = os.path.expanduser(cell["path"])
    if base_dir is not None and not os.path.isabs(expanded):
        expanded = os.path.join(base_dir, expanded)
    path = _canonical_leaf_path(expanded)
    width, height = _image_dimensions(path)
    return {
        "path": path,
        "label": _bounded_text(cell.get("label", Path(path).name), "cell label"),
    }, width * height


def validate_job(raw: Any, base_dir: str | None = None) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise GridError("grid job must be an object")
    dense = raw.get("dense", False)
    if not isinstance(dense, bool):
        raise GridError("dense must be a boolean")
    layout = raw.get("layout")
    total_pixels = 0
    cell_count = 0
    if layout == "grid":
        cells = raw.get("cells")
        if not isinstance(cells, list) or not cells:
            raise GridError("grid needs at least one cell")
        if len(cells) > MAX_CELLS:
            raise GridError(f"too many cells (max {MAX_CELLS})")
        cols = raw.get("cols")
        if cols is not None and (not isinstance(cols, int) or isinstance(cols, bool) or cols < 1):
            raise GridError("cols must be a positive integer")
        checked_cells = []
        for cell in cells:
            checked, pixels = _validate_cell(cell, base_dir)
            checked_cells.append(checked)
            total_pixels += pixels
        checked_job: dict[str, Any] = {
            "layout": "grid",
            "cells": checked_cells,
            "cols": cols,
            "dense": dense,
        }
    elif layout == "cards":
        rows = raw.get("rows")
        if not isinstance(rows, list) or not rows:
            raise GridError("manifest needs at least one row")
        if len(rows) > MAX_ROWS:
            raise GridError(f"too many rows (max {MAX_ROWS})")
        checked_rows = []
        for row in rows:
            if not isinstance(row, dict):
                raise GridError("every manifest row must be an object")
            cells = row.get("cells")
            if not isinstance(cells, list) or not cells:
                raise GridError("every manifest row needs at least one cell")
            cell_count += len(cells)
            if cell_count > MAX_CELLS:
                raise GridError(f"too many cells (max {MAX_CELLS})")
            checked_cells = []
            for cell in cells:
                checked, pixels = _validate_cell(cell, base_dir)
                checked_cells.append(checked)
                total_pixels += pixels
            checked_rows.append(
                {
                    "row_id": _bounded_text(row.get("row_id", ""), "row id"),
                    "badge": _bounded_text(row.get("badge", ""), "badge"),
                    "note": _bounded_text(row.get("note", ""), "note"),
                    "cells": checked_cells,
                }
            )
        checked_job = {"layout": "cards", "rows": checked_rows, "dense": dense}
    else:
        raise GridError("grid job layout must be grid or cards")
    if total_pixels > MAX_TOTAL_PIXELS:
        raise GridError(f"decoded pixel limit exceeded ({total_pixels} > {MAX_TOTAL_PIXELS})")
    return checked_job


def _read_job(path: str) -> dict[str, Any]:
    fd = -1
    try:
        fd = _nofollow_fd(_canonical_leaf_path(path), "grid job")
        info = os.fstat(fd)
        if info.st_size > MAX_JSON_BYTES:
            raise GridError(f"manifest JSON is too large (max {MAX_JSON_BYTES} bytes)")
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            raw = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise GridError(f"cannot read grid job {path}: {exc}") from exc
    finally:
        if fd >= 0:
            os.close(fd)
    return validate_job(raw, os.path.dirname(os.path.abspath(path)))


def _default_cols(count: int, width: int, height: int) -> int:
    aspect = max(0.5, width / max(1, height))
    return max(1, min(count, int(math.ceil(math.sqrt(count * aspect)))))


def _grid_pages(job: dict[str, Any], width: int, height: int) -> list[list[dict[str, str]]]:
    cells = job["cells"]
    cols = job.get("cols") or _default_cols(len(cells), width, height)
    rows_per_page = max(1, height // (150 if job["dense"] else 190))
    per_page = max(1, cols * rows_per_page)
    return [cells[i : i + per_page] for i in range(0, len(cells), per_page)]


def _card_height(
    draw: ImageDraw.ImageDraw,
    row: dict[str, Any],
    width: int,
    height: int,
    note_font: ImageFont.ImageFont,
) -> int:
    inner = width - 16
    note_lines = _wrap(draw, row["note"], note_font, inner - 16, limit=2)
    note_height = len(note_lines) * max(18, getattr(note_font, "size", 15) + 3)
    cells = len(row["cells"])
    cell_width = max(1, (inner - 16 - (cells - 1) * 8) // cells)
    image_height = max(100, min(int(cell_width * 0.8), height // 2))
    return 30 + image_height + 24 + note_height + 16


def _card_pages(job: dict[str, Any], width: int, height: int) -> list[list[dict[str, Any]]]:
    probe = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(probe)
    note_font = _font(max(13, min(18, width // 70)))
    pages: list[list[dict[str, Any]]] = []
    page: list[dict[str, Any]] = []
    used = 4
    for row in job["rows"]:
        needed = _card_height(draw, row, width, height, note_font)
        if page and used + needed + 6 > height - 4:
            pages.append(page)
            page = []
            used = 4
        page.append(row)
        used += needed + 6
    if page:
        pages.append(page)
    return pages


def _palette(background: str) -> dict[str, str]:
    if not COLOR_RE.fullmatch(background):
        raise GridError("background must be #RRGGBB")
    background = background.lower()
    red, green, blue = (int(background[i : i + 2], 16) for i in (1, 3, 5))
    luminance = (299 * red + 587 * green + 114 * blue) / 1000
    light = luminance >= 150
    return {
        "background": background,
        "text": "#111318" if light else DEFAULT_TEXT,
        "muted": "#424956" if light else DEFAULT_MUTED,
        "card": "#eef0f4" if light else "#1d2129",
        "edge": "#c4c9d2" if light else "#343b49",
        "badge": "#f3d9a7" if light else "#5b3b08",
        "badge_text": "#4d3100" if light else "#ffd88a",
        "focus": "#006dff" if light else "#69a7ff",
    }


def _draw_label(
    draw: ImageDraw.ImageDraw,
    label: str,
    box: tuple[int, int, int, int],
    font: ImageFont.ImageFont,
    rendered: list[str],
    color: str,
) -> None:
    x0, y0, x1, _ = box
    value = textwrap.shorten(label, width=max(8, (x1 - x0) // 8), placeholder="...")
    rendered.append(label)
    draw.text((x0, y0), value, fill=color, font=font)


def _draw_focus(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    color: str,
) -> None:
    x0, y0, x1, y1 = box
    if x1 < x0 or y1 < y0:
        return
    width = max(1, min(4, (x1 - x0 + 1) // 2, (y1 - y0 + 1) // 2))
    draw.rectangle(box, outline=color, width=width)


def _render_focused_image(canvas: Image.Image, cell: dict[str, str]) -> int:
    source = _open_image(cell["path"])
    fitted = ImageOps.contain(source, canvas.size, Image.Resampling.LANCZOS)
    x = (canvas.width - fitted.width) // 2
    y = (canvas.height - fitted.height) // 2
    canvas.paste(fitted, (x, y))
    return fitted.width * fitted.height


def _render_grid(
    canvas: Image.Image,
    cells: list[dict[str, str]],
    cols: int,
    rendered: list[str],
    palette: dict[str, str],
    dense: bool,
    focus: int,
) -> int:
    draw = ImageDraw.Draw(canvas)
    width, height = canvas.size
    margin, gap = (0, 2) if dense else (4, 6)
    rows = max(1, math.ceil(len(cells) / cols))
    cell_w = max(1, (width - 2 * margin - (cols - 1) * gap) // cols)
    cell_h = max(1, (height - 2 * margin - (rows - 1) * gap) // rows)
    label_font = _font(max(13, min(18, width // max(60, cols * 28))))
    label_h = 0 if dense else max(24, getattr(label_font, "size", 15) + 8)
    image_area = 0
    for index, cell in enumerate(cells):
        row, col = divmod(index, cols)
        x = margin + col * (cell_w + gap)
        y = margin + row * (cell_h + gap)
        if not dense:
            draw.rounded_rectangle(
                (x, y, x + cell_w, y + cell_h), 8, fill=palette["card"], outline=palette["edge"], width=1
            )
        image_w = cell_w if dense else max(1, cell_w - 6)
        image_h = cell_h if dense else max(1, cell_h - label_h - 6)
        fitted = _cover(_open_image(cell["path"]), image_w, image_h)
        ix = x if dense else x + 3
        iy = y if dense else y + 3
        canvas.paste(fitted, (ix, iy))
        image_area += image_w * image_h
        if not dense:
            _draw_label(
                draw,
                cell["label"],
                (x + 5, y + cell_h - label_h + 3, x + cell_w - 5, y + cell_h),
                label_font,
                rendered,
                palette["text"],
            )
        if index == focus:
            inset = 1 if cell_w > 2 and cell_h > 2 else 0
            _draw_focus(
                draw,
                (x + inset, y + inset, x + cell_w - inset - 1, y + cell_h - inset - 1),
                palette["focus"],
            )
    return image_area


def _render_cards(
    canvas: Image.Image,
    rows: list[dict[str, Any]],
    rendered: list[str],
    palette: dict[str, str],
    dense: bool,
    focus: int,
) -> tuple[int, list[list[str]]]:
    width, height = canvas.size
    if dense:
        cells = [cell for row in rows for cell in row["cells"]]
        cols = _default_cols(len(cells), width, height)
        return _render_grid(canvas, cells, cols, rendered, palette, True, focus), []
    draw = ImageDraw.Draw(canvas)
    margin, gap = 4, 6
    row_id_font = _font(max(14, min(19, width // 62)), mono=True)
    badge_font = _font(max(12, min(16, width // 72)))
    label_font = _font(max(12, min(17, width // 70)))
    note_font = _font(max(13, min(18, width // 70)))
    heights = [_card_height(draw, row, width, height, note_font) for row in rows]
    free = max(0, height - 2 * margin - gap * (len(rows) - 1) - sum(heights))
    bonus = free // max(1, len(rows))
    image_area = 0
    rendered_notes: list[list[str]] = []
    y = margin
    cell_index = 0
    for row, base_height in zip(rows, heights):
        card_h = base_height + bonus
        x0, x1, y1 = margin, width - margin, min(height - margin, y + card_h)
        draw.rounded_rectangle((x0, y, x1, y1), 10, fill=palette["card"], outline=palette["edge"], width=1)
        row_id, badge, note = row["row_id"], row["badge"], row["note"]
        rendered.extend(value for value in (row_id, badge) if value)
        badge_display = _ellipsize(draw, badge, badge_font, max(60, (x1 - x0) // 3)) if badge else ""
        badge_w = _text_width(draw, badge_display, badge_font) + 16 if badge_display else 0
        row_display = _ellipsize(draw, row_id, row_id_font, max(20, x1 - x0 - badge_w - 32))
        draw.text((x0 + 8, y + 6), row_display, fill=palette["text"], font=row_id_font)
        if badge:
            bx0 = max(x0 + 100, x1 - 8 - badge_w)
            draw.rounded_rectangle((bx0, y + 4, x1 - 8, y + 25), 8, fill=palette["badge"])
            draw.text((bx0 + 8, y + 6), badge_display, fill=palette["badge_text"], font=badge_font)

        note_lines = _wrap(draw, note, note_font, x1 - x0 - 16, limit=2)
        rendered_notes.append(note_lines)
        note_line_h = max(18, getattr(note_font, "size", 15) + 3)
        note_h = len(note_lines) * note_line_h
        label_h = max(24, getattr(label_font, "size", 15) + 8)
        image_top = y + 30
        image_bottom = max(image_top + 1, y1 - 8 - note_h - label_h)
        cells = row["cells"]
        cell_gap = 8
        cell_w = max(1, (x1 - x0 - 16 - cell_gap * (len(cells) - 1)) // len(cells))
        for index, cell in enumerate(cells):
            cx = x0 + 8 + index * (cell_w + cell_gap)
            fitted = _cover(_open_image(cell["path"]), cell_w, image_bottom - image_top)
            canvas.paste(fitted, (cx, image_top))
            image_area += cell_w * (image_bottom - image_top)
            _draw_label(
                draw,
                cell["label"],
                (cx, image_bottom + 3, cx + cell_w, image_bottom + label_h),
                label_font,
                rendered,
                palette["text"],
            )
            if cell_index == focus:
                inset = 1 if cell_w > 2 and image_bottom - image_top > 2 else 0
                _draw_focus(
                    draw,
                    (
                        cx + inset,
                        image_top + inset,
                        cx + cell_w - inset - 1,
                        image_bottom - inset - 1,
                    ),
                    palette["focus"],
                )
            cell_index += 1
        if note:
            rendered.append(note)
            ny = y1 - 8 - note_h
            for line in note_lines:
                draw.text((x0 + 8, ny), line, fill=palette["muted"], font=note_font)
                ny += note_line_h
        y = y1 + gap
    return image_area, rendered_notes


def _focus_navigation(row_lengths: list[int], focus: int) -> dict[str, int]:
    offsets: list[int] = []
    total = 0
    for length in row_lengths:
        offsets.append(total)
        total += length
    focus = max(0, min(focus, total - 1))
    row = max(index for index, offset in enumerate(offsets) if offset <= focus)
    col = focus - offsets[row]
    left = focus - 1 if col > 0 else focus
    right = focus + 1 if col + 1 < row_lengths[row] else focus
    up = offsets[row - 1] + min(col, row_lengths[row - 1] - 1) if row > 0 else focus
    down = offsets[row + 1] + min(col, row_lengths[row + 1] - 1) if row + 1 < len(row_lengths) else focus
    return {"left": left, "right": right, "up": up, "down": down}


def _publish_png(canvas: Image.Image, output: str) -> None:
    """Publish one verified PNG without ever opening the destination for writes."""
    destination = Path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=".image-grid-", suffix=".png", dir=destination.parent)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise GridError("composer temp output is not a regular file")
        with os.fdopen(fd, "wb") as handle:
            canvas.save(handle, "PNG")
            handle.flush()
            os.fsync(handle.fileno())
        fd = -1
        info = os.stat(temp_name, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode):
            raise GridError("composer temp output changed type")
        with Image.open(temp_name) as check:
            check.verify()
        with Image.open(temp_name) as check:
            if check.format != "PNG" or check.size != canvas.size:
                raise GridError("composer temp output failed verification")
        _atomic_publish(Path(temp_name), destination, stat.S_ISREG, "composer output")
        temp_name = ""
    finally:
        if fd >= 0:
            os.close(fd)
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass


def compose(
    job: dict[str, Any],
    width: int,
    height: int,
    page: int = 0,
    output: str | None = None,
    background: str = DEFAULT_BG,
    focus: int = 0,
    open_focus: bool = False,
    _validated: bool = False,
) -> dict[str, Any]:
    if width < 160 or height < 120:
        raise GridError("pane geometry must be at least 160x120 pixels")
    if width * height > MAX_OUTPUT_PIXELS:
        raise GridError(f"output pixel limit exceeded ({width * height} > {MAX_OUTPUT_PIXELS})")
    checked = job if _validated else validate_job(job)
    palette = _palette(background)
    if checked["layout"] == "grid":
        pages = _grid_pages(checked, width, height)
    elif checked["dense"]:
        dense_job = {
            "cells": [cell for row in checked["rows"] for cell in row["cells"]],
            "cols": None,
            "dense": True,
        }
        pages = _grid_pages(dense_job, width, height)
    else:
        pages = _card_pages(checked, width, height)
    actual_page = max(0, min(page, len(pages) - 1))
    canvas = Image.new("RGB", (width, height), palette["background"])
    rendered: list[str] = []
    note_lines: list[list[str]] = []
    if checked["layout"] == "grid":
        cols = checked.get("cols") or _default_cols(len(checked["cells"]), width, height)
        page_cells = pages[actual_page]
        page_cols = min(cols, len(page_cells))
        row_lengths = [min(page_cols, len(page_cells) - index) for index in range(0, len(page_cells), page_cols)]
        focus = max(0, min(focus, len(page_cells) - 1))
        if open_focus:
            image_area = _render_focused_image(canvas, page_cells[focus])
        else:
            image_area = _render_grid(
                canvas,
                page_cells,
                page_cols,
                rendered,
                palette,
                checked["dense"],
                focus,
            )
    elif checked["dense"]:
        page_cells = pages[actual_page]
        page_cols = _default_cols(len(page_cells), width, height)
        row_lengths = [min(page_cols, len(page_cells) - index) for index in range(0, len(page_cells), page_cols)]
        focus = max(0, min(focus, len(page_cells) - 1))
        if open_focus:
            image_area = _render_focused_image(canvas, page_cells[focus])
        else:
            image_area = _render_grid(canvas, page_cells, page_cols, rendered, palette, True, focus)
    else:
        page_rows = pages[actual_page]
        page_cells = [cell for row in page_rows for cell in row["cells"]]
        row_lengths = [len(row["cells"]) for row in page_rows]
        page_cols = max(row_lengths)
        focus = max(0, min(focus, len(page_cells) - 1))
        if open_focus:
            image_area = _render_focused_image(canvas, page_cells[focus])
        else:
            image_area, note_lines = _render_cards(canvas, page_rows, rendered, palette, checked["dense"], focus)
    if output:
        _publish_png(canvas, output)
    return {
        "size": [width, height],
        "page": actual_page + 1,
        "page_count": len(pages),
        "rendered_text": rendered,
        "rendered_note_lines": note_lines,
        "note_line_counts": [len(lines) for lines in note_lines],
        "image_area_ratio": round(image_area / (width * height), 4),
        "background": palette["background"],
        "text_color": palette["text"],
        "focus": focus,
        "focus_navigation": _focus_navigation(row_lengths, focus),
        "page_cell_count": len(page_cells),
        "page_cols": page_cols,
        "open_focus": open_focus,
        "output": output,
    }


def _copy_nofollow(source: str, destination: Path) -> None:
    with _nofollow_open(source) as src:
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "wb") as target:
                fd = -1
                shutil.copyfileobj(src, target, length=1024 * 1024)
                target.flush()
                os.fsync(target.fileno())
        finally:
            if fd >= 0:
                os.close(fd)
    if not stat.S_ISREG(os.stat(destination, follow_symlinks=False).st_mode):
        raise GridError(f"staged source is not a regular file: {destination}")


def _atomic_publish(source: Path, destination: Path, expected_type: Any, label: str) -> None:
    if not expected_type(os.stat(source, follow_symlinks=False).st_mode):
        raise GridError(f"{label} is not the expected file type")
    try:
        os.replace(source, destination)
    except OSError as exc:
        raise GridError(f"cannot publish {label}: {exc}") from exc
    if not expected_type(os.stat(destination, follow_symlinks=False).st_mode):
        raise GridError(f"published {label} changed file type")


def _stage_job_into(job_path: str, root: Path, caption: str) -> Path:
    checked = _read_job(job_path)
    sources = root / "sources"
    sources.mkdir(mode=0o700)
    cells = checked["cells"] if checked["layout"] == "grid" else [cell for row in checked["rows"] for cell in row["cells"]]
    for index, cell in enumerate(cells):
        suffix = Path(cell["path"]).suffix.lower()
        if not re.fullmatch(r"\.[a-z0-9]{1,8}", suffix):
            suffix = ".img"
        target = sources / f"{index:04d}{suffix}"
        _copy_nofollow(cell["path"], target)
        _image_dimensions(_canonical_leaf_path(str(target)))
        cell["path"] = str(Path("sources") / target.name)
    destination = root / "job.grid.json"
    temp = root / ".job.grid.json.tmp"
    with open(temp, "x", encoding="utf-8") as handle:
        json.dump(checked, handle, ensure_ascii=False, separators=(",", ":"))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp, destination)
    if caption:
        caption_path = root / "job.grid.json.caption"
        with open(caption_path, "x", encoding="utf-8") as handle:
            handle.write(caption + "\n")
            handle.flush()
            os.fsync(handle.fileno())
    return destination


def stage_job(job_path: str, stage_dir: str, caption: str = "") -> Path:
    destination = Path(stage_dir)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=".grid-job-", dir=destination.parent))
    os.chmod(temp, 0o700)
    published = False
    try:
        _stage_job_into(job_path, temp, caption)
        _atomic_publish(temp, destination, stat.S_ISDIR, "staged grid job")
        published = True
        job = destination / "job.grid.json"
        if not stat.S_ISREG(os.stat(job, follow_symlinks=False).st_mode):
            raise GridError("published grid job is not a regular file")
        return job
    finally:
        if not published:
            shutil.rmtree(temp, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("job")
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    parser.add_argument("--page", type=int, default=0)
    parser.add_argument("--output")
    parser.add_argument("--background", default=DEFAULT_BG)
    parser.add_argument("--focus", type=int, default=0)
    parser.add_argument("--open-focus", action="store_true")
    parser.add_argument("--stage-dir")
    parser.add_argument("--caption", default="")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.stage_dir:
            staged = stage_job(args.job, args.stage_dir, args.caption)
            result: dict[str, Any] = {"job": str(staged)}
        else:
            if args.width is None or args.height is None or not args.output:
                raise GridError("--width, --height, and --output are required for composition")
            job = _read_job(args.job)
            result = compose(
                job,
                args.width,
                args.height,
                args.page,
                args.output,
                args.background,
                args.focus,
                args.open_focus,
                _validated=True,
            )
    except (OSError, json.JSONDecodeError, GridError) as exc:
        print(f"image-grid: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    elif args.stage_dir:
        print(result["job"])
    else:
        print(f"{result['page']} {result['page_count']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
