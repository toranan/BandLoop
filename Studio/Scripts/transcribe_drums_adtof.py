#!/usr/bin/env python3
"""Transcribe a separated drum stem into five-class MIDI and JSON events."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pretty_midi
import torch

from adtof_pytorch import (
    FRAME_RNN_THRESHOLDS,
    LABELS_5,
    PeakPicker,
    calculate_n_bins,
    create_frame_rnn_model,
    load_audio_for_model,
    load_pytorch_weights,
)


DRUM_NAMES = {
    35: "kick",
    38: "snare",
    47: "tom",
    42: "hi_hat",
    49: "cymbal",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("weights", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--device", choices=("cpu", "mps", "cuda"), default="mps")
    parser.add_argument("--fps", type=int, default=100)
    parser.add_argument("--chunk-seconds", type=float, default=20.0)
    parser.add_argument("--context-seconds", type=float, default=2.0)
    parser.add_argument(
        "--thresholds",
        default=",".join(str(value) for value in FRAME_RNN_THRESHOLDS),
    )
    return parser.parse_args()


def resolve_device(requested: str) -> str:
    if requested == "mps" and not torch.backends.mps.is_available():
        return "cpu"
    if requested == "cuda" and not torch.cuda.is_available():
        return "cpu"
    return requested


def write_midi(events: list[dict], path: Path) -> None:
    midi = pretty_midi.PrettyMIDI()
    drums = pretty_midi.Instrument(program=0, is_drum=True, name="BandLoop Drums")
    for event in events:
        drums.notes.append(
            pretty_midi.Note(
                velocity=event["velocity"],
                pitch=event["midi_note"],
                start=event["time"],
                end=event["time"] + 0.08,
            )
        )
    drums.notes.sort(key=lambda note: (note.start, note.pitch))
    midi.instruments.append(drums)
    midi.write(str(path))


def infer_in_chunks(
    model: torch.nn.Module,
    features: torch.Tensor,
    device: str,
    fps: int,
    chunk_seconds: float,
    context_seconds: float,
) -> np.ndarray:
    total_frames = features.shape[1]
    chunk_frames = max(1, round(chunk_seconds * fps))
    context_frames = max(0, round(context_seconds * fps))
    output = np.empty((1, total_frames, len(LABELS_5)), dtype=np.float32)

    for core_start in range(0, total_frames, chunk_frames):
        core_end = min(total_frames, core_start + chunk_frames)
        input_start = max(0, core_start - context_frames)
        input_end = min(total_frames, core_end + context_frames)
        chunk = features[:, input_start:input_end].to(device)
        with torch.inference_mode():
            prediction = model(chunk).cpu().numpy()
        local_start = core_start - input_start
        local_end = local_start + (core_end - core_start)
        output[:, core_start:core_end] = prediction[:, local_start:local_end]
        del chunk
        if device == "mps":
            torch.mps.empty_cache()
        print(f"frames {core_start}:{core_end} / {total_frames}", flush=True)

    if not np.isfinite(output).all():
        raise RuntimeError("Model produced non-finite activations")
    return output


def main() -> None:
    args = parse_args()
    output_prefix = args.audio.stem
    thresholds = [float(value) for value in args.thresholds.split(",")]
    if len(thresholds) != len(LABELS_5):
        raise ValueError("Exactly five thresholds are required")

    device = resolve_device(args.device)
    model = create_frame_rnn_model(calculate_n_bins())
    model = load_pytorch_weights(model, str(args.weights), strict=False)
    model.eval().to(device)

    features = load_audio_for_model(str(args.audio))
    activations = infer_in_chunks(
        model,
        features,
        device,
        args.fps,
        args.chunk_seconds,
        args.context_seconds,
    )

    picker = PeakPicker(thresholds=thresholds, fps=args.fps)
    peaks = picker.pick(activations, labels=LABELS_5)[0]
    event_list: list[dict] = []
    activation_frames = activations[0]
    for class_index, midi_note in enumerate(LABELS_5):
        for time in peaks[midi_note]:
            frame = min(round(time * args.fps), len(activation_frames) - 1)
            confidence = float(activation_frames[frame, class_index])
            velocity = int(np.clip(round(48 + confidence * 79), 1, 127))
            event_list.append(
                {
                    "time": round(float(time), 4),
                    "instrument": DRUM_NAMES[midi_note],
                    "midi_note": int(midi_note),
                    "confidence": round(confidence, 4),
                    "velocity": velocity,
                }
            )

    event_list.sort(key=lambda event: (event["time"], event["midi_note"]))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.output_dir / f"{output_prefix}-drum-activations.npz",
        activations=activations.astype(np.float16),
        fps=np.array(args.fps),
        labels=np.array(LABELS_5),
    )
    (args.output_dir / f"{output_prefix}-drum-events-raw.json").write_text(
        json.dumps(
            {
                "source": str(args.audio),
                "model": "ADTOF Frame_RNN PyTorch",
                "device": device,
                "fps": args.fps,
                "thresholds": thresholds,
                "event_count": len(event_list),
                "events": event_list,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    write_midi(event_list, args.output_dir / f"{output_prefix}-drums-raw.mid")
    counts = {
        name: sum(event["instrument"] == name for event in event_list)
        for name in DRUM_NAMES.values()
    }
    print(json.dumps({"device": device, "events": len(event_list), "counts": counts}))


if __name__ == "__main__":
    main()
