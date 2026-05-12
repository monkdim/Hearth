import Foundation
import os

@MainActor
final class LTMExtractor {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "LTMExtractor")
    private let modelsManager: ModelsManager
    private let projectsStore: ProjectsStore
    private let appState: AppState

    private(set) var isExtracting = false

    init(modelsManager: ModelsManager, projectsStore: ProjectsStore, appState: AppState) {
        self.modelsManager = modelsManager
        self.projectsStore = projectsStore
        self.appState = appState
    }

    /// Runs a one-shot generation that asks the active model to extract durable
    /// facts from the conversation, then appends them to the project's LTM.
    func extract(from chat: Chat) async {
        guard !isExtracting else { return }
        guard chat.messages.contains(where: { $0.role == .user }) else { return }

        let projectId = chat.projectId ?? Project.defaultId
        guard let project = projectsStore.project(with: projectId) else { return }

        isExtracting = true
        appState.statusMessage = "Extracting memory from this chat…"
        defer {
            isExtracting = false
            if appState.statusMessage == "Extracting memory from this chat…" {
                appState.statusMessage = nil
            }
        }

        let extractionPrompt = Self.buildPrompt(for: chat, project: project)

        let engine = modelsManager.engine
        let stream = engine.generate(
            history: [ChatMessage(role: .user, content: extractionPrompt)],
            maxTokens: 1024,
            temperature: 0.3,
            toolbox: .empty,
            promptContext: InferenceEngine.PromptContext(
                projectName: project.name,
                workingDirectory: nil,
                ltm: ""
            )
        )

        var output = ""
        do {
            for try await event in stream {
                if case .token(let chunk) = event { output += chunk }
            }
        } catch {
            logger.error("Extraction failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.uppercased().contains("NONE") else {
            appState.statusMessage = "Nothing memorable to add."
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return
        }

        var updated = project
        let stamp = Self.dateStamp()
        if updated.ltm.isEmpty {
            updated.ltm = "## \(stamp)\n\n\(trimmed)"
        } else {
            updated.ltm += "\n\n## \(stamp)\n\n\(trimmed)"
        }
        projectsStore.update(updated)

        appState.statusMessage = "Added to \(project.name) memory."
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    private static func buildPrompt(for chat: Chat, project: Project) -> String {
        let lines = chat.messages.compactMap { msg -> String? in
            switch msg.role {
            case .user: return "USER: \(msg.content)"
            case .assistant where !msg.content.isEmpty: return "ASSISTANT: \(msg.content)"
            default: return nil
            }
        }
        let transcript = lines.joined(separator: "\n\n")

        return """
        You're maintaining long-term memory for the project **\(project.name)**. Read the conversation below and extract durable facts worth remembering in future conversations.

        Focus on:
        - Decisions the user made and their reasoning
        - Preferences the user expressed
        - Project conventions, constraints, goals
        - Technical details (stack, paths, naming, tooling) worth recalling
        - Personal facts the user shared

        Do NOT include:
        - Ephemeral status ("trying X right now")
        - Things already in existing LTM
        - Verbose explanations — keep it terse

        Output 1–6 bullet points in Markdown. No preamble. If nothing notable, respond with exactly: NONE

        ---

        Existing LTM for context (don't duplicate):
        \(project.ltm.isEmpty ? "(empty)" : project.ltm)

        ---

        Conversation:
        \(transcript)
        """
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
