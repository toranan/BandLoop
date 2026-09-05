#!/usr/bin/env python3
"""Render a local click-track preview from BandLoop structure-analysis JSON."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf


SAMPLE_RATE = 48_000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("analysis_json", type=Path)
    parser.add_argument("source_audio", type=Path)
    parser.add_argument("output_audio", type=Path)
    parser.add_argument("--start", type=float, default=0.0)
    parser.add_argument("--duration", type=float, default=60.0)
    return parser.parse_args()


def add_click(buffer: np.ndarray, time_seconds: float, frequency: float, amplitude: float) -> None:
    start_sample = round(time_seconds * SAMPLE_RATE)
    click_samples = round(0.055 * SAMPLE_RATE)
    if start_sample < 0 or start_sample >= len(buffer):
        return

    available = min(click_samples, len(buffer) - start_sample)
    time = np.arange(available, dtype=np.float32) / SAMPLE_RATE
    envelope = np.exp(-55.0 * time)
    click = amplitude * np.sin(2.0 * math.pi * frequency * time) * envelope
    buffer[start_sample : start_sample + available] += click.astype(np.float32)


def render_click_track(analysis: dict, start: float, duration: float, output: Path) -> None:
    samples = np.zeros(round(duration * SAMPLE_RATE), dtype=np.float32)
    beats = analysis["beats"]
    positions = analysis.get("beat_positions", [])

    for index, absolute_time in enumerate(beats):
        relative_time = absolute_time - start
        if not 0 <= relative_time < duration:
            continue
        is_downbeat = index < len(positions) and positions[index] == 1
        add_click(
            samples,
            relative_time,
            frequency=1_760.0 if is_downbeat else 880.0,
            amplitude=0.86 if is_downbeat else 0.58,
        )

    np.clip(samples, -0.98, 0.98, out=samples)
    sf.write(output, samples, SAMPLE_RATE, subtype="PCM_16")


def mix_preview(source: Path, click_track: Path, output: Path, start: float, duration: float) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "ffmpeg",
        "-y",
        "-ss",
        f"{start:.3f}",
        "-t",
        f"{duration:.3f}",
        "-i",
        str(source),
        "-i",
        str(click_track),
        "-filter_complex",
        "[0:a]volume=0.72[music];"
        "[1:a]volume=0.90,pan=stereo|c0=c0|c1=c0[click];"
        "[music][click]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[out]",
        "-map",
        "[out]",
        "-ar",
        str(SAMPLE_RATE),
        "-c:a",
        "aac",
        "-b:a",
        "256k",
        str(output),
    ]
    subprocess.run(command, check=True)


def main() -> None:
    args = parse_args()
    analysis = json.loads(args.analysis_json.read_text(encoding="utf-8"))

    with tempfile.TemporaryDirectory(prefix="bandloop-click-") as temp_dir:
        click_track = Path(temp_dir) / "click.wav"
        render_click_track(analysis, args.start, args.duration, click_track)
        mix_preview(
            args.source_audio,
            click_track,
            args.output_audio,
            args.start,
            args.duration,
        )


if __name__ == "__main__":
    main()
