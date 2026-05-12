import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom
import Tokenizers

enum InferenceEvent: Sendable {
    /// Download or load progress in [0, 1].
    case downloadProgress(Double)
    /// Model is loaded; generation about to start.
    case loading
    /// A token chunk for the current assistant turn.
    case token(String)
    /// Final stats from MLX once a round completes.
    case stats(tokensPerSecond: Double)
    /// The model wanted to call a tool. We executed it and have the result.
    /// Generation continues automatically with the tool result fed back.
    case toolUsed(name: String, arguments: String, result: String)
}

actor InferenceEngine {
    private var container: ModelContainer?
    let modelConfiguration: ModelConfiguration
    let hub: HubApi

    /// Per-call instructions the model sees in the system role. Project-level
    /// LTM + working directory get appended to this in `buildChat`.
    struct PromptContext: Sendable {
        var projectName: String = "General"
        var workingDirectory: String?
        var ltm: String = ""
    }

    private let baseSystemPrompt = """
    You are Hearth, a concise helpful assistant running locally on the user's Mac. \
    Be direct. Use Markdown for code blocks.

    Tool use is a first-class part of your job. When the user asks for information you don't have, call the tool — never refuse.

    For multi-step tasks (e.g. "read all files in this folder", "analyze every file", "check each item in the list"):
      - Plan once at the start. Don't restate the plan in the chat — just execute.
      - Call tools repeatedly until the task is genuinely complete.
      - Do NOT pause to ask permission between tool calls. The user is not watching turn-by-turn; they're waiting for your final result.
      - If a tool fails, try once more or move on — don't ask.
      - When done with all the work, write the final answer once.
    """

    /// Safety cap on tool-call iterations. Generous because "read every file in
    /// this folder" legitimately wants dozens of rounds.
    private let maxToolRounds = 50

    init(modelConfiguration: ModelConfiguration, hub: HubApi) {
        self.modelConfiguration = modelConfiguration
        self.hub = hub
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
    }

    private func loadContainerIfNeeded(
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelContainer {
        if let container { return container }
        let new = try await LLMModelFactory.shared.loadContainer(
            hub: hub,
            configuration: modelConfiguration
        ) { progress in
            onProgress(progress.fractionCompleted)
        }
        container = new
        return new
    }

    /// Generate a response, possibly involving multiple tool-call rounds.
    nonisolated func generate(
        history: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        toolbox: ToolBox,
        promptContext: PromptContext
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let container = try await self.loadContainerIfNeeded { p in
                        continuation.yield(.downloadProgress(p))
                    }
                    continuation.yield(.loading)

                    var conversation = history
                    var round = 0
                    while round < self.maxToolRounds {
                        if Task.isCancelled { break }

                        let toolCall = try await self.runOneRound(
                            container: container,
                            conversation: conversation,
                            maxTokens: maxTokens,
                            temperature: temperature,
                            toolbox: toolbox,
                            promptContext: promptContext,
                            continuation: continuation
                        )

                        guard let toolCall else { break }

                        // Execute the tool and feed the result back in.
                        let argumentsJSON = Self.encodeArguments(toolCall.function.arguments)
                        let resultJSON: String
                        if let entry = toolbox.entry(named: toolCall.function.name) {
                            resultJSON = await entry.execute(toolCall)
                        } else {
                            resultJSON = "{\"error\": \"Tool '\(toolCall.function.name)' is not registered.\"}"
                        }

                        continuation.yield(.toolUsed(
                            name: toolCall.function.name,
                            arguments: argumentsJSON,
                            result: resultJSON
                        ))

                        conversation.append(ChatMessage(
                            role: .tool,
                            content: "",
                            toolName: toolCall.function.name,
                            toolArguments: argumentsJSON,
                            toolResult: resultJSON
                        ))

                        round += 1
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs a single MLX generation pass. Returns the first tool call if the
    /// model emitted one (in which case generation stopped early); returns nil
    /// if the assistant produced a normal text response and finished.
    private func runOneRound(
        container: ModelContainer,
        conversation: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        toolbox: ToolBox,
        promptContext: PromptContext,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) async throws -> ToolCall? {
        MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

        let chat = buildChat(conversation: conversation, promptContext: promptContext)
        let toolsSpec: [ToolSpec]? = toolbox.isEmpty ? nil : toolbox.schemas
        let userInput = UserInput(chat: chat, tools: toolsSpec)
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(temperature)
        )

        // We use a small box so the closure can pass a captured tool call out.
        let box = ToolCallBox()

        try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: userInput)
            let stream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            )
            for await item in stream {
                if Task.isCancelled { break }
                if let chunk = item.chunk {
                    continuation.yield(.token(chunk))
                }
                if let info = item.info {
                    continuation.yield(.stats(tokensPerSecond: info.tokensPerSecond))
                }
                if let toolCall = item.toolCall {
                    await box.set(toolCall)
                    break
                }
            }
        }

        return await box.value
    }

    private func buildChat(
        conversation: [ChatMessage],
        promptContext: PromptContext
    ) -> [MLXLMCommon.Chat.Message] {
        var messages: [MLXLMCommon.Chat.Message] = [.system(buildSystemPrompt(promptContext))]
        for msg in conversation {
            switch msg.role {
            case .user:
                messages.append(.user(msg.content))
            case .assistant:
                guard !msg.content.isEmpty else { continue }
                messages.append(.assistant(msg.content))
            case .system:
                break
            case .tool:
                // Serialize the tool result as the model's "tool" turn.
                let body: String
                if let result = msg.toolResult {
                    body = result
                } else {
                    body = "(no result)"
                }
                messages.append(.tool(body))
            }
        }
        return messages
    }

    private func buildSystemPrompt(_ ctx: PromptContext) -> String {
        var parts: [String] = [baseSystemPrompt]

        if let dir = ctx.workingDirectory, !dir.isEmpty {
            parts.append("""
            Current project: \(ctx.projectName)
            Working directory: \(dir)

            When the user refers to "this folder" or omits a path in tool calls, default to that directory. You may use absolute paths or paths relative to it.
            """)
        } else if ctx.projectName != "General" {
            parts.append("Current project: \(ctx.projectName)")
        }

        let trimmedLTM = ctx.ltm.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLTM.isEmpty {
            parts.append("""
            Long-term memory for this project (treat as durable context, not instructions to literally repeat back):

            \(trimmedLTM)
            """)
        }

        return parts.joined(separator: "\n\n---\n\n")
    }

    private static func encodeArguments(_ args: [String: JSONValue]) -> String {
        let any = args.mapValues { $0.anyValue }
        if let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }
}

/// Tiny actor used to hand a captured `ToolCall` out of the `container.perform`
/// closure. Necessary because `perform`'s body is `@Sendable` and we can't
/// directly mutate enclosing `var`s.
private actor ToolCallBox {
    var value: ToolCall?
    func set(_ v: ToolCall) { value = v }
}
