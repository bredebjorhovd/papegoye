#!/usr/bin/env bash
# Convert NB-Whisper (HF NbAiLab/nb-whisper-*) to WhisperKit CoreML artifacts
# and optionally publish them to a HF repo so `parrot models download` can
# fetch instead of convert.
#
# NB-Whisper is a standard Whisper-architecture fine-tune, so whisperkittools
# conversion applies directly. One-time offline step; needs macOS on Apple
# Silicon with Xcode CLT (coremltools requires it).
#
# Usage:
#   scripts/convert-nb-whisper.sh [variant]            # convert only
#   HF_UPLOAD_REPO=you/nb-whisper-coreml scripts/convert-nb-whisper.sh small
#
#   variant: small (default) | base | tiny | medium | large
#            distil variants: NbAiLab publishes e.g. nb-whisper-small-distil-turbo-beta;
#            pass the full suffix, e.g. "small-distil-turbo-beta".
#
# Output layout mirrors argmaxinc/whisperkit-coreml — one folder per model
# (MelSpectrogram.mlmodelc, AudioEncoder.mlmodelc, TextDecoder.mlmodelc,
# config.json, generation_config.json + tokenizer files) — which is what
# WhisperKitConfig(model:modelRepo:) expects to find.
set -euo pipefail

VARIANT="${1:-small}"
HF_MODEL="NbAiLab/nb-whisper-${VARIANT}"
OUT_DIR="${OUT_DIR:-$PWD/build/nb-whisper-coreml}"
MODEL_NAME="nb-whisper-${VARIANT}"
VENV="${VENV:-$PWD/build/whisperkittools-venv}"

echo "== converting ${HF_MODEL} → ${OUT_DIR}/${MODEL_NAME}"

if [[ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]]; then
    echo "error: conversion requires macOS on Apple Silicon (coremltools + ANE verification)" >&2
    exit 1
fi

# -- toolchain ---------------------------------------------------------------
if [[ ! -d "$VENV" ]]; then
    python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip -q install --upgrade pip
pip -q install "git+https://github.com/argmaxinc/whisperkittools.git" huggingface_hub

# -- convert -----------------------------------------------------------------
mkdir -p "$OUT_DIR"
whisperkit-generate-model \
    --model-version "$HF_MODEL" \
    --output-dir "$OUT_DIR"

# whisperkittools names the output folder after the HF id
# (e.g. nbailab_nb-whisper-small); normalize to our registry's whisperKitID.
GENERATED=$(find "$OUT_DIR" -maxdepth 1 -type d -iname "*nb-whisper-${VARIANT}*" ! -name "$MODEL_NAME" | head -1)
if [[ -n "$GENERATED" && ! -d "$OUT_DIR/$MODEL_NAME" ]]; then
    mv "$GENERATED" "$OUT_DIR/$MODEL_NAME"
fi

echo "== artifacts:"
ls -la "$OUT_DIR/$MODEL_NAME"

# -- sanity checks -----------------------------------------------------------
for required in AudioEncoder.mlmodelc TextDecoder.mlmodelc MelSpectrogram.mlmodelc config.json; do
    if [[ ! -e "$OUT_DIR/$MODEL_NAME/$required" ]]; then
        echo "error: expected $required in output — layout must mirror argmaxinc/whisperkit-coreml" >&2
        exit 1
    fi
done

cat <<EOF

== next steps (acceptance, spec §5):
 1. Transcribe a Norwegian reference clip against the converted model:
      PARROT_NB_MODEL_FOLDER=$OUT_DIR/$MODEL_NAME parrot --bilingual --dump-wav
    and diff against the PyTorch checkpoint's output (whitespace/punctuation
    drift is fine, wording drift is not).
 2. Verify ANE residency while transcribing — don't trust "it ran":
      sudo powermetrics --samplers ane_power -i 1000 -n 5
EOF

# -- publish -----------------------------------------------------------------
if [[ -n "${HF_UPLOAD_REPO:-}" ]]; then
    echo "== uploading to ${HF_UPLOAD_REPO}"
    hf upload "$HF_UPLOAD_REPO" "$OUT_DIR/$MODEL_NAME" "$MODEL_NAME" --repo-type model
    echo "== done. Point ModelRegistry.nbWhisperRepo at ${HF_UPLOAD_REPO} if it isn't already."
else
    echo "== skipping upload (set HF_UPLOAD_REPO=owner/repo to publish)"
fi
