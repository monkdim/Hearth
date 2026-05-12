import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var query: String = ""
    var isGenerating: Bool = false
    /// Transient one-line UI hint: "Downloading model… 42%", "Generating…", etc.
    var statusMessage: String?
    var tokensPerSecond: Double = 0
    /// Text captured from the frontmost app (or clipboard fallback) when the
    /// launcher opens. Cleared on submit, hide, or when the user dismisses the chip.
    var capturedContext: CapturedContext?
    /// A committed prompt shortcut. Query text after commit becomes its `{input}`.
    var activeShortcut: PromptShortcut?
}
