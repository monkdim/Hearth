import Foundation
import Observation
import os

struct PromptShortcut: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    /// Token after the `/` — lower-case, no spaces. e.g. `summarize`.
    var trigger: String
    var name: String
    /// Template body. Supports `{context}` (captured selection) and `{input}` (rest of query).
    var template: String
    /// Optional model id override (HF repo). When nil, uses the active model.
    var modelId: String?

    init(
        id: UUID = UUID(),
        trigger: String,
        name: String,
        template: String,
        modelId: String? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.name = name
        self.template = template
        self.modelId = modelId
    }

    /// Render the prompt by substituting `{context}` and `{input}` placeholders.
    /// Missing placeholders are dropped silently so a one-shot shortcut still works.
    func render(context: String?, input: String) -> String {
        var output = template
        output = output.replacingOccurrences(of: "{context}", with: context ?? "")
        output = output.replacingOccurrences(of: "{input}", with: input)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Observable
final class PromptsStore {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "PromptsStore")
    private let url: URL
    private(set) var shortcuts: [PromptShortcut] = []

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.url = url
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create prompts dir: \(error.localizedDescription, privacy: .public)")
        }

        if let loaded = Self.loadFromDisk(at: url) {
            shortcuts = loaded
        } else {
            shortcuts = Self.defaults
            save()
        }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appending(path: "Hearth", directoryHint: .isDirectory)
            .appending(path: "prompts.json")
    }

    // MARK: - CRUD

    func add(_ shortcut: PromptShortcut) {
        shortcuts.append(shortcut)
        save()
    }

    func update(_ shortcut: PromptShortcut) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index] = shortcut
        save()
    }

    func delete(_ shortcut: PromptShortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        save()
    }

    func restoreDefaults() {
        shortcuts = Self.defaults
        save()
    }

    /// Returns shortcuts whose trigger starts with `prefix`, sorted by closeness.
    /// Empty `prefix` returns all shortcuts in their stored order.
    func suggestions(matching prefix: String) -> [PromptShortcut] {
        let needle = prefix.lowercased()
        if needle.isEmpty { return shortcuts }
        return shortcuts
            .filter { $0.trigger.lowercased().hasPrefix(needle) }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(shortcuts)
            try data.write(to: url, options: [.atomic])
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadFromDisk(at url: URL) -> [PromptShortcut]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([PromptShortcut].self, from: data)
    }

    // MARK: - Defaults

    static let defaults: [PromptShortcut] = [
        PromptShortcut(
            trigger: "summarize",
            name: "Summarize",
            template: "Summarize the following in 3-5 bullet points:\n\n{context}\n\n{input}"
        ),
        PromptShortcut(
            trigger: "explain",
            name: "Explain",
            template: "Explain what this does and why, clearly and concisely:\n\n{context}\n\nFollow-up: {input}"
        ),
        PromptShortcut(
            trigger: "fix",
            name: "Fix grammar",
            template: "Rewrite this with corrected grammar and clearer phrasing. Keep the tone. Return only the rewritten text:\n\n{context}"
        ),
        PromptShortcut(
            trigger: "translate",
            name: "Translate",
            template: "Translate this to {input}. Return only the translation:\n\n{context}"
        ),
        PromptShortcut(
            trigger: "review",
            name: "Code review",
            template: "Review this code for bugs, security issues, and clarity. Be specific and terse.\n\n{context}\n\nExtra concerns: {input}"
        ),
        PromptShortcut(
            trigger: "rev",
            name: "Reverse engineer",
            template: "Analyze this code/disassembly. Identify what it's doing, suspect intent, and notable patterns. Be precise.\n\n{context}\n\nFocus: {input}"
        ),
    ]
}
