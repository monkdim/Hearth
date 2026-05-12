import Foundation

/// User-facing description of a tool the LLM can call.
struct ToolInfo: Identifiable, Sendable, Hashable, Codable {
    enum Kind: String, Sendable, Codable {
        case builtin
        case shell
    }

    let id: UUID
    var kind: Kind
    /// Identifier used in the function-calling schema (e.g. "read_file").
    var name: String
    /// Plain-English description shown to the LLM and the user.
    var description: String
    /// Whether the LLM is allowed to use this tool.
    var enabled: Bool

    // shell-only ↓
    /// Description of what the LLM should put into the `input` parameter.
    /// Used both for the schema description and the UI.
    var inputDescription: String?
    /// Shell command with `{input}` placeholder. The LLM-provided value gets
    /// substituted before execution.
    var commandTemplate: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        description: String,
        enabled: Bool = true,
        inputDescription: String? = nil,
        commandTemplate: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.description = description
        self.enabled = enabled
        self.inputDescription = inputDescription
        self.commandTemplate = commandTemplate
    }
}
