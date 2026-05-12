import SwiftUI

struct ToolCallCard: View {
    let message: ChatMessage
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                body_
            }
        }
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.tint.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tint)
                Text("called")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(message.toolName ?? "tool")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tint)
                if let snippet = compactArgs(message.toolArguments) {
                    Text(snippet)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.\(isExpanded ? "up" : "down")")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            if let args = message.toolArguments, !args.isEmpty {
                section(title: "Input", body: prettyJSON(args))
            }
            if let result = message.toolResult, !result.isEmpty {
                section(title: "Result", body: prettyJSON(result))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func compactArgs(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw
        }
        // Build a tight `key=value, key=value` preview.
        let parts = json
            .sorted(by: { $0.key < $1.key })
            .prefix(3)
            .map { key, value -> String in
                let valStr: String
                if let s = value as? String {
                    valStr = "\"\(s)\""
                } else {
                    valStr = String(describing: value)
                }
                return "\(key)=\(valStr)"
            }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return str
    }
}
