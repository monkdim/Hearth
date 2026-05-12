import SwiftUI

struct PromptsSettingsView: View {
    @Bindable var promptsStore: PromptsStore
    @State private var editing: PromptShortcut?
    @State private var isCreating: Bool = false
    @State private var pendingDelete: PromptShortcut?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Prompt Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    isCreating = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Type `/` in the launcher, pick a shortcut, then add details. Use `{context}` for the highlighted text and `{input}` for what you type after the shortcut.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(promptsStore.shortcuts) { shortcut in
                        row(shortcut)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Restore defaults") {
                    promptsStore.restoreDefaults()
                }
                .buttonStyle(.bordered)
            }
        }
        .sheet(item: $editing) { shortcut in
            ShortcutEditor(initial: shortcut) { updated in
                promptsStore.update(updated)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .sheet(isPresented: $isCreating) {
            ShortcutEditor(initial: PromptShortcut(trigger: "", name: "", template: "")) { new in
                promptsStore.add(new)
                isCreating = false
            } onCancel: {
                isCreating = false
            }
        }
        .alert("Delete /\(pendingDelete?.trigger ?? "")?",
               isPresented: Binding(
                   get: { pendingDelete != nil },
                   set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete) { shortcut in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                promptsStore.delete(shortcut)
            }
        } message: { _ in
            Text("This is permanent. You can restore defaults later.")
        }
    }

    @ViewBuilder
    private func row(_ shortcut: PromptShortcut) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("/" + shortcut.trigger)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(shortcut.name).font(.headline)
                }
                Text(previewTemplate(shortcut.template))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer()
            HStack(spacing: 6) {
                Button("Edit") { editing = shortcut }
                    .buttonStyle(.bordered)
                Button(role: .destructive) {
                    pendingDelete = shortcut
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func previewTemplate(_ t: String) -> String {
        t.replacingOccurrences(of: "\n", with: " · ")
    }
}

private struct ShortcutEditor: View {
    @State var draft: PromptShortcut
    let onSave: (PromptShortcut) -> Void
    let onCancel: () -> Void

    init(initial: PromptShortcut,
         onSave: @escaping (PromptShortcut) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.name.isEmpty ? "New shortcut" : "Edit shortcut").font(.title3.weight(.semibold))

            Form {
                LabeledContent("Trigger") {
                    HStack(spacing: 4) {
                        Text("/")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        TextField("summarize", text: $draft.trigger)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: draft.trigger) { _, new in
                                draft.trigger = sanitizeTrigger(new)
                            }
                    }
                }
                LabeledContent("Name") {
                    TextField("Summarize", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Template") {
                    TextEditor(text: $draft.template)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
                }
            }

            Text("Use **{context}** for the captured selection and **{input}** for what the user types after the shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trigger.isEmpty || draft.name.isEmpty || draft.template.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func sanitizeTrigger(_ raw: String) -> String {
        raw
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
