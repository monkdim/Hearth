import Foundation

/// Which external server we're talking to. Each backend has its own request
/// shape and capabilities.
enum SidecarBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic1111
    case comfyUI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic1111: "AUTOMATIC1111"
        case .comfyUI:       "ComfyUI"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .automatic1111: "http://127.0.0.1:7860"
        case .comfyUI:       "http://127.0.0.1:8188"
        }
    }

    var capabilityNote: String {
        switch self {
        case .automatic1111: "Image generation. Run A1111's webui with --api on this Mac."
        case .comfyUI:       "Image, video, audio. Run ComfyUI with the API enabled."
        }
    }
}

/// What this sidecar produces. Constrains where it shows up in the UI and how
/// the result is rendered in chat.
enum SidecarOutput: String, Codable, Sendable, CaseIterable, Identifiable {
    case image
    case video
    case audio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        }
    }
}

/// One configured external generation backend. Persisted to disk so users
/// don't have to re-enter URLs.
struct SidecarConfig: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var backend: SidecarBackend
    var output: SidecarOutput
    var baseURL: String
    /// Model name as the backend understands it (e.g., a checkpoint filename
    /// for A1111). Optional — most backends accept generation requests with
    /// no model override and use whatever's currently loaded.
    var model: String?
    /// For ComfyUI: a workflow JSON template with `{prompt}` as a placeholder.
    /// Unused for A1111.
    var workflow: String?
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        backend: SidecarBackend,
        output: SidecarOutput = .image,
        baseURL: String,
        model: String? = nil,
        workflow: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.output = output
        self.baseURL = baseURL
        self.model = model
        self.workflow = workflow
        self.enabled = enabled
    }
}
