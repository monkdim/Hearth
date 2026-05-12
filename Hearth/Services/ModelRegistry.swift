import Foundation
import MLXLLM
import MLXLMCommon
import StableDiffusion

/// What the model produces. Affects which engine runs it, the UI, and the
/// RAM estimator.
enum ModelKind: Sendable {
    case text(ModelConfiguration)
    case image(StableDiffusionConfiguration)
    /// External backend (AUTOMATIC1111, ComfyUI, etc.) reached over HTTP.
    /// The user manages the backend separately; Hearth just talks to it.
    case sidecar(SidecarConfig)
}

/// User-facing description of a model Hearth can run.
struct ModelInfo: Identifiable, Sendable, Hashable {
    /// Hugging Face repo path. Stable identity across builds.
    let id: String
    let displayName: String
    let sizeGB: Double
    /// For text models, the model's max context window. 0 for image models.
    let contextTokens: Int
    let category: Category
    let blurb: String
    let kind: ModelKind

    enum Category: String, Sendable {
        case general = "General"
        case coding = "Coding"
        case reasoning = "Reasoning"
        case image = "Image"
        case sidecar = "Sidecar"
    }

    static func == (lhs: ModelInfo, rhs: ModelInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }

    var isSidecar: Bool {
        if case .sidecar = kind { return true }
        return false
    }

    /// Convenience: the text `ModelConfiguration`, or nil for non-text models.
    var mlxConfiguration: ModelConfiguration? {
        if case .text(let cfg) = kind { return cfg }
        return nil
    }

    /// Rough KV-cache bytes used per token at fp16 (text models only).
    var kvBytesPerToken: UInt64 {
        guard case .text = kind else { return 0 }
        let n = displayName.lowercased()
        if n.contains("32b")  { return 280_000 }
        if n.contains("14b") || n.contains("phi-4") { return 200_000 }
        if n.contains("7b")   { return 130_000 }
        if n.contains("3b")   { return 95_000 }
        if n.contains("1.5b") { return 65_000 }
        if n.contains("1b")   { return 33_000 }
        return 150_000
    }

    /// Approximate runtime RAM in GB. Sidecars return 0 — they run in a
    /// separate process, not in Hearth's address space.
    func estimatedRuntimeRAMGB(maxTokens: Int) -> Double {
        switch kind {
        case .sidecar: return 0
        case .image: return sizeGB + 2.0
        case .text:
            let kvGB = Double(kvBytesPerToken) * Double(maxTokens) / 1_000_000_000
            return sizeGB + kvGB
        }
    }

    /// Bridge from a user-configured `SidecarConfig` into a `ModelInfo` so it
    /// shows up in pickers alongside native models.
    static func sidecarModel(from config: SidecarConfig) -> ModelInfo {
        ModelInfo(
            id: "sidecar:\(config.id.uuidString)",
            displayName: config.name,
            sizeGB: 0,
            contextTokens: 0,
            category: .sidecar,
            blurb: "\(config.backend.displayName) · \(config.output.label) · \(config.baseURL)",
            kind: .sidecar(config)
        )
    }
}

