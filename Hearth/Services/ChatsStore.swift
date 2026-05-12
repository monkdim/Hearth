import Foundation
import Observation
import os

@MainActor
@Observable
final class ChatsStore {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "ChatsStore")
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private(set) var chats: [Chat] = []
    var currentChatId: UUID?

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let loaded = Self.loadFromDisk(at: url) {
            self.chats = loaded.sorted { $0.updatedAt > $1.updatedAt }
            self.currentChatId = self.chats.first?.id
        }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appending(path: "Hearth", directoryHint: .isDirectory)
            .appending(path: "chats.json")
    }

    // MARK: - Current chat

    var currentChat: Chat? {
        get {
            guard let id = currentChatId else { return nil }
            return chats.first { $0.id == id }
        }
    }

    /// Returns the current chat, creating one if none exists. New chats
    /// inherit the supplied project id; pass nil for the General project.
    @discardableResult
    func ensureCurrentChat(projectId: UUID? = nil) -> Chat {
        if let chat = currentChat { return chat }
        let chat = Chat(projectId: projectId)
        chats.insert(chat, at: 0)
        currentChatId = chat.id
        scheduleSave()
        return chat
    }

    func startNewChat(projectId: UUID? = nil) {
        let chat = Chat(projectId: projectId)
        chats.insert(chat, at: 0)
        currentChatId = chat.id
        scheduleSave()
    }

    func setProject(_ projectId: UUID?, for chatId: UUID) {
        guard let idx = chats.firstIndex(where: { $0.id == chatId }) else { return }
        chats[idx].projectId = projectId
        chats[idx].updatedAt = Date()
        scheduleSave()
    }

    func setDirectory(_ path: String?, for chatId: UUID) {
        guard let idx = chats.firstIndex(where: { $0.id == chatId }) else { return }
        chats[idx].directoryPath = path
        chats[idx].updatedAt = Date()
        scheduleSave()
    }

    func switchTo(_ chatId: UUID) {
        guard chats.contains(where: { $0.id == chatId }) else { return }
        currentChatId = chatId
    }

    func delete(_ chatId: UUID) {
        chats.removeAll { $0.id == chatId }
        if currentChatId == chatId {
            currentChatId = chats.first?.id
        }
        scheduleSave()
    }

    func deleteAll() {
        chats.removeAll()
        currentChatId = nil
        scheduleSave()
    }

    // MARK: - Messages

    func append(message: ChatMessage, modelId: String? = nil) {
        let chatId = ensureCurrentChat().id
        guard let idx = chats.firstIndex(where: { $0.id == chatId }) else { return }
        chats[idx].messages.append(message)
        chats[idx].updatedAt = Date()
        if let modelId { chats[idx].modelId = modelId }
        // Auto-title from first user message if still "New chat"
        if chats[idx].title == "New chat", message.role == .user {
            chats[idx].title = makeTitle(from: message.content)
        }
        moveCurrentToTop()
        scheduleSave()
    }

    /// Appends a chunk of streamed text to the LAST assistant message of the
    /// current chat. Caller is responsible for having added the placeholder.
    func appendChunk(_ chunk: String) {
        guard let chatId = currentChatId,
              let chatIdx = chats.firstIndex(where: { $0.id == chatId }) else { return }
        guard let lastIdx = chats[chatIdx].messages.indices.last,
              chats[chatIdx].messages[lastIdx].role == .assistant else { return }
        chats[chatIdx].messages[lastIdx].content += chunk
        chats[chatIdx].updatedAt = Date()
        scheduleSave()
    }

    /// Inserts a tool result message into the current chat, then a new empty
    /// assistant placeholder so the next round streams cleanly into it.
    func insertToolMessage(name: String, arguments: String, result: String) {
        guard let chatId = currentChatId,
              let chatIdx = chats.firstIndex(where: { $0.id == chatId }) else { return }
        // Drop a trailing empty assistant placeholder if it exists — it'll be
        // re-created at the end so the tool message lands between rounds.
        if let last = chats[chatIdx].messages.last,
           last.role == .assistant,
           last.content.isEmpty {
            chats[chatIdx].messages.removeLast()
        }
        chats[chatIdx].messages.append(ChatMessage(
            role: .tool,
            content: "",
            toolName: name,
            toolArguments: arguments,
            toolResult: result
        ))
        chats[chatIdx].messages.append(ChatMessage(role: .assistant, content: ""))
        chats[chatIdx].updatedAt = Date()
        scheduleSave()
    }

    /// Sets the image path on the last assistant message of the current chat.
    func setLastAssistantImage(_ path: String) {
        attachMedia(at: \.imagePath, value: path)
    }

    /// Sets the video path on the last assistant message of the current chat.
    func setLastAssistantVideo(_ path: String) {
        attachMedia(at: \.videoPath, value: path)
    }

    /// Sets the audio path on the last assistant message of the current chat.
    func setLastAssistantAudio(_ path: String) {
        attachMedia(at: \.audioPath, value: path)
    }

    private func attachMedia(at keyPath: WritableKeyPath<ChatMessage, String?>, value: String) {
        guard let chatId = currentChatId,
              let chatIdx = chats.firstIndex(where: { $0.id == chatId }) else { return }
        guard let lastIdx = chats[chatIdx].messages.indices.last,
              chats[chatIdx].messages[lastIdx].role == .assistant else { return }
        chats[chatIdx].messages[lastIdx][keyPath: keyPath] = value
        chats[chatIdx].updatedAt = Date()
        scheduleSave()
    }

    /// Replace the last assistant message's content outright (e.g., to insert an error).
    func setLastAssistant(_ content: String) {
        guard let chatId = currentChatId,
              let chatIdx = chats.firstIndex(where: { $0.id == chatId }) else { return }
        guard let lastIdx = chats[chatIdx].messages.indices.last,
              chats[chatIdx].messages[lastIdx].role == .assistant else { return }
        chats[chatIdx].messages[lastIdx].content = content
        chats[chatIdx].updatedAt = Date()
        scheduleSave()
    }

    // MARK: - Persistence

    private func moveCurrentToTop() {
        guard let id = currentChatId,
              let idx = chats.firstIndex(where: { $0.id == id }),
              idx != 0 else { return }
        let chat = chats.remove(at: idx)
        chats.insert(chat, at: 0)
    }

    /// Debounced save. Streaming token-by-token would otherwise hammer the disk.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000) // 600 ms
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Forces an immediate save. Call at app-quit or important checkpoints.
    func saveNow() {
        saveTask?.cancel()
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(chats)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadFromDisk(at url: URL) -> [Chat]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Chat].self, from: data)
    }

    private func makeTitle(from content: String) -> String {
        let cleaned = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.count <= 50 { return cleaned }
        let end = cleaned.index(cleaned.startIndex, offsetBy: 50)
        return String(cleaned[..<end]) + "…"
    }
}
