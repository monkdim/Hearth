import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var preferences: Preferences
    let modelsManager: ModelsManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("General").font(.title2.weight(.semibold))

                responseLengthSection

                temperatureSection

                positionSection
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Position

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launcher position").font(.headline)
            Picker("Position", selection: $preferences.positionMode) {
                ForEach(Preferences.PositionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("\"Center of active screen\" follows your mouse and stays in the upper third. \"Remember last position\" lets you drag Hearth anywhere and it'll reopen there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Response length

    private var responseLengthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Response length").font(.headline)
                Spacer()
                Text(currentPreset.label + " · \(formatTokens(preferences.maxResponseTokens))")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Picker("Response length", selection: presetBinding) {
                ForEach(Preferences.LengthPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentPreset.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ramBadge
            }

            Text("RAM is the rough minimum needed to generate this response length on top of an empty conversation. Long conversations grow KV cache further — typically by another \(modelsManager.activeModel.kvBytesPerToken / 1000) KB per token of history.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Temperature

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Temperature").font(.headline)
                Spacer()
                Text(String(format: "%.2f", preferences.temperature))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $preferences.temperature, in: 0...1.5, step: 0.05) {
                Text("Temperature")
            } minimumValueLabel: {
                Text("0").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("1.5").font(.caption2).foregroundStyle(.secondary)
            }
            .labelsHidden()
            Text("0 is deterministic and dry; 1 is balanced; 1.5 is wild. The default 0.6 is good for code and Q&A.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - RAM hint

    private var ramBadge: some View {
        let model = modelsManager.activeModel
        let ram = model.estimatedRuntimeRAMGB(maxTokens: preferences.maxResponseTokens)
        let color: Color = {
            if ram > 24 { return .red }
            if ram > 12 { return .orange }
            return .green
        }()
        return HStack(spacing: 6) {
            Image(systemName: "memorychip")
                .font(.caption)
            Text("≈ \(String(format: "%.1f", ram)) GB RAM")
                .font(.caption.weight(.semibold))
            Text("· \(model.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule(style: .continuous))
        .foregroundStyle(color)
    }

    // MARK: - Bindings

    private var currentPreset: Preferences.LengthPreset {
        Preferences.nearestPreset(to: preferences.maxResponseTokens)
    }

    private var presetBinding: Binding<Preferences.LengthPreset> {
        Binding(
            get: { currentPreset },
            set: { preferences.maxResponseTokens = $0.rawValue }
        )
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1024 {
            return "\(tokens / 1024)K"
        }
        return "\(tokens)"
    }
}
