#!/usr/bin/env bash
# Rebuilds ComfyUI venv under native ARM64 Python and downloads the model
# weights we agreed on for a 16 GB Apple Silicon Mac:
#   - Flux Schnell (image, ~17 GB)
#   - MusicGen Medium (audio, ~3 GB)
#   - SD 1.5 + AnimateDiff motion module (video, ~6 GB)
#
# Run from anywhere:
#   bash ~/Documents/LLM/scripts/setup-comfyui.sh
#
# Pulls only what's missing — safe to re-run if interrupted.

set -euo pipefail

COMFY=~/ComfyUI
ARM_PY=/opt/homebrew/bin/python3.12

if [ ! -x "$ARM_PY" ]; then
  echo "✗ ARM64 Python missing at $ARM_PY"
  echo "  Run: /opt/homebrew/bin/brew install python@3.12"
  exit 1
fi

echo "→ Building ARM64 venv at $COMFY/venv"
"$ARM_PY" -m venv "$COMFY/venv"
source "$COMFY/venv/bin/activate"
python -c "import platform; print('arch:', platform.machine())"
pip install --upgrade pip
pip install -r "$COMFY/requirements.txt"

echo
echo "→ Sanity check"
python - <<'PY'
import torch, transformers, numpy
print(f"torch {torch.__version__} | mps={torch.backends.mps.is_available()}")
print(f"transformers {transformers.__version__}")
print(f"numpy {numpy.__version__}")
PY

# Helper: download a file if it's not already present at the destination.
fetch() {
  local url="$1"; local dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -s "$dest" ]; then
    echo "✓ already have $(basename "$dest")"
    return 0
  fi
  echo "→ downloading $(basename "$dest")"
  curl -L --fail --progress-bar -o "$dest" "$url"
}

echo
echo "=== Flux Schnell (image, ~17 GB) ==="
fetch "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors" \
      "$COMFY/models/unet/flux1-schnell.safetensors"
fetch "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors" \
      "$COMFY/models/vae/ae.safetensors"
fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors" \
      "$COMFY/models/clip/t5xxl_fp8_e4m3fn.safetensors"
fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" \
      "$COMFY/models/clip/clip_l.safetensors"

echo
echo "=== Stable Diffusion 1.5 + AnimateDiff (video, ~6 GB) ==="
fetch "https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors" \
      "$COMFY/models/checkpoints/v1-5-pruned-emaonly.safetensors"
fetch "https://huggingface.co/guoyww/animatediff/resolve/main/v3_sd15_mm.ckpt" \
      "$COMFY/models/animatediff_models/v3_sd15_mm.ckpt"

echo
echo "=== Audio: MusicGen Medium (~3 GB) ==="
# MusicGen runs via custom nodes; the weights are downloaded by transformers on
# first use, but we pre-pull them so first generation is fast.
fetch "https://huggingface.co/facebook/musicgen-medium/resolve/main/state_dict.bin" \
      "$COMFY/models/musicgen/state_dict.bin"
fetch "https://huggingface.co/facebook/musicgen-medium/resolve/main/compression_state_dict.bin" \
      "$COMFY/models/musicgen/compression_state_dict.bin"

echo
echo "=== Custom nodes ==="
NODES=$COMFY/custom_nodes
mkdir -p "$NODES"
clone_if_missing() {
  local url="$1"; local target="$2"
  if [ -d "$target" ]; then
    echo "✓ already have $(basename "$target")"
  else
    git clone --depth 1 "$url" "$target"
  fi
}
clone_if_missing https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved "$NODES/ComfyUI-AnimateDiff-Evolved"
clone_if_missing https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite       "$NODES/ComfyUI-VideoHelperSuite"
clone_if_missing https://github.com/ShmuelRonen/ComfyUI_MusicGen               "$NODES/ComfyUI_MusicGen"

echo
echo "✓ ComfyUI is set up. Start it with:"
echo "    cd $COMFY && source venv/bin/activate && python main.py"
echo
echo "Then in Hearth:"
echo "  Settings → Sidecars → New → ComfyUI"
echo "  Base URL: http://127.0.0.1:8188"
echo "  Insert Template → pick Flux / Mochi / MusicGen as appropriate"
