#!/usr/bin/env bash
# Sets up the on-device Kokoro voice. Run once (a few minutes, mostly
# downloading), then build the app in Xcode as usual.
#
# Builds the Kokoro v1.0 models for the Neural Engine (Apache-2.0, from
# https://github.com/mattmireles/kokoro-coreml) into ios/KokoroRuntime/, which
# is bundled into the app (about 195 MB):
#  - the 28 English voices the app offers;
#  - one 15-second model size (the SDK splits longer sentences into pieces);
#  - no ANE+GPU "hybrid" generator, because Lamplight never uses the GPU (iOS
#    refuses it in the background).
# The app compiles the models for the iPhone the first time it loads them
# (about a minute) and keeps them in Application Support.
#
# Needs: git, uv (brew install uv), node.
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$IOS_DIR/KokoroRuntime"
WORK="$IOS_DIR/build/kokoro-setup"
# Keep in step with the kokoro-coreml revision in ABPlayer.xcodeproj.
SDK_COMMIT=b23caa862f0585c2c65187d0fc97e0f8311041dc
# The Hugging Face revision of the models that SDK commit expects
# (KokoroHostedModels.revision in that commit).
HF_REVISION=034f7741bf938fd6b4b9c75c22bc72cd795f908a
VOICES=af_alloy,af_aoede,af_bella,af_heart,af_jessica,af_kore,af_nicole,af_nova,af_river,af_sarah,af_sky,am_adam,am_echo,am_eric,am_fenrir,am_liam,am_michael,am_onyx,am_puck,am_santa,bf_alice,bf_emma,bf_isabella,bf_lily,bm_daniel,bm_fable,bm_george,bm_lewis
BUCKETS=15

command -v uv >/dev/null || { echo "uv is needed: brew install uv"; exit 1; }
command -v node >/dev/null || { echo "node is needed: brew install node"; exit 1; }

# ---- MisakiSwift, patched ----
# kokoro-coreml turns text into phonemes with MisakiSwift (Apache-2.0). For words
# missing from its dictionary it runs a small neural network with MLX, which
# uses the GPU by default; with the screen locked iOS refuses that, and MLX then
# aborts the app. The patch runs that network on the CPU. ABPlayer.xcodeproj
# uses this copy in place of the one kokoro-coreml asks for (same revision).
MISAKI="$IOS_DIR/Packages/MisakiSwift"
MISAKI_COMMIT=3a27756a780fc138e328a96e533fb440a3419d5b
if [ ! -d "$MISAKI/.git" ]; then
  mkdir -p "$IOS_DIR/Packages"
  git clone https://github.com/mattmireles/MisakiSwift.git "$MISAKI"
fi
git -C "$MISAKI" fetch --quiet origin
git -C "$MISAKI" checkout --quiet --force "$MISAKI_COMMIT"
git -C "$MISAKI" apply "$IOS_DIR/Scripts/misaki-cpu-fallback.patch"
echo "MisakiSwift is in $MISAKI (patched to keep off the GPU)."

if [ -f "$OUT/KokoroRuntimeManifest.json" ]; then
  echo "Kokoro is already set up in $OUT. Delete that folder's contents (keep README.md) to rebuild."
  exit 0
fi

mkdir -p "$WORK"
SRC="$WORK/kokoro-coreml"
if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/mattmireles/kokoro-coreml.git "$SRC"
fi
cd "$SRC"
git fetch --quiet origin
git checkout --quiet --force "$SDK_COMMIT"

# Leave the hybrid generator out of the bundle.
git checkout --quiet -- scripts/sdk_profiles.json
uv run python -c "
import json; p = 'scripts/sdk_profiles.json'; d = json.load(open(p))
d['custom']['hybrid_rows'] = {}; json.dump(d, open(p, 'w'), indent=2)"

echo "Downloading the Kokoro models…"
uv run python scripts/download_models.py \
  --repo-id mattmireles/kokoro-coreml --revision "$HF_REVISION" \
  --sdk-profile custom --sdk-voices "$VOICES" --sdk-buckets "$BUCKETS" \
  --manifest-out "$WORK/download-manifest.json"

echo "Building the bundle…"
TMP="$WORK/KokoroRuntime"
rm -rf "$TMP"
node scripts/build_sdk_bundle.mjs \
  --profile custom --voices "$VOICES" --buckets "$BUCKETS" \
  --compile-models 0 --allow-dirty 1 --output "$TMP" \
  --repo-id mattmireles/kokoro-coreml --revision "$HF_REVISION" \
  --download-manifest "$WORK/download-manifest.json"
node scripts/validate_sdk_bundle.mjs "$TMP"
git checkout --quiet -- scripts/sdk_profiles.json

rmdir "$TMP/compiled" 2>/dev/null || true
cp "$SRC/LICENSE" "$TMP/LICENSE-kokoro-coreml.txt"
find "$OUT" -mindepth 1 ! -name README.md -exec rm -rf {} +
cp -R "$TMP"/. "$OUT"/
rm -rf "$TMP"
echo "Kokoro is set up in $OUT ($(du -sh "$OUT" | cut -f1)). Build the app in Xcode."
