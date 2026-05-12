import Foundation

enum MarkdownUtilities {
    /// Extracts fenced code blocks (```...```) from a Markdown string,
    /// returning their inner contents in order. Drops the language tag.
    static func extractCodeBlocks(from text: String) -> [String] {
        var results: [String] = []
        let pattern = "```[^\\n]*\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return results
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 2,
                  let bodyRange = Range(match.range(at: 1), in: text) else { return }
            let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                results.append(body)
            }
        }
        return results
    }

    /// Returns the joined contents of all code blocks, separated by a blank line.
    /// Empty if the text contains no fenced code blocks.
    static func joinedCodeBlocks(in text: String) -> String {
        extractCodeBlocks(from: text).joined(separator: "\n\n")
    }
}
