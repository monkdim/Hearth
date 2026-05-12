import SwiftUI

/// Local OpenAI-compatible HTTP server settings. Lets external tools
/// (OpenClaw, IDE plugins, scripts) call Hearth's active local model as if
/// it were a hosted LLM — without any cloud calls.
struct APIServerSettingsView: View {
    @Bindable var store: APIServerStore
    let modelsManager: ModelsManager
    /// Called whenever a setting that needs the server restarted changes.
    let onChange: () -> Void

    @State private var tokenVisible: Bool = false
    @State private var portString: String = ""
    @State private var copiedField: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                Toggle(isOn: $store.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable local API server").font(.body.weight(.medium))
                        Text("Hearth listens on 127.0.0.1 only. Never the public network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: store.isEnabled) { _, _ in onChange() }

                Divider()

                portRow
                urlRow
                tokenRow
                modelRow

                Divider()

                howTo
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Server").font(.title2.weight(.semibold))
            Text("Expose Hearth's active local model over an OpenAI-compatible HTTP endpoint. Useful for OpenClaw (Discord, etc.), IDE plugins, and scripts — they call Hearth like they'd call openai.com, but everything runs on this Mac. No cloud, no token cost.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var portRow: some View {
        LabeledContent("Port") {
            HStack(spacing: 8) {
                TextField("11435", text: $portString)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 120)
                    .onAppear { portString = String(store.port) }
                    .onSubmit { applyPort() }
                Button("Apply") { applyPort() }
                    .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    private func applyPort() {
        guard let n = Int(portString), n > 0, n < 65_536 else { return }
        if n != store.port {
            store.port = n
            onChange()
        }
    }

    private var urlRow: some View {
        LabeledContent("Base URL") {
            HStack(spacing: 6) {
                Text("http://127.0.0.1:\(store.port)/v1")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                copyButton("url", value: "http://127.0.0.1:\(store.port)/v1")
                Spacer()
            }
        }
    }

    private var tokenRow: some View {
        LabeledContent("API key") {
            HStack(spacing: 6) {
                if tokenVisible {
                    Text(store.token)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading)
                } else {
                    Text(String(repeating: "•", count: 18))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button(tokenVisible ? "Hide" : "Show") { tokenVisible.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                copyButton("token", value: store.token)
                Button("Regenerate") {
                    store.regenerateToken()
                    onChange()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
    }

    private var modelRow: some View {
        LabeledContent("Served model") {
            HStack(spacing: 6) {
                Text(modelsManager.activeModel.id)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
            }
        }
    }

    private func copyButton(_ kind: String, value: String) -> some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(value, forType: .string)
            copiedField = kind
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if copiedField == kind { copiedField = nil }
            }
        } label: {
            Image(systemName: copiedField == kind ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pointing OpenClaw at Hearth").font(.headline)
            Text("In your OpenClaw config, set the upstream LLM provider to:")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                row("Base URL", "http://127.0.0.1:\(store.port)/v1")
                row("API Key", tokenVisible ? store.token : "(shown above)")
                row("Model", modelsManager.activeModel.id)
            }
            .padding(10)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))

            Text("Test from Terminal:").font(.callout.weight(.semibold)).padding(.top, 6)
            Text("""
            curl -sS http://127.0.0.1:\(store.port)/v1/chat/completions \\
              -H 'Authorization: Bearer <your-token>' \\
              -H 'Content-Type: application/json' \\
              -d '{"model":"hearth","messages":[{"role":"user","content":"hi"}]}'
            """)
            .font(.system(.caption, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            .textSelection(.enabled)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
