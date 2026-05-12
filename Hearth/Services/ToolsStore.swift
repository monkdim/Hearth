import Foundation
import Observation
import os

@MainActor
@Observable
final class ToolsStore {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "ToolsStore")
    private let fileURL: URL

    /// Built-in tools that ship with Hearth. Their `id` is stable across builds
    /// so we can persist enable/disable state.
    static let builtinDefaults: [ToolInfo] = [
        ToolInfo(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!,
            kind: .builtin,
            name: "read_file",
            description: "Read the contents of a file on disk. Use this when the user asks about a specific file or directs you to a path.",
            enabled: true
        ),
        ToolInfo(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!,
            kind: .builtin,
            name: "list_directory",
            description: "List the entries (files and subfolders) in a directory.",
            enabled: true
        ),
        ToolInfo(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!,
            kind: .builtin,
            name: "find_files",
            description: "Find files matching a glob pattern (e.g. \"~/Documents/**/*.swift\").",
            enabled: true
        ),
    ]

    private(set) var tools: [ToolInfo] = []

    /// Global kill-switch — when false, no tools are sent to the model.
    var toolsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(toolsEnabled, forKey: Self.toolsEnabledKey)
        }
    }

    /// When true, every shell tool execution requires explicit user approval.
    var requireShellApproval: Bool {
        didSet {
            UserDefaults.standard.set(requireShellApproval, forKey: Self.requireApprovalKey)
        }
    }

    private static let toolsEnabledKey = "hearth.toolsEnabled"
    private static let requireApprovalKey = "hearth.requireShellApproval"

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url

        self.toolsEnabled = UserDefaults.standard.object(forKey: Self.toolsEnabledKey) as? Bool ?? true
        self.requireShellApproval = UserDefaults.standard.object(forKey: Self.requireApprovalKey) as? Bool ?? true

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let loaded = Self.loadFromDisk(at: url) {
            self.tools = Self.mergeBuiltins(loaded: loaded)
        } else {
            self.tools = Self.builtinDefaults
            save()
        }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appending(path: "Hearth", directoryHint: .isDirectory)
            .appending(path: "tools.json")
    }

    var enabledTools: [ToolInfo] {
        guard toolsEnabled else { return [] }
        return tools.filter { $0.enabled }
    }

    // MARK: - CRUD

    func add(_ tool: ToolInfo) {
        tools.append(tool)
        save()
    }

    func update(_ tool: ToolInfo) {
        guard let idx = tools.firstIndex(where: { $0.id == tool.id }) else { return }
        tools[idx] = tool
        save()
    }

    func setEnabled(_ tool: ToolInfo, enabled: Bool) {
        guard let idx = tools.firstIndex(where: { $0.id == tool.id }) else { return }
        tools[idx].enabled = enabled
        save()
    }

    func delete(_ tool: ToolInfo) {
        // Built-ins can be disabled but not deleted.
        guard tool.kind != .builtin else { return }
        tools.removeAll { $0.id == tool.id }
        save()
    }

    func restoreDefaults() {
        tools = Self.builtinDefaults
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tools)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadFromDisk(at url: URL) -> [ToolInfo]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ToolInfo].self, from: data)
    }

    /// Ensures every built-in tool from the current shipping defaults is
    /// represented in the loaded list. New built-ins get appended; user
    /// enable/disable settings on existing built-ins are preserved.
    private static func mergeBuiltins(loaded: [ToolInfo]) -> [ToolInfo] {
        var result = loaded
        for builtin in builtinDefaults {
            if !result.contains(where: { $0.id == builtin.id }) {
                result.append(builtin)
            } else if let idx = result.firstIndex(where: { $0.id == builtin.id }) {
                // Refresh description / name from shipping defaults so we don't
                // get stuck with an out-of-date copy if we improve the wording.
                result[idx].description = builtin.description
                result[idx].name = builtin.name
                result[idx].kind = .builtin
            }
        }
        return result
    }
}
