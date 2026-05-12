import Foundation
import Observation
import os

@MainActor
@Observable
final class SidecarsStore {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "SidecarsStore")
    private let fileURL: URL

    private(set) var sidecars: [SidecarConfig] = []

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let loaded = Self.loadFromDisk(at: url) {
            self.sidecars = loaded
        }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appending(path: "Hearth", directoryHint: .isDirectory)
            .appending(path: "sidecars.json")
    }

    var enabledSidecars: [SidecarConfig] {
        sidecars.filter { $0.enabled }
    }

    func sidecar(with id: UUID) -> SidecarConfig? {
        sidecars.first { $0.id == id }
    }

    // MARK: - CRUD

    func add(_ sidecar: SidecarConfig) {
        sidecars.append(sidecar)
        save()
    }

    func update(_ sidecar: SidecarConfig) {
        guard let idx = sidecars.firstIndex(where: { $0.id == sidecar.id }) else { return }
        sidecars[idx] = sidecar
        save()
    }

    func delete(_ id: UUID) {
        sidecars.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = sidecars.firstIndex(where: { $0.id == id }) else { return }
        sidecars[idx].enabled = enabled
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sidecars)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadFromDisk(at url: URL) -> [SidecarConfig]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([SidecarConfig].self, from: data)
    }
}
