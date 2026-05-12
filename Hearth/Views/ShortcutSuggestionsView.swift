import SwiftUI

struct ShortcutSuggestionsView: View {
    let suggestions: [PromptShortcut]
    let selectedIndex: Int
    let onSelect: (PromptShortcut) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, shortcut in
                row(shortcut, isSelected: index == selectedIndex)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(shortcut) }
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ shortcut: PromptShortcut, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text("/" + shortcut.trigger)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tint)
                .frame(minWidth: 90, alignment: .leading)
            Text(shortcut.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(previewLine(shortcut.template))
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private func previewLine(_ template: String) -> String {
        template
            .replacingOccurrences(of: "\n", with: " · ")
            .replacingOccurrences(of: "{context}", with: "<context>")
            .replacingOccurrences(of: "{input}", with: "<input>")
    }
}
