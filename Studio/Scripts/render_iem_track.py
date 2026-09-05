#!/usr/bin/env python3
"""Render a full-song BandLoop IEM mix from beat analysis and cue metadata."""

from __future__ import annotations

import argparse
import json
import math
import statistics
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf


SAMPLE_RATE = 48_000
COUNT_WORDS = ("하나", "둘", "셋", "넷")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("analysis_json", type=Path)
    parser.add_argument("cue_config", type=Path)
    parser.add_argument("source_audio", type=Path)
    parser.add_argument("voice_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--slug")
    parser.add_argument("--fixed-bpm", type=float)
    return parser.parse_args()


def add_click(
    buffer: np.ndarray,
    time_seconds: float,
    frequency: float,
    amplitude: float,
) -> None:
    start = round(time_seconds * SAMPLE_RATE)
    length = round(0.05 * SAMPLE_RATE)
    if start < 0 or start >= len(buffer):
        return

    available = min(length, len(buffer) - start)
    time = np.arange(available, dtype=np.float32) / SAMPLE_RATE
    envelope = np.exp(-62.0 * time)
    fundamental = np.sin(2.0 * math.pi * frequency * time)
    overtone = 0.24 * np.sin(2.0 * math.pi * frequency * 1.87 * time)
    click = amplitude * (fundamental + overtone) * envelope
    buffer[start : start + available] += click.astype(np.float32)


def load_voice(path: Path) -> np.ndarray:
    audio, sample_rate = sf.read(path, dtype="float32")
    if audio.ndim == 2:
        audio = audio.mean(axis=1)
    if sample_rate != SAMPLE_RATE:
        raise ValueError(f"Voice sample must be {SAMPLE_RATE} Hz: {path}")

    peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
    if peak == 0:
        raise ValueError(f"Voice sample is empty: {path}")

    active = np.flatnonzero(np.abs(audio) >= peak * 0.015)
    if len(active):
        padding = round(0.012 * SAMPLE_RATE)
        first = max(0, int(active[0]) - padding)
        last = min(len(audio), int(active[-1]) + padding + 1)
        audio = audio[first:last]

    return audio * (0.94 / max(float(np.max(np.abs(audio))), 1e-6))


def add_voice(buffer: np.ndarray, sample: np.ndarray, time_seconds: float) -> None:
    start = round(time_seconds * SAMPLE_RATE)
    if start < 0 or start >= len(buffer):
        return
    available = min(len(sample), len(buffer) - start)
    buffer[start : start + available] += sample[:available]


def find_voice_sample(voice_dir: Path, text: str) -> Path:
    manifest_path = voice_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    filename = manifest.get(text)
    if not filename:
        raise KeyError(f"Missing voice sample for {text!r} in {manifest_path}")
    return voice_dir / filename


def beat_period(analysis: dict) -> float:
    beats = analysis["beats"]
    return statistics.median(b - a for a, b in zip(beats, beats[1:]))


def cue_measure_beats(analysis: dict, target: float) -> list[float]:
    downbeats = analysis["downbeats"]
    previous = [time for time in downbeats if time < target - 0.15]
    if not previous:
        raise ValueError(f"No preceding measure for cue at {target:.3f}")
    start = previous[-1]
    beats = analysis["beats"]
    positions = analysis["beat_positions"]
    result = [
        time
        for time, position in zip(beats, positions)
        if start - 0.05 <= time < target - 0.05 and position in (1, 2, 3, 4)
    ]
    if len(result) < 4:
        period = beat_period(analysis)
        result = [start + index * period for index in range(4)]
    return result[:4]


