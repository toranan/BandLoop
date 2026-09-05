#!/usr/bin/env python3
"""Build BandLoop drum-chart assets from raw ADTOF events and beat analysis."""

from __future__ import annotations

import argparse
import bisect
import json
import math
import subprocess
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

import numpy as np
import pretty_midi
from PIL import Image, ImageDraw, ImageFont


FONT_REGULAR = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
FONT_BOLD = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
LIME = "#D5FF2C"
CORAL = "#FF674F"
INK = "#10110F"
WHITE = "#F7F8F3"
MUTED = "#92958C"
GRID = "#3A3D37"

LANE_ORDER = ("cymbal", "hi_hat", "tom", "snare", "kick")
LANE_LABELS = {
    "cymbal": "CY",
    "hi_hat": "HH",
    "tom": "T",
    "snare": "SD",
    "kick": "BD",
}
DISPLAY_POSITIONS = {
    "cymbal": ("A", 5),
    "hi_hat": ("G", 5),
    "tom": ("D", 5),
    "snare": ("C", 5),
    "kick": ("F", 4),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw_events", type=Path)
    parser.add_argument("beat_analysis", type=Path)
    parser.add_argument("section_config", type=Path)
    parser.add_argument("source_audio", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--title", default="Untitled")
    parser.add_argument("--artist", default="Unknown Artist")
    parser.add_argument("--video", action="store_true")
    return parser.parse_args()


def probe_duration(path: Path) -> float:
    return float(
        subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            text=True,
        ).strip()
    )


def build_measures(analysis: dict, duration: float) -> list[dict]:
    downbeats = [float(value) for value in analysis["downbeats"]]
    period = float(np.median(np.diff(analysis["beats"])))
    measure_period = float(np.median(np.diff(downbeats)))
    while downbeats[-1] + 0.2 < duration:
        downbeats.append(downbeats[-1] + measure_period)
    if downbeats[-1] < duration:
        downbeats.append(downbeats[-1] + measure_period)

    measures: list[dict] = []
    pickup_end = downbeats[0]
    pickup_beats = [
        time
        for time, position in zip(analysis["beats"], analysis["beat_positions"])
        if 0 <= time < pickup_end and position in (3, 4)
    ]
    if len(pickup_beats) >= 2:
        pickup_grid: list[float] = []
        points = pickup_beats[:2] + [pickup_end]
        for left, right in zip(points[:-1], points[1:]):
            pickup_grid.extend(left + (right - left) * step / 4 for step in range(4))
    else:
        pickup_grid = [step * pickup_end / 8 for step in range(8)]
    measures.append(
        {
            "number": 0,
            "start": 0.0,
            "end": pickup_end,
            "ticks": pickup_grid,
            "tick_count": 8,
            "pickup": True,
        }
    )

    for index, (start, end) in enumerate(zip(downbeats[:-1], downbeats[1:]), start=1):
        if start >= duration - 0.1:
            break
        ticks = [start + (end - start) * tick / 16 for tick in range(16)]
        measures.append(
            {
                "number": index,
                "start": start,
                "end": end,
                "ticks": ticks,
                "tick_count": 16,
                "pickup": False,
            }
        )
    return measures


def quantize_events(raw_events: list[dict], measures: list[dict]) -> tuple[list[dict], dict]:
    grid: list[tuple[float, int, int]] = []
    for measure in measures:
        for tick, time in enumerate(measure["ticks"]):
            grid.append((float(time), int(measure["number"]), tick))
    grid.sort()
    times = [point[0] for point in grid]

    merged: dict[tuple[int, int, str], dict] = {}
    timing_errors: list[float] = []
    for raw in raw_events:
        time = float(raw["time"])
        insertion = bisect.bisect_left(times, time)
        candidates = [index for index in (insertion - 1, insertion) if 0 <= index < len(grid)]
        nearest = min(candidates, key=lambda index: abs(times[index] - time))
        quantized_time, measure, tick = grid[nearest]
        error = time - quantized_time
        timing_errors.append(abs(error))
        event = {
            **raw,
            "raw_time": round(time, 4),
            "time": round(quantized_time, 4),
            "timing_error": round(error, 4),
            "measure": measure,
            "tick": tick,
            "beat": tick // 4 + 1 if measure else tick // 4 + 3,
            "subdivision": tick % 4,
            "ghost": raw["instrument"] == "snare" and float(raw["confidence"]) < 0.55,
        }
        key = (measure, tick, str(raw["instrument"]))
        if key not in merged or event["confidence"] > merged[key]["confidence"]:
            merged[key] = event

    events = list(merged.values())
    occupied = {(event["measure"], event["tick"], event["instrument"]) for event in events}
    events = [
        event
        for event in events
        if not (
            event["instrument"] == "hi_hat"
            and (event["measure"], event["tick"], "cymbal") in occupied
        )
    ]
    events.sort(key=lambda event: (event["time"], LANE_ORDER.index(event["instrument"])))
    stats = {
        "raw_event_count": len(raw_events),
        "event_count": len(events),
        "median_quantization_error_ms": round(float(np.median(timing_errors)) * 1000, 2),
        "p95_quantization_error_ms": round(float(np.quantile(timing_errors, 0.95)) * 1000, 2),
        "counts": {
            instrument: sum(event["instrument"] == instrument for event in events)
            for instrument in LANE_ORDER
        },
    }
    return events, stats


def section_for_time(sections: list[dict], time: float) -> str:
    label = sections[0]["label"]
    for section in sections:
        if float(section["time"]) <= time + 0.15:
            label = section["label"]
        else:
            break
    return str(label)


def write_quantized_midi(events: list[dict], path: Path, tempo: float) -> None:
    midi = pretty_midi.PrettyMIDI(initial_tempo=tempo)
    drums = pretty_midi.Instrument(program=0, is_drum=True, name="BandLoop Drums")
    for event in events:
        drums.notes.append(
            pretty_midi.Note(
                velocity=int(event["velocity"]),
                pitch=int(event["midi_note"]),
                start=float(event["time"]),
                end=float(event["time"]) + 0.08,
            )
        )
    drums.notes.sort(key=lambda note: (note.start, note.pitch))
    midi.instruments.append(drums)
    midi.write(str(path))


def add_text(parent: ET.Element, tag: str, text: str, **attributes: str) -> ET.Element:
    element = ET.SubElement(parent, tag, attributes)
    element.text = text
    return element


def add_musicxml_note(measure: ET.Element, event: dict, chord: bool) -> None:
    note = ET.SubElement(measure, "note")
    if chord:
        ET.SubElement(note, "chord")
    unpitched = ET.SubElement(note, "unpitched")
    step, octave = DISPLAY_POSITIONS[event["instrument"]]
    add_text(unpitched, "display-step", step)
    add_text(unpitched, "display-octave", str(octave))
    ET.SubElement(note, "instrument", {"id": f"P1-{event['instrument']}"})
    add_text(note, "duration", "1")
    add_text(note, "voice", "1")
    add_text(note, "type", "16th")
    if event["instrument"] in ("hi_hat", "cymbal"):
        add_text(note, "notehead", "x")
    add_text(note, "stem", "up")


def add_musicxml_rest(measure: ET.Element, duration: int) -> None:
    while duration > 0:
        value = next(option for option in (16, 8, 4, 2, 1) if option <= duration)
        note = ET.SubElement(measure, "note")
        ET.SubElement(note, "rest")
        add_text(note, "duration", str(value))
        add_text(note, "voice", "1")
        add_text(
            note,
            "type",
            {16: "whole", 8: "half", 4: "quarter", 2: "eighth", 1: "16th"}[value],
        )
        duration -= value


def write_musicxml(events: list[dict], measures: list[dict], path: Path, title: str) -> None:
    root = ET.Element("score-partwise", version="4.0")
    work = ET.SubElement(root, "work")
    add_text(work, "work-title", f"{title} — Drum Score")
    identification = ET.SubElement(root, "identification")
    add_text(identification, "creator", "BandLoop AI draft", type="arranger")
    part_list = ET.SubElement(root, "part-list")
    score_part = ET.SubElement(part_list, "score-part", id="P1")
    add_text(score_part, "part-name", "Drum Set")
    for instrument in LANE_ORDER:
        score_instrument = ET.SubElement(score_part, "score-instrument", id=f"P1-{instrument}")
        add_text(score_instrument, "instrument-name", instrument.replace("_", " ").title())
        midi_instrument = ET.SubElement(score_part, "midi-instrument", id=f"P1-{instrument}")
        add_text(midi_instrument, "midi-channel", "10")
        midi_note = next(event["midi_note"] for event in events if event["instrument"] == instrument)
        add_text(midi_instrument, "midi-unpitched", str(int(midi_note) + 1))

    part = ET.SubElement(root, "part", id="P1")
    grouped: dict[tuple[int, int], list[dict]] = defaultdict(list)
    for event in events:
        grouped[(event["measure"], event["tick"])].append(event)

    for index, measure_data in enumerate(measures):
        attributes = {"number": str(measure_data["number"])}
        if measure_data["pickup"]:
            attributes["implicit"] = "yes"
        measure = ET.SubElement(part, "measure", attributes)
        if index == 0:
            attrs = ET.SubElement(measure, "attributes")
            add_text(attrs, "divisions", "4")
            time = ET.SubElement(attrs, "time")
            add_text(time, "beats", "4")
            add_text(time, "beat-type", "4")
            clef = ET.SubElement(attrs, "clef")
            add_text(clef, "sign", "percussion")
            add_text(clef, "line", "2")
        cursor = 0
        for tick in range(measure_data["tick_count"]):
            tick_events = grouped.get((measure_data["number"], tick), [])
            if not tick_events:
                continue
            if tick > cursor:
                add_musicxml_rest(measure, tick - cursor)
            tick_events.sort(key=lambda event: LANE_ORDER.index(event["instrument"]))
            for chord_index, event in enumerate(tick_events):
                add_musicxml_note(measure, event, chord_index > 0)
            cursor = tick + 1
        if cursor < measure_data["tick_count"]:
            add_musicxml_rest(measure, measure_data["tick_count"] - cursor)

    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REGULAR, size=size, index=6 if bold else 0)


