import Foundation

@MainActor
final class GenerationController {
    private let appState: AppState
    private let modelsManager: ModelsManager
    private let chatsStore: ChatsStore
    private let preferences: Preferences
    private let toolsStore: ToolsStore
    private let projectsStore: ProjectsStore
    private var currentTask: Task<Void, Never>?

    init(
        appState: AppState,
        modelsManager: ModelsManager,
        chatsStore: ChatsStore,
        preferences: Preferences,
        toolsStore: ToolsStore,
        projectsStore: ProjectsStore
    ) {
        self.appState = appState
        self.modelsManager = modelsManager
        self.chatsStore = chatsStore
        self.preferences = preferences
        self.toolsStore = toolsStore
        self.projectsStore = projectsStore
    }

    func submit() {
        let rawInput = appState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortcut = appState.activeShortcut
        let capturedContext = appState.capturedContext

        let userContent: String
        if let shortcut {
            userContent = shortcut.render(
                context: capturedContext?.text,
                input: rawInput
            )
        } else if let context = capturedContext {
            userContent = Self.wrapWithContext(userPrompt: rawInput, context: context)
        } else {
            userContent = rawInput
        }

        guard !userContent.isEmpty, !appState.isGenerating else { return }

        cancel()

        // Stamp the chat with the currently-active project if it doesn't have one.
        chatsStore.ensureCurrentChat(projectId: projectsStore.activeProjectId)
        if let chatId = chatsStore.currentChatId,
           chatsStore.currentChat?.projectId == nil {
            chatsStore.setProject(projectsStore.activeProjectId, for: chatId)
        }

        // Branch on active model kind.
        switch modelsManager.activeEngine {
        case .image(let imageEngine):
            submitImageGeneration(prompt: userContent, engine: imageEngine)
            return
        case .sidecar(let sidecarEngine):
            submitSidecarGeneration(prompt: userContent, engine: sidecarEngine)
            return
        case .text:
            break  // fall through to text generation below
        }

        chatsStore.append(
            message: ChatMessage(role: .user, content: userContent),
            modelId: modelsManager.activeModel.id
        )
        chatsStore.append(
            message: ChatMessage(role: .assistant, content: ""),
            modelId: modelsManager.activeModel.id
        )

        appState.query = ""
        appState.activeShortcut = nil
        appState.capturedContext = nil
        appState.tokensPerSecond = 0
        appState.isGenerating = true
        appState.statusMessage = "Preparing model…"

        let engine = modelsManager.engine
        let state = appState
        let store = chatsStore
        let toolbox = ToolBoxFactory.build(from: toolsStore.enabledTools)

        let history = (chatsStore.currentChat?.messages ?? []).dropLast()
        let maxTokens = preferences.maxResponseTokens
        let temperature = preferences.temperature
        let promptContext = buildPromptContext()

        currentTask = Task {
            let stream = engine.generate(
                history: Array(history),
                maxTokens: maxTokens,
                temperature: temperature,
                toolbox: toolbox,
                promptContext: promptContext
            )
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .downloadProgress(let p):
                        state.statusMessage = "Downloading model… \(Int(p * 100))%"
                    case .loading:
                        state.statusMessage = "Generating…"
                    case .token(let chunk):
                        state.statusMessage = nil
                        store.appendChunk(chunk)
                    case .stats(let tps):
                        state.tokensPerSecond = tps
                    case .toolUsed(let name, let args, let result):
                        store.insertToolMessage(name: name, arguments: args, result: result)
                        state.statusMessage = "Continuing with tool result…"
                    }
                }
            } catch {
                state.statusMessage = nil
                store.setLastAssistant("Error: \(error.localizedDescription)")
            }
            state.isGenerating = false
            state.statusMessage = nil
            store.saveNow()
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        appState.isGenerating = false
        appState.statusMessage = nil
    }

    // MARK: - Image generation

    private func submitImageGeneration(prompt: String, engine: ImageEngine) {
        chatsStore.append(
            message: ChatMessage(role: .user, content: prompt),
            modelId: modelsManager.activeModel.id
        )
        chatsStore.append(
            message: ChatMessage(role: .assistant, content: ""),
            modelId: modelsManager.activeModel.id
        )

        appState.query = ""
        appState.activeShortcut = nil
        appState.capturedContext = nil
        appState.tokensPerSecond = 0
        appState.isGenerating = true
        appState.statusMessage = "Preparing image model…"

        let store = chatsStore
        let state = appState

        let chatId = chatsStore.currentChatId ?? UUID()
        let outputDir = Self.imageDirectory(for: chatId)
        let filename = "\(UUID().uuidString.prefix(8)).png"

        currentTask = Task {
            let stream = engine.generate(
                prompt: prompt,
                outputDirectory: outputDir,
                filename: String(filename)
            )
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .downloadProgress(let p):
                        state.statusMessage = "Downloading image model… \(Int(p * 100))%"
                    case .loading:
                        state.statusMessage = "Generating image…"
                    case .stepProgress(let p):
                        state.statusMessage = "Step \(Int(p * 100))%"
                    case .finished(let url):
                        store.setLastAssistantImage(url.path)
                        store.setLastAssistant("Generated image.")
                    }
                }
            } catch {
                store.setLastAssistant("Image generation failed: \(error.localizedDescription)")
            }
            state.isGenerating = false
            state.statusMessage = nil
            store.saveNow()
        }
    }

    private static func imageDirectory(for chatId: UUID) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appending(path: "Hearth/Generated", directoryHint: .isDirectory)
            .appending(path: chatId.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - Sidecar generation

    private func submitSidecarGeneration(prompt: String, engine: SidecarEngine) {
        chatsStore.append(
            message: ChatMessage(role: .user, content: prompt),
            modelId: modelsManager.activeModel.id
        )
        chatsStore.append(
            message: ChatMessage(role: .assistant, content: ""),
            modelId: modelsManager.activeModel.id
        )

        appState.query = ""
        appState.activeShortcut = nil
        appState.capturedContext = nil
        appState.tokensPerSecond = 0
        appState.isGenerating = true
        appState.statusMessage = "Contacting sidecar…"

        let store = chatsStore
        let state = appState
        let chatId = chatsStore.currentChatId ?? UUID()
        let outputDir = Self.imageDirectory(for: chatId)
        let stem = UUID().uuidString.prefix(8).description
        // Snapshot the output kind so the closure doesn't need to await the actor.
        let outputKind: SidecarOutput = {
            if case .sidecar(let cfg) = modelsManager.activeModel.kind { return cfg.output }
            return .image
        }()

        currentTask = Task {
            let stream = engine.generate(
                prompt: prompt,
                outputDirectory: outputDir,
                filenameStem: stem
            )
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .starting:
                        state.statusMessage = "Generating…"
                    case .progress(let p):
                        state.statusMessage = "Sidecar progress \(Int(p * 100))%"
                    case .finished(let url):
                        switch outputKind {
                        case .image: store.setLastAssistantImage(url.path)
                        case .video: store.setLastAssistantVideo(url.path)
                        case .audio: store.setLastAssistantAudio(url.path)
                        }
                        store.setLastAssistant("Generated via sidecar.")
                    }
                }
            } catch {
                store.setLastAssistant("Sidecar failed: \(error.localizedDescription)")
            }
            state.isGenerating = false
            state.statusMessage = nil
            store.saveNow()
        }
    }

    /// Derives the system-prompt context from the current chat + project. The
    /// chat's `directoryPath` overrides the project's `rootPath`.
    private func buildPromptContext() -> InferenceEngine.PromptContext {
        let chat = chatsStore.currentChat
        let project: Project = {
            if let id = chat?.projectId,
               let found = projectsStore.project(with: id) {
                return found
            }
            return projectsStore.activeProject
        }()

        let workingDir = (chat?.directoryPath ?? project.rootPath)
            .map { NSString(string: $0).expandingTildeInPath }

        return InferenceEngine.PromptContext(
            projectName: project.name,
            workingDirectory: workingDir,
            ltm: project.ltm
        )
    }

    private static func wrapWithContext(userPrompt: String, context: CapturedContext) -> String {
        """
        Context from \(context.source.label):

        \"\"\"
        \(context.text)
        \"\"\"

        \(userPrompt)
        """
    }
}
