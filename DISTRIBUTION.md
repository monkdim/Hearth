# Distributing Hearth v1.0.0

Two paths depending on whether you have a paid Apple Developer ID
($99/year). Both produce the same artifacts in `dist/`:

- `Hearth.app` (signed)
- `Hearth-1.0.0.zip`
- `Hearth-1.0.0.dmg`

## Path A — Ad-hoc (no Developer ID, free)

Run:

```bash
bash scripts/release.sh
```

That's it. The app is ad-hoc signed and will run, but **the first time** any
of your teammates open it macOS will refuse with *"Hearth can't be opened
because Apple cannot check it for malicious software."*

Tell them to:

1. Drag `Hearth.app` to `/Applications`
2. **Right-click → Open** (not double-click)
3. Click **Open** in the prompt

After the first successful open, double-click works forever. This is the
standard friction for unsigned apps on macOS.

## Path B — Developer ID + notarization (best UX)

Prereqs:

- Apple Developer account ($99/year, https://developer.apple.com/programs/)
- A *Developer ID Application* certificate in Keychain
  (Xcode → Settings → Accounts → Manage Certificates → +)
- An app-specific password for your Apple ID
  (https://appleid.apple.com/account/manage → App-Specific Passwords)

One-time setup (creates a Keychain profile so the script doesn't need your
password every release):

```bash
xcrun notarytool store-credentials hearth-notary \
  --apple-id you@example.com \
  --team-id ABCD123456 \
  --password "abcd-efgh-ijkl-mnop"
```

Then ship:

```bash
DEV_ID="Developer ID Application: Your Name (ABCD123456)" \
NOTARIZE_PROFILE="hearth-notary" \
bash scripts/release.sh
```

The script will sign, submit for notarization, wait (~3-10 min), and staple
the ticket to the app. Teammates can then double-click with no warnings.

## What's in this release

- Local text generation via MLX (Llama, Qwen, Phi, DeepSeek, all 4-bit)
- Local image generation via MLX (SD 2.1, SDXL Turbo)
- Voice input via WhisperKit (Core ML)
- Selected-text capture via the Accessibility API
- Prompt shortcuts, projects with LTM, per-chat folder scoping
- Built-in tools (read_file / list_directory / find_files) and user-defined
  shell tools
- Sidecar mode infrastructure (A1111 image gen works; ComfyUI workflows
  configured but require user to install ComfyUI + weights separately)

## Known v1.0 limitations

- ComfyUI sidecar workflows for Flux, Mochi, MusicGen ship as paste-in
  templates but require the user to install ComfyUI + the matching custom
  nodes + the weights. See `scripts/setup-comfyui.sh` for one-shot setup.
- No auto-updates yet (would need Sparkle integration).
- On first launch your teammates will need to grant Accessibility permission
  in System Settings → Privacy & Security → Accessibility.
- Microphone permission requested on first use of voice input.
