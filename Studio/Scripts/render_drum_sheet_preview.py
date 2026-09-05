#!/usr/bin/env python3
"""Render a page-style multi-system drum score with a moving play marker."""

from __future__ import annotations

import argparse
import json
import subprocess
from collections import defaultdict
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from build_drum_score import build_measures, quantize_events
from build_drum_staff_preview import classify_events


FONT = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
BLACK = "#11120F"
GRAY = "#666961"
LIGHT_GRAY = "#A3A69F"
BLUE = "#69B6FF"

LINE_GAP = 24
SYSTEM_TOPS = (278, 553, 828)
SCORE_LEFT = 180
SCORE_RIGHT = 1800
MEASURES_PER_SYSTEM = 3
MEASURE_WIDTH = (SCORE_RIGHT - SCORE_LEFT) // MEASURES_PER_SYSTEM

# Half-line offsets from the top staff line. These follow common drum-set
# notation: metal above the staff, toms descend through it, kick at the bottom.
STAFF_STEP = {
    "crash": -2,
    "open_hi_hat": -1,
    "closed_hi_hat": -1,
    "ride": 0,
    "high_tom": 1,
    "mid_tom": 2,
    "snare": 4,
    "low_tom": 5,
    "floor_tom": 6,
    "kick": 7,
}

