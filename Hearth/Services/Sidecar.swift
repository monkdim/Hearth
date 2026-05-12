import Foundation

/// Which external server we're talking to. Each backend has its own request
/// shape and capabilities.
enum SidecarBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic1111
    case comfyUI
    /// Any server speaking OpenAI's `/v1/chat/completions` schema: Ollama,
    /// LM Studio's server mode, vLLM, OpenClaw's gateway, llama.cpp's server.
    case openAIChat

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic1111: "AUTOMATIC1111"
        case .comfyUI:       "ComfyUI"
        case .openAIChat:    "OpenAI-compatible (Ollama / LM Studio / OpenClaw)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .automatic1111: "http://127.0.0.1:7860"
        case .comfyUI:       "http://127.0.0.1:8188"
        case .openAIChat:    "http://127.0.0.1:11434"
        }
    }

    var capabilityNote: String {
        switch self {
        case .automatic1111: "Image generation. Run A1111's webui with --api on this Mac."
        case .comfyUI:       "Image, video, audio. Run ComfyUI with the API enabled."
        case .openAIChat:
            """
            Text models served by a local server that speaks OpenAI's chat completions schema. Not the openai.com hosted API — these all run on this machine:

            • Ollama → URL http://127.0.0.1:11434, Model e.g. "deepseek-r1:14b", no API key
            • LM Studio (server mode) → URL http://127.0.0.1:1234, Model whatever's loaded, no API key
            • OpenClaw gateway → URL http://127.0.0.1:18789, Model "openclaw/default" (or "openclaw/<agentId>"), API key = your gateway bearer token
            • vLLM → URL http://127.0.0.1:8000, Model the HF repo id you served, no API key

            Reverse direction (other tools using Hearth's model as their LLM): Settings → API Server.
            """
        }
    }

    var producesText: Bool {
        self == .openAIChat
    }
}

/// What this sidecar produces. Constrains where it shows up in the UI and how
/// the result is rendered in chat.
enum SidecarOutput: String, Codable, Sendable, CaseIterable, Identifiable {
    case text
    case image
    case video
    case audio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
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
    /// Bearer token for OpenAI-compatible backends that require auth
    /// (OpenClaw uses one by default; Ollama / LM Studio typically don't).
    /// Sent as `Authorization: Bearer <token>`.
    var apiKey: String?
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        backend: SidecarBackend,
        output: SidecarOutput = .image,
        baseURL: String,
        model: String? = nil,
        workflow: String? = nil,
        apiKey: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.output = output
        self.baseURL = baseURL
        self.model = model
        self.workflow = workflow
        self.apiKey = apiKey
        self.enabled = enabled
    }
}
