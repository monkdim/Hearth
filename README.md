# Hearth

A small Mac app that lets you talk to language models without sending anything to anybody.

You press ⌥Space, a panel slides in, you ask a question, you get an answer. The model runs on your machine. There's no API key, no account, no telemetry. If your wifi dies mid-conversation, it keeps working.

## Why I built this

I wanted ChatGPT-style ergonomics without the dependency on someone else's servers, and without paying per token to ask "what does this swift error mean." MLX makes local inference on Apple Silicon fast enough to be practical now, but every wrapper around it I tried felt either too chat-app or too command-line. Hearth sits in the middle: a Spotlight-style hotkey panel that grows into a full chat window when the conversation needs it.

It's also a project, not a product. I'm building features as I want them, fixing things as they break.

## Requirements

You need:

- A Mac with Apple Silicon (M1 / M2 / M3 / M4 / M5). Intel Macs cannot run this. MLX is ARM64-only.
- macOS 14 (Sonoma) or newer.

That's it.

## Install

Grab the DMG from [Releases](https://github.com/monkdim/Hearth/releases/latest), open it, drag Hearth into Applications. The app is signed with my Developer ID and notarized by Apple, so it opens with no Gatekeeper warning.

First launch:

1. A small flame icon appears in your menu bar. Hearth lives there.
2. Press **⌥Space** anywhere — the launcher panel appears.
3. The first time you hit Enter, the default model (Llama 3.2 3B, about 2 GB) downloads from Hugging Face. Subsequent launches use the cached copy.
4. macOS will ask for Accessibility permission so Hearth can grab selected text from other apps. Optional but useful — if you're looking at code in Xcode and want to ask about it, just highlight, hit ⌥Space, and the selection comes along.

## What it does

**Local LLMs.** A curated list of models you can download from Settings → Models. The defaults are tuned for what fits on different Macs:

- 8 GB Mac: Llama 3.2 1B / 3B, Qwen 2.5 Coder 1.5B / 3B
- 16 GB Mac: Qwen 2.5 Coder 7B / 14B, DeepSeek R1 Distill 14B, Phi-4
- 24 GB+ Mac: Qwen 2.5 Coder 32B, DeepSeek R1 Distill 32B

Switching models in the chat header swaps the active one and reloads. Settings → General lets you tune the MLX cache size for your machine — bigger cache trades RAM for tokens/sec.

**Image generation.** Stable Diffusion 2.1 Base and SDXL Turbo run natively via MLX. Pick one in the model picker, type a prompt, and the image renders inline in the chat. They're not Flux-quality, but they don't need a separate server and they don't leave your machine.

**Tools.** The model can read files, list directories, and find files via glob. It can also call user-defined shell tools — set them up in Settings → Tools with a name, description, and a `bash` template containing `{input}`. Useful for things like `git {input}` so you can ask "what changed in the last 3 commits?"

**Projects.** A project has a name, an optional root folder, an LTM markdown blob, and a preferred model. Switch projects and the model swap is automatic; the LTM gets injected into the system prompt so the model has durable context across chats. You can also scope an individual chat to a folder if it doesn't belong to a project.

**Prompt shortcuts.** Type `/` to see a list. Defaults ship: `/summarize`, `/explain`, `/fix`, `/translate`, `/review`, `/rev`. The templates use `{context}` (highlighted text) and `{input}` (what you type after). Add your own in Settings → Prompts.

**Voice input.** Click the mic icon in the input row, talk, click again. Whisper runs locally via WhisperKit. Default model (Small) is ~470 MB; pick a smaller or larger one in Settings → Voice depending on whether you care about accuracy or instant startup.

**Markdown rendering with syntax-highlighted code blocks.** Code answers don't look like plain text. There's a copy button on every code block. ⌘⇧C copies just the code blocks from the last response.

**Sidecar mode.** When a model isn't in MLX yet (Flux, video, music, the bleeding edge), Hearth can talk to a separately-running ComfyUI or AUTOMATIC1111 over HTTP. You install the server yourself; Hearth becomes a frontend that routes prompts and renders the result inline. Bundled workflow templates as starting points for Flux Schnell, Mochi video, and MusicGen audio.

**Captured context.** Highlight text anywhere on macOS, hit the hotkey, and the selection attaches to your prompt as context. The model sees it as quoted material. Works in Safari, Notes, Xcode, terminals, most apps — anything that exposes selection through the Accessibility API. Falls back to your clipboard if Accessibility isn't granted.

**Long-term memory extraction.** After a useful chat, hit Save Memory in the chat header. The active model summarizes durable facts (decisions, preferences, conventions) and appends them to the current project's LTM. Next chat in that project sees the notes automatically.

## Privacy

Hearth is local-first by design.

- No telemetry. No analytics. No crash reporting back to me or anyone else.
- Chats, prompts, projects, tools, generated images, voice transcripts all live under `~/Library/Application Support/Hearth/`. Plain JSON for chats/prompts/etc; PNGs for images. Nothing's encrypted because nothing's leaving the machine — but feel free to encrypt that folder if your threat model wants it.
- Network traffic out of Hearth: model downloads from Hugging Face the first time you use a model, optional Apple notarization check on first launch (standard macOS), and HTTP calls to your sidecar URL if you configured one. That's it.

## Development

```bash
brew install xcodegen
git clone https://github.com/monkdim/Hearth
cd Hearth
xcodegen generate
open Hearth.xcodeproj
```

Swift packages resolve on first build. Dependencies are:

- [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) — inference + Stable Diffusion
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) — markdown rendering
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — voice transcription

### Releases

If you want to build a signed+notarized DMG yourself, you need your own Apple Developer cert. With it set up:

```bash
DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_PROFILE="your-notary-profile" \
bash scripts/release.sh
```

The script builds Release, code-signs with hardened runtime, submits to Apple's notary, staples the ticket, and writes `dist/Hearth-x.y.z.{dmg,zip}`. Notarization usually takes a few minutes; sometimes Apple drags their feet for half an hour.

Without the env vars the script does ad-hoc signing — fine for local testing, won't open without right-click-Open on a friend's machine.

## License

Apache 2.0. See [LICENSE](LICENSE).

## Credits

Hearth is mostly a wrapper around remarkable work by people much smarter than me:

- [Apple's MLX team](https://github.com/ml-explore/mlx-swift) for making local inference on Apple Silicon actually fast.
- The folks publishing 4-bit quantized weights as [`mlx-community`](https://huggingface.co/mlx-community) on Hugging Face.
- [argmaxinc](https://github.com/argmaxinc) for WhisperKit and DiffusionKit.
- [gonzalezreal](https://github.com/gonzalezreal) for swift-markdown-ui.
- The Hugging Face [swift-transformers](https://github.com/huggingface/swift-transformers) team.
