import AppKit
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var isTrusted: Bool = ContextProvider.isAccessibilityTrusted
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isTrusted ? .green : .orange)
                    Text("Accessibility").font(.headline)
                    statusBadge
                }
                Text("Lets Hearth read selected text from the frontmost app so you can highlight code or text anywhere, hit ⌥Space, and ask a question about it. Without this, Hearth falls back to your recent clipboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !isTrusted {
                    rebuildHint
                }

                HStack(spacing: 10) {
                    Button {
                        ContextProvider.requestAccessibilityIfNeeded()
                    } label: {
                        Label("Request Access", systemImage: "hand.raised")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTrusted)

                    Button {
                        openAccessibilitySettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gear")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        isTrusted = ContextProvider.isAccessibilityTrusted
                    } label: {
                        Label("Recheck", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(14)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))

            Spacer()
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    private var statusBadge: some View {
        Text(isTrusted ? "GRANTED" : "NOT GRANTED")
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                (isTrusted ? Color.green : Color.orange).opacity(0.18),
                in: Capsule(style: .continuous)
            )
            .foregroundStyle(isTrusted ? Color.green : Color.orange)
    }

    /// Each rebuild of the dev app changes the binary's code-signature hash,
    /// which invalidates an existing Accessibility grant. Tell the user how
    /// to fix it cleanly.
    private var rebuildHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Already granted but still says NOT GRANTED?")
                .font(.callout.weight(.medium))
            Text("macOS ties Accessibility trust to the binary's code signature. Every fresh build of Hearth invalidates it. Fix: open System Settings → Privacy & Security → Accessibility → click **−** to remove the old Hearth entry, then click **Request Access** above (or just toggle the existing entry off and on).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func startPolling() {
        // Use `.common` so the timer keeps firing when the user is interacting
        // with system menus or popovers.
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                isTrusted = ContextProvider.isAccessibilityTrusted
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
