import AppKit
import SwiftUI

struct LauncherView: View {
    /// Locked size so SwiftUI reports a stable preferredContentSize to
    /// NSHostingController. Keeping these constant prevents the layout
    /// feedback loop that crashed earlier on chat swaps.
    static let fixedWidth: CGFloat = 760
    static let fixedHeight: CGFloat = 620

    @Bindable var appState: AppState
    let controller: GenerationController
    @Bindable var promptsStore: PromptsStore
    @Bindable var chatsStore: ChatsStore
    let modelsManager: ModelsManager
    @Bindable var projectsStore: ProjectsStore
    let ltmExtractor: LTMExtractor
    @Bindable var voiceInput: VoiceInputService
    /// Triggered by an explicit user action (close button, ⌘W).
    let onDismiss: () -> Void
    /// Triggered by ESC. Goes through WindowManager's time-guarded dismiss
    /// so a stray ESC from a returning system service (e.g., the macOS
    /// Screenshot tool handing focus back) doesn't hide the panel.
    let onEscape: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var selectedSuggestionIndex: Int = 0

    var body: some View {
        // `animation(nil, value:)` on the content-shape values keeps SwiftUI
        // from animating chat swaps. The NSHostingController auto-sizes the
        // panel based on intrinsic content size; if a swap animates, the
        // panel resizes mid-animation and we get a layout feedback loop that
        // overflows the main thread stack.
        VStack(alignment: .leading, spacing: 0) {
            if let chat = chatsStore.currentChat {
                chatHeader(chat: chat)
                Divider().opacity(0.25)
                if !chat.messages.isEmpty {
                    ChatThreadView(messages: chat.messages, isStreaming: appState.isGenerating)
                    Divider().opacity(0.25)
                } else if shouldShowEmptyState {
                    emptyStateView
                    Divider().opacity(0.2)
                }
            } else if shouldShowEmptyState {
                emptyStateView
                Divider().opacity(0.2)
            }

            if let shortcut = appState.activeShortcut {
                shortcutChip(shortcut)
            }
            if let context = appState.capturedContext {
                contextChip(context)
            }
            inputRow

            if !visibleSuggestions.isEmpty {
                Divider().opacity(0.2)
                ShortcutSuggestionsView(
                    suggestions: visibleSuggestions,
                    selectedIndex: clampedIndex(in: visibleSuggestions)
                ) { commit($0) }
            }

            if let status = appState.statusMessage, !status.isEmpty {
                statusRow(status)
            }

            keyboardShortcuts
        }
        .frame(width: Self.fixedWidth, height: Self.fixedHeight)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear { inputFocused = true }
        .onExitCommand(perform: onEscape)
        .onKeyPress(.upArrow) { handleUpArrow() }
        .onKeyPress(.downArrow) { handleDownArrow() }
        .onKeyPress(.tab) { handleTab() }
        .onChange(of: appState.query) { _, newValue in
            selectedSuggestionIndex = 0
            if appState.activeShortcut == nil,
               let match = exactTriggerMatch(in: newValue) {
                commit(match.shortcut, trailing: match.trailing)
            }
        }
        // Disable implicit SwiftUI animations on the chat-content swap so the
        // hosting panel doesn't enter a resize ↔ relayout feedback loop.
        .animation(nil, value: chatsStore.currentChatId)
        .animation(nil, value: chatsStore.currentChat?.messages.count ?? 0)
    }

    // MARK: - Header

