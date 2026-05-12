import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        let win = window ?? makeWindow()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        if !win.isVisible { win.center() }
        win.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: AboutView())
        let win = NSWindow(contentViewController: controller)
        win.title = "About Hearth"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 380, height: 460))
        win.delegate = self
        return win
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
            } else {
                Image(systemName: "flame.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.tint)
            }

            VStack(spacing: 4) {
                Text("Hearth").font(.system(size: 22, weight: .semibold))
                Text("Version \(version) (\(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("A Spotlight-style launcher for running language models locally on your Mac. Everything stays on your device.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 14)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 6) {
                creditRow("Inference", "Apple MLX Swift")
                creditRow("Models", "Hugging Face mlx-community")
                creditRow("Markdown", "swift-markdown-ui")
                creditRow("Tokenizers", "swift-transformers")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 30)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button("Visit MLX") {
                    if let url = URL(string: "https://github.com/ml-explore/mlx-swift") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                Button("Hugging Face") {
                    if let url = URL(string: "https://huggingface.co/mlx-community") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(.vertical, 22)
        .frame(width: 380, height: 460)
    }

    private func creditRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
        }
    }
}
