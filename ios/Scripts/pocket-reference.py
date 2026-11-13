# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "numpy<2.1",
#   "soundfile",
#   "librosa",
#   "pyloudnorm",
#   "sherpa-onnx==2.0.1",
# ]
# ///
"""Picks reference clips for the Pocket TTS voice from a narrator recording.

Pocket TTS copies a voice from a short clip, so the clip decides how the voice
sounds. This finds a few candidate stretches of steady narration (12-15 s, one
voice, no clipping, starting and ending at real pauses rather than mid-word),
turns each into a clip the model expects (mono, 24 kHz, starting right on the
first word and ending ~100 ms after the last, loudness evened to -20 LUFS, no denoising), and reads the same test
paragraph with each, so you can choose by ear.

Usage (from ios/):
  uv run Scripts/pocket-reference.py RECORDING [TRANSCRIPT] --model DIR [--count 3]

DIR is the unpacked sherpa-onnx-pocket-tts-int8-2026-01-26 folder. Writes to
build/pocket/reference/: candidate-N.wav (the clip), candidate-N-test.wav (the
test paragraph in that voice) and candidates.txt (where each clip came from).
The recording and the clips stay out of git: build/ is ignored.
"""
import argparse
import re
import subprocess
import time
from pathlib import Path

import librosa
import numpy as np
import pyloudnorm
import sherpa_onnx
import soundfile as sf

IOS = Path(__file__).resolve().parent.parent
OUT = IOS / "build" / "pocket" / "reference"
SR = 24000
HOP = 0.01  # seconds per analysis frame

TEST = (
    "Chapter One. It was late in the autumn when the stranger came to the village. "
    "He carried nothing but a small leather case, and he asked for a room facing the sea. "
    "Nobody knew his name, and for a while, nobody thought to ask. "
    "The innkeeper's wife, who noticed everything, said only that he had kind eyes, "
    "and that kind eyes were the most dangerous kind."
)
# Same settings the app will use, so what you hear here is what the phone makes.
SEED, TEMPERATURE, STEPS = 42, 0.7, 4


def decode(path, sr, mono):
    cmd = ["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-ar", str(sr), "-ac", "1" if mono else "2", "-"]
    raw = np.frombuffer(subprocess.run(cmd, capture_output=True, check=True).stdout, dtype=np.float32)
    return raw if mono else raw.reshape(-1, 2)


def read_transcript(path):
    """[(seconds, text)] from lines like '1:08' + '1 minute, 8 seconds' + text."""
    lines = []
    if not path:
        return lines
    for line in Path(path).read_text().splitlines():
        m = re.match(r"^(?:(\d+):)?(\d+):(\d\d)(.*)$", line)
        if not m:
            continue
        h, mnt, s, rest = m.groups()
        t = int(h or 0) * 3600 + int(mnt) * 60 + int(s)
        rest = re.sub(r"^(\d+ (hours?|minutes?|seconds?),? ?)+", "", rest)
        rest = re.sub(r"^\d+ seconds?", "", rest)
        lines.append((t, rest.strip()))
    return lines


def text_near(lines, start, end):
    return " ".join(t for (s, t), nxt in zip(lines, lines[1:] + [(1e9, "")]) if nxt[0] > start and s < end)


def find_candidates(audio, stereo, lines, count, lo, hi):
    hop = int(HOP * SR)
    rms = librosa.feature.rms(y=audio, frame_length=2 * hop, hop_length=hop)[0]
    db = 20 * np.log10(rms + 1e-9)
    speech_level = np.percentile(db, 90)
    voiced = db > speech_level - 35
    # Pauses: runs of quiet frames at least 300 ms long.
    pauses, i, n = [], 0, len(voiced)
    while i < n:
        if not voiced[i]:
            j = i
            while j < n and not voiced[j]:
                j += 1
            if (j - i) * HOP >= 0.3:
                pauses.append((i * HOP, j * HOP))
            i = j
        else:
            i += 1
    # Pitch over the whole recording once (cheap YIN), to judge steadiness.
    f0 = librosa.yin(audio, fmin=60, fmax=300, sr=SR, frame_length=2048, hop_length=hop)
    cands = []
    for a in range(len(pauses)):
        start = pauses[a][1]
        for b in range(a + 1, len(pauses)):
            end = pauses[b][0]
            length = end - start
            if length > hi:
                break
            if length < lo:
                continue
            s0, s1 = int(start * SR), int(end * SR)
            # Clipping in the original recording.
            st = stereo[int(start * 44100):int(end * 44100)]
            if st.size == 0 or np.abs(st).max() >= 0.98:
                continue
            f = slice(int(start / HOP), int(end / HOP))
            seg_db, seg_f0 = db[f], f0[f]
            loud = seg_db[seg_db > speech_level - 20]
            pitch = seg_f0[(seg_f0 > 65) & (seg_f0 < 290) & (seg_db > speech_level - 20)]
            if len(pitch) < 200:
                continue
            # One steady narrator: a narrow pitch spread (character voices jump)
            # and an even loudness.
            pitch_spread = float(np.std(np.log2(pitch)))
            loud_spread = float(np.std(loud))
            # Clean edges: the pauses around the clip are quiet (no breath or click).
            edge_noise = max(np.percentile(db[int(pauses[a][0] / HOP):int(start / HOP)], 90),
                             np.percentile(db[int(end / HOP):int(pauses[b][1] / HOP)], 90)) - speech_level
            text = text_near(lines, start, end)
            quotes = text.count('"') + text.count("“") + text.count("”")
            score = -pitch_spread * 10 - loud_spread * 0.1 - max(0, edge_noise + 45) * 0.05 - quotes * 0.5 \
                + 0.2 * min(pauses[a][1] - pauses[a][0], 0.8) + 0.2 * min(pauses[b][1] - pauses[b][0], 0.8)
            cands.append(dict(start=start, end=end, score=score, pitch_spread=pitch_spread,
                              loud_spread=loud_spread, edge_noise=edge_noise, quotes=quotes,
                              median_f0=float(np.median(pitch)), text=text))
    cands.sort(key=lambda c: -c["score"])
    picked = []
    for c in cands:
        # Spread the picks through the book, so they aren't three takes of one moment.
        if all(abs(c["start"] - p["start"]) > 120 for p in picked):
            picked.append(c)
        if len(picked) == count:
            break
    return picked


