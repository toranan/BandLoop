#!/usr/bin/env python3
"""Render a short, conventional five-line drum-score preview.

The onset model used by BandLoop has only five output classes.  This script
re-inspects the separated drum audio around each onset so that toms, cymbals,
and hi-hats can be placed on useful drum-set staff positions.
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
from collections import defaultdict
from pathlib import Path

import librosa
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from build_drum_score import build_measures, quantize_events, section_for_time


FONT = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
LIME = "#D5FF2C"
CORAL = "#FF674F"
PAPER = "#F5F6F1"
MUTED = "#8C9087"
INK = "#0A0B09"
PANEL = "#141612"
GRID = "#50544C"

# Standard drum-set-style vertical ordering on a five-line percussion staff.
# Values are y positions within the transparent 720 px score strip.
NOTE_Y = {
    "crash": 124,
    "ride": 180,
    "open_hi_hat": 152,
    "closed_hi_hat": 152,
    "high_tom": 208,
    "mid_tom": 236,
    "snare": 292,
    "low_tom": 320,
    "floor_tom": 348,
    "kick": 376,
}

MIDI_NOTE = {
    "kick": 36,
    "snare": 38,
    "high_tom": 50,
    "mid_tom": 47,
    "low_tom": 45,
    "floor_tom": 41,
    "closed_hi_hat": 42,
    "open_hi_hat": 46,
    "ride": 51,
    "crash": 49,
}

UPPER_DETAILS = {
    "crash",
    "ride",
    "open_hi_hat",
    "closed_hi_hat",
    "high_tom",
    "mid_tom",
    "low_tom",
    "floor_tom",
    "snare",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw_events", type=Path)
    parser.add_argument("beat_analysis", type=Path)
    parser.add_argument("section_config", type=Path)
    parser.add_argument("drum_audio", type=Path)
    parser.add_argument("source_audio", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--title", default="Untitled")
    parser.add_argument("--artist", default="Unknown Artist")
    return parser.parse_args()


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT, size=size, index=6 if bold else 0)


def spectral_band_energy(
    y: np.ndarray,
    sr: int,
    start: float,
    end: float,
    low_hz: float,
    high_hz: float,
) -> float:
    left = max(0, round(start * sr))
    right = min(len(y), round(end * sr))
    if right - left < 256:
        return 0.0
    segment = y[left:right] * np.hanning(right - left)
    spectrum = np.abs(np.fft.rfft(segment, n=8192)) ** 2
    frequencies = np.fft.rfftfreq(8192, 1.0 / sr)
    selected = (frequencies >= low_hz) & (frequencies < high_hz)
    return float(spectrum[selected].sum() / max(1, right - left))


def spectral_centroid(y: np.ndarray, sr: int, start: float, end: float) -> float:
    left = max(0, round(start * sr))
    right = min(len(y), round(end * sr))
    if right - left < 256:
        return 0.0
    segment = y[left:right] * np.hanning(right - left)
    spectrum = np.abs(np.fft.rfft(segment, n=8192)) ** 2
    frequencies = np.fft.rfftfreq(8192, 1.0 / sr)
    selected = (frequencies >= 1000) & (frequencies < 16000)
    weights = spectrum[selected]
    return float((frequencies[selected] * weights).sum() / (weights.sum() + 1e-12))


def tom_resonance(y: np.ndarray, sr: int, time: float) -> float:
    """Estimate the drum-shell fundamental after the attack."""
    left = max(0, round((time + 0.025) * sr))
    right = min(len(y), round((time + 0.30) * sr))
    if right - left < 1024:
        return 0.0
    segment = y[left:right] * np.hanning(right - left)
    spectrum = np.abs(np.fft.rfft(segment, n=32768))
    frequencies = np.fft.rfftfreq(32768, 1.0 / sr)
    selected = (frequencies >= 60) & (frequencies <= 240)
    local = spectrum[selected]
    return float(frequencies[selected][int(np.argmax(local))])


def classify_events(events: list[dict], drum_audio: Path, duration: float) -> list[dict]:
    y, sr = librosa.load(drum_audio, sr=None, mono=True, duration=duration + 0.6)
    metal_times = sorted(
        float(event["raw_time"])
        for event in events
        if event["instrument"] in ("hi_hat", "cymbal") and float(event["time"]) <= duration
    )
    cymbal_times = sorted(
        float(event["raw_time"])
        for event in events
        if event["instrument"] == "cymbal" and float(event["time"]) <= duration
    )

    enriched: list[dict] = []
    for event in events:
        if float(event["time"]) > duration + 0.02:
            continue
        item = dict(event)
        raw_time = float(item["raw_time"])
        instrument = str(item["instrument"])
        detail = instrument
        features: dict[str, float] = {}

        if instrument == "tom":
            resonance = tom_resonance(y, sr, raw_time)
            features["resonance_hz"] = round(resonance, 1)
            if resonance >= 99:
                detail = "high_tom"
            elif resonance >= 90:
                detail = "mid_tom"
            elif resonance >= 84:
                detail = "low_tom"
            else:
                detail = "floor_tom"
        elif instrument == "cymbal":
            centroid = spectral_centroid(y, sr, raw_time, raw_time + 0.09)
            neighbor = min(
                (abs(raw_time - other) for other in cymbal_times if abs(raw_time - other) > 0.03),
                default=99.0,
            )
            features.update({"centroid_hz": round(centroid, 1), "nearest_cymbal_s": round(neighbor, 3)})
            # Repeated lower-centroid metal hits behave like a ride pattern;
            # isolated broad attacks are written as crashes.
            detail = "ride" if neighbor < 0.95 and centroid < 7600 else "crash"
        elif instrument == "hi_hat":
            early = spectral_band_energy(y, sr, raw_time, raw_time + 0.07, 5000, 16000)
            late = spectral_band_energy(y, sr, raw_time + 0.14, raw_time + 0.28, 5000, 16000)
            decay_ratio = late / (early + 1e-12)
            next_metal_gap = min(
                (other - raw_time for other in metal_times if other > raw_time + 0.03),
                default=99.0,
            )
            centroid = spectral_centroid(y, sr, raw_time, raw_time + 0.08)
            features.update(
                {
                    "centroid_hz": round(centroid, 1),
                    "decay_ratio": round(decay_ratio, 4),
                    "next_metal_gap_s": round(next_metal_gap, 3),
                }
            )
            detail = "open_hi_hat" if decay_ratio > 0.22 and next_metal_gap > 0.28 else "closed_hi_hat"

        item["detail"] = detail
        item["midi_note"] = MIDI_NOTE[detail]
        if features:
            item["audio_features"] = features
        enriched.append(item)
    return enriched


def draw_x_head(draw: ImageDraw.ImageDraw, x: float, y: float, color: str, size: int = 12) -> None:
    draw.line((x - size, y - size, x + size, y + size), fill=color, width=5)
    draw.line((x - size, y + size, x + size, y - size), fill=color, width=5)


def draw_solid_head(draw: ImageDraw.ImageDraw, x: float, y: float, color: str) -> None:
    draw.ellipse((x - 13, y - 9, x + 13, y + 9), fill=color)


def draw_note_head(draw: ImageDraw.ImageDraw, x: float, event: dict) -> None:
    detail = str(event["detail"])
    y = NOTE_Y[detail]
    color = CORAL if event.get("ghost") else PAPER
    if detail in {"crash", "ride", "open_hi_hat", "closed_hi_hat"}:
        draw_x_head(draw, x, y, color)
        if detail == "open_hi_hat":
            draw.ellipse((x - 7, y - 31, x + 7, y - 17), outline=PAPER, width=3)
        if detail == "ride":
            draw.text((x - 8, y - 48), "R", font=font(18, True), fill=MUTED)
        if detail == "crash":
            draw.text((x - 12, y - 52), "CR", font=font(17, True), fill=MUTED)
    else:
        draw_solid_head(draw, x, y, color)
        if event.get("ghost"):
            draw.text((x - 25, y - 22), "(", font=font(35), fill=CORAL)
            draw.text((x + 14, y - 22), ")", font=font(35), fill=CORAL)


def draw_flag(draw: ImageDraw.ImageDraw, stem_x: float, stem_y: float, up: bool, levels: int) -> None:
    direction = 1 if up else -1
    for level in range(levels):
        y = stem_y + direction * level * 13
        if up:
            draw.line((stem_x, y, stem_x + 25, y + 15), fill=PAPER, width=7)
        else:
            draw.line((stem_x, y, stem_x - 25, y - 15), fill=PAPER, width=7)


def draw_voice_beat(
    draw: ImageDraw.ImageDraw,
    events_by_tick: dict[int, list[dict]],
    tick_x: dict[int, float],
    beat_start: int,
    upper: bool,
) -> None:
    ticks = [
        tick
        for tick in range(beat_start, beat_start + 4)
        if any(
            (event["detail"] in UPPER_DETAILS) if upper else (event["detail"] == "kick")
            for event in events_by_tick.get(tick, [])
        )
    ]
    if not ticks:
        return

    stem_points: dict[int, tuple[float, float]] = {}
    selected_by_tick: dict[int, list[dict]] = {}
    for tick in ticks:
        selected = [
            event
            for event in events_by_tick[tick]
            if ((event["detail"] in UPPER_DETAILS) if upper else (event["detail"] == "kick"))
        ]
        selected_by_tick[tick] = selected
        x = tick_x[tick]
        for event in selected:
            draw_note_head(draw, x, event)
        ys = [NOTE_Y[str(event["detail"])] for event in selected]
        if upper:
            stem_x = x + 13
            beam_y = min(ys) - 62
            draw.line((stem_x, max(ys), stem_x, beam_y), fill=PAPER, width=4)
        else:
            stem_x = x - 13
            beam_y = max(ys) + 62
            draw.line((stem_x, min(ys), stem_x, beam_y), fill=PAPER, width=4)
        stem_points[tick] = (stem_x, beam_y)

    if len(ticks) == 1:
        subdivision = ticks[0] - beat_start
        if subdivision:
            levels = 2 if subdivision in (1, 3) else 1
            x, y = stem_points[ticks[0]]
            draw_flag(draw, x, y, upper, levels)
        return

    # Beam within the beat. A one-tick gap receives two beams (16ths), a
    # two-tick gap one beam (8ths). Irregular gaps retain individual flags.
    for left, right in zip(ticks[:-1], ticks[1:]):
        gap = right - left
        levels = 2 if gap == 1 else 1 if gap == 2 else 0
        if not levels:
            continue
        x0, y0 = stem_points[left]
        x1, y1 = stem_points[right]
        y = min(y0, y1) if upper else max(y0, y1)
        for level in range(levels):
            offset = (13 * level) if upper else (-13 * level)
            draw.line((x0, y + offset, x1, y + offset), fill=PAPER, width=9)

    for index, tick in enumerate(ticks):
        connected = False
        if index > 0 and tick - ticks[index - 1] <= 2:
            connected = True
        if index + 1 < len(ticks) and ticks[index + 1] - tick <= 2:
            connected = True
        if not connected:
            x, y = stem_points[tick]
            draw_flag(draw, x, y, upper, 2 if (tick - beat_start) % 2 else 1)


def draw_percussion_clef(draw: ImageDraw.ImageDraw, x: int, line_top: int, line_bottom: int) -> None:
    center = (line_top + line_bottom) // 2
    draw.line((x, center - 47, x, center + 47), fill=PAPER, width=10)
    draw.line((x + 22, center - 47, x + 22, center + 47), fill=PAPER, width=10)


def render_assets(
    events: list[dict],
    measures: list[dict],
    sections: list[dict],
    duration: float,
    output_dir: Path,
    title: str,
    artist: str,
) -> tuple[Path, Path, Path, float]:
    pps = 155.0
    playhead_x = 500
    width = math.ceil(playhead_x + duration * pps + (1920 - playhead_x))
    strip = Image.new("RGBA", (width, 720), (0, 0, 0, 0))
    draw = ImageDraw.Draw(strip)
    staff_lines = [180, 236, 292, 348, 404]
    staff_start = playhead_x - 140
    staff_end = playhead_x + duration * pps + 1420
    for y in staff_lines:
        draw.line((staff_start, y, staff_end, y), fill=GRID, width=3)

    draw_percussion_clef(draw, playhead_x - 122, staff_lines[0], staff_lines[-1])
    draw.text((playhead_x - 78, 198), "4", font=font(45, True), fill=PAPER)
    draw.text((playhead_x - 78, 297), "4", font=font(45, True), fill=PAPER)

    grouped: dict[int, list[dict]] = defaultdict(list)
    for event in events:
        grouped[int(event["measure"])].append(event)

    for measure in measures:
        if float(measure["start"]) > duration:
            continue
        x0 = playhead_x + float(measure["start"]) * pps
        x1 = playhead_x + min(duration, float(measure["end"])) * pps
        draw.line((x0, staff_lines[0], x0, staff_lines[-1]), fill="#9DA198", width=4)
        number = "P" if measure["pickup"] else str(measure["number"])
        draw.text((x0 + 14, 137), number, font=font(24, True), fill=MUTED)

        tick_count = int(measure["tick_count"])
        tick_x = {
            tick: x0 + (tick + 0.5) / tick_count * max(1.0, x1 - x0)
            for tick in range(tick_count)
        }
        by_tick: dict[int, list[dict]] = defaultdict(list)
        for event in grouped.get(int(measure["number"]), []):
            tick = int(event["tick"])
            if tick < tick_count and float(event["time"]) <= duration + 0.02:
                by_tick[tick].append(event)
        beat_starts = range(0, tick_count, 4)
        for beat_start in beat_starts:
            draw_voice_beat(draw, by_tick, tick_x, beat_start, upper=True)
            draw_voice_beat(draw, by_tick, tick_x, beat_start, upper=False)

    end_x = playhead_x + duration * pps
    draw.line((end_x, staff_lines[0], end_x, staff_lines[-1]), fill=PAPER, width=7)

    visible_sections = [section for section in sections if float(section["time"]) <= duration]
    for section in visible_sections:
        x = playhead_x + float(section["time"]) * pps
        label = str(section["label"])
        bbox = draw.textbbox((0, 0), label, font=font(29, True))
        label_width = bbox[2] - bbox[0] + 42
        draw.rounded_rectangle((x + 10, 28, x + label_width, 86), radius=24, fill=LIME)
        draw.text((x + 31, 40), label, font=font(29, True), fill=INK)
        draw.line((x, 95, x, 128), fill=LIME, width=4)

    strip_path = output_dir / "drum-staff-strip-preview.png"
    strip.save(strip_path, optimize=True)

    background = Image.new("RGB", (1920, 1080), INK)
    bg = ImageDraw.Draw(background)
    bg.text((76, 48), title, font=font(64, True), fill=PAPER)
    bg.text((78, 130), f"{artist}  ·  DRUM STAFF", font=font(28, True), fill=MUTED)
    bg.rounded_rectangle((1570, 54, 1838, 136), radius=39, fill=LIME)
    bg.text((1632, 77), "30초 PREVIEW", font=font(26, True), fill=INK)
    bg.rounded_rectangle((54, 244, 1866, 978), radius=35, fill=PANEL, outline="#2D302A", width=3)
    bg.line((playhead_x, 284, playhead_x, 907), fill=LIME, width=5)
    bg.polygon(((playhead_x - 13, 282), (playhead_x + 13, 282), (playhead_x, 303)), fill=LIME)
    bg.text((playhead_x - 44, 245), "현재", font=font(22, True), fill=LIME)
    legend = "CR 크래시   R 라이드   × 하이햇   HT 하이탐   MT 미드탐   LT 로우탐   FT 플로어탐   SD 스네어   BD 킥"
    bg.text((78, 1006), legend, font=font(23, True), fill="#A7AAA1")
    background_path = output_dir / "drum-staff-background-preview.png"
    background.save(background_path, optimize=True)

    # Still image at 12 seconds, useful for checking the notation without
    # seeking through the encoded preview.
    preview_time = min(12.0, duration)
    crop_x = min(max(0, round(preview_time * pps)), width - 1920)
    viewport = strip.crop((crop_x, 0, crop_x + 1920, 720))
    still = background.copy()
    still.alpha_composite(viewport, (0, 284)) if still.mode == "RGBA" else still.paste(viewport, (0, 284), viewport)
    still_path = output_dir / "drum-staff-preview.png"
    still.save(still_path, optimize=True)
    return strip_path, background_path, still_path, pps


def render_video(
    strip: Path,
    background: Path,
    source_audio: Path,
    duration: float,
    pps: float,
    output: Path,
) -> None:
    graph = (
        f"[1:v]crop=1920:720:x='min(max(t*{pps:.3f},0),iw-1920)':y=0[score];"
        "[0:v][score]overlay=0:284:shortest=1,format=yuv420p[v]"
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
    sections = json.loads(args.section_config.read_text(encoding="utf-8"))["sections"]
    measures = build_measures(analysis, args.duration)
    preview_raw_events = [
        event for event in raw["events"] if float(event["time"]) <= args.duration + 0.15
    ]
    events, stats = quantize_events(preview_raw_events, measures)
    events = classify_events(events, args.drum_audio, args.duration)
    counts: dict[str, int] = defaultdict(int)
    for event in events:
        counts[str(event["detail"])] += 1
    stats["detailed_counts"] = dict(sorted(counts.items()))

    args.output_dir.mkdir(parents=True, exist_ok=True)
    result = {
        "title": args.title,
        "artist": args.artist,
        "duration": args.duration,
        "draft": True,
        "classification": "ADTOF 5-class onset + BandLoop audio-feature refinement",
        "stats": stats,
        "events": events,
    }
    json_path = args.output_dir / "drum-staff-events-preview.json"
    json_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    strip, background, still, pps = render_assets(
        events,
        measures,
        sections,
        args.duration,
        args.output_dir,
        args.title,
        args.artist,
    )
    video = args.output_dir / "drum-staff-preview.mp4"
    render_video(strip, background, args.source_audio, args.duration, pps, video)
    print(json.dumps({"video": str(video), "still": str(still), "stats": stats}, ensure_ascii=False))


if __name__ == "__main__":
    main()