enum AppModelRegistry {
    static let all: [ModelInfo] = [
        // -- Tiny / fits anywhere (≤4 GB RAM headroom) --
        ModelInfo(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            displayName: "Llama 3.2 1B Instruct",
            sizeGB: 0.7,
            contextTokens: 128_000,
            category: .general,
            blurb: "Tiniest general model. Instant answers, weaker reasoning. Fine for 8 GB Macs.",
            kind: .text(LLMRegistry.llama3_2_1B_4bit)
        ),
        ModelInfo(
            id: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            displayName: "Qwen 2.5 Coder 1.5B",
            sizeGB: 0.9,
            contextTokens: 32_768,
            category: .coding,
            blurb: "Smallest coder. Surprisingly capable for autocomplete-style help.",
            kind: .text(ModelConfiguration(
                id: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
                defaultPrompt: "Write a function that…"
            ))
        ),
        ModelInfo(
            id: "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
            displayName: "Qwen 2.5 Coder 3B",
            sizeGB: 1.8,
            contextTokens: 32_768,
            category: .coding,
            blurb: "Compact coder. Good fit for 8 GB Macs.",
            kind: .text(ModelConfiguration(
                id: "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
                defaultPrompt: "Write a function that…"
            ))
        ),
        ModelInfo(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B Instruct",
            sizeGB: 1.8,
            contextTokens: 128_000,
            category: .general,
            blurb: "Fast general-purpose default. Good for short Q&A.",
            kind: .text(LLMRegistry.llama3_2_3B_4bit)
        ),

        // -- 16 GB sweet spot --
        ModelInfo(
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            displayName: "Qwen 2.5 Coder 7B",
            sizeGB: 4.5,
            contextTokens: 32_768,
            category: .coding,
            blurb: "Fast coder for 16 GB Macs. Great for refactoring & quick code Q&A.",
            kind: .text(ModelConfiguration(
                id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                defaultPrompt: "Write a function that…"
            ))
        ),
        ModelInfo(
            id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            displayName: "Qwen 2.5 7B Instruct",
            sizeGB: 4.5,
            contextTokens: 32_768,
            category: .general,
            blurb: "Balanced general model. Good all-rounder if you don't need coding-specific.",
            kind: .text(LLMRegistry.qwen2_5_7b)
        ),
        ModelInfo(
            id: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit",
            displayName: "Qwen 2.5 Coder 14B",
            sizeGB: 8.5,
            contextTokens: 32_768,
            category: .coding,
            blurb: "Top open coding model for 16 GB. Strong on RE / disassembly.",
            kind: .text(ModelConfiguration(
                id: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit",
                defaultPrompt: "Write a function that…"
            ))
        ),
        ModelInfo(
            id: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit",
            displayName: "DeepSeek R1 Distill 14B",
            sizeGB: 8.5,
            contextTokens: 131_072,
            category: .reasoning,
            blurb: "Explicit step-by-step reasoning. Best for puzzling out what code does.",
            kind: .text(ModelConfiguration(
                id: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit",
                defaultPrompt: "Solve this step by step:",
                extraEOSTokens: ["<｜end▁of▁sentence｜>"]
            ))
        ),
        ModelInfo(
            id: "mlx-community/phi-4-4bit",
            displayName: "Phi-4 14B",
            sizeGB: 8.3,
            contextTokens: 16_384,
            category: .reasoning,
            blurb: "Microsoft's reasoning model. Punches above its weight on logic & math.",
            kind: .text(ModelConfiguration(
                id: "mlx-community/phi-4-4bit",
                defaultPrompt: "Explain step by step:"
            ))
        ),

        // -- High-RAM (24+ GB) --
        ModelInfo(
            id: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
            displayName: "Qwen 2.5 Coder 32B",
            sizeGB: 18.5,
            contextTokens: 32_768,
            category: .coding,
            blurb: "Flagship open coder — rivals Claude 3.5 Sonnet on code. Needs 24+ GB.",
            kind: .text(ModelConfiguration(
                id: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
                defaultPrompt: "Write a function that…"
            ))
        ),
        ModelInfo(
            id: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit",
            displayName: "DeepSeek R1 Distill 32B",
            sizeGB: 18.5,
            contextTokens: 131_072,
            category: .reasoning,
            blurb: "Strongest open reasoning model. Slow but worth it for hard RE problems.",
            kind: .text(ModelConfiguration(
                id: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit",
                defaultPrompt: "Solve this step by step:",
                extraEOSTokens: ["<｜end▁of▁sentence｜>"]
            ))
        ),

        // -- Image generation --
        ModelInfo(
            id: "stabilityai/stable-diffusion-2-1-base",
            displayName: "Stable Diffusion 2.1 Base",
            sizeGB: 5.0,
            contextTokens: 0,
            category: .image,
            blurb: "Open-weight image generator from Stability AI. Slow (~50 steps), runs on anything 8 GB+.",
            kind: .image(.presetStableDiffusion21Base)
        ),
        ModelInfo(
            id: "stabilityai/sdxl-turbo",
            displayName: "SDXL Turbo",
            sizeGB: 7.0,
            contextTokens: 0,
            category: .image,
            blurb: "Fast 2-step generator. Best quality-per-second for image gen. Comfortable on 16 GB+.",
            kind: .image(.presetSDXLTurbo)
        ),
    ]

    static let `default`: ModelInfo = all.first(where: { $0.id == "mlx-community/Llama-3.2-3B-Instruct-4bit" }) ?? all[0]
}
