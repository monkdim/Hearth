import Foundation
import Observation
import os

@MainActor
@Observable
final class ProjectsStore {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "ProjectsStore")
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private static let activeProjectKey = "hearth.activeProjectId"

    private(set) var projects: [Project] = []
    /// Globally-active project id. Newly-created chats inherit this. Switching
    /// chats can change this to track the chat's project.
    var activeProjectId: UUID {
        didSet {
            UserDefaults.standard.set(activeProjectId.uuidString, forKey: Self.activeProjectKey)
        }
    }

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url

        let storedActive = UserDefaults.standard.string(forKey: Self.activeProjectKey)
            .flatMap { UUID(uuidString: $0) } ?? Project.defaultId
        self.activeProjectId = storedActive

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let loaded = Self.loadFromDisk(at: url) {
            self.projects = Self.ensureDefault(in: loaded)
        } else {
            self.projects = [Project.general]
            save()
        }

        // If the persisted active id no longer matches a known project, fall back.
        if !self.projects.contains(where: { $0.id == self.activeProjectId }) {
            self.activeProjectId = Project.defaultId
        }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appending(path: "Hearth", directoryHint: .isDirectory)
            .appending(path: "projects.json")
    }

    var activeProject: Project {
        project(with: activeProjectId) ?? Project.general
    }

    func project(with id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    // MARK: - CRUD

    func add(_ project: Project) {
        projects.append(project)
        scheduleSave()
    }

    func update(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        projects[idx].updatedAt = Date()
        scheduleSave()
    }

    func delete(_ projectId: UUID) {
        // Default project is sacrosanct.
        guard projectId != Project.defaultId else { return }
        projects.removeAll { $0.id == projectId }
        if activeProjectId == projectId {
            activeProjectId = Project.defaultId
        }
        scheduleSave()
    }

    func setActive(_ projectId: UUID) {
        guard projects.contains(where: { $0.id == projectId }) else { return }
        activeProjectId = projectId
    }

    // MARK: - Persistence

    private static func ensureDefault(in loaded: [Project]) -> [Project] {
        var result = loaded
        if !result.contains(where: { $0.id == Project.defaultId }) {
            result.insert(Project.general, at: 0)
        }
        return result
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(projects)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadFromDisk(at url: URL) -> [Project]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Project].self, from: data)
    }
}
