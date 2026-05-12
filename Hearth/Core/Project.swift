import Foundation

/// A workspace — an LTM, a default model, and an optional root directory the
/// model should treat as its working folder.
struct Project: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    /// Optional working directory. When set, tools default to this directory
    /// and the system prompt mentions it as the project's root.
    var rootPath: String?
    /// Long-term memory — Markdown the model sees as context for every chat
    /// in this project.
    var ltm: String
    /// Preferred model for chats in this project. When set, switching to a
    /// project / chat in this project switches the active model.
    var modelId: String?
    let createdAt: Date
    var updatedAt: Date

    /// Sentinel UUID for the always-present "General" project.
    static let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init(
        id: UUID = UUID(),
        name: String,
        rootPath: String? = nil,
        ltm: String = "",
        modelId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.ltm = ltm
        self.modelId = modelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isDefault: Bool { id == Self.defaultId }

    static let general = Project(
        id: Self.defaultId,
        name: "General",
        ltm: ""
    )
}
