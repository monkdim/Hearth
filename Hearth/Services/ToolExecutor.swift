import Foundation
import os

/// Executes built-in and custom (shell) tools.
/// Results are length-capped so they don't blow the model's context window.
enum ToolExecutor {
    private static let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "ToolExecutor")
    private static let maxOutputBytes = 16_000

    // MARK: - Built-in: read_file

    struct ReadFileInput: Codable, Sendable {
        let path: String
    }
    struct ReadFileOutput: Codable, Sendable {
        let path: String
        let content: String
        let truncated: Bool
        let error: String?
    }

    static func readFile(_ input: ReadFileInput) async -> ReadFileOutput {
        let url = expandedURL(input.path)
        do {
            let data = try Data(contentsOf: url)
            let raw = String(data: data, encoding: .utf8)
                ?? "<binary file, \(data.count) bytes — read as text not possible>"
            let (clamped, truncated) = clamp(raw)
            return ReadFileOutput(path: url.path, content: clamped,
                                  truncated: truncated, error: nil)
        } catch {
            return ReadFileOutput(path: url.path, content: "",
                                  truncated: false, error: error.localizedDescription)
        }
    }

    // MARK: - Built-in: list_directory

    struct ListDirectoryInput: Codable, Sendable {
        let path: String
    }
    struct ListDirectoryOutput: Codable, Sendable {
        let path: String
        let entries: [String]
        let error: String?
    }

    static func listDirectory(_ input: ListDirectoryInput) async -> ListDirectoryOutput {
        let url = expandedURL(input.path)
        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            let entries = items.map { item -> String in
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return item.lastPathComponent + (isDir ? "/" : "")
            }.sorted()
            return ListDirectoryOutput(path: url.path, entries: entries, error: nil)
        } catch {
            return ListDirectoryOutput(path: url.path, entries: [],
                                       error: error.localizedDescription)
        }
    }

    // MARK: - Built-in: find_files

    struct FindFilesInput: Codable, Sendable {
        let pattern: String
    }
    struct FindFilesOutput: Codable, Sendable {
        let pattern: String
        let matches: [String]
        let truncated: Bool
        let error: String?
    }

    static func findFiles(_ input: FindFilesInput) async -> FindFilesOutput {
        // Shell out to `find` for ergonomic glob handling.
        let expanded = NSString(string: input.pattern).expandingTildeInPath
        let result = await runShell("/usr/bin/find", arguments: [
            (expanded as NSString).deletingLastPathComponent.isEmpty ? "." : (expanded as NSString).deletingLastPathComponent,
            "-name", (expanded as NSString).lastPathComponent
        ])
        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let capped = Array(lines.prefix(200))
        return FindFilesOutput(
            pattern: input.pattern,
            matches: capped,
            truncated: lines.count > capped.count,
            error: result.error
        )
    }

    // MARK: - Custom: shell template

    struct ShellInput: Codable, Sendable {
        let input: String
    }
    struct ShellOutput: Codable, Sendable {
        let command: String
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let truncated: Bool
        let error: String?
    }

    /// Runs a user-defined shell template with the LLM's `input` substituted in.
    /// Caller is responsible for obtaining user approval before calling this.
    static func runCustomShell(template: String, llmInput: String) async -> ShellOutput {
        let command = template.replacingOccurrences(of: "{input}", with: llmInput)
        let result = await runShell("/bin/zsh", arguments: ["-l", "-c", command])
        let (clamped, truncated) = clamp(result.stdout)
        return ShellOutput(
            command: command,
            stdout: clamped,
            stderr: result.stderr,
            exitCode: result.exitCode,
            truncated: truncated,
            error: result.error
        )
    }

    // MARK: - Shell runner

    private struct ShellResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let error: String?
    }

    private static func runShell(_ executable: String, arguments: [String]) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: ShellResult(
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? "",
                        exitCode: process.terminationStatus,
                        error: nil
                    ))
                } catch {
                    continuation.resume(returning: ShellResult(
                        stdout: "", stderr: "", exitCode: -1,
                        error: error.localizedDescription
                    ))
                }
            }
        }
    }

    // MARK: - Helpers

    private static func expandedURL(_ raw: String) -> URL {
        URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
    }

    private static func clamp(_ string: String) -> (String, Bool) {
        let data = Data(string.utf8)
        if data.count <= maxOutputBytes { return (string, false) }
        let prefix = data.prefix(maxOutputBytes)
        let truncatedString = String(data: prefix, encoding: .utf8) ?? ""
        return (truncatedString + "\n… [truncated]", true)
    }
}
