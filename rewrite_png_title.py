#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Rewrite the title area of an existing PNG in-place.")
    p.add_argument("--input", required=True, help="Input PNG path")
    p.add_argument(
        "--output",
        default=None,
        help="Output PNG path (default: overwrite --input)",
    )
    p.add_argument("--title", required=True, help="New title text")
    p.add_argument(
        "--title-height-px",
        type=int,
        default=70,
        help="Top strip height to clear and redraw (pixels). Default: 70",
    )
    p.add_argument(
        "--font-size",
        type=int,
        default=28,
        help="Font size for the title. Default: 28",
    )
    return p.parse_args()


def load_font(size: int) -> ImageFont.ImageFont:
    # Try common DejaVu fonts first (often present with matplotlib / system),
    # then fall back to Pillow's default bitmap font.
    for name in ("DejaVuSans.ttf", "DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(name, size=size)
        except Exception:
            pass
    return ImageFont.load_default()


def main() -> int:
    args = parse_args()
    in_path = Path(args.input)
    out_path = Path(args.output) if args.output else in_path

    img = Image.open(in_path)
    img.load()
    if img.mode not in ("RGB", "RGBA"):
        img = img.convert("RGBA")

    w, h = img.size
    title_h = max(1, min(int(args.title_height_px), h))

    draw = ImageDraw.Draw(img)
    # Clear the existing title region.
    if img.mode == "RGBA":
        fill = (255, 255, 255, 255)
    else:
        fill = (255, 255, 255)
    draw.rectangle([0, 0, w, title_h], fill=fill)

    font = load_font(int(args.font_size))
    text = str(args.title)
    # Center text horizontally, and vertically within the cleared band.
    # Pillow compatibility: older versions may not have ImageDraw.textbbox.
    if hasattr(draw, "textbbox"):
        bbox = draw.textbbox((0, 0), text, font=font)  # type: ignore[attr-defined]
        text_w = bbox[2] - bbox[0]
        text_h = bbox[3] - bbox[1]
    else:
        # Deprecated in newer Pillow but available in older versions.
        text_w, text_h = draw.textsize(text, font=font)  # type: ignore[attr-defined]
    x = max(0, (w - text_w) // 2)
    y = max(0, (title_h - text_h) // 2)
    draw.text((x, y), text, fill=(0, 0, 0), font=font)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, format="PNG")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

