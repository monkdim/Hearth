import AppKit
import MarkdownUI
import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    let isLast: Bool
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            switch message.role {
            case .user:
                Spacer(minLength: 60)
                userContent
            case .tool:
                ToolCallCard(message: message)
                Spacer(minLength: 30)
            default:
                assistantContent
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - User

    private var userContent: some View {
        Text(message.content)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.accentColor.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Assistant

    private var assistantContent: some View {
        let display = Self.parseAssistant(message.content)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Hearth")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if isStreaming && isLast && display.visible.isEmpty && !hasMedia {
                    ProgressView().controlSize(.mini)
                }
            }

            if display.isThinking && display.visible.isEmpty {
                thinkingIndicator
            }

            if let imagePath = message.imagePath {
                MediaPlayerView(kind: .image(path: imagePath))
            }
            if let videoPath = message.videoPath {
                MediaPlayerView(kind: .video(path: videoPath))
            }
            if let audioPath = message.audioPath {
                MediaPlayerView(kind: .audio(path: audioPath))
            }

            if !display.visible.isEmpty {
                Markdown(display.visible)
                    .markdownTheme(.ember)
                    .markdownCodeSyntaxHighlighter(.ember)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if display.hadHiddenReasoning {
                ReasoningDisclosure(text: display.reasoning)
            }
        }
    }

    private var hasMedia: Bool {
        message.imagePath != nil || message.videoPath != nil || message.audioPath != nil
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Thinking…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Split an assistant message into the user-facing answer and the
    /// reasoning blob inside `<think>…</think>` tags. Handles both the
    /// fully-closed case (post-stream) and the open-tag case (mid-stream),
    /// so DeepSeek R1's chain-of-thought doesn't flood the chat.
    struct AssistantDisplay {
        var visible: String       // text outside any <think>…</think>
        var reasoning: String     // text inside <think>…</think> blocks
        var isThinking: Bool      // currently inside an open <think>
        var hadHiddenReasoning: Bool { !reasoning.isEmpty }
    }

    static func parseAssistant(_ text: String) -> AssistantDisplay {
        var stripped = text
        var reasoning = ""

        // 1. Paired <think>…</think> blocks
        let pairedPattern = "<think>([\\s\\S]*?)</think>"
        if let regex = try? NSRegularExpression(pattern: pairedPattern) {
            let range = NSRange(stripped.startIndex..., in: stripped)
            let matches = regex.matches(in: stripped, range: range)
            for m in matches.reversed() {
                if let inner = Range(m.range(at: 1), in: stripped) {
                    reasoning = stripped[inner] + (reasoning.isEmpty ? "" : "\n\n" + reasoning)
                }
                if let full = Range(m.range, in: stripped) {
                    stripped.removeSubrange(full)
                }
            }
        }

        // 2. Orphan </think> — the tokenizer ate the opening <think>. Treat
        //    everything before the closing tag as reasoning.
        if let closeRange = stripped.range(of: "</think>") {
            let prefix = stripped[..<closeRange.lowerBound]
            if !prefix.isEmpty {
                let prefixStr = String(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefixStr.isEmpty {
                    reasoning = prefixStr + (reasoning.isEmpty ? "" : "\n\n" + reasoning)
                }
            }
            stripped.removeSubrange(..<closeRange.upperBound)
        }

        // 3. Orphan <think> — mid-stream, no closing tag yet.
        var isThinking = false
        if let openRange = stripped.range(of: "<think>") {
            let prefix = stripped[..<openRange.lowerBound]
            stripped = String(prefix)
            isThinking = true
        }

        // 4. Hide TOOL_CALL: lines from display — the tool-call card shows
        //    the user what actually happened. Raw JSON would be noise.
        let toolCallLine = "(?m)^\\s*TOOL_CALL:\\s*\\{[\\s\\S]*?\\}\\s*$"
        if let regex = try? NSRegularExpression(pattern: toolCallLine) {
            let range = NSRange(stripped.startIndex..., in: stripped)
            stripped = regex.stringByReplacingMatches(
                in: stripped, range: range, withTemplate: ""
            )
        }

        return AssistantDisplay(
            visible: stripped.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoning: reasoning.trimmingCharacters(in: .whitespacesAndNewlines),
            isThinking: isThinking
        )
    }
}

/// Small expandable footer that lets the user peek at the model's hidden
/// reasoning if they want. Default state collapsed.
private struct ReasoningDisclosure: View {
    let text: String
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                    Text("Reasoning")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Theme + syntax highlighter

private extension Theme {
    static let ember = Theme()
        .text {
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(HearthColors.codeInline)
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { config in
            VStack(alignment: .leading, spacing: 4) {
                config.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(18)
                    }
                Divider().opacity(0.4)
            }
            .padding(.vertical, 4)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .padding(.top, 4)
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                }
        }
        .paragraph { config in
            config.label
                .lineSpacing(2)
                .padding(.bottom, 2)
        }
        .codeBlock { config in
            CodeBlockView(configuration: config)
        }
        .blockquote { config in
            config.label
                .padding(.leading, 12)
                .overlay(
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(width: 2),
                    alignment: .leading
                )
                .padding(.leading, 4)
        }
        .listItem { config in
            config.label.padding(.vertical, 1)
        }
}

private enum HearthColors {
    static let codeInline = SwiftUI.Color.secondary.opacity(0.18)
    static let codeBackground = SwiftUI.Color(nsColor: NSColor.textBackgroundColor).opacity(0.55)
}

/// Renders fenced code blocks as a card with the language tag, a copy button,
/// and the code in a monospaced font.
private struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12)
                    }
                    .padding(12)
            }
        }
        .background(HearthColors.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let lang = configuration.language, !lang.isEmpty {
                Text(lang.lowercased())
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("code")
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                copy()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.opacity(0.5))
        .overlay(Divider().opacity(0.4), alignment: .bottom)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration.content, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { copied = false }
        }
    }
}