UPPER_DETAILS = {
    "crash",
    "open_hi_hat",
    "closed_hi_hat",
    "ride",
    "high_tom",
    "mid_tom",
    "snare",
    "low_tom",
    "floor_tom",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw_events", type=Path)
    parser.add_argument("beat_analysis", type=Path)
    parser.add_argument("drum_audio", type=Path)
    parser.add_argument("source_audio", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--title", default="Untitled")
    parser.add_argument("--artist", default="Unknown Artist")
    return parser.parse_args()


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT, size=size, index=6 if bold else 0)


def note_y(staff_top: int, detail: str) -> float:
    return staff_top + STAFF_STEP[detail] * LINE_GAP / 2


def draw_x_head(draw: ImageDraw.ImageDraw, x: float, y: float, size: int = 7) -> None:
    draw.line((x - size, y - size, x + size, y + size), fill=BLACK, width=3)
    draw.line((x - size, y + size, x + size, y - size), fill=BLACK, width=3)


def draw_solid_head(draw: ImageDraw.ImageDraw, x: float, y: float) -> None:
    draw.ellipse((x - 8, y - 5, x + 8, y + 5), fill=BLACK)


def draw_note_head(draw: ImageDraw.ImageDraw, x: float, event: dict, staff_top: int) -> None:
    detail = str(event["detail"])
    y = note_y(staff_top, detail)
    if detail in {"crash", "ride", "open_hi_hat", "closed_hi_hat"}:
        draw_x_head(draw, x, y)
        if detail == "open_hi_hat":
            draw.ellipse((x - 4, y - 18, x + 4, y - 10), outline=BLACK, width=2)
        elif detail == "crash":
            draw.text((x - 8, y - 29), "Cr.", font=font(13, True), fill=GRAY)
        elif detail == "ride":
            draw.text((x - 10, y - 27), "Ride", font=font(12, True), fill=GRAY)
    else:
        draw_solid_head(draw, x, y)
        if event.get("ghost"):
            draw.text((x - 15, y - 12), "(", font=font(20), fill=GRAY)
            draw.text((x + 8, y - 12), ")", font=font(20), fill=GRAY)


def draw_flag(draw: ImageDraw.ImageDraw, x: float, y: float, up: bool, levels: int) -> None:
    direction = 1 if up else -1
    for level in range(levels):
        flag_y = y + direction * level * 7
        if up:
            draw.line((x, flag_y, x + 15, flag_y + 9), fill=BLACK, width=4)
        else:
            draw.line((x, flag_y, x - 15, flag_y - 9), fill=BLACK, width=4)


def draw_quarter_rest(draw: ImageDraw.ImageDraw, x: float, y: float) -> None:
    # Compact engraved-style quarter-rest approximation.
    draw.line((x + 4, y - 18, x - 4, y - 6), fill=BLACK, width=4)
    draw.line((x - 4, y - 6, x + 5, y + 4), fill=BLACK, width=4)
    draw.line((x + 5, y + 4, x - 4, y + 12), fill=BLACK, width=4)
    draw.ellipse((x - 5, y + 8, x + 5, y + 17), fill=BLACK)


def draw_voice_beat(
    draw: ImageDraw.ImageDraw,
    by_tick: dict[int, list[dict]],
    tick_x: dict[int, float],
    beat_start: int,
    staff_top: int,
    upper: bool,
) -> None:
    ticks = [
        tick
        for tick in range(beat_start, beat_start + 4)
        if any(
            (str(event["detail"]) in UPPER_DETAILS)
            if upper
            else (str(event["detail"]) == "kick")
            for event in by_tick.get(tick, [])
        )
    ]
    if not ticks:
        if upper:
            rest_x = tick_x.get(beat_start, next(iter(tick_x.values()))) + 20
            draw_quarter_rest(draw, rest_x, staff_top + 2 * LINE_GAP)
        return

    stem_points: dict[int, tuple[float, float]] = {}
    for tick in ticks:
        selected = [
            event
            for event in by_tick[tick]
            if ((str(event["detail"]) in UPPER_DETAILS) if upper else (str(event["detail"]) == "kick"))
        ]
        x = tick_x[tick]
        for event in selected:
            draw_note_head(draw, x, event, staff_top)
        ys = [note_y(staff_top, str(event["detail"])) for event in selected]
        if upper:
            stem_x = x + 8
            beam_y = min(ys) - 34
            draw.line((stem_x, max(ys), stem_x, beam_y), fill=BLACK, width=3)
        else:
            stem_x = x - 8
            beam_y = max(ys) + 35
            draw.line((stem_x, min(ys), stem_x, beam_y), fill=BLACK, width=3)
        stem_points[tick] = (stem_x, beam_y)

    if len(ticks) == 1:
        subdivision = ticks[0] - beat_start
        if subdivision:
            x, y = stem_points[ticks[0]]
            draw_flag(draw, x, y, upper, 2 if subdivision in (1, 3) else 1)
        return

    connected: set[int] = set()
    for left, right in zip(ticks[:-1], ticks[1:]):
        gap = right - left
        levels = 2 if gap == 1 else 1 if gap == 2 else 0
        if not levels:
            continue
        connected.update((left, right))
        x0, y0 = stem_points[left]
        x1, y1 = stem_points[right]
        beam_y = min(y0, y1) if upper else max(y0, y1)
        for level in range(levels):
            offset = 7 * level if upper else -7 * level
            draw.line((x0, beam_y + offset, x1, beam_y + offset), fill=BLACK, width=6)
    for tick in ticks:
        if tick not in connected:
            x, y = stem_points[tick]
            subdivision = tick - beat_start
            draw_flag(draw, x, y, upper, 2 if subdivision in (1, 3) else 1)


def draw_percussion_clef(draw: ImageDraw.ImageDraw, x: int, staff_top: int) -> None:
    center = staff_top + 2 * LINE_GAP
    draw.line((x, center - 24, x, center + 24), fill=BLACK, width=6)
    draw.line((x + 13, center - 24, x + 13, center + 24), fill=BLACK, width=6)


def render_sheet(
    events: list[dict],
    measures: list[dict],
    duration: float,
    title: str,
    artist: str,
    output: Path,
) -> list[dict]:
    page = Image.new("RGB", (1920, 1080), "#FCFCFA")
    draw = ImageDraw.Draw(page)

    title_box = draw.textbbox((0, 0), title, font=font(67, True))
    title_width = title_box[2] - title_box[0]
    draw.text(((1920 - title_width) / 2, 38), title, font=font(67, True), fill=BLACK)
    subtitle = f"{artist}  ·  DRUM SCORE"
    subtitle_box = draw.textbbox((0, 0), subtitle, font=font(25, True))
    draw.text(((1920 - (subtitle_box[2] - subtitle_box[0])) / 2, 122), subtitle, font=font(25, True), fill=GRAY)

    draw_solid_head(draw, 117, 191)
    draw.line((125, 191, 125, 158), fill=BLACK, width=3)
    draw.text((145, 166), "= 68", font=font(27, True), fill=BLACK)
    draw.text((1540, 172), "BandLoop 자동 채보 · 30초 미리보기", font=font(20, True), fill=GRAY)

    grouped: dict[int, list[dict]] = defaultdict(list)
    for event in events:
        grouped[int(event["measure"])].append(event)

    visible_measures = [measure for measure in measures if float(measure["start"]) < duration]
    regions: list[dict] = []
    for index, measure in enumerate(visible_measures):
        system = index // MEASURES_PER_SYSTEM
        column = index % MEASURES_PER_SYSTEM
        if system >= len(SYSTEM_TOPS):
            break
        staff_top = SYSTEM_TOPS[system]
        x0 = SCORE_LEFT + column * MEASURE_WIDTH
        x1 = x0 + MEASURE_WIDTH

        if column == 0:
            for line in range(5):
                y = staff_top + line * LINE_GAP
                draw.line((78, y, SCORE_RIGHT, y), fill=BLACK, width=2)
            draw_percussion_clef(draw, 96, staff_top)
            if system == 0:
                draw.text((131, staff_top - 7), "4", font=font(27, True), fill=BLACK)
                draw.text((131, staff_top + 43), "4", font=font(27, True), fill=BLACK)

        draw.line((x0, staff_top, x0, staff_top + 4 * LINE_GAP), fill=BLACK, width=3)
        measure_label = "픽업" if measure["pickup"] else str(measure["number"])
        draw.text((x0 + 8, staff_top - 63), measure_label, font=font(17, True), fill=GRAY)

        tick_count = int(measure["tick_count"])
        content_left = x0 + 23
        content_right = x1 - 23
        tick_x = {
            tick: content_left + (tick + 0.5) / tick_count * (content_right - content_left)
            for tick in range(tick_count)
        }
        by_tick: dict[int, list[dict]] = defaultdict(list)
        for event in grouped.get(int(measure["number"]), []):
            tick = int(event["tick"])
            if tick < tick_count and float(event["time"]) <= duration + 0.02:
                by_tick[tick].append(event)
        for beat_start in range(0, tick_count, 4):
            draw_voice_beat(draw, by_tick, tick_x, beat_start, staff_top, upper=True)
            draw_voice_beat(draw, by_tick, tick_x, beat_start, staff_top, upper=False)

        regions.append(
            {
                "start": float(measure["start"]),
                "end": min(duration, float(measure["end"])),
                "x0": content_left,
                "x1": content_right,
                "y": staff_top - 65,
            }
        )

        is_last_in_system = column == MEASURES_PER_SYSTEM - 1
        is_last_measure = index == len(visible_measures) - 1
        if is_last_in_system or is_last_measure:
            draw.line((x1, staff_top, x1, staff_top + 4 * LINE_GAP), fill=BLACK, width=3)
            if is_last_measure:
                draw.line((x1 - 7, staff_top, x1 - 7, staff_top + 4 * LINE_GAP), fill=BLACK, width=2)

    draw.line((72, 1017, 1848, 1017), fill="#DDDED9", width=2)
    draw.text((76, 1032), "CR 크래시   RD 라이드   HH 하이햇   HT·MT·LT·FT 탐   SD 스네어   BD 킥", font=font(18, True), fill=GRAY)
    draw.text((1664, 1032), "AI DRAFT", font=font(18, True), fill=LIGHT_GRAY)
    page.save(output, optimize=True)
    return regions


def nested_expression(regions: list[dict], key: str) -> str:
    def value(region: dict) -> str:
        if key == "x":
            span = region["x1"] - region["x0"]
            duration = max(0.001, region["end"] - region["start"])
            return f"{region['x0']:.3f}+(t-{region['start']:.3f})/{duration:.3f}*{span:.3f}-24"
        return f"{region['y']:.3f}"

    expression = value(regions[-1])
    for region in reversed(regions[:-1]):
        expression = f"if(lt(t,{region['end']:.3f}),{value(region)},{expression})"
    return expression


def render_video(
    sheet: Path,
    regions: list[dict],
    source_audio: Path,
    duration: float,
    output: Path,
) -> None:
    x_expression = nested_expression(regions, "x")
    y_expression = nested_expression(regions, "y")
    graph = (
        "[1:v]format=rgba,colorchannelmixer=aa=0.28[marker];"
        f"[0:v][marker]overlay=x='{x_expression}':y='{y_expression}':eval=frame:shortest=1,"
        "format=yuv420p[v]"
    )
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
            str(sheet),
            "-f",
            "lavfi",
            "-i",
            f"color=c=0x69B6FF:s=48x226:r=30:d={duration:.3f}",
            "-i",
            str(source_audio),
            "-filter_complex",
            graph,
            "-map",
            "[v]",
            "-map",
            "2:a:0",
            "-t",
            f"{duration:.3f}",
            "-r",
            "30",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "19",
            "-c:a",
            "aac",
            "-b:a",
            "320k",
            "-movflags",
            "+faststart",
            str(output),
        ],
        check=True,
    )


def main() -> None:
    args = parse_args()
    raw = json.loads(args.raw_events.read_text(encoding="utf-8"))
    analysis = json.loads(args.beat_analysis.read_text(encoding="utf-8"))
    measures = build_measures(analysis, args.duration)
    preview_raw_events = [
        event for event in raw["events"] if float(event["time"]) <= args.duration + 0.15
    ]
    events, _ = quantize_events(preview_raw_events, measures)
    events = classify_events(events, args.drum_audio, args.duration)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    sheet = args.output_dir / "drum-sheet-preview.png"
    regions = render_sheet(events, measures, args.duration, args.title, args.artist, sheet)
    video = args.output_dir / "drum-sheet-preview.mp4"
    render_video(sheet, regions, args.source_audio, args.duration, video)
    print(json.dumps({"sheet": str(sheet), "video": str(video), "systems": 3, "measures": len(regions)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
