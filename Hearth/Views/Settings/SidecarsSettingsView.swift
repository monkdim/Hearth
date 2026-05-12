import SwiftUI

struct SidecarsSettingsView: View {
    @Bindable var sidecarsStore: SidecarsStore
    let modelsManager: ModelsManager
    @State private var editing: SidecarConfig?
    @State private var isCreating: Bool = false
    @State private var pendingDelete: SidecarConfig?
    @State private var pingResults: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sidecars").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    isCreating = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Hearth can hand off generation to an external local server (AUTOMATIC1111, ComfyUI, …). Useful for models that don't run on MLX yet — Flux, Mochi, MusicGen, etc. You install the server separately and point Hearth at its URL.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if sidecarsStore.sidecars.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(sidecarsStore.sidecars) { row($0) }
                    }
                }
            }
        }
        .sheet(item: $editing) { sidecar in
            SidecarEditor(initial: sidecar) { updated in
                sidecarsStore.update(updated)
                modelsManager.refreshSidecars(sidecarsStore.sidecars)
                editing = nil
            } onCancel: { editing = nil }
        }
        .sheet(isPresented: $isCreating) {
            SidecarEditor(initial: SidecarConfig(
                name: "Local A1111",
                backend: .automatic1111,
                baseURL: SidecarBackend.automatic1111.defaultBaseURL
            )) { new in
                sidecarsStore.add(new)
                modelsManager.refreshSidecars(sidecarsStore.sidecars)
                isCreating = false
            } onCancel: { isCreating = false }
        }
        .alert("Delete \(pendingDelete?.name ?? "sidecar")?",
               isPresented: Binding(
                   get: { pendingDelete != nil },
                   set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete) { sidecar in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                sidecarsStore.delete(sidecar.id)
                modelsManager.refreshSidecars(sidecarsStore.sidecars)
            }
        } message: { _ in
            Text("Hearth forgets the URL. The server itself isn't touched.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No sidecars yet.")
                .font(.headline)
            Text("Quickstart — AUTOMATIC1111:")
                .font(.callout.weight(.semibold))
            Text("""
            1. Install A1111: `git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui`
            2. Run with: `./webui.sh --api`
            3. Wait for it to load (default: http://127.0.0.1:7860)
            4. Click **New** above, choose AUTOMATIC1111, paste the URL, save.
            5. Pick the sidecar in the launcher's model picker and prompt away.
            """)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private func row(_ sidecar: SidecarConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(.tint)
                Text(sidecar.name).font(.headline)
                badge(sidecar.backend.displayName, color: .blue)
                badge(sidecar.output.label, color: .purple)
                if !sidecar.enabled {
                    badge("DISABLED", color: .gray)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { sidecar.enabled },
                    set: {
                        sidecarsStore.setEnabled(sidecar.id, enabled: $0)
                        modelsManager.refreshSidecars(sidecarsStore.sidecars)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            Text(sidecar.baseURL)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if let result = pingResults[sidecar.id] {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.contains("✓") ? .green : .red)
            }

            HStack(spacing: 6) {
                Button("Test connection") { ping(sidecar) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Edit") { editing = sidecar }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button(role: .destructive) {
                    pendingDelete = sidecar
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

    private func badge(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule(style: .continuous))
            .foregroundStyle(color)
    }

    private func ping(_ sidecar: SidecarConfig) {
        pingResults[sidecar.id] = "Pinging…"
        Task {
            let engine = SidecarEngine(config: sidecar)
            let result = await engine.ping()
            await MainActor.run {
                pingResults[sidecar.id] = result == nil
                    ? "✓ reachable"
                    : "✗ \(result!)"
            }
        }
    }
}

private struct SidecarEditor: View {
    @State var draft: SidecarConfig
    let onSave: (SidecarConfig) -> Void
    let onCancel: () -> Void

    init(initial: SidecarConfig,
         onSave: @escaping (SidecarConfig) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.name.isEmpty ? "New sidecar" : "Edit sidecar")
                .font(.title3.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Form {
                        LabeledContent("Name") {
                            TextField("Local A1111", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Backend") {
                            Picker("Backend", selection: $draft.backend) {
                                ForEach(SidecarBackend.allCases) { backend in
                                    Text(backend.displayName).tag(backend)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: draft.backend) { _, newBackend in
                                if draft.baseURL.isEmpty || isDefaultURL(draft.baseURL) {
                                    draft.baseURL = newBackend.defaultBaseURL
                                }
                            }
                        }
                        LabeledContent("Output") {
                            Picker("Output", selection: $draft.output) {
                                ForEach(SidecarOutput.allCases) { output in
                                    Text(output.label).tag(output)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        LabeledContent("Base URL") {
                            TextField("http://127.0.0.1:7860", text: $draft.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    Text(draft.backend.capabilityNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if draft.backend == .comfyUI {
                        workflowSection
                    }
                }
            }
            .frame(maxHeight: 460)

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
        .frame(width: 580)
    }

    private var isValid: Bool {
        if draft.name.isEmpty || draft.baseURL.isEmpty { return false }
        if draft.backend == .comfyUI, (draft.workflow ?? "").isEmpty { return false }
        return true
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workflow JSON").font(.headline)
                Spacer()
                Menu("Insert template…") {
                    ForEach(WorkflowTemplates.all) { template in
                        Button(template.title) {
                            draft.workflow = template.json
                            draft.output = template.output
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }
            Text("Paste a workflow exported from ComfyUI (☰ → Save (API Format)). Use `{prompt}` where you want the user's prompt substituted at run time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(
                get: { draft.workflow ?? "" },
                set: { draft.workflow = $0 }
            ))
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 180)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))

            if let blurb = WorkflowTemplates.all.first(where: { $0.json == (draft.workflow ?? "") })?.blurb {
                Text(blurb)
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isDefaultURL(_ url: String) -> Bool {
        SidecarBackend.allCases.contains { $0.defaultBaseURL == url }
    }
}
