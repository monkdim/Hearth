# Hearth

A Spotlight-style launcher that runs language models locally on your Mac. Press ⌥Space anywhere, ask a question, get an answer — without your data ever leaving the machine.

<p align="center">
  <img src="Hearth/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Hearth icon">
</p>

## Why

- **Local-first.** Every model runs on your Apple Silicon GPU via [MLX](https://github.com/ml-explore/mlx-swift). No API calls, no API keys, no token bills, no telemetry. Works offline.
- **Launcher feel.** A global hotkey opens a small panel. Ask, get an answer, dismiss. No window to manage.
- **Captures what you're looking at.** Highlight code or text in any app, hit the hotkey, and the selection comes along as context.
- **Real tool use.** The model can read files, list directories, glob, or run custom shell tools you define.

## Requirements

- **macOS 14 (Sonoma) or later**
- **Apple Silicon Mac** (M1, M2, M3, M4, M5) — Intel Macs are not supported, MLX is ARM64-only

## Install

1. Grab the latest `Hearth-x.y.z.dmg` from [Releases](https://github.com/monkdim/Hearth/releases).
2. Open the DMG, drag **Hearth** into Applications.
3. Launch Hearth. The flame icon appears in your menu bar.
4. Press **⌥Space** anywhere to open the launcher.

The app is signed with a Developer ID and notarized by Apple, so it opens without Gatekeeper warnings.

## First-run

- **Default model**: Llama 3.2 3B Instruct (~2 GB) downloads from Hugging Face on your first prompt.
- **Accessibility permission**: macOS prompts on first hotkey press so Hearth can read selected text from other apps. Optional but useful.
- **Microphone permission**: prompted the first time you click the mic button for voice input via Whisper.

## What's in v1.0

| Feature | Details |
|---|---|
| Local LLMs | Llama 3.2 1B/3B, Qwen 2.5 7B, Qwen 2.5 Coder 1.5B/3B/7B/14B/32B, DeepSeek R1 Distill 14B/32B, Phi-4 |
| Image generation | Stable Diffusion 2.1 Base, SDXL Turbo (native MLX) |
| Voice input | Whisper via WhisperKit (tiny → large-v3) |
| Projects | Per-project long-term memory, root folder, preferred model |
| Per-chat folder scoping | Tell the model "this chat operates in `~/Documents/foo`"; tools default there |
| Tools | `read_file`, `list_directory`, `find_files`, plus user-created shell tools |
| Prompt shortcuts | `/summarize`, `/explain`, `/rev`, `/review`, custom |
| Captured-text context | Highlight in any app → ⌥Space → it's attached |
| Markdown rendering | With syntax-highlighted code blocks, copy buttons |
| Auto-LTM | One-click "Save Memory" extracts durable facts from a chat |
| Sidecar mode | HTTP bridge to AUTOMATIC1111 or ComfyUI for Flux, video (Mochi/AnimateDiff), audio (MusicGen) — anything PyTorch |
| Local-only chats | Conversations persist at `~/Library/Application Support/Hearth/chats.json` — never sent anywhere |

## Local development

```bash
# One-time setup
brew install xcodegen
git clone https://github.com/monkdim/Hearth
cd Hearth

# Generate the Xcode project from project.yml, then open
xcodegen generate
open Hearth.xcodeproj
```

The project resolves Swift package dependencies on first build:

- [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) — MLX inference + Stable Diffusion
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) — Markdown rendering
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Voice transcription

### Build a signed + notarized release

The release script handles everything end-to-end:

```bash
DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_PROFILE="your-notary-profile" \
bash scripts/release.sh
```

It builds Release, signs with Developer ID + hardened runtime, submits to Apple for notarization, staples the ticket, and writes `dist/Hearth-x.y.z.{zip,dmg}`. See [scripts/release.sh](scripts/release.sh) for details.

For a quick unsigned build (local testing only), omit the env vars:

```bash
bash scripts/release.sh
```

## Privacy

Hearth is local-first by design:

- No analytics, telemetry, or crash reporting back to any server
- Model weights download from Hugging Face on first use (you can pre-download via Settings → Models)
- Chats, prompts, projects, tools, and generated images live entirely under `~/Library/Application Support/Hearth/`
- The only network calls are:
  - Hugging Face on model download
  - Optional sidecar to a local HTTP server you configure (AUTOMATIC1111, ComfyUI)
  - Apple's notarization check the first time you launch (standard macOS behavior, not Hearth-specific)

## License

GPL-3.0 — see [LICENSE](LICENSE).

## Credits

Built on top of remarkable open-source work:

- [Apple MLX](https://github.com/ml-explore/mlx-swift) — the inference engine that makes this possible
- [mlx-community](https://huggingface.co/mlx-community) on Hugging Face — for quantized model weights
- [swift-transformers](https://github.com/huggingface/swift-transformers) — tokenizers and Hugging Face Hub integration
- [Argmax](https://github.com/argmaxinc) — [WhisperKit](https://github.com/argmaxinc/WhisperKit), DiffusionKit
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) — Markdown rendering with code highlighting
