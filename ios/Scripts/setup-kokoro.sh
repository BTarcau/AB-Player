#!/usr/bin/env bash
# Sets up the on-device Kokoro voice. Run once (takes about 15–30 minutes, mostly
# compiling), then build the app in Xcode as usual.
#
#  1. Builds sherpa-onnx v1.13.8 (Apache-2.0, https://github.com/k2-fsa/sherpa-onnx)
#     for iPhone and the simulator, with ONNX Runtime, into ios/Vendor/.
#     1.13.8 is the last release with the built-in espeak-ng phonemizer that
#     turns text into the sounds Kokoro speaks; 2.x removed it.
#  2. Downloads the Kokoro v1.0 model (Apache-2.0, full precision) and keeps the
#     English parts (about 380 MB) in ios/KokoroModel/, which is bundled into the
#     app. The int8 version is a third the size but adds hiss, sounds duller and
#     was slower on Apple CPUs.
#
# Needs: Xcode, cmake (brew install cmake), git, curl.
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$IOS_DIR/Vendor"
MODEL="$IOS_DIR/KokoroModel"
WORK="$IOS_DIR/build/kokoro-setup"
SHERPA_TAG=v1.13.8
MODEL_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2

mkdir -p "$VENDOR" "$MODEL" "$WORK"

# ---- 1. sherpa-onnx + ONNX Runtime ----
if [ ! -d "$VENDOR/sherpa-onnx.xcframework" ] || [ ! -d "$VENDOR/onnxruntime.xcframework" ]; then
  command -v cmake >/dev/null || { echo "cmake is needed: brew install cmake"; exit 1; }
  if [ ! -d "$WORK/sherpa-onnx" ]; then
    git clone --depth 1 --branch "$SHERPA_TAG" https://github.com/k2-fsa/sherpa-onnx.git "$WORK/sherpa-onnx"
  fi
  cd "$WORK/sherpa-onnx"
  # The script downloads ONNX Runtime with wget; use curl when wget isn't installed.
  command -v wget >/dev/null || sed -i '' 's/wget -c /curl -sSLO /' build-ios.sh
  echo "Building sherpa-onnx for iOS (this takes a while)…"
  ./build-ios.sh

  rm -rf "$VENDOR/sherpa-onnx.xcframework" "$VENDOR/onnxruntime.xcframework"
  cp -R build-ios/sherpa-onnx.xcframework "$VENDOR/"
  cp -RL build-ios/ios-onnxruntime/onnxruntime.xcframework "$VENDOR/"

  # Let `import SherpaOnnxC` link everything it needs by itself.
  for mm in "$VENDOR"/sherpa-onnx.xcframework/*/SherpaOnnxC.framework/Modules/module.modulemap; do
    cat > "$mm" <<'EOF'
framework module SherpaOnnxC {
  header "sherpa-onnx/c-api/c-api.h"
  export *
  link framework "SherpaOnnxC"
  link framework "onnxruntime"
  link "c++"
}
EOF
  done
  echo "Frameworks are in $VENDOR"
fi

# ---- 2. Kokoro model (English voices) ----
if [ ! -f "$MODEL/model.onnx" ]; then
  echo "Downloading the Kokoro v1.0 model…"
  curl -L --fail -o "$WORK/kokoro.tar.bz2" "$MODEL_URL"
  tar -xjf "$WORK/kokoro.tar.bz2" -C "$WORK"
  SRC="$WORK/kokoro-multi-lang-v1_0"
  cp "$SRC/model.onnx" "$SRC/voices.bin" "$SRC/tokens.txt" \
     "$SRC/lexicon-us-en.txt" "$SRC/lexicon-gb-en.txt" "$MODEL/"
  cp "$SRC/LICENSE" "$MODEL/LICENSE-kokoro.txt"
  rm -rf "$MODEL/espeak-ng-data"
  cp -R "$SRC/espeak-ng-data" "$MODEL/"
  rm -rf "$SRC" "$WORK/kokoro.tar.bz2"
  echo "Model is in $MODEL"
fi

echo "Kokoro is set up. Build the app in Xcode."
