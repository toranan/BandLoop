#!/usr/bin/env python3
"""Create a reusable static album-art MP4 for an IEM practice mix."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


FONT = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
CJK_FONT = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("audio", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--title", required=True)
    parser.add_argument("--artist", required=True)
    parser.add_argument("--background", default="#292929")
    return parser.parse_args()


def font(text: str, size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    # Apple SD Gothic Neo does not contain every Japanese kanji (for example
    # 髭 in Official髭男dism). Arial Unicode prevents missing-glyph boxes.
    has_cjk = any("\u3400" <= character <= "\u9fff" for character in text)
    if has_cjk:
        return ImageFont.truetype(CJK_FONT, size=size)
    return ImageFont.truetype(FONT, size=size, index=6 if bold else 0)


def centered_text(draw: ImageDraw.ImageDraw, text: str, y: int, text_font: ImageFont.FreeTypeFont, color: str) -> None:
    box = draw.textbbox((0, 0), text, font=text_font)
    width = box[2] - box[0]
    draw.text(((1920 - width) / 2, y), text, font=text_font, fill=color)


def render_cover(image_path: Path, output: Path, title: str, artist: str, background: str) -> None:
    canvas = Image.new("RGB", (1920, 1080), background)
    artwork_size = 720
    artwork_x = (1920 - artwork_size) // 2
    artwork_y = 58

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (artwork_x - 5, artwork_y + 10, artwork_x + artwork_size + 5, artwork_y + artwork_size + 22),
        radius=18,
        fill=(0, 0, 0, 115),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    canvas.paste(shadow, (0, 0), shadow)

    artwork = Image.open(image_path).convert("RGB")
    artwork = ImageOps.fit(artwork, (artwork_size, artwork_size), method=Image.Resampling.LANCZOS)
    mask = Image.new("L", (artwork_size, artwork_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, artwork_size, artwork_size), radius=12, fill=255)
    canvas.paste(artwork, (artwork_x, artwork_y), mask)

    draw = ImageDraw.Draw(canvas)
    centered_text(draw, title, 825, font(title, 61, True), "#F6F6F4")
    centered_text(draw, artist, 904, font(artist, 37, True), "#B9BBB7")
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, optimize=True)


def render_video(cover: Path, audio: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-v",
            "error",
            "-loop",
            "1",
            "-framerate",
            "30",
            "-i",
            str(cover),
            "-i",
            str(audio),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "18",
            "-tune",
            "stillimage",
            "-pix_fmt",
            "yuv420p",
            "-r",
            "30",
            "-c:a",
            "copy",
            "-shortest",
            "-movflags",
            "+faststart",
            str(output),
        ],
        check=True,
    )


def main() -> None:
    args = parse_args()
    cover = args.output.with_suffix(".png")
    render_cover(args.image, cover, args.title, args.artist, args.background)
    render_video(cover, args.audio, args.output)
    print(f"cover={cover}\nvideo={args.output}")


if __name__ == "__main__":
    main()
