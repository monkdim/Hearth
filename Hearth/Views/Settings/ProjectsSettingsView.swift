import AppKit
import SwiftUI

struct ProjectsSettingsView: View {
    @Bindable var projectsStore: ProjectsStore
    let modelsManager: ModelsManager
    @State private var pendingDelete: Project?
    @State private var isCreating: Bool = false
    @State private var editingProjectId: UUID?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200)
            detail
                .frame(minWidth: 400)
        }
        .alert("Delete \(pendingDelete?.name ?? "project")?",
               isPresented: Binding(
                   get: { pendingDelete != nil },
                   set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete) { project in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                projectsStore.delete(project.id)
                if editingProjectId == project.id {
                    editingProjectId = nil
                }
            }
        } message: { _ in
            Text("Chats linked to this project will revert to General.")
        }
        .sheet(isPresented: $isCreating) {
            ProjectEditor(
                initial: Project(name: "New Project"),
                modelsManager: modelsManager
            ) { newProject in
                projectsStore.add(newProject)
                editingProjectId = newProject.id
                isCreating = false
            } onCancel: { isCreating = false }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New project")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(selection: Binding(
                get: { editingProjectId ?? projectsStore.activeProjectId },
                set: { editingProjectId = $0 }
            )) {
                ForEach(projectsStore.projects) { project in
                    HStack(spacing: 6) {
                        Image(systemName: project.isDefault ? "circle.dashed" : "folder")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(.system(size: 12, weight: .medium))
                            if let root = project.rootPath, !root.isEmpty {
                                Text(displayPath(root))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        if project.id == projectsStore.activeProjectId {
                            Text("ACTIVE")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18),
                                            in: Capsule(style: .continuous))
                                .foregroundStyle(.tint)
                        }
                    }
                    .tag(project.id)
                    .contextMenu {
                        if !project.isDefault {
                            Button(role: .destructive) {
                                pendingDelete = project
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Button {
                            projectsStore.setActive(project.id)
                        } label: {
                            Label("Set Active", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let selectedId = editingProjectId ?? projectsStore.activeProjectId
        if let project = projectsStore.project(with: selectedId) {
            ProjectDetailView(
                project: Binding(
                    get: { projectsStore.project(with: project.id) ?? project },
                    set: { projectsStore.update($0) }
                ),
                modelsManager: modelsManager,
                isActive: project.id == projectsStore.activeProjectId,
                onSetActive: { projectsStore.setActive(project.id) }
            )
            .id(project.id)
        } else {
            ContentUnavailableView(
                "Pick a project",
                systemImage: "folder",
                description: Text("Choose one from the sidebar, or create a new project.")
            )
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
}

// MARK: - Project detail (read/edit)

private struct ProjectDetailView: View {
    @Binding var project: Project
    let modelsManager: ModelsManager
    let isActive: Bool
    let onSetActive: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if project.isDefault {
                        Text(project.name).font(.title3.weight(.semibold))
                    } else {
                        TextField("Project name", text: $project.name)
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                    }
                    Spacer()
                    if !isActive {
                        Button("Set Active", action: onSetActive)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text("ACTIVE")
                            .font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18),
                                        in: Capsule(style: .continuous))
                            .foregroundStyle(.tint)
                    }
                }

                rootDirectorySection
                modelSection
                ltmSection
            }
            .padding(16)
        }
    }

    // MARK: - Root directory

    private var rootDirectorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Root folder").font(.headline)
            Text("Optional. When set, chats in this project default to operating in this folder. Tools that take a path treat it as a starting point.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(project.rootPath.flatMap { $0.isEmpty ? nil : displayPath($0) } ?? "(none)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(project.rootPath?.isEmpty == false ? .primary : .secondary)
                Spacer()
                Button("Choose…") { pickRoot() }
                    .buttonStyle(.bordered)
                if project.rootPath?.isEmpty == false {
                    Button("Clear") { project.rootPath = nil }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preferred model").font(.headline)
            Text("Switching to this project will swap the active model to your pick if it's installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Preferred model", selection: Binding(
                get: { project.modelId ?? "" },
                set: { project.modelId = $0.isEmpty ? nil : $0 }
            )) {
                Text("Use global default").tag("")
                ForEach(modelsManager.availableModels.filter {
                    modelsManager.installationState(for: $0).isInstalled
                }) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - LTM

    private var ltmSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Long-term memory").font(.headline)
            Text("Markdown notes the model sees as context for every chat in this project. Good for: tech stack, conventions, project goals, naming, key facts about you. Keep it focused — long LTM eats context.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $project.ltm)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
            Text("\(project.ltm.count) characters")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick the root directory for this project."
        if let existing = project.rootPath, !existing.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: existing).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            project.rootPath = url.path
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
}

// MARK: - Project creator sheet

private struct ProjectEditor: View {
    @State var draft: Project
    let modelsManager: ModelsManager
    let onSave: (Project) -> Void
    let onCancel: () -> Void

    init(initial: Project,
         modelsManager: ModelsManager,
         onSave: @escaping (Project) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.modelsManager = modelsManager
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.title3.weight(.semibold))
            Form {
                LabeledContent("Name") {
                    TextField("e.g. Ember Polish", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text("You can configure the root folder, preferred model, and long-term memory after creating it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
