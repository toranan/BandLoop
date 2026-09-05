#!/usr/bin/env python3
"""One-command BandLoop pipeline: song + artwork -> IEM mix + upload MP4."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent

SECTION_LABELS = {
    "intro": "인트로",
    "verse": "벌스",
    "pre-chorus": "프리 코러스",
    "prechorus": "프리 코러스",
    "chorus": "코러스",
    "bridge": "브릿지",
    "instrumental": "간주",
    "interlude": "간주",
    "solo": "솔로",
    "outro": "아웃트로",
}

KOREAN_NUMBERS = ("하나", "둘", "셋", "넷", "다섯", "여섯")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create beat analysis, IEM audio variants, and a static album-art MP4."
    )
    parser.add_argument("source_audio", type=Path)
    parser.add_argument("album_image", type=Path)
    parser.add_argument("--title", required=True)
    parser.add_argument("--artist", required=True)
    parser.add_argument("--slug")
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--analysis-json", type=Path)
    parser.add_argument("--cue-config", type=Path)
    parser.add_argument("--voice-dir", type=Path)
    parser.add_argument("--voice", default="Yuna")
    parser.add_argument("--fixed-bpm", type=float)
    parser.add_argument("--force-analysis", action="store_true")
    return parser.parse_args()


def slugify(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value)
    ascii_value = normalized.encode("ascii", "ignore").decode("ascii").lower()
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_value).strip("-")
    return slug or "track"


def run(command: list[str], stage: str) -> None:
    print(f"[{stage}]", flush=True)
    subprocess.run(command, check=True)


def require_file(path: Path, description: str) -> Path:
    path = path.expanduser().resolve()
    if not path.is_file():
        raise FileNotFoundError(f"{description} not found: {path}")
    return path


def find_analysis(analysis_dir: Path, source: Path) -> Path:
    expected = analysis_dir / f"{source.stem}.json"
    if expected.is_file():
        return expected
    candidates = sorted(analysis_dir.glob("*.json"), key=lambda path: path.stat().st_mtime)
    if not candidates:
        raise FileNotFoundError(f"Analysis JSON was not created in {analysis_dir}")
    return candidates[-1]


def analyze_song(source: Path, analysis_dir: Path, force: bool) -> Path:
    analysis_dir.mkdir(parents=True, exist_ok=True)
    existing = analysis_dir / f"{source.stem}.json"
    if existing.is_file() and not force:
        print("[analysis: cached]", flush=True)
        return existing
    command = [
        sys.executable,
        "-m",
        "allin1_mlx.cli",
        str(source),
        "--out-dir",
        str(analysis_dir),
        "--no-multiprocess",
        "--no-ensemble-parallel",
    ]
    if force:
        command.extend(("--overwrite", "all"))
    run(command, "analysis")
    return find_analysis(analysis_dir, source)


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


def merged_segments(analysis: dict) -> list[dict]:
    ignored = {"start", "end", "silence"}
    result: list[dict] = []
    for segment in sorted(analysis.get("segments", []), key=lambda item: float(item["start"])):
        label = str(segment.get("label", "")).strip().lower().replace("_", "-")
        if not label or label in ignored:
            continue
        start = float(segment["start"])
        end = float(segment.get("end", start))
        if result and result[-1]["label"] == label and start <= result[-1]["end"] + 0.35:
            result[-1]["end"] = max(result[-1]["end"], end)
        else:
            result.append({"start": start, "end": end, "label": label})
    return result


def snap_to_downbeat(time: float, downbeats: list[float]) -> float:
    if not downbeats:
        return time
    nearest = min(downbeats, key=lambda value: abs(value - time))
    return nearest if abs(nearest - time) <= 1.0 else time


def auto_cue_config(analysis: dict, title: str, duration: float) -> dict:
    segments = merged_segments(analysis)
    if not segments:
        return {"title": title, "sections": [{"time": 0.0, "label": "연주 시작"}]}

    downbeats = [float(value) for value in analysis.get("downbeats", [])]
    verse_number = 0
    last_chorus = max(
        (index for index, segment in enumerate(segments) if segment["label"] == "chorus"),
        default=-1,
    )
    sections: list[dict] = []
    for index, segment in enumerate(segments):
        source_label = segment["label"]
        label = SECTION_LABELS.get(source_label, source_label.replace("-", " "))
        if source_label == "verse":
            verse_number += 1
            suffix = KOREAN_NUMBERS[min(verse_number, len(KOREAN_NUMBERS)) - 1]
            label = f"벌스 {suffix}"
        elif source_label == "chorus" and index == last_chorus and segment["start"] >= duration * 0.70:
            label = "마지막 코러스"

        time = 0.0 if not sections else snap_to_downbeat(float(segment["start"]), downbeats)
        item = {"time": round(time, 3), "label": label}
        if sections and item["label"] == sections[-1]["label"]:
            continue
        sections.append(item)
    if sections:
        sections[0]["time"] = 0.0
    return {"title": title, "sections": sections}


def prepare_cue_config(analysis_path: Path, title: str, source: Path, destination: Path) -> Path:
    analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
    config = auto_cue_config(analysis, title, probe_duration(source))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return destination


def validate_voice_dir(voice_dir: Path, labels: list[str]) -> bool:
    manifest_path = voice_dir / "manifest.json"
    if not manifest_path.is_file():
        return False
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    return all(label in manifest and (voice_dir / manifest[label]).is_file() for label in labels)


def generate_voices(config_path: Path, voice_dir: Path, voice_name: str) -> Path:
    config = json.loads(config_path.read_text(encoding="utf-8"))
    labels = list(
        dict.fromkeys(
            [section["label"] for section in config["sections"]]
            + ["곡 시작", "하나", "둘", "셋", "넷"]
        )
    )
    if validate_voice_dir(voice_dir, labels):
        print("[voice: cached]", flush=True)
        return voice_dir

    if shutil.which("say") is None:
        raise RuntimeError("macOS 'say' command is required to generate Korean guide voices")
    voice_dir.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, str] = {}
    with tempfile.TemporaryDirectory(prefix="bandloop-voice-") as temp_dir:
        temp = Path(temp_dir)
        for index, label in enumerate(labels, start=1):
            filename = f"cue-{index:02d}.wav"
            aiff = temp / f"cue-{index:02d}.aiff"
            run(["say", "-v", voice_name, "-r", "205", "-o", str(aiff), label], f"voice {index}/{len(labels)}")
            subprocess.run(
                [
                    "ffmpeg",
                    "-y",
                    "-v",
                    "error",
                    "-i",
                    str(aiff),
                    "-ac",
                    "1",
                    "-ar",
                    "48000",
                    "-c:a",
                    "pcm_s16le",
                    str(voice_dir / filename),
                ],
                check=True,
            )
            manifest[label] = filename
    (voice_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return voice_dir


def main() -> None:
    args = parse_args()
    source = require_file(args.source_audio, "Source audio")
    artwork = require_file(args.album_image, "Album image")
    slug = args.slug or slugify(args.title)
    project_dir = (args.work_dir or Path("Studio/Test") / slug).resolve()
    analysis_dir = project_dir / "analysis"
    config_dir = project_dir / "config"
    generated_voice_dir = project_dir / "voice"
    rendered_dir = project_dir / "rendered"
    rendered_dir.mkdir(parents=True, exist_ok=True)

    analysis_path = (
        require_file(args.analysis_json, "Analysis JSON")
        if args.analysis_json
        else analyze_song(source, analysis_dir, args.force_analysis)
    )
    cue_config = (
        require_file(args.cue_config, "Cue config")
        if args.cue_config
        else prepare_cue_config(analysis_path, args.title, source, config_dir / f"{slug}-iem-cues.json")
    )
    voice_dir = (
        args.voice_dir.expanduser().resolve()
        if args.voice_dir
        else generated_voice_dir
    )
    voice_dir = generate_voices(cue_config, voice_dir, args.voice)

    run(
        [
            sys.executable,
            str(SCRIPT_DIR / "render_iem_track.py"),
            str(analysis_path),
            str(cue_config),
            str(source),
            str(voice_dir),
            str(rendered_dir),
            "--slug",
            slug,
            *(["--fixed-bpm", str(args.fixed_bpm)] if args.fixed_bpm is not None else []),
        ],
        "IEM audio",
    )

    full_mix = rendered_dir / f"{slug}-iem-full-mix.m4a"
    video = rendered_dir / f"{slug}-iem-video.mp4"
    run(
        [
            sys.executable,
            str(SCRIPT_DIR / "render_album_video.py"),
            str(artwork),
            str(full_mix),
            str(video),
            "--title",
            args.title,
            "--artist",
            args.artist,
        ],
        "album video",
    )

    outputs = {
        "title": args.title,
        "artist": args.artist,
        "slug": slug,
        "source_audio": str(source),
        "album_image": str(artwork),
        "analysis_json": str(analysis_path),
        "cue_config": str(cue_config),
        "voice_dir": str(voice_dir),
        "fixed_bpm": args.fixed_bpm,
        "full_mix": str(full_mix),
        "guide_only": str(rendered_dir / f"{slug}-click-guide-only.m4a"),
        "split_mix": str(rendered_dir / f"{slug}-iem-split-music-left-guide-right.m4a"),
        "video": str(video),
        "cover": str(video.with_suffix(".png")),
    }
    manifest = project_dir / "pipeline-manifest.json"
    manifest.write_text(json.dumps(outputs, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"complete": True, "video": str(video), "manifest": str(manifest)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
