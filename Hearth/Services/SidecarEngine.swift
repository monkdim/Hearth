import Foundation
import AppKit
import os

enum SidecarGenerationEvent: Sendable {
    case starting
    case progress(Double)
    case finished(URL)
}

enum SidecarError: LocalizedError {
    case invalidURL(String)
    case httpStatus(Int, body: String)
    case unsupported(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s): "Invalid sidecar URL: \(s)"
        case .httpStatus(let code, let body): "Sidecar returned HTTP \(code). \(body)"
        case .unsupported(let s): s
        case .decode(let s): "Couldn't decode response: \(s)"
        }
    }
}

/// HTTP client for external generation backends. We instantiate one per
/// configured sidecar — each holds its config and a URLSession.
actor SidecarEngine {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "SidecarEngine")
    let config: SidecarConfig
    private let session: URLSession

    init(config: SidecarConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 1200
        self.session = URLSession(configuration: cfg)
    }

    /// Generate something based on the prompt. The output path's extension
    /// reflects `config.output` (`.png`, `.mp4`, `.wav`). Caller passes the
    /// directory and filename stem.
    nonisolated func generate(
        prompt: String,
        outputDirectory: URL,
        filenameStem: String
    ) -> AsyncThrowingStream<SidecarGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.starting)
                    try FileManager.default.createDirectory(
                        at: outputDirectory, withIntermediateDirectories: true
                    )
                    let ext: String
                    switch await self.config.output {
                    case .image: ext = "png"
                    case .video: ext = "mp4"
                    case .audio: ext = "wav"
                    case .text:
                        // Text-producing sidecars are routed through TextSidecarEngine,
                        // not this one. If we got here it's a config mismatch.
                        throw SidecarError.unsupported("Text sidecars don't run through the media engine.")
                    }
                    let outURL = outputDirectory.appending(path: "\(filenameStem).\(ext)")

                    switch await self.config.backend {
                    case .automatic1111:
                        try await self.runAutomatic1111(prompt: prompt, outURL: outURL,
                                                       continuation: continuation)
                    case .comfyUI:
                        try await self.runComfyUI(prompt: prompt, outURL: outURL,
                                                  continuation: continuation)
                    case .openAIChat:
                        throw SidecarError.unsupported("OpenAI-compatible sidecars are text-only; pick Text output.")
                    }

                    continuation.yield(.finished(outURL))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Liveness check. Returns nil on success, a human-readable error otherwise.
    nonisolated func ping() async -> String? {
        do {
            let base = try await self.baseURL()
            let url: URL
            switch await config.backend {
            case .automatic1111:
                url = base.appending(path: "sdapi/v1/options")
            case .comfyUI:
                url = base.appending(path: "queue")
            case .openAIChat:
                // Standard OpenAI / Ollama / LM Studio liveness endpoint.
                url = base.appending(path: "v1/models")
            }
            var request = URLRequest(url: url, timeoutInterval: 4)
            if let key = await config.apiKey, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "no http response" }
            if (200..<400).contains(http.statusCode) { return nil }
            // Surface the server's error body — OpenClaw returns a useful
            // JSON message when the token is wrong / missing.
            let bodyText = String(data: data.prefix(200), encoding: .utf8) ?? ""
            return bodyText.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(bodyText)"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - AUTOMATIC1111

    private struct A1111Request: Codable {
        let prompt: String
        let steps: Int
        let cfg_scale: Double
        let width: Int
        let height: Int
        let sampler_name: String
    }

    private struct A1111Response: Codable {
        let images: [String]
    }

    private func runAutomatic1111(
        prompt: String,
        outURL: URL,
        continuation: AsyncThrowingStream<SidecarGenerationEvent, Error>.Continuation
    ) async throws {
        let base = try baseURL()
        let endpoint = base.appending(path: "sdapi/v1/txt2img")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = A1111Request(
            prompt: prompt,
            steps: 30,
            cfg_scale: 7,
            width: 1024,
            height: 1024,
            sampler_name: "Euler a"
        )
        request.httpBody = try JSONEncoder().encode(body)

        // A1111 doesn't have a clean streaming progress API per-request, so we
        // poll /sdapi/v1/progress in parallel and emit progress events.
        let progressTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let p = await self.fetchA1111Progress() {
                    continuation.yield(.progress(p))
                    if p >= 0.999 { return }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { progressTask.cancel() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SidecarError.httpStatus(0, body: "(no response)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            throw SidecarError.httpStatus(http.statusCode, body: String(body.prefix(400)))
        }

        let parsed = try JSONDecoder().decode(A1111Response.self, from: data)
        guard let first = parsed.images.first else {
            throw SidecarError.decode("no images returned")
        }
        guard let imageData = Data(base64Encoded: first) else {
            throw SidecarError.decode("base64 decode failed")
        }
        try imageData.write(to: outURL)
    }

    private nonisolated func fetchA1111Progress() async -> Double? {
        guard let base = try? await baseURL() else { return nil }
        let url = base.appending(path: "sdapi/v1/progress")
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let progress = json["progress"] as? Double else { return nil }
            return progress
        } catch {
            return nil
        }
    }

    private func baseURL() throws -> URL {
        guard let url = URL(string: config.baseURL) else {
            throw SidecarError.invalidURL(config.baseURL)
        }
        return url
    }

    // MARK: - ComfyUI

    /// ComfyUI workflow flow:
    /// 1. POST /prompt with `{prompt: workflow, client_id: ...}` → returns `prompt_id`.
    /// 2. Poll GET /history/{prompt_id} until outputs appear.
    /// 3. Walk outputs to find image/video/audio file metadata.
    /// 4. GET /view?filename=...&subfolder=...&type=output → write to outURL.
    private func runComfyUI(
        prompt: String,
        outURL: URL,
        continuation: AsyncThrowingStream<SidecarGenerationEvent, Error>.Continuation
    ) async throws {
        guard let template = config.workflow, !template.isEmpty else {
            throw SidecarError.unsupported(
                "ComfyUI sidecar has no workflow template. Add one in Settings → Sidecars → Edit."
            )
        }
        let workflowJSON = template.replacingOccurrences(of: "{prompt}", with: Self.jsonEscape(prompt))

        guard let workflowData = workflowJSON.data(using: .utf8),
              let workflowObject = try? JSONSerialization.jsonObject(with: workflowData) else {
            throw SidecarError.decode("workflow template isn't valid JSON")
        }

        let clientId = UUID().uuidString
        let promptBody: [String: Any] = [
            "prompt": workflowObject,
            "client_id": clientId
        ]
        let body = try JSONSerialization.data(withJSONObject: promptBody)

        let base = try baseURL()
        var request = URLRequest(url: base.appending(path: "prompt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (postData, postResponse) = try await session.data(for: request)
        guard let http = postResponse as? HTTPURLResponse else {
            throw SidecarError.httpStatus(0, body: "(no response)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: postData, encoding: .utf8) ?? "(binary)"
            throw SidecarError.httpStatus(http.statusCode, body: String(bodyText.prefix(400)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: postData) as? [String: Any],
              let promptId = json["prompt_id"] as? String else {
            throw SidecarError.decode("missing prompt_id in /prompt response")
        }

        // Poll for completion.
        let polledOutput = try await pollComfyHistory(promptId: promptId, base: base) { fraction in
            continuation.yield(.progress(fraction))
        }

        guard let resource = polledOutput else {
            throw SidecarError.decode("ComfyUI returned no output media")
        }

        // Download the result file.
        try await downloadComfyOutput(resource, base: base, to: outURL)
    }

    private struct ComfyOutputResource {
        let filename: String
        let subfolder: String
        let type: String
    }

    private func pollComfyHistory(
        promptId: String,
        base: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ComfyOutputResource? {
        let pollURL = base.appending(path: "history/\(promptId)")
        let timeoutSeconds: TimeInterval = 600  // 10-minute ceiling
        let start = Date()

        while !Task.isCancelled {
            if Date().timeIntervalSince(start) > timeoutSeconds {
                throw SidecarError.unsupported("ComfyUI generation timed out after \(Int(timeoutSeconds))s.")
            }

            let (data, response) = try await session.data(from: pollURL)
            if let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entry = root[promptId] as? [String: Any] {
                if let outputs = entry["outputs"] as? [String: Any] {
                    if let resource = Self.firstMediaResource(from: outputs) {
                        onProgress(1.0)
                        return resource
                    }
                }
            }
            // Best-effort progress hint while we wait.
            onProgress(Double.random(in: 0.05...0.6))
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return nil
    }

    /// Walks the ComfyUI outputs dictionary to find the first image/video/audio
    /// file metadata. Different node types put media under different keys
    /// (images, gifs, videos, audio), so try the common ones.
    private static func firstMediaResource(from outputs: [String: Any]) -> ComfyOutputResource? {
        let candidateKeys = ["images", "gifs", "videos", "audio"]
        for (_, nodeAny) in outputs {
            guard let node = nodeAny as? [String: Any] else { continue }
            for key in candidateKeys {
                guard let arr = node[key] as? [[String: Any]] else { continue }
                for item in arr {
                    if let filename = item["filename"] as? String {
                        let subfolder = item["subfolder"] as? String ?? ""
                        let type = item["type"] as? String ?? "output"
                        return ComfyOutputResource(
                            filename: filename, subfolder: subfolder, type: type
                        )
                    }
                }
            }
        }
        return nil
    }

    private func downloadComfyOutput(
        _ resource: ComfyOutputResource,
        base: URL,
        to outURL: URL
    ) async throws {
        var components = URLComponents(url: base.appending(path: "view"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "filename", value: resource.filename),
            URLQueryItem(name: "subfolder", value: resource.subfolder),
            URLQueryItem(name: "type", value: resource.type)
        ]
        guard let url = components.url else {
            throw SidecarError.invalidURL("\(base) /view")
        }

        let (tempURL, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SidecarError.httpStatus(code, body: "couldn't download \(resource.filename)")
        }
        if FileManager.default.fileExists(atPath: outURL.path) {
            try FileManager.default.removeItem(at: outURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: outURL)
    }

    private static func jsonEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:   out.append(ch)
            }
        }
        return out
    }
}
