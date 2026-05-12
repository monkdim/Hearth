import SwiftUI

struct ToolsSettingsView: View {
    @Bindable var toolsStore: ToolsStore
    @State private var editing: ToolInfo?
    @State private var isCreating: Bool = false
    @State private var pendingDelete: ToolInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tools").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    isCreating = true
                } label: {
                    Label("New Shell Tool", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Tools let the active model read files, list directories, or run shell commands you've authorized. Disable any you don't want exposed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Tools enabled", isOn: $toolsStore.toolsEnabled)
                .toggleStyle(.switch)
                .help("Master kill-switch — when off, the model gets no tools.")

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    if !builtins.isEmpty {
                        sectionHeader("Built-in")
                        ForEach(builtins) { row($0) }
                    }
                    if !customs.isEmpty {
                        sectionHeader("Custom (shell)")
                        ForEach(customs) { row($0) }
                    } else {
                        sectionHeader("Custom (shell)")
                        emptyCustomHint
                    }
                }
            }

            HStack {
                Spacer()
                Button("Restore defaults") { toolsStore.restoreDefaults() }
                    .buttonStyle(.bordered)
            }
        }
        .sheet(item: $editing) { tool in
            ShellToolEditor(initial: tool) { updated in
                toolsStore.update(updated)
                editing = nil
            } onCancel: { editing = nil }
        }
        .sheet(isPresented: $isCreating) {
            ShellToolEditor(
                initial: ToolInfo(
                    kind: .shell,
                    name: "",
                    description: "",
                    enabled: true,
                    inputDescription: "",
                    commandTemplate: ""
                )
            ) { new in
                toolsStore.add(new)
                isCreating = false
            } onCancel: { isCreating = false }
        }
        .alert("Delete \(pendingDelete?.name ?? "tool")?",
               isPresented: Binding(
                   get: { pendingDelete != nil },
                   set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete) { tool in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { toolsStore.delete(tool) }
        } message: { _ in Text("This is permanent.") }
    }

    private var builtins: [ToolInfo] { toolsStore.tools.filter { $0.kind == .builtin } }
    private var customs: [ToolInfo]  { toolsStore.tools.filter { $0.kind == .shell } }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var emptyCustomHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No custom tools yet.")
                .font(.callout)
            Text("Add a shell tool with a name, description, and a command template containing `{input}`. The model will see it as a function with a single `input` parameter.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private func row(_ tool: ToolInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.tint)
                    if tool.kind == .builtin {
                        Text("BUILT-IN")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.gray.opacity(0.18),
                                        in: Capsule(style: .continuous))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("SHELL")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18),
                                        in: Capsule(style: .continuous))
                            .foregroundStyle(.orange)
                    }
                }
                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let template = tool.commandTemplate, !template.isEmpty {
                    Text(template)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("Enabled", isOn: Binding(
                    get: { tool.enabled },
                    set: { toolsStore.setEnabled(tool, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                if tool.kind == .shell {
                    HStack(spacing: 4) {
                        Button("Edit") { editing = tool }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button(role: .destructive) { pendingDelete = tool } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}

private struct ShellToolEditor: View {
    @State var draft: ToolInfo
    let onSave: (ToolInfo) -> Void
    let onCancel: () -> Void

    init(initial: ToolInfo,
         onSave: @escaping (ToolInfo) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.name.isEmpty ? "New shell tool" : "Edit shell tool")
                .font(.title3.weight(.semibold))

            Form {
                LabeledContent("Name") {
                    TextField("run_git", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draft.name) { _, new in
                            draft.name = sanitizeName(new)
                        }
                }
                LabeledContent("Description") {
                    TextField("Run a git subcommand in the current directory.", text: $draft.description)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Input description") {
                    TextField("e.g. \"a git subcommand like 'log --oneline -10'\"",
                              text: Binding(
                                get: { draft.inputDescription ?? "" },
                                set: { draft.inputDescription = $0 }
                              ))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Command template") {
                    TextEditor(text: Binding(
                        get: { draft.commandTemplate ?? "" },
                        set: { draft.commandTemplate = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
                }
            }

            Text("Use **{input}** in the command template — the model's argument is substituted in. Example: `git {input}`. Be careful what you grant.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var isValid: Bool {
        !draft.name.isEmpty &&
        !draft.description.isEmpty &&
        !(draft.commandTemplate ?? "").isEmpty
    }

    private func sanitizeName(_ raw: String) -> String {
        raw
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