def render_guide(
    analysis: dict,
    config: dict,
    voice_dir: Path,
    source_duration: float,
    fixed_bpm: float | None = None,
) -> tuple[np.ndarray, dict]:
    if fixed_bpm is not None and fixed_bpm <= 0:
        raise ValueError("Fixed BPM must be greater than zero")
    period = 60.0 / fixed_bpm if fixed_bpm is not None else beat_period(analysis)
    first_beat_time = float(analysis["beats"][0])
    first_beat_position = int(analysis["beat_positions"][0])
    # Opening only: announce the start, play two pickup clicks, give one full
    # count-in measure, then place the first detected beat.
    announcement_beats = 3
    count_in_beats = 4
    grid_beats_before_entry = announcement_beats + count_in_beats
    source_offset = grid_beats_before_entry * period - first_beat_time
    total_duration = source_offset + source_duration
    click = np.zeros(round(total_duration * SAMPLE_RATE), dtype=np.float32)
    voice = np.zeros_like(click)

    # No click masks the announcement. Two pickup clicks lead into the count.
    for index in range(grid_beats_before_entry):
        if index == 0:
            continue
        add_click(
            click,
            index * period,
            frequency=1_760.0 if index % 4 == 0 else 920.0,
            amplitude=0.72 if index % 4 == 0 else 0.50,
        )

    opening_announcement = "곡 시작"
    add_voice(
        voice,
        load_voice(find_voice_sample(voice_dir, opening_announcement)),
        0.0,
    )

    opening_words = COUNT_WORDS
    for index, word in enumerate(opening_words):
        add_voice(
            voice,
            load_voice(find_voice_sample(voice_dir, word)),
            (announcement_beats + index) * period,
        )

    if fixed_bpm is not None:
        source_beats = np.arange(first_beat_time, source_duration, period)
        source_positions = [
            ((first_beat_position - 1 + index) % 4) + 1
            for index in range(len(source_beats))
        ]
    else:
        source_beats = analysis["beats"]
        source_positions = analysis["beat_positions"]

    for time, position in zip(source_beats, source_positions):
        add_click(
            click,
            source_offset + time,
            frequency=1_760.0 if position == 1 else 920.0,
            amplitude=0.70 if position == 1 else 0.47,
        )

    rendered_sections: list[dict] = []
    for index, section in enumerate(config["sections"]):
        rendered_sections.append(
            {
                **section,
                "rendered_time": round(source_offset + float(section["time"]), 3),
            }
        )
        if index == 0:
            continue
        if fixed_bpm is not None:
            target_index = round((float(section["time"]) - first_beat_time) / period)
            measure_beats = [
                first_beat_time + (target_index - 4 + offset) * period
                for offset in range(4)
            ]
        else:
            measure_beats = cue_measure_beats(analysis, float(section["time"]))
        words = (section["label"], "둘", "셋", "넷")
        for time, word in zip(measure_beats, words):
            add_voice(
                voice,
                load_voice(find_voice_sample(voice_dir, word)),
                source_offset + time,
            )

    guide = np.stack((click * 0.64 + voice * 0.96,) * 2, axis=1)
    np.clip(guide, -0.98, 0.98, out=guide)
    timeline = {
        "title": config["title"],
        "source_offset": round(source_offset, 3),
        "entry_beat_position": first_beat_position,
        "opening_announcement": opening_announcement,
        "pickup_clicks": 2,
        "count_in_pattern": list(opening_words),
        "beat_period": round(period, 6),
        "estimated_bpm": round(60.0 / period, 2),
        "tempo_mode": "fixed" if fixed_bpm is not None else "detected",
        "duration": round(total_duration, 3),
        "sections": rendered_sections,
    }
    return guide, timeline


def probe_duration(path: Path) -> float:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(path),
    ]
    return float(subprocess.check_output(command, text=True).strip())


def encode_outputs(
    source: Path,
    guide_wav: Path,
    output_dir: Path,
    source_offset: float,
    slug: str,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    delay_ms = round(source_offset * 1_000)

    full_mix = output_dir / f"{slug}-iem-full-mix.m4a"
    command = [
        "ffmpeg",
        "-y",
        "-v",
        "error",
        "-i",
        str(source),
        "-i",
        str(guide_wav),
        "-filter_complex",
        f"[0:a]volume=0.70,adelay={delay_ms}:all=1[music];"
        "[1:a]volume=0.95[guide];"
        "[music][guide]amix=inputs=2:duration=longest:normalize=0,"
        "alimiter=limit=0.85:level=false[out]",
        "-map",
        "[out]",
        "-ar",
        str(SAMPLE_RATE),
        "-c:a",
        "aac",
        "-b:a",
        "320k",
        str(full_mix),
    ]
    subprocess.run(command, check=True)

    guide_only = output_dir / f"{slug}-click-guide-only.m4a"
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-v",
            "error",
            "-i",
            str(guide_wav),
            "-ar",
            str(SAMPLE_RATE),
            "-c:a",
            "aac",
            "-b:a",
            "256k",
            str(guide_only),
        ],
        check=True,
    )

    split_mix = output_dir / f"{slug}-iem-split-music-left-guide-right.m4a"
    split_command = [
        "ffmpeg",
        "-y",
        "-v",
        "error",
        "-i",
        str(source),
        "-i",
        str(guide_wav),
        "-filter_complex",
        f"[0:a]volume=0.82,adelay={delay_ms}:all=1,pan=mono|c0=.5*c0+.5*c1[music];"
        "[1:a]volume=0.98,pan=mono|c0=.5*c0+.5*c1[guide];"
        "[music][guide]amerge=inputs=2,alimiter=limit=0.85:level=false[out]",
        "-map",
        "[out]",
        "-ac",
        "2",
        "-ar",
        str(SAMPLE_RATE),
        "-c:a",
        "aac",
        "-b:a",
        "320k",
        str(split_mix),
    ]
    subprocess.run(split_command, check=True)


def main() -> None:
    args = parse_args()
    slug = args.slug or args.source_audio.stem
    analysis = json.loads(args.analysis_json.read_text(encoding="utf-8"))
    config = json.loads(args.cue_config.read_text(encoding="utf-8"))
    source_duration = probe_duration(args.source_audio)
    guide, timeline = render_guide(
        analysis,
        config,
        args.voice_dir,
        source_duration,
        args.fixed_bpm,
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bandloop-iem-") as temp_dir:
        guide_wav = Path(temp_dir) / "guide.wav"
        sf.write(guide_wav, guide, SAMPLE_RATE, subtype="PCM_16")
        encode_outputs(
            args.source_audio,
            guide_wav,
            args.output_dir,
            float(timeline["source_offset"]),
            slug,
        )

    (args.output_dir / f"{slug}-iem-timeline.json").write_text(
        json.dumps(timeline, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