def make_clip(audio, start, end):
    # No silence before the first word: with a lead-in, Pocket drops the first
    # word of most sentences it reads (8 of 10 in a test, against 2 of 10 without).
    pad = int(0.1 * SR)
    clip = audio[int(start * SR):int(end * SR) + pad].copy()
    fade_in, fade_out = int(0.005 * SR), int(0.01 * SR)
    clip[:fade_in] *= np.linspace(0, 1, fade_in)
    clip[-fade_out:] *= np.linspace(1, 0, fade_out)
    meter = pyloudnorm.Meter(SR)
    clip = pyloudnorm.normalize.loudness(clip, meter.integrated_loudness(clip), -20.0)
    peak = np.abs(clip).max()
    if peak > 0.89:  # keep peaks under -1 dBFS
        clip *= 0.89 / peak
    return clip.astype(np.float32)


def pocket(model_dir):
    d = Path(model_dir)
    cfg = sherpa_onnx.OfflineTtsConfig(
        model=sherpa_onnx.OfflineTtsModelConfig(
            pocket=sherpa_onnx.OfflineTtsPocketModelConfig(
                lm_flow=str(d / "lm_flow.int8.onnx"), lm_main=str(d / "lm_main.int8.onnx"),
                encoder=str(d / "encoder.onnx"), decoder=str(d / "decoder.int8.onnx"),
                text_conditioner=str(d / "text_conditioner.onnx"), vocab_json=str(d / "vocab.json"),
                token_scores_json=str(d / "token_scores.json")),
            num_threads=2, provider="cpu"))
    return sherpa_onnx.OfflineTts(cfg)


def speak(tts, clip, text):
    g = sherpa_onnx.GenerationConfig()
    g.reference_audio = clip.tolist()
    g.reference_sample_rate = SR
    g.num_steps = STEPS
    g.extra = {"seed": str(SEED), "temperature": str(TEMPERATURE), "max_reference_audio_len": "16"}
    t0 = time.time()
    out = tts.generate(text, g)
    return np.array(out.samples, dtype=np.float32), out.sample_rate, time.time() - t0


def clock(t):
    return f"{int(t // 3600)}:{int(t % 3600 // 60):02d}:{t % 60:05.2f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recording")
    ap.add_argument("transcript", nargs="?")
    ap.add_argument("--model", required=True)
    ap.add_argument("--count", type=int, default=3)
    ap.add_argument("--min", type=float, default=12.0, help="shortest clip, seconds of speech")
    ap.add_argument("--max", type=float, default=14.6, help="longest clip, seconds of speech")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    print("Reading the recording…", flush=True)
    audio = decode(args.recording, SR, mono=True)
    stereo = decode(args.recording, 44100, mono=False)
    lines = read_transcript(args.transcript)
    picks = find_candidates(audio, stereo, lines, args.count, args.min, args.max)
    if not picks:
        raise SystemExit("No stretch of steady narration found; try a wider --min/--max.")

    tts = pocket(args.model)
    report = [f"Test paragraph: {TEST}", f"Settings: seed {SEED}, temperature {TEMPERATURE}, steps {STEPS}", ""]
    for n, c in enumerate(picks, 1):
        clip = make_clip(audio, c["start"], c["end"])
        sf.write(OUT / f"candidate-{n}.wav", clip, SR, subtype="PCM_16")
        speech, rate, took = speak(tts, clip, TEST)
        sf.write(OUT / f"candidate-{n}-test.wav", speech, rate, subtype="PCM_16")
        dur = len(speech) / rate
        line = (f"candidate-{n}: {clock(c['start'])} to {clock(c['end'])} in the source "
                f"({c['end'] - c['start']:.1f} s of speech, clip {len(clip) / SR:.1f} s); "
                f"pitch {c['median_f0']:.0f} Hz, pitch spread {c['pitch_spread']:.3f} oct, "
                f"loudness spread {c['loud_spread']:.1f} dB, edge noise {c['edge_noise']:.0f} dB; "
                f"test read {dur:.1f} s in {took:.1f} s on this Mac's CPU (RTF {took / dur:.2f})\n"
                f"    around: {c['text'][:300]}")
        print(line, flush=True)
        report.append(line)
    (OUT / "candidates.txt").write_text("\n".join(report) + "\n")
    print(f"Wrote {OUT}", flush=True)


if __name__ == "__main__":
    main()
