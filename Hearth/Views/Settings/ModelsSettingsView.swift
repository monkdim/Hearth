import SwiftUI

struct ModelsSettingsView: View {
    @Bindable var modelsManager: ModelsManager
    @State private var installProgress: [String: Double] = [:]
    @State private var installError: String?
    @State private var installTasks: [String: Task<Void, Never>] = [:]
    @State private var pendingUninstall: ModelInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models")
                .font(.title2.weight(.semibold))
            Text("Models run entirely on your Mac. Downloads land in **~/Library/Application Support/Hearth/Models**.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(modelsManager.availableModels) { model in
                        modelRow(model)
                    }
                }
            }

            if let installError {
                Text(installError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .alert("Remove \(pendingUninstall?.displayName ?? "model")?",
               isPresented: Binding(
                   get: { pendingUninstall != nil },
                   set: { if !$0 { pendingUninstall = nil } }
               ),
               presenting: pendingUninstall) { model in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                do {
                    try modelsManager.uninstall(model)
                } catch {
                    installError = error.localizedDescription
                }
            }
        } message: { model in
            Text("This frees \(formattedSize(model.sizeGB)) on disk. You can re-download it any time.")
        }
    }

    @ViewBuilder
    private func modelRow(_ model: ModelInfo) -> some View {
        let state = modelsManager.installationState(for: model)
        let isInstalling = modelsManager.installingIds.contains(model.id)
        let isActive = modelsManager.activeModel.id == model.id

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.displayName).font(.headline)
                    categoryBadge(model.category)
                    if isActive {
                        statusBadge("ACTIVE", color: .accentColor)
                    } else if case .partial = state {
                        statusBadge("PARTIAL", color: .orange)
                    }
                }
                Text(model.blurb)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                Text("\(formattedSize(model.sizeGB)) · \(formattedContext(model.contextTokens)) · \(model.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                progressArea(state: state, isInstalling: isInstalling, modelId: model.id)
            }

            Spacer()

            controls(model: model, state: state, isInstalling: isInstalling, isActive: isActive)
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func progressArea(state: InstallationState, isInstalling: Bool, modelId: String) -> some View {
        if isInstalling, let progress = installProgress[modelId] {
            ProgressView(value: progress) {
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.caption)
            }
            .progressViewStyle(.linear)
            .padding(.top, 4)
        } else if case .partial(let downloaded, let total) = state, total > 0 {
            let frac = min(Double(downloaded) / Double(total), 1.0)
            ProgressView(value: frac) {
                Text("\(formattedBytes(downloaded)) / \(formattedBytes(total)) downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func controls(model: ModelInfo, state: InstallationState, isInstalling: Bool, isActive: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isInstalling {
                Button("Cancel") { cancelInstall(model) }
                    .buttonStyle(.bordered)
            } else {
                switch state {
                case .installed:
                    if !isActive {
                        Button("Set Active") { modelsManager.setActive(model) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Remove") { pendingUninstall = model }
                        .buttonStyle(.bordered)
                case .partial:
                    Button {
                        install(model)
                    } label: {
                        Label("Continue", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Discard") { pendingUninstall = model }
                        .buttonStyle(.bordered)
                case .notInstalled:
                    Button {
                        install(model)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func install(_ model: ModelInfo) {
        installError = nil
        installProgress[model.id] = 0
        let task = Task { @MainActor in
            do {
                for try await event in modelsManager.install(model) {
                    switch event {
                    case .progress(let p):
                        installProgress[model.id] = p
                    case .complete:
                        installProgress[model.id] = nil
                    }
                }
            } catch is CancellationError {
                installProgress[model.id] = nil
            } catch {
                installProgress[model.id] = nil
                installError = error.localizedDescription
            }
            installTasks[model.id] = nil
        }
        installTasks[model.id] = task
    }

    private func cancelInstall(_ model: ModelInfo) {
        installTasks[model.id]?.cancel()
        installTasks[model.id] = nil
        installProgress[model.id] = nil
    }

    private func formattedSize(_ gb: Double) -> String {
        String(format: "%.1f GB", gb)
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        return String(format: "%.0f MB", mb)
    }

    @ViewBuilder
    private func categoryBadge(_ category: ModelInfo.Category) -> some View {
        let (label, color): (String, Color) = {
            switch category {
            case .general:   return ("General", .gray)
            case .coding:    return ("Coding", .blue)
            case .reasoning: return ("Reasoning", .purple)
            case .image:     return ("Image", .pink)
            case .sidecar:   return ("Sidecar", .teal)
            }
        }()
        statusBadge(label.uppercased(), color: color)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule(style: .continuous))
            .foregroundStyle(color)
    }

    private func formattedContext(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return "\(tokens / 1000)k context"
        }
        return "\(tokens) context"
    }
}
