import Foundation
import MLXLMCommon
import Tokenizers

/// Type-erased view of a single MLX `Tool<Input, Output>` instance. The MLX
/// `Tool<>` type is generic over its Input/Output, which makes it awkward to
/// store heterogeneous tools in one array; this wrapper lets us list them and
/// dispatch by name.
protocol AnyToolBoxEntry: Sendable {
    var name: String { get }
    var schema: ToolSpec { get }
    /// Execute the underlying tool with the given call and return its result
    /// as a JSON string ready to feed back to the model.
    func execute(_ call: ToolCall) async -> String
}

struct ToolBoxEntry<Input: Codable & Sendable, Output: Codable & Sendable>: AnyToolBoxEntry {
    let tool: Tool<Input, Output>

    var name: String { tool.name }
    var schema: ToolSpec { tool.schema }

    func execute(_ call: ToolCall) async -> String {
        do {
            let output = try await call.execute(with: tool)
            let data = try JSONEncoder().encode(output)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"\(error.localizedDescription)\"}"
        }
    }
}

/// Built from the user's enabled `ToolInfo`s by `ToolBox.from(_:)`. Pass this
/// to the inference engine; it provides schemas to MLX and runs handlers.
struct ToolBox: Sendable {
    let entries: [AnyToolBoxEntry]

    var isEmpty: Bool { entries.isEmpty }

    var schemas: [ToolSpec] {
        entries.map { $0.schema }
    }

    func entry(named name: String) -> AnyToolBoxEntry? {
        entries.first { $0.name == name }
    }

    static let empty = ToolBox(entries: [])
}

enum ToolBoxFactory {
    /// Builds a `ToolBox` from the active set of `ToolInfo`s. Custom shell
    /// tools each get their own `Tool<ShellInput, ShellOutput>` so the model
    /// sees them as distinct named functions.
    static func build(from tools: [ToolInfo]) -> ToolBox {
        var entries: [AnyToolBoxEntry] = []
        for info in tools where info.enabled {
            switch info.kind {
            case .builtin:
                if let entry = buildBuiltin(info) {
                    entries.append(entry)
                }
            case .shell:
                if let entry = buildShell(info) {
                    entries.append(entry)
                }
            }
        }
        return ToolBox(entries: entries)
    }

    private static func buildBuiltin(_ info: ToolInfo) -> AnyToolBoxEntry? {
        switch info.name {
        case "read_file":
            let tool = Tool<ToolExecutor.ReadFileInput, ToolExecutor.ReadFileOutput>(
                name: info.name,
                description: info.description,
                parameters: [
                    .required("path", type: .string,
                              description: "Absolute or ~-expanded path to a file.")
                ]
            ) { input in
                await ToolExecutor.readFile(input)
            }
            return ToolBoxEntry(tool: tool)

        case "list_directory":
            let tool = Tool<ToolExecutor.ListDirectoryInput, ToolExecutor.ListDirectoryOutput>(
                name: info.name,
                description: info.description,
                parameters: [
                    .required("path", type: .string,
                              description: "Absolute or ~-expanded path to a directory.")
                ]
            ) { input in
                await ToolExecutor.listDirectory(input)
            }
            return ToolBoxEntry(tool: tool)

        case "find_files":
            let tool = Tool<ToolExecutor.FindFilesInput, ToolExecutor.FindFilesOutput>(
                name: info.name,
                description: info.description,
                parameters: [
                    .required("pattern", type: .string,
                              description: "A path/glob pattern, e.g. \"~/Documents/**/*.swift\".")
                ]
            ) { input in
                await ToolExecutor.findFiles(input)
            }
            return ToolBoxEntry(tool: tool)

        default:
            return nil
        }
    }

    private static func buildShell(_ info: ToolInfo) -> AnyToolBoxEntry? {
        guard let template = info.commandTemplate, !template.isEmpty else { return nil }
        let inputDescription = info.inputDescription ?? "The argument substituted into the shell template."
        let tool = Tool<ToolExecutor.ShellInput, ToolExecutor.ShellOutput>(
            name: info.name,
            description: info.description,
            parameters: [
                .required("input", type: .string, description: inputDescription)
            ]
        ) { input in
            await ToolExecutor.runCustomShell(template: template, llmInput: input.input)
        }
        return ToolBoxEntry(tool: tool)
    }
}
