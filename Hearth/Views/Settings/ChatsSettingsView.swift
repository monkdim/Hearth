import SwiftUI

struct ChatsSettingsView: View {
    @Bindable var chatsStore: ChatsStore
    @Bindable var projectsStore: ProjectsStore
    let modelsManager: ModelsManager
    @State private var pendingDelete: Chat?
    @State private var showingDeleteAll: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chats").font(.title2.weight(.semibold))
                Spacer()
                Button(role: .destructive) {
                    showingDeleteAll = true
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(chatsStore.chats.isEmpty)
            }
            Text("Your conversations live entirely on this Mac at **~/Library/Application Support/Hearth/chats.json**.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            if chatsStore.chats.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(chatsStore.chats) { chat in
                            row(chat)
                        }
                    }
                }
            }
        }
        .alert("Delete this chat?",
               isPresented: Binding(
                   get: { pendingDelete != nil },
                   set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete) { chat in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                chatsStore.delete(chat.id)
            }
        } message: { chat in
            Text("\"\(chat.title)\" will be removed permanently.")
        }
        .alert("Delete all chats?", isPresented: $showingDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                chatsStore.deleteAll()
            }
        } message: {
            Text("All \(chatsStore.chats.count) chats will be removed permanently.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No chats yet").font(.headline)
            Text("Hit ⌥Space and ask something.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ chat: Chat) -> some View {
        let isCurrent = chatsStore.currentChatId == chat.id
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(chat.title)
                        .font(.headline)
                        .lineLimit(1)
                    if isCurrent {
                        Text("CURRENT")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18),
                                        in: Capsule(style: .continuous))
                            .foregroundStyle(.tint)
                    }
                }
                Text(chat.previewLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(chat.messages.count) message\(chat.messages.count == 1 ? "" : "s") · \(relativeTime(chat.updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if !isCurrent {
                    Button("Open") {
                        openChat(chat)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button(role: .destructive) {
                    pendingDelete = chat
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    /// Switching to a chat from the sidebar also syncs the active project and
    /// active model — otherwise the user lands in a chat whose context doesn't
    /// match what the side rails (status bar, settings) say is current.
    private func openChat(_ chat: Chat) {
        chatsStore.switchTo(chat.id)
        if let projectId = chat.projectId, projectsStore.project(with: projectId) != nil {
            projectsStore.setActive(projectId)
            if let project = projectsStore.project(with: projectId),
               let preferred = project.modelId,
               let model = modelsManager.availableModels.first(where: { $0.id == preferred }),
               modelsManager.installationState(for: model).isInstalled {
                modelsManager.setActive(model)
            }
        }
        if let chatModelId = chat.modelId,
           let model = modelsManager.availableModels.first(where: { $0.id == chatModelId }),
           modelsManager.installationState(for: model).isInstalled {
            modelsManager.setActive(model)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