// MARK: - Syntax highlighter (lightweight — keywords + strings + comments)

private struct HearthCodeHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        // We rely on MarkdownUI's default rendering and add light coloring for
        // common patterns. Full syntax-tree highlighting would need a parser
        // per language; this is a pragmatic middle ground that looks decent
        // for any C-family / Swift / Python source.
        let attributed = applyHighlights(to: code, language: language?.lowercased())
        return Text(attributed)
    }

    private func applyHighlights(to code: String, language: String?) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.foregroundColor = .primary

        // Patterns: comments, strings, keywords, numbers.
        // Order matters — apply broader patterns first, then refinements.
        applyRegex(
            #"(/\*[\s\S]*?\*/)|(//[^\n]*)|(#[^\n]*)"#,
            color: .secondary,
            italic: true,
            to: &attributed,
            source: code
        )
        applyRegex(
            #""([^"\\]|\\.)*""#,
            color: .green,
            to: &attributed,
            source: code
        )
        applyRegex(
            #"'([^'\\]|\\.)*'"#,
            color: .green,
            to: &attributed,
            source: code
        )
        applyRegex(
            #"\b\d+(\.\d+)?\b"#,
            color: .orange,
            to: &attributed,
            source: code
        )
        applyRegex(
            keywordPattern(for: language),
            color: .pink,
            weight: .semibold,
            to: &attributed,
            source: code
        )
        return attributed
    }

    private func applyRegex(
        _ pattern: String,
        color: SwiftUI.Color,
        weight: Font.Weight? = nil,
        italic: Bool = false,
        to attributed: inout AttributedString,
        source: String
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        regex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let match,
                  let swiftRange = Range(match.range, in: source),
                  let attrRange = attributed.range(of: source[swiftRange]) else { return }
            attributed[attrRange].foregroundColor = color
            if italic { attributed[attrRange].font = .system(size: 12, design: .monospaced).italic() }
            if let weight {
                attributed[attrRange].font = .system(size: 12, weight: weight, design: .monospaced)
            }
        }
    }

    private func keywordPattern(for language: String?) -> String {
        let common = [
            "if", "else", "for", "while", "return", "break", "continue", "do",
            "switch", "case", "default", "in", "true", "false", "nil", "null", "None",
            "true", "True", "False", "and", "or", "not"
        ]
        let swift = ["func", "let", "var", "class", "struct", "enum", "protocol", "extension",
                     "import", "public", "private", "internal", "fileprivate", "static",
                     "self", "Self", "guard", "where", "throws", "try", "catch", "async", "await"]
        let cFamily = ["int", "void", "char", "long", "short", "float", "double", "unsigned",
                       "signed", "const", "static", "extern", "struct", "typedef", "sizeof",
                       "include", "define", "ifndef", "endif"]
        let py = ["def", "class", "import", "from", "as", "with", "lambda", "global",
                  "nonlocal", "pass", "yield", "raise", "except", "finally", "self"]
        let js = ["function", "const", "let", "var", "class", "extends", "new", "this",
                  "async", "await", "import", "from", "export", "default", "of", "typeof"]

        var keywords = common
        switch language {
        case "swift": keywords += swift
        case "c", "cpp", "c++", "objc", "objective-c", "objective-c++": keywords += cFamily
        case "python", "py": keywords += py
        case "js", "javascript", "ts", "typescript": keywords += js
        default: keywords += swift + cFamily + py + js
        }
        let pattern = keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return "\\b(?:\(pattern))\\b"
    }
}

private extension CodeSyntaxHighlighter where Self == HearthCodeHighlighter {
    static var ember: HearthCodeHighlighter { HearthCodeHighlighter() }
}
