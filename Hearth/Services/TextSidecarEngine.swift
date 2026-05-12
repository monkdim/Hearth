import Foundation
import MLXLMCommon
import os

/// HTTP-based text engine. Talks the OpenAI `/v1/chat/completions` schema —
/// works with Ollama, LM Studio's server mode, vLLM, OpenClaw's gateway,
/// llama.cpp's server, and any other OpenAI-compatible HTTP backend.
///
/// Streams tokens via SSE (`stream: true`). Tool calls are forwarded in
/// OpenAI's native format, executed locally via Hearth's toolbox, and the
/// result is fed back into the conversation as a `tool` role message.
actor TextSidecarEngine: TextEngine {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "TextSidecarEngine")
    let config: SidecarConfig
    private let session: URLSession

    private let baseSystemPrompt = "You are Hearth, a concise helpful assistant. Be direct. Use Markdown for code blocks. Call available tools when helpful."

    init(config: SidecarConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 1800
        self.session = URLSession(configuration: cfg)
    }

    nonisolated func generate(
        history: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        toolbox: ToolBox,
        promptContext: InferenceEngine.PromptContext
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.loading)
                    var conversation = history
                    var rounds = 0
                    while rounds < 8 {  // tool-loop safety cap
                        if Task.isCancelled { break }
                        let outcome = try await self.singleRound(
                            conversation: conversation,
                            maxTokens: maxTokens,
                            temperature: temperature,
                            toolbox: toolbox,
                            promptContext: promptContext,
                            continuation: continuation
                        )
                        guard let toolCalls = outcome.toolCalls, !toolCalls.isEmpty else {
                            break  // plain text response, we're done
                        }
                        for call in toolCalls {
                            let result: String
                            if let entry = toolbox.entry(named: call.name) {
                                let mlxCall = MLXLMCommon_ToolCall(name: call.name,
                                                                  argumentsJSON: call.argumentsJSON)
                                result = await Self.execute(entry, mlxCall: mlxCall)
                            } else {
                                result = "{\"error\": \"Unknown tool '\(call.name)'\"}"
                            }
                            continuation.yield(.toolUsed(
                                name: call.name,
                                arguments: call.argumentsJSON,
                                result: result
                            ))
                            conversation.append(ChatMessage(
                                role: .tool,
                                content: "",
                                toolName: call.name,
                                toolArguments: call.argumentsJSON,
                                toolResult: result
                            ))
                        }
                        rounds += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Round

    private struct StreamedToolCall {
        var name: String = ""
        var argumentsJSON: String = ""
    }

    private struct RoundOutcome {
        var toolCalls: [StreamedToolCall]?
    }

    private func singleRound(
        conversation: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        toolbox: ToolBox,
        promptContext: InferenceEngine.PromptContext,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) async throws -> RoundOutcome {
        guard let base = URL(string: config.baseURL) else {
            throw SidecarError.invalidURL(config.baseURL)
        }
        // Match OpenAI / Ollama / LM Studio / vLLM / OpenClaw conventions.
        let endpoint = base.appending(path: "v1/chat/completions")

        let modelName = (config.model?.isEmpty == false) ? config.model! : "default"
        let body: [String: Any] = buildRequestBody(
            model: modelName,
            conversation: conversation,
            promptContext: promptContext,
            toolbox: toolbox,
            temperature: temperature,
            maxTokens: maxTokens
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SidecarError.httpStatus(0, body: "(no response)")
        }
        guard (200..<300).contains(http.statusCode) else {
            var bodyText = ""
            for try await line in bytes.lines {
                bodyText += line
                if bodyText.count > 600 { break }
            }
            throw SidecarError.httpStatus(http.statusCode, body: String(bodyText.prefix(600)))
        }

        var toolCalls: [Int: StreamedToolCall] = [:]
        var emittedTPS: Bool = false
        let startedAt = Date()
        var tokenCount = 0

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            // SSE lines arrive as `data: {...}`. Skip blanks and comments.
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else { continue }

            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                continuation.yield(.token(chunk))
                tokenCount += chunk.count / 4  // rough char-to-token ratio
                if !emittedTPS, tokenCount > 50 {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    if elapsed > 0.5 {
                        continuation.yield(.stats(tokensPerSecond: Double(tokenCount) / elapsed))
                        emittedTPS = true
                    }
                }
            }
            // Each delta may carry a partial tool call. Each entry has an
            // `index` so we can stitch fragments back together.
            if let deltaCalls = delta["tool_calls"] as? [[String: Any]] {
                for item in deltaCalls {
                    let index = (item["index"] as? Int) ?? 0
                    var current = toolCalls[index] ?? StreamedToolCall()
                    if let fn = item["function"] as? [String: Any] {
                        if let name = fn["name"] as? String, !name.isEmpty {
                            current.name = name
                        }
                        if let arg = fn["arguments"] as? String {
                            current.argumentsJSON += arg
                        }
                    }
                    toolCalls[index] = current
                }
            }
        }

        // Final tokens/sec readout.
        let elapsed = Date().timeIntervalSince(startedAt)
        if !emittedTPS, elapsed > 0, tokenCount > 0 {
            continuation.yield(.stats(tokensPerSecond: Double(tokenCount) / elapsed))
        }

        let finalCalls = toolCalls
            .sorted(by: { $0.key < $1.key })
            .map { $0.value }
            .filter { !$0.name.isEmpty }
        return RoundOutcome(toolCalls: finalCalls.isEmpty ? nil : finalCalls)
    }

    // MARK: - Request body

    private func buildRequestBody(
        model: String,
        conversation: [ChatMessage],
        promptContext: InferenceEngine.PromptContext,
        toolbox: ToolBox,
        temperature: Double,
        maxTokens: Int
    ) -> [String: Any] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": buildSystemPrompt(promptContext, toolbox: toolbox)]
        ]
        for msg in conversation {
            switch msg.role {
            case .user:
                messages.append(["role": "user", "content": msg.content])
            case .assistant:
                guard !msg.content.isEmpty else { continue }
                messages.append(["role": "assistant", "content": msg.content])
            case .tool:
                let toolMessage: [String: Any] = [
                    "role": "tool",
                    "tool_call_id": msg.toolName ?? "tool",
                    "content": msg.toolResult ?? ""
                ]
                messages.append(toolMessage)
            case .system:
                continue  // we injected our own
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]

        if !toolbox.isEmpty {
            body["tools"] = toolbox.entries.map { entry -> [String: Any] in
                // entry.schema is already in OpenAI-compatible function-call format.
                return entry.schema as [String: Any]
            }
        }
        return body
    }

    private func buildSystemPrompt(_ ctx: InferenceEngine.PromptContext, toolbox: ToolBox) -> String {
        var parts = [baseSystemPrompt]
        if let dir = ctx.workingDirectory, !dir.isEmpty {
            parts.append("Current project: \(ctx.projectName)\nWorking directory: \(dir)\nWhen the user refers to \"this folder\" or omits a path in tool calls, default to that directory.")
        }
        let ltm = ctx.ltm.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ltm.isEmpty {
            parts.append("Long-term memory for this project (durable context):\n\n\(ltm)")
        }
        return parts.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Tool execution bridge

    /// Adapter so a streamed tool call can run through MLX's `Tool<>` instances
    /// in the same toolbox we use for native MLX inference.
    private struct MLXLMCommon_ToolCall {
        let name: String
        let argumentsJSON: String
    }

    private static func execute(_ entry: AnyToolBoxEntry, mlxCall: MLXLMCommon_ToolCall) async -> String {
        // The toolbox entries take an MLX `ToolCall`. We construct one from our
        // streamed name + JSON args.
        guard let argsData = mlxCall.argumentsJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any] else {
            return "{\"error\": \"Couldn't parse tool arguments: \(mlxCall.argumentsJSON)\"}"
        }
        let toolCall = MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(name: mlxCall.name, arguments: args)
        )
        return await entry.execute(toolCall)
    }
}

