import AppKit
import ApplicationServices
import Foundation
import os

/// Source from which a `CapturedContext` was lifted.
enum ContextSource: Sendable, Hashable {
    case app(name: String, bundleId: String?)
    case clipboard

    var label: String {
        switch self {
        case .app(let name, _): name
        case .clipboard: "Clipboard"
        }
    }

    var iconName: String {
        switch self {
        case .app: "doc.text"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

struct CapturedContext: Sendable, Hashable {
    let text: String
    let source: ContextSource
}

/// Captures selected text from the frontmost app via the Accessibility API,
/// with an optional fallback to the clipboard (only when the clipboard was
/// updated recently, so we don't surprise the user with stale data).
struct ContextProvider: Sendable {
    private static let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "ContextProvider")
    /// Maximum clipboard age (seconds) to be considered fresh enough to use as fallback.
    private static let clipboardFreshnessWindow: TimeInterval = 30
    /// Length cap on captured context so we don't blow the model's context window.
    private static let maxLength = 8_000

    static var isAccessibilityTrusted: Bool {
        // Using the options-nil variant rather than `AXIsProcessTrusted()` —
        // both should be equivalent in theory but the latter can return stale
        // results between rebuilds when the binary's code-signature hash changes.
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Triggers the system Accessibility prompt if Hearth is not yet trusted.
    /// Returns whether trust is currently granted.
    @discardableResult
    static func requestAccessibilityIfNeeded() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options: [CFString: Any] = [promptKey: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Captures context to attach to the launcher prompt.
    /// Tries the Accessibility API first; falls back to the pasteboard if the
    /// clipboard was changed recently.
    /// Runs the AX query off the main actor so it doesn't stall panel display.
    static func capture() async -> CapturedContext? {
        // Snapshot what we need from the main actor first.
        let frontApp = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        let clipboard = await MainActor.run { Self.snapshotClipboard() }

        return await Task.detached(priority: .userInitiated) {
            if let app = frontApp,
               let text = Self.readSelectedText(pid: app.processIdentifier),
               let trimmed = Self.normalize(text) {
                return CapturedContext(
                    text: trimmed,
                    source: .app(
                        name: app.localizedName ?? "Active app",
                        bundleId: app.bundleIdentifier
                    )
                )
            }
            if let clipboard, let trimmed = Self.normalize(clipboard) {
                return CapturedContext(text: trimmed, source: .clipboard)
            }
            return nil
        }.value
    }

    // MARK: - Internals

    private static func readSelectedText(pid: pid_t) -> String? {
        guard isAccessibilityTrusted else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard focusStatus == .success, let focusedRef = focused else { return nil }

        // Force-cast is safe: the AX framework only returns AXUIElement here.
        let focusedElement = focusedRef as! AXUIElement

        var selected: CFTypeRef?
        let textStatus = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selected
        )
        guard textStatus == .success, let text = selected as? String, !text.isEmpty else {
            return nil
        }
        return text
    }

    /// Reads the pasteboard string only if the last change happened within
    /// `clipboardFreshnessWindow` seconds, suggesting the user just copied it.
    private static func snapshotClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        // No public timestamp API; approximate freshness via change count delta.
        // First-time: always allow. Later: only if changeCount moved within window.
        let currentCount = pasteboard.changeCount
        let recordedCount = UserDefaults.standard.integer(forKey: ClipboardTracker.countKey)
        let recordedTime = UserDefaults.standard.double(forKey: ClipboardTracker.timeKey)

        if currentCount != recordedCount {
            UserDefaults.standard.set(currentCount, forKey: ClipboardTracker.countKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: ClipboardTracker.timeKey)
            // Fresh change — allow.
            return pasteboard.string(forType: .string)
        }
        let age = Date().timeIntervalSince1970 - recordedTime
        guard age < clipboardFreshnessWindow else { return nil }
        return pasteboard.string(forType: .string)
    }

    private static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxLength {
            let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
            return String(trimmed[..<endIndex]) + "\n… [truncated]"
        }
        return trimmed
    }

    private enum ClipboardTracker {
        static let countKey = "hearth.clipboardChangeCount"
        static let timeKey = "hearth.clipboardChangeTime"
    }
}
