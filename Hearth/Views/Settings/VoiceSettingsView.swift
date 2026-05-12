import SwiftUI

struct VoiceSettingsView: View {
    @Bindable var voiceInput: VoiceInputService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voice Input").font(.title2.weight(.semibold))

            Text("Click the mic in the launcher, dictate, click again — Hearth transcribes locally using Whisper. Audio never leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Whisper model").font(.headline)
                Picker("Whisper model", selection: $voiceInput.modelName) {
                    ForEach(VoiceInputService.availableModels, id: \.id) { entry in
                        Text(entry.label).tag(entry.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Text("Models download on first use from Hugging Face. Smaller = faster startup and less RAM; larger = more accurate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 6) {
                Text("Status").font(.headline)
                HStack(spacing: 8) {
                    Circle()
                        .frame(width: 8, height: 8)
                        .foregroundStyle(statusColor)
                    Text(statusLabel).font(.callout)
                }
                if !voiceInput.lastError.isEmpty {
                    Text(voiceInput.lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(14)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))

            Spacer()
        }
    }

    private var statusColor: Color {
        switch voiceInput.state {
        case .idle: .secondary
        case .recording: .red
        case .transcribing: .orange
        }
    }

    private var statusLabel: String {
        switch voiceInput.state {
        case .idle: "Idle"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        }
    }
}