def draw_cross(draw: ImageDraw.ImageDraw, x: float, y: float, radius: int, color: str, width: int) -> None:
    draw.line((x - radius, y - radius, x + radius, y + radius), fill=color, width=width)
    draw.line((x - radius, y + radius, x + radius, y - radius), fill=color, width=width)


def draw_note(draw: ImageDraw.ImageDraw, x: float, y: float, event: dict, color: str, scale: float = 1.0) -> None:
    radius = max(3, round(7 * scale))
    if event["instrument"] in ("hi_hat", "cymbal"):
        draw_cross(draw, x, y, radius, color, max(2, round(3 * scale)))
    else:
        draw.ellipse((x - radius, y - radius * 0.65, x + radius, y + radius * 0.65), fill=color)
        if event.get("ghost"):
            draw.arc((x - radius - 5, y - radius - 5, x + radius + 5, y + radius + 5), 80, 280, fill=MUTED, width=2)
    stem_x = x + radius
    draw.line((stem_x, y, stem_x, y - 34 * scale), fill=color, width=max(1, round(2 * scale)))


def render_pdf(
    events: list[dict],
    measures: list[dict],
    sections: list[dict],
    output: Path,
    title: str,
    artist: str,
    tempo: float,
) -> None:
    page_size = (2480, 3508)
    rows_per_page = 5
    measures_per_row = 4
    row_height = 560
    measure_width = 520
    left = 260
    top = 430
    grouped: dict[int, list[dict]] = defaultdict(list)
    for event in events:
        grouped[event["measure"]].append(event)

    pages: list[Image.Image] = []
    chunks = [measures[index : index + rows_per_page * measures_per_row] for index in range(0, len(measures), rows_per_page * measures_per_row)]
    for page_index, chunk in enumerate(chunks):
        page = Image.new("RGB", page_size, "#FAFAF7")
        draw = ImageDraw.Draw(page)
        draw.text((170, 115), title, font=font(76, True), fill=INK)
        draw.text((170, 210), f"{artist}  ·  DRUM SCORE", font=font(34, True), fill="#55584F")
        draw.rounded_rectangle((1840, 120, 2310, 245), radius=55, fill=LIME)
        draw.text((1962, 151), f"{round(tempo)} BPM · 4/4", font=font(31, True), fill=INK)
        draw.text((170, 300), "AI 자동 채보 초안 · 킥 / 스네어 / 탐 / 하이햇 / 심벌", font=font(27), fill="#73766D")

        for row in range(rows_per_page):
            row_measures = chunk[row * measures_per_row : (row + 1) * measures_per_row]
            if not row_measures:
                break
            row_y = top + row * row_height
            line_ys = [row_y + 165 + lane * 44 for lane in range(5)]
            lane_y = {
                "cymbal": line_ys[0] - 70,
                "hi_hat": line_ys[0] - 25,
                "tom": line_ys[1],
                "snare": line_ys[2],
                "kick": line_ys[4] - 20,
            }
            for lane, label in zip(LANE_ORDER, ("CY", "HH", "T", "SD", "BD")):
                draw.text((170, lane_y[lane] - 17), label, font=font(24, True), fill="#686B63")
            for y in line_ys:
                draw.line((left, y, left + len(row_measures) * measure_width, y), fill="#8A8D84", width=2)

            for column, measure in enumerate(row_measures):
                x0 = left + column * measure_width
                width = measure_width
                section = section_for_time(sections, measure["start"])
                previous_section = (
                    section_for_time(sections, row_measures[column - 1]["start"])
                    if column > 0
                    else None
                )
                if column == 0 or section != previous_section:
                    draw.text((x0 + 12, row_y + 32), section, font=font(28, True), fill="#384000")
                number = "픽업" if measure["pickup"] else str(measure["number"])
                draw.text((x0 + width - 72, row_y + 38), number, font=font(23, True), fill="#777A71")
                draw.line((x0, line_ys[0], x0, line_ys[-1]), fill=INK, width=4)
                for beat in range(1, 4):
                    beat_x = x0 + width * beat / 4
                    draw.line((beat_x, line_ys[0], beat_x, line_ys[-1]), fill="#D5D7CF", width=2)
                for event in grouped.get(measure["number"], []):
                    tick_count = measure["tick_count"]
                    x = x0 + (event["tick"] + 0.5) / tick_count * width
                    draw_note(draw, x, lane_y[event["instrument"]], event, INK, 1.15)
            row_end = left + len(row_measures) * measure_width
            draw.line((row_end, line_ys[0], row_end, line_ys[-1]), fill=INK, width=4)
        draw.text((170, 3380), f"BandLoop · {page_index + 1}/{len(chunks)}", font=font(24), fill="#868980")
        pages.append(page)

    first, rest = pages[0], pages[1:]
    first.save(output, "PDF", resolution=150.0, save_all=True, append_images=rest)


