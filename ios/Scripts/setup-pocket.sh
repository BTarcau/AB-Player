#!/usr/bin/env bash
# Sets up the on-device Pocket TTS voice (Andrei). Run once, then build the app
# in Xcode as usual.
#
# Puts into ios/PocketRuntime/, which is bundled into the app (about 200 MB):
#  - Kyutai's Pocket TTS, int8 ONNX export packaged by sherpa-onnx
#    (sherpa-onnx-pocket-tts-int8-2026-01-26, CC BY 4.0, attribution to Kyutai),
#    without its sample voices;
#  - the reference clip of each voice in ios/PocketVoices/ (<name>.wav, 24 kHz
#    mono, made with Scripts/pocket-reference.py). Those clips copy real people's
#    voices, so ios/PocketVoices/ stays on this Mac, out of git.
# The sherpa-onnx library itself comes through Swift Package Manager.
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$IOS_DIR/PocketRuntime"
WORK="$IOS_DIR/build/pocket/model-dl"
MODEL=sherpa-onnx-pocket-tts-int8-2026-01-26
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$MODEL.tar.bz2"
SHA256=2f3b88823cbbb9bf0b2477ec8ae7b3fec417b3a87b6bb5f256dba66f2ad967cb

mkdir -p "$WORK"
if [ ! -d "$WORK/$MODEL" ]; then
  echo "Downloading Pocket TTS (about 100 MB)…"
  curl -fL --progress-bar -o "$WORK/pocket.tar.bz2" "$URL"
  echo "$SHA256  $WORK/pocket.tar.bz2" | shasum -a 256 -c -
  tar -xjf "$WORK/pocket.tar.bz2" -C "$WORK"
fi

find "$OUT" -mindepth 1 ! -name README.md -exec rm -rf {} +
for f in lm_flow.int8.onnx lm_main.int8.onnx encoder.onnx decoder.int8.onnx text_conditioner.onnx \
         vocab.json token_scores.json; do
  cp "$WORK/$MODEL/$f" "$OUT/"
done
cp "$WORK/$MODEL/LICENSE" "$OUT/LICENSE-pocket-tts.txt"

mkdir -p "$OUT/voices"
shopt -s nullglob
voices=("$IOS_DIR"/PocketVoices/*.wav)
for v in "${voices[@]}"; do cp "$v" "$OUT/voices/"; done
echo "Pocket TTS is set up in $OUT ($(du -sh "$OUT" | cut -f1)), voices: ${#voices[@]}."
[ ${#voices[@]} -gt 0 ] || echo "No voices: put a reference clip in ios/PocketVoices/ and run this again."
