import Foundation

/// Common interface for anything that can stream chat completions back to
/// `GenerationController`. Both `InferenceEngine` (MLX, local) and
/// `TextSidecarEngine` (OpenAI-compatible HTTP server like Ollama, LM Studio,
/// OpenClaw, vLLM) conform — so the rest of the app doesn't care which is
/// running.
protocol TextEngine: Sendable {
    func generate(
        history: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        toolbox: ToolBox,
        promptContext: InferenceEngine.PromptContext
    ) -> AsyncThrowingStream<InferenceEvent, Error>
}

extension InferenceEngine: TextEngine {}