    private func chatHeader(chat: Chat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(chat.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary.opacity(0.9))

                projectPickerMenu(chat: chat)
                modelPickerMenu

                if appState.tokensPerSecond > 0 {
                    Text("· \(Int(appState.tokensPerSecond)) tok/s")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await ltmExtractor.extract(from: chat) }
                } label: {
                    Label("Save Memory", systemImage: "brain")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(chat.messages.isEmpty || appState.isGenerating)
                .help("Extract durable facts from this chat into the project's long-term memory")

                Button {
                    chatsStore.startNewChat(projectId: projectsStore.activeProjectId)
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Start a new chat (⌘N)")
            }
            folderRow(chat: chat)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func projectPickerMenu(chat: Chat) -> some View {
        let activeId = chat.projectId ?? projectsStore.activeProjectId
        let activeProject = projectsStore.project(with: activeId) ?? Project.general
        return Menu {
            ForEach(projectsStore.projects) { project in
                Button {
                    chatsStore.setProject(project.id, for: chat.id)
                    projectsStore.setActive(project.id)
                    // Switch active model to the project's preferred one if installed.
                    if let modelId = project.modelId,
                       let model = modelsManager.availableModels.first(where: { $0.id == modelId }),
                       modelsManager.installationState(for: model).isInstalled {
                        modelsManager.setActive(model)
                    }
                } label: {
                    HStack {
                        Text(project.name)
                        if project.id == activeId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(activeProject.name)
                    .font(.system(size: 11))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(.tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project for this chat")
    }

    @ViewBuilder
    private func folderRow(chat: Chat) -> some View {
        let effective = chat.directoryPath
            ?? projectsStore.project(with: chat.projectId ?? projectsStore.activeProjectId)?.rootPath
        if let dir = effective, !dir.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(displayPath(dir))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { pickChatFolder(chat: chat) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.tint)
                if chat.directoryPath != nil {
                    Button {
                        chatsStore.setDirectory(nil, for: chat.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Detach this chat from a folder")
                }
            }
            .padding(.leading, 18)
        } else {
            HStack(spacing: 6) {
                Spacer()
                Button {
                    pickChatFolder(chat: chat)
                } label: {
                    Label("Scope to folder…", systemImage: "folder.badge.plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Tell the model which directory this chat works in")
            }
        }
    }

    private func pickChatFolder(chat: Chat) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder this chat should operate in. Tools will default to this directory."
        if let existing = chat.directoryPath {
            panel.directoryURL = URL(fileURLWithPath:
                NSString(string: existing).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            chatsStore.setDirectory(url.path, for: chat.id)
        }
    }

    private func displayPath(_ raw: String) -> String {
        let home = NSHomeDirectory()
        let expanded = NSString(string: raw).expandingTildeInPath
        if expanded.hasPrefix(home) {
            return "~" + expanded.dropFirst(home.count)
        }
        return expanded
    }

    private var modelPickerMenu: some View {
        let installed = modelsManager.availableModels.filter {
            modelsManager.installationState(for: $0).isInstalled
        }
        return Menu {
            if installed.isEmpty {
                Text("No models installed yet")
            }
            ForEach(installed) { model in
                Button {
                    modelsManager.setActive(model)
                } label: {
                    HStack {
                        Text(model.displayName)
                        if model.id == modelsManager.activeModel.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("· \(modelsManager.activeModel.displayName)")
                    .font(.system(size: 11))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(placeholderText, text: $appState.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($inputFocused)
                .onSubmit { controller.submit() }
                .disabled(appState.isGenerating)

            micButton

            if appState.isGenerating {
                Button {
                    controller.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Stop (⌘.)")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 72)
    }

    @ViewBuilder
    private var micButton: some View {
        let color: Color = {
            switch voiceInput.state {
            case .recording: return .red
            case .transcribing: return .orange
            case .idle: return .secondary
            }
        }()
        let symbol: String = {
            switch voiceInput.state {
            case .recording: return "mic.fill"
            case .transcribing: return "waveform"
            case .idle: return "mic"
            }
        }()
        Button {
            Task { await toggleVoiceInput() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(appState.isGenerating || voiceInput.state == .transcribing)
        .help(voiceInput.state == .recording
              ? "Stop recording and transcribe"
              : "Dictate a prompt (Whisper)")
    }

    private func toggleVoiceInput() async {
        switch voiceInput.state {
        case .idle:
            let granted = await voiceInput.requestMicrophoneAccess()
            guard granted else {
                appState.statusMessage = "Microphone access denied. Grant it in System Settings."
                return
            }
            voiceInput.startRecording()
        case .recording:
            appState.statusMessage = "Transcribing…"
            if let text = await voiceInput.stopAndTranscribe() {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if appState.query.isEmpty {
                    appState.query = trimmed
                } else {
                    appState.query += " " + trimmed
                }
                inputFocused = true
            } else if !voiceInput.lastError.isEmpty {
                appState.statusMessage = "Voice error: \(voiceInput.lastError)"
            }
            if appState.statusMessage == "Transcribing…" {
                appState.statusMessage = nil
            }
        case .transcribing:
            break
        }
    }

    private var placeholderText: String {
        if appState.isGenerating { return "Generating…" }
        if modelsManager.activeModel.isImage {
            return "Describe an image to generate…"
        }
        if appState.activeShortcut != nil { return "Add details, or press Enter…" }
        if let chat = chatsStore.currentChat, !chat.messages.isEmpty {
            return "Continue the conversation…"
        }
        return "Ask anything, or / for shortcuts"
    }

    private func statusRow(_ status: String) -> some View {
        HStack {
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Chips

    private func shortcutChip(_ shortcut: PromptShortcut) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "command.square.fill")
                .foregroundStyle(.tint)
            Text("/" + shortcut.trigger)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tint)
            Text(shortcut.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                appState.activeShortcut = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove shortcut")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
        .overlay(Divider().opacity(0.3), alignment: .bottom)
    }

    private func contextChip(_ context: CapturedContext) -> some View {
        HStack(spacing: 10) {
            Image(systemName: context.source.iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("From \(context.source.label)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(context.text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary.opacity(0.85))
            }
            Spacer(minLength: 8)
            Button {
                appState.capturedContext = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attached context")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .overlay(Divider().opacity(0.3), alignment: .bottom)
    }

    // MARK: - Hidden keyboard shortcuts

    @ViewBuilder
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Copy last response") { copyLastResponse() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Stop") { controller.cancel() }
                .keyboardShortcut(".", modifiers: .command)
            Button("Close") { onDismiss() }
                .keyboardShortcut("w", modifiers: .command)
            Button("New Chat") { chatsStore.startNewChat() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Smart copy: if the last assistant reply contains fenced code blocks,
    /// copy just those (joined with blank lines). Otherwise copy the full reply.
    private func copyLastResponse() {
        let lastAssistant = chatsStore.currentChat?.messages.last(where: { $0.role == .assistant })
        guard let content = lastAssistant?.content, !content.isEmpty else { return }
        let codeOnly = MarkdownUtilities.joinedCodeBlocks(in: content)
        let payload = codeOnly.isEmpty ? content : codeOnly
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }

    // MARK: - Empty state

    private var shouldShowEmptyState: Bool {
        guard chatsStore.currentChat?.messages.isEmpty != false else { return false }
        return appState.query.isEmpty
            && appState.activeShortcut == nil
            && appState.capturedContext == nil
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Try these")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                hintRow("/", "type a slash to see prompt shortcuts (\(promptsStore.shortcuts.count) installed)")
                hintRow("⇧⌥", "highlight text in any app, then ⌥Space to attach it as context")
                hintRow("⌘N", "start a new chat once a conversation gets crowded")
                hintRow("⌘⇧C", "copy the last response — code blocks only when present")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hintRow(_ key: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tint)
                .frame(minWidth: 38, alignment: .leading)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    // MARK: - Suggestions logic

    private var visibleSuggestions: [PromptShortcut] {
        guard appState.activeShortcut == nil,
              appState.query.hasPrefix("/") else { return [] }
        let trigger = String(appState.query.dropFirst())
        if trigger.contains(" ") { return [] }
        return promptsStore.suggestions(matching: trigger)
    }

    private func clampedIndex(in list: [PromptShortcut]) -> Int {
        guard !list.isEmpty else { return 0 }
        return max(0, min(selectedSuggestionIndex, list.count - 1))
    }

    private func handleUpArrow() -> KeyPress.Result {
        guard !visibleSuggestions.isEmpty else { return .ignored }
        selectedSuggestionIndex = max(0, clampedIndex(in: visibleSuggestions) - 1)
        return .handled
    }

    private func handleDownArrow() -> KeyPress.Result {
        guard !visibleSuggestions.isEmpty else { return .ignored }
        selectedSuggestionIndex = min(visibleSuggestions.count - 1, clampedIndex(in: visibleSuggestions) + 1)
        return .handled
    }

    private func handleTab() -> KeyPress.Result {
        guard !visibleSuggestions.isEmpty else { return .ignored }
        let shortcut = visibleSuggestions[clampedIndex(in: visibleSuggestions)]
        commit(shortcut)
        return .handled
    }

    private func commit(_ shortcut: PromptShortcut, trailing: String = "") {
        appState.activeShortcut = shortcut
        appState.query = trailing
        selectedSuggestionIndex = 0
    }

    private func exactTriggerMatch(in query: String) -> (shortcut: PromptShortcut, trailing: String)? {
        guard query.hasPrefix("/"),
              let spaceIndex = query.firstIndex(of: " ") else { return nil }
        let after = query.index(after: query.startIndex)
        let trigger = String(query[after..<spaceIndex]).lowercased()
        guard !trigger.isEmpty,
              let shortcut = promptsStore.shortcuts.first(where: { $0.trigger.lowercased() == trigger })
        else { return nil }
        let trailing = String(query[query.index(after: spaceIndex)...])
        return (shortcut, trailing)
    }
}
