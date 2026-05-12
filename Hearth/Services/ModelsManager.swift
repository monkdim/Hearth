import Foundation
import Hub
import MLXLLM
import MLXLMCommon
import StableDiffusion
import Observation
import os

enum ModelInstallEvent: Sendable {
    case progress(Double)
    case complete
}

enum InstallationState: Sendable, Hashable {
    case notInstalled
    /// Some weights have been written to disk but the model isn't loadable yet.
    case partial(downloadedBytes: UInt64, totalBytes: UInt64)
    case installed

    var isInstalled: Bool { if case .installed = self { true } else { false } }
    var isPartial:   Bool { if case .partial   = self { true } else { false } }
}

/// Holds the currently-loaded inference engine. Text models use
/// `InferenceEngine`; image models use `ImageEngine`; sidecar models talk
/// over HTTP to a local external server.
enum ActiveEngine: Sendable {
    case text(InferenceEngine)
    case image(ImageEngine)
    case sidecar(SidecarEngine)
}

@MainActor
@Observable
final class ModelsManager {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "ModelsManager")
    private static let activeModelDefaultsKey = "hearth.activeModelId"

    static let modelsRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "Hearth/Models", directoryHint: .isDirectory)
    }()

    let hub: HubApi
    /// User-configured sidecars. Read at init and refreshed via `refreshSidecars(_:)`
    /// when SidecarsStore changes.
    private(set) var sidecars: [SidecarConfig] = []

    /// Native models plus any user-configured sidecars, in display order.
    var availableModels: [ModelInfo] {
        AppModelRegistry.all + sidecars.filter { $0.enabled }.map(ModelInfo.sidecarModel)
    }

    private(set) var installationStates: [String: InstallationState] = [:]
    private(set) var activeModel: ModelInfo
    private(set) var activeEngine: ActiveEngine
    private(set) var installingIds: Set<String> = []

    init(sidecars: [SidecarConfig] = []) {
        try? FileManager.default.createDirectory(
            at: Self.modelsRoot, withIntermediateDirectories: true
        )
        self.hub = HubApi(downloadBase: Self.modelsRoot)
        self.sidecars = sidecars

        let saved = UserDefaults.standard.string(forKey: Self.activeModelDefaultsKey)
        let allWithSidecars = AppModelRegistry.all
            + sidecars.filter { $0.enabled }.map(ModelInfo.sidecarModel)
        let model = allWithSidecars.first { $0.id == saved } ?? AppModelRegistry.default
        self.activeModel = model
        self.activeEngine = Self.makeEngine(for: model, hub: hub)
        rescan()
    }

    /// Update the list of sidecars (called when SidecarsStore changes).
    /// Keeps the active model valid; if the active model was a sidecar that
    /// got removed, falls back to the default text model.
    func refreshSidecars(_ updated: [SidecarConfig]) {
        sidecars = updated
        rescan()
        if case .sidecar(let config) = activeModel.kind,
           !updated.contains(where: { $0.id == config.id && $0.enabled }) {
            setActive(AppModelRegistry.default)
        }
    }

    // MARK: - Engine accessors

    /// Convenience: the active text engine. Returns nil when an image model is active.
    var textEngine: InferenceEngine? {
        if case .text(let engine) = activeEngine { return engine }
        return nil
    }

    /// Convenience: the active image engine. Returns nil when a text model is active.
    var imageEngine: ImageEngine? {
        if case .image(let engine) = activeEngine { return engine }
        return nil
    }

    /// Convenience: the active sidecar engine. Returns nil when a local model is active.
    var sidecarEngine: SidecarEngine? {
        if case .sidecar(let engine) = activeEngine { return engine }
        return nil
    }

    /// Legacy accessor used by code that hasn't been updated to handle image
    /// models yet — for new code prefer `activeEngine` and switch on it.
    var engine: InferenceEngine {
        // If the active model is image-kind, return a throwaway text engine so
        // we don't crash. Callers should be checking `activeModel.isImage` first.
        if let textEngine { return textEngine }
        return InferenceEngine(modelConfiguration: AppModelRegistry.default.mlxConfiguration!, hub: hub)
    }

    // MARK: - Installation state

    func installationState(for model: ModelInfo) -> InstallationState {
        installationStates[model.id] ?? .notInstalled
    }

    func isInstalled(_ model: ModelInfo) -> Bool {
        installationState(for: model).isInstalled
    }

    func rescan() {
        var states: [String: InstallationState] = [:]
        for model in availableModels {
            states[model.id] = Self.detectState(for: model)
        }
        installationStates = states
    }

    private static func detectState(for model: ModelInfo) -> InstallationState {
        switch model.kind {
        case .text:
            return detectTextState(for: model)
        case .image(let sdConfig):
            return detectImageState(for: model, configuration: sdConfig)
        case .sidecar:
            // Sidecars are always "installed" — the user manages the backend
            // separately. Reachability is checked at use-time.
            return .installed
        }
    }

    private static func detectTextState(for model: ModelInfo) -> InstallationState {
        let dir = modelDirectory(for: model)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return .notInstalled }

        let downloadedBytes = directorySize(at: dir)
        if downloadedBytes == 0 { return .notInstalled }

        let configURL = dir.appending(path: "config.json")
        let indexURL = dir.appending(path: "model.safetensors.index.json")
        let singleShardURL = dir.appending(path: "model.safetensors")

        if let totalFromIndex = readTotalSize(from: indexURL),
           let shards = readShards(from: indexURL) {
            let allShardsPresent = shards.allSatisfy { shard in
                let url = dir.appending(path: shard)
                if let size = fileSize(at: url), size > 0 { return true }
                return false
            }
            if fm.fileExists(atPath: configURL.path), allShardsPresent {
                return .installed
            }
            return .partial(downloadedBytes: downloadedBytes, totalBytes: totalFromIndex)
        }

        if fm.fileExists(atPath: configURL.path),
           let size = fileSize(at: singleShardURL), size > 0 {
            return .installed
        }

        let estimatedTotal = UInt64(model.sizeGB * 1_000_000_000)
        return .partial(downloadedBytes: downloadedBytes, totalBytes: estimatedTotal)
    }

    /// Stable Diffusion models are a constellation of files (unet, text-encoder,
    /// vae, tokenizer, scheduler). We treat the model as "installed" only if
    /// every file listed in its `StableDiffusionConfiguration.files` exists.
    private static func detectImageState(
        for model: ModelInfo,
        configuration: StableDiffusionConfiguration
    ) -> InstallationState {
        let dir = modelDirectory(for: model)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return .notInstalled }

        let downloadedBytes = directorySize(at: dir)
        if downloadedBytes == 0 { return .notInstalled }

        // Use mirror reflection to peek at the configuration's `files` dictionary
        // values. The library exposes the dict only internally, but the
        // *download* call uses the same paths and lays them out under `dir`.
        // We approximate by checking that ANY safetensors + the scheduler config
        // exist. If anything's missing, treat as partial.
        let candidates = [
            "unet/diffusion_pytorch_model.safetensors",
            "vae/diffusion_pytorch_model.safetensors",
            "scheduler/scheduler_config.json"
        ]
        let allPresent = candidates.allSatisfy { rel in
            fm.fileExists(atPath: dir.appending(path: rel).path)
        }
        if allPresent { return .installed }
        let estimatedTotal = UInt64(model.sizeGB * 1_000_000_000)
        return .partial(downloadedBytes: downloadedBytes, totalBytes: estimatedTotal)
    }

    private static func modelDirectory(for model: ModelInfo) -> URL {
        modelsRoot
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: model.id, directoryHint: .isDirectory)
    }

    private static func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if fileURL.path.contains("/.cache/") { continue }
            guard let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]
            ) else { continue }
            if values.isRegularFile == true, let size = values.totalFileAllocatedSize {
                total += UInt64(size)
            }
        }
        return total
    }

    private static func fileSize(at url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return UInt64(size)
    }

    private static func readShards(from indexURL: URL) -> [String]? {
        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String] else { return nil }
        return Array(Set(weightMap.values)).sorted()
    }

    private static func readTotalSize(from indexURL: URL) -> UInt64? {
        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = json["metadata"] as? [String: Any] else { return nil }
        if let n = metadata["total_size"] as? UInt64 { return n }
        if let n = metadata["total_size"] as? Int    { return UInt64(n) }
        if let n = metadata["total_size"] as? Double { return UInt64(n) }
        return nil
    }

    // MARK: - Install / uninstall

    func install(_ model: ModelInfo) -> AsyncThrowingStream<ModelInstallEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !installingIds.contains(model.id) else {
                continuation.finish(throwing: ModelsError.alreadyInstalling)
                return
            }
            installingIds.insert(model.id)
            let hub = self.hub
            let modelId = model.id
            let kind = model.kind

            let task = Task { [weak self] in
                do {
                    switch kind {
                    case .text(let configuration):
                        _ = try await MLXLMCommon.downloadModel(
                            hub: hub, configuration: configuration
                        ) { progress in
                            continuation.yield(.progress(progress.fractionCompleted))
                        }
                    case .image(let configuration):
                        try await configuration.download(hub: hub) { progress in
                            continuation.yield(.progress(progress.fractionCompleted))
                        }
                    case .sidecar:
                        // Nothing to install — the backend lives outside Hearth.
                        continuation.yield(.progress(1.0))
                    }
                    await MainActor.run {
                        self?.installingIds.remove(modelId)
                        self?.rescan()
                    }
                    continuation.yield(.complete)
                    continuation.finish()
                } catch {
                    await MainActor.run {
                        self?.installingIds.remove(modelId)
                        self?.rescan()
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func uninstall(_ model: ModelInfo) throws {
        let dir = Self.modelDirectory(for: model)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        rescan()
        logger.info("Uninstalled \(model.id, privacy: .public)")
    }

    // MARK: - Active model

    func setActive(_ model: ModelInfo) {
        guard model.id != activeModel.id else { return }
        activeModel = model
        activeEngine = Self.makeEngine(for: model, hub: hub)
        UserDefaults.standard.set(model.id, forKey: Self.activeModelDefaultsKey)
        logger.info("Active model → \(model.id, privacy: .public)")
    }

    private static func makeEngine(for model: ModelInfo, hub: HubApi) -> ActiveEngine {
        switch model.kind {
        case .text(let configuration):
            return .text(InferenceEngine(modelConfiguration: configuration, hub: hub))
        case .image(let configuration):
            return .image(ImageEngine(configuration: configuration, hub: hub))
        case .sidecar(let config):
            return .sidecar(SidecarEngine(config: config))
        }
    }
}

enum ModelsError: LocalizedError {
    case alreadyInstalling
    var errorDescription: String? {
        switch self {
        case .alreadyInstalling: "This model is already downloading."
        }
    }
}