def render_scroll_assets(
    events: list[dict],
    measures: list[dict],
    sections: list[dict],
    duration: float,
    output_dir: Path,
    title: str,
    artist: str,
    tempo: float,
) -> tuple[Path, Path, float, int]:
    pixels_per_second = 100.0
    playhead_x = 520
    viewport_width = 1920
    strip_height = 720
    strip_width = math.ceil(playhead_x + duration * pixels_per_second + (viewport_width - playhead_x))
    strip = Image.new("RGBA", (strip_width, strip_height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(strip)
    line_ys = [245 + lane * 68 for lane in range(5)]
    lane_y = {
        "cymbal": line_ys[0] - 105,
        "hi_hat": line_ys[0] - 42,
        "tom": line_ys[1],
        "snare": line_ys[2],
        "kick": line_ys[4] - 28,
    }
    score_start = playhead_x
    score_end = playhead_x + duration * pixels_per_second
    for y in line_ys:
        draw.line((score_start, y, score_end, y), fill="#51544D", width=2)

    for measure in measures:
        x0 = playhead_x + measure["start"] * pixels_per_second
        x1 = playhead_x + min(duration, measure["end"]) * pixels_per_second
        if x0 > score_end:
            continue
        draw.line((x0, line_ys[0], x0, line_ys[-1]), fill="#A7AAA1", width=3)
        for beat in range(1, 4):
            beat_x = x0 + (x1 - x0) * beat / 4
            draw.line((beat_x, line_ys[0], beat_x, line_ys[-1]), fill="#30332E", width=2)
        number = "P" if measure["pickup"] else str(measure["number"])
        draw.text((x0 + 10, 635), number, font=font(25, True), fill="#969990")

    for section in sections:
        x = playhead_x + float(section["time"]) * pixels_per_second
        label = str(section["label"])
        text_box = draw.textbbox((0, 0), label, font=font(32, True))
        width = text_box[2] - text_box[0] + 44
        draw.rounded_rectangle((x + 8, 55, x + width, 112), radius=25, fill=LIME)
        draw.text((x + 30, 66), label, font=font(32, True), fill=INK)
        draw.line((x, 120, x, line_ys[-1] + 30), fill=LIME, width=3)

    for event in events:
        x = playhead_x + float(event["time"]) * pixels_per_second
        color = CORAL if event.get("ghost") else WHITE
        draw_note(draw, x, lane_y[event["instrument"]], event, color, 1.0)
    strip_path = output_dir / "drum-scroll-strip.png"
    strip.save(strip_path, optimize=True)

    background = Image.new("RGB", (1920, 1080), "#0A0B09")
    bg = ImageDraw.Draw(background)
    bg.text((84, 62), title, font=font(68, True), fill=WHITE)
    bg.text((86, 142), f"{artist}  ·  DRUM PRACTICE SCORE", font=font(29, True), fill="#9A9D94")
    bg.rounded_rectangle((1570, 62, 1835, 142), radius=38, fill=LIME)
    bg.text((1630, 83), f"{round(tempo)} BPM · 4/4", font=font(25, True), fill=INK)
    legend_x = 86
    for instrument in LANE_ORDER:
        bg.text((legend_x, 232), f"{LANE_LABELS[instrument]}  {instrument.replace('_', ' ')}", font=font(23, True), fill="#8F9289")
        legend_x += 205
    bg.rounded_rectangle((70, 284, 1850, 1040), radius=34, fill="#141612", outline="#2A2D27", width=2)
    bg.line((playhead_x, 300, playhead_x, 1020), fill=LIME, width=5)
    bg.polygon(((playhead_x - 11, 298), (playhead_x + 11, 298), (playhead_x, 316)), fill=LIME)
    bg.text((playhead_x - 54, 258), "현재", font=font(23, True), fill=LIME)
    bg.text((82, 1035), "AI 자동 채보 초안 · 심벌 종류와 고스트 노트는 연주 전 확인", font=font(21), fill="#73766D")
    background_path = output_dir / "drum-scroll-background.png"
    background.save(background_path, optimize=True)
    return strip_path, background_path, pixels_per_second, playhead_x


def render_video(
    strip: Path,
    background: Path,
    audio: Path,
    duration: float,
    pixels_per_second: float,
    output: Path,
) -> None:
    filter_graph = (
        f"[1:v]crop=1920:720:x='min(max(t*{pixels_per_second:.3f},0),iw-1920)':y=0[score];"
        "[0:v][score]overlay=0:300:shortest=1,format=yuv420p[v]"
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
            str(background),
            "-loop",
            "1",
            "-framerate",
            "30",
            "-i",
            str(strip),
            "-i",
            str(audio),
            "-filter_complex",
            filter_graph,
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
            "20",
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
    sections = json.loads(args.section_config.read_text(encoding="utf-8"))["sections"]
    duration = probe_duration(args.source_audio)
    beats = [float(value) for value in analysis["beats"]]
    if len(beats) < 2:
        raise ValueError("At least two beat timestamps are required")
    tempo = 60.0 / float(np.median(np.diff(beats)))
    measures = build_measures(analysis, duration)
    events, stats = quantize_events(raw["events"], measures)
    for measure in measures:
        measure["section"] = section_for_time(sections, measure["start"])

    args.output_dir.mkdir(parents=True, exist_ok=True)
    timeline = {
        "title": args.title,
        "artist": args.artist,
        "duration": round(duration, 3),
        "tempo": round(tempo, 3),
        "time_signature": "4/4",
        "model": raw["model"],
        "draft": True,
        "stats": stats,
        "sections": sections,
        "measures": measures,
        "events": events,
    }
    (args.output_dir / "drum-score.json").write_text(
        json.dumps(timeline, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_quantized_midi(events, args.output_dir / "drum-score.mid", tempo)
    write_musicxml(events, measures, args.output_dir / "drum-score.musicxml", args.title)
    render_pdf(
        events,
        measures,
        sections,
        args.output_dir / "drum-score.pdf",
        args.title,
        args.artist,
        tempo,
    )
    strip, background, pixels_per_second, _ = render_scroll_assets(
        events,
        measures,
        sections,
        duration,
        args.output_dir,
        args.title,
        args.artist,
        tempo,
    )
    if args.video:
        render_video(
            strip,
            background,
            args.source_audio,
            duration,
            pixels_per_second,
            args.output_dir / "drum-score-scroll.mp4",
        )
    print(json.dumps(stats, ensure_ascii=False))


if __name__ == "__main__":
    main()
