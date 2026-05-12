import Foundation

struct ChatMessage: Codable, Sendable, Identifiable, Hashable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
        case tool
    }

    let id: UUID
    let role: Role
    var content: String
    let createdAt: Date

    // Tool-specific fields, populated when `role == .tool`.
    var toolName: String?
    var toolArguments: String?
    var toolResult: String?
    /// Path to generated media on disk. Only one of these is set per message.
    var imagePath: String?
    var videoPath: String?
    var audioPath: String?

    init(id: UUID = UUID(),
         role: Role,
         content: String,
         createdAt: Date = Date(),
         toolName: String? = nil,
         toolArguments: String? = nil,
         toolResult: String? = nil,
         imagePath: String? = nil,
         videoPath: String? = nil,
         audioPath: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.toolName = toolName
        self.toolArguments = toolArguments
        self.toolResult = toolResult
        self.imagePath = imagePath
        self.videoPath = videoPath
        self.audioPath = audioPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(Role.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        self.toolArguments = try c.decodeIfPresent(String.self, forKey: .toolArguments)
        self.toolResult = try c.decodeIfPresent(String.self, forKey: .toolResult)
        self.imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        self.videoPath = try c.decodeIfPresent(String.self, forKey: .videoPath)
        self.audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt, toolName, toolArguments, toolResult
        case imagePath, videoPath, audioPath
    }
}

struct Chat: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    /// HuggingFace id of the model that's been associated with this chat.
    var modelId: String?
    /// Project this chat belongs to. nil → treat as the default ("General") project.
    var projectId: UUID?
    /// Optional working directory for this chat — overrides project.rootPath.
    var directoryPath: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New chat",
        messages: [ChatMessage] = [],
        modelId: String? = nil,
        projectId: UUID? = nil,
        directoryPath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.modelId = modelId
        self.projectId = projectId
        self.directoryPath = directoryPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Friendly preview line for chat lists. First user message, truncated.
    var previewLine: String {
        guard let firstUser = messages.first(where: { $0.role == .user }) else {
            return "(empty)"
        }
        let cleaned = firstUser.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.count > 90 {
            let end = cleaned.index(cleaned.startIndex, offsetBy: 90)
            return String(cleaned[..<end]) + "…"
        }
        return cleaned
    }

    /// Custom decoder so older chat files (which don't have projectId / directoryPath)
    /// load cleanly with sensible defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try container.decode(UUID.self,        forKey: .id)
        self.title       = try container.decode(String.self,      forKey: .title)
        self.messages    = try container.decode([ChatMessage].self, forKey: .messages)
        self.modelId     = try container.decodeIfPresent(String.self, forKey: .modelId)
        self.projectId   = try container.decodeIfPresent(UUID.self,   forKey: .projectId)
        self.directoryPath = try container.decodeIfPresent(String.self, forKey: .directoryPath)
        self.createdAt   = try container.decode(Date.self,        forKey: .createdAt)
        self.updatedAt   = try container.decode(Date.self,        forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, modelId, projectId, directoryPath, createdAt, updatedAt
    }
}
