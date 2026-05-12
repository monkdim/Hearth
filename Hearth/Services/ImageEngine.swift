import Foundation
import Hub
import MLX
import StableDiffusion
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

enum ImageGenerationEvent: Sendable {
    case downloadProgress(Double)
    case loading
    case stepProgress(Double)
    case finished(URL)
}

/// Image generation via MLX StableDiffusion. We bypass `ModelContainer`
/// because its convenience constructor uses the default `HubApi()` (which
/// points at `~/Documents/huggingface/`); Hearth downloads models into
/// `~/Library/Application Support/Hearth/Models/` via a custom HubApi, so the
/// container's loader couldn't find files. Holding the generator directly
/// lets us route the same HubApi through `configuration.textToImageGenerator`.
actor ImageEngine {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "ImageEngine")
    let configuration: StableDiffusionConfiguration
    let hub: HubApi
    private var generator: TextToImageGenerator?
    private let loadConfiguration: LoadConfiguration

    init(configuration: StableDiffusionConfiguration, hub: HubApi) {
        self.configuration = configuration
        self.hub = hub
        let lowMemory = MLX.GPU.memoryLimit < 8 * 1024 * 1024 * 1024
        self.loadConfiguration = LoadConfiguration(float16: true, quantize: lowMemory)
        // Respect the user's MLX cache preference unless we've detected a
        // genuinely tight memory situation, in which case we still cap low.
        let userCacheMB = UserDefaults.standard.object(forKey: Preferences.mlxCacheLimitKey) as? Int ?? 256
        if lowMemory {
            MLX.GPU.set(cacheLimit: min(userCacheMB, 64) * 1024 * 1024)
            MLX.GPU.set(memoryLimit: 3 * 1024 * 1024 * 1024)
        } else {
            MLX.GPU.set(cacheLimit: userCacheMB * 1024 * 1024)
        }
    }

    private func loadIfNeeded(
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> TextToImageGenerator {
        if let generator { return generator }

        do {
            try await configuration.download(hub: hub) { progress in
                onProgress(progress.fractionCompleted)
            }
        } catch let nserror as NSError where
            nserror.domain == NSURLErrorDomain &&
            nserror.code == NSURLErrorNotConnectedToInternet
        {
            // Offline: continue with whatever's cached.
        }

        guard let new = try configuration.textToImageGenerator(
            hub: hub, configuration: loadConfiguration
        ) else {
            throw NSError(domain: "Hearth.ImageEngine", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create text-to-image generator for \(configuration.id)"
            ])
        }
        self.generator = new
        return new
    }

    nonisolated func generate(
        prompt: String,
        negativePrompt: String = "",
        outputDirectory: URL,
        filename: String
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let generator = try await self.loadIfNeeded { p in
                        continuation.yield(.downloadProgress(p))
                    }
                    continuation.yield(.loading)

                    try FileManager.default.createDirectory(
                        at: outputDirectory,
                        withIntermediateDirectories: true
                    )
                    let outURL = outputDirectory.appending(path: filename)

                    let baseParameters = await self.configuration.defaultParameters()
                    let conserve = await self.loadConfiguration.quantize

                    var parameters = baseParameters
                    parameters.prompt = prompt
                    parameters.negativePrompt = negativePrompt
                    if conserve { parameters.steps = max(1, parameters.steps - 1) }

                    let decoder = generator.detachedDecoder()
                    let latents = generator.generateLatents(parameters: parameters)

                    var stepIndex = 0
                    var lastXt: MLXArray?
                    let total = parameters.steps
                    for xt in latents {
                        if Task.isCancelled { break }
                        eval(xt)
                        lastXt = xt
                        stepIndex += 1
                        let fraction = Double(stepIndex) / Double(max(total, 1))
                        continuation.yield(.stepProgress(fraction))
                    }
                    if let lastXt {
                        let decoded = decoder(lastXt)
                        try Self.savePNG(decoded: decoded, to: outURL)
                        continuation.yield(.finished(outURL))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated private static func savePNG(decoded: MLXArray, to url: URL) throws {
        let raster = (decoded * 255).asType(.uint8).squeezed()
        let cgImage = Image(raster).asCGImage()
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "Hearth.ImageEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create image destination at \(url.path)"
            ])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Hearth.ImageEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to finalize PNG at \(url.path)"
            ])
        }
    }
}
