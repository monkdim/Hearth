import Foundation
import Network
import os

/// Local HTTP server that exposes Hearth's active text engine through the
/// OpenAI `/v1/chat/completions` schema. Lets external tools (OpenClaw,
/// scripts, IDE extensions) use Hearth's local MLX model as if it were a
/// hosted LLM, with zero cloud calls.
///
/// Bound to 127.0.0.1 only — never the public interface. Auth is a single
/// bearer token compared in constant time. Streaming uses SSE in the same
/// chunk format OpenAI's hosted API emits, so off-the-shelf clients work
/// without modification.
actor HearthAPIServer {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "HearthAPIServer")

    // The active engine + supporting context are MainActor-isolated on their
    // owning stores, so the server reaches for them through closures provided
    // at init. Toolbox + prompt context are re-read per request so that
    // tool/project changes take effect without a server restart.
    private let engineProvider: @MainActor () -> any TextEngine
    private let modelIdProvider: @MainActor () -> String
    private let tokenProvider: @MainActor () -> String
    private let toolboxProvider: @MainActor () -> ToolBox
    private let promptContextProvider: @MainActor () -> InferenceEngine.PromptContext

    private var listener: NWListener?
    private var connections: Set<NWConnectionBox> = []
    private(set) var lastError: String?
    private(set) var boundPort: Int?

    init(
        engineProvider: @escaping @MainActor () -> any TextEngine,
        modelIdProvider: @escaping @MainActor () -> String,
        tokenProvider: @escaping @MainActor () -> String,
        toolboxProvider: @escaping @MainActor () -> ToolBox,
        promptContextProvider: @escaping @MainActor () -> InferenceEngine.PromptContext
    ) {
        self.engineProvider = engineProvider
        self.modelIdProvider = modelIdProvider
        self.tokenProvider = tokenProvider
        self.toolboxProvider = toolboxProvider
        self.promptContextProvider = promptContextProvider
    }

    // MARK: - Lifecycle

    func start(port: Int) {
        if listener != nil { stop() }
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                lastError = "Port \(port) is out of range."
                return
            }
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true  // 127.0.0.1 only
            let l = try NWListener(using: parameters, on: nwPort)
            l.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleListenerState(state) }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { await self?.accept(conn) }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
            boundPort = port
            lastError = nil
            logger.info("API server listening on 127.0.0.1:\(port, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            logger.error("Failed to bind \(port, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        for conn in connections { conn.connection.cancel() }
        connections.removeAll()
        logger.info("API server stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .failed(let err):
            lastError = err.localizedDescription
            logger.error("Listener failed: \(err.localizedDescription, privacy: .public)")
        case .cancelled:
            break
        default:
            break
        }
    }

    // MARK: - Connection lifecycle

    private func accept(_ connection: NWConnection) {
        let box = NWConnectionBox(connection: connection)
        connections.insert(box)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.readRequest(on: box) }
            case .failed, .cancelled:
                Task { await self.drop(box) }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func drop(_ box: NWConnectionBox) {
        connections.remove(box)
    }

    // MARK: - HTTP/1.1 parsing

    private func readRequest(on box: NWConnectionBox) {
        var buffer = Data()
        readMore(on: box, buffer: buffer)
    }

    private func readMore(on box: NWConnectionBox, buffer initial: Data) {
        var buffer = initial
        box.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                Task { await self.tryHandle(buffer: buffer, on: box, isComplete: isComplete, error: error) }
            } else {
                Task { await self.tryHandle(buffer: buffer, on: box, isComplete: isComplete, error: error) }
            }
        }
    }

    private func tryHandle(buffer: Data, on box: NWConnectionBox, isComplete: Bool, error: NWError?) {
        if let error {
            logger.error("Receive error: \(error.localizedDescription, privacy: .public)")
            box.connection.cancel()
            return
        }
        // Look for end of headers.
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // Not enough data yet — keep reading.
            if isComplete { box.connection.cancel(); return }
            readMore(on: box, buffer: buffer)
            return
        }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            respondPlain(.badRequest, "Invalid headers", on: box)
            return
        }
        let request = HTTPRequest.parse(headerString)
        let bodyStart = headerEnd.upperBound
        let declaredLen = request.contentLength ?? 0
        let bodyAvailable = buffer.count - bodyStart

        if bodyAvailable < declaredLen {
            // Need more body bytes.
            if isComplete { box.connection.cancel(); return }
            readMore(on: box, buffer: buffer)
            return
        }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + declaredLen))
        Task { await self.route(request: request, body: body, on: box) }
    }

    // MARK: - Routing

    private func route(request: HTTPRequest, body: Data, on box: NWConnectionBox) async {
        // CORS preflight — some IDE plugins probe.
        if request.method == "OPTIONS" {
            respondPlain(.ok, "", on: box, extraHeaders: corsHeaders())
            return
        }

        // Auth check.
        let token = await tokenProvider()
        if !token.isEmpty {
            let provided = request.bearerToken ?? ""
            if !constantTimeEqual(provided, token) {
                respondJSON([
                    "error": [
                        "message": "Missing or invalid bearer token. Set the API key in your client to Hearth's token from Settings → API Server.",
                        "type": "invalid_request_error"
                    ]
                ], status: .unauthorized, on: box)
                return
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            await handleListModels(on: box)
        case ("POST", "/v1/chat/completions"):
            await handleChatCompletions(body: body, on: box)
        default:
            respondJSON([
                "error": [
                    "message": "Not found: \(request.method) \(request.path)",
                    "type": "invalid_request_error"
                ]
            ], status: .notFound, on: box)
        }
    }

    // MARK: - /v1/models

    private func handleListModels(on box: NWConnectionBox) async {
        let modelId = await modelIdProvider()
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "object": "list",
            "data": [[
                "id": modelId,
                "object": "model",
                "created": now,
                "owned_by": "hearth"
            ]]
        ]
        respondJSON(payload, status: .ok, on: box)
    }

    // MARK: - /v1/chat/completions

    private func handleChatCompletions(body: Data, on box: NWConnectionBox) async {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            respondJSON([
                "error": [
                    "message": "Body isn't valid JSON.",
                    "type": "invalid_request_error"
                ]
            ], status: .badRequest, on: box)
            return
        }
        let stream = (json["stream"] as? Bool) ?? false
        let messages = (json["messages"] as? [[String: Any]]) ?? []
        let temperature = (json["temperature"] as? Double) ?? 0.7
        let maxTokens = (json["max_tokens"] as? Int) ?? 2048
        let requestedModel = (json["model"] as? String) ?? ""

        // Convert OpenAI messages → Hearth's [ChatMessage].
        let history = messages.compactMap { msg -> ChatMessage? in
            let role = (msg["role"] as? String) ?? "user"
            let content = Self.extractContent(msg["content"])
            switch role {
            case "user":      return ChatMessage(role: .user, content: content)
            case "assistant": return ChatMessage(role: .assistant, content: content)
            case "system":    return ChatMessage(role: .system, content: content)
            case "tool":
                return ChatMessage(
                    role: .tool,
                    content: "",
                    toolName: (msg["name"] as? String) ?? (msg["tool_call_id"] as? String),
                    toolResult: content
                )
            default: return nil
            }
        }

        let engine = await engineProvider()
        let activeModel = await modelIdProvider()
        let responseModel = requestedModel.isEmpty ? activeModel : requestedModel
        let completionId = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let created = Int(Date().timeIntervalSince1970)

        // Pull live toolbox + project context. Hearth executes tools internally
        // during the generation loop — clients (OpenClaw, etc.) only see the
        // final assistant text, never the tool round-trips.
        //
        // Readonly gate: any requested model that ends with `:readonly` or
        // `-readonly` gets an empty toolbox so the caller can't trigger file
        // reads / shell commands. Used to let OpenClaw expose a "guest" agent
        // to Discord users who shouldn't have local file access while the
        // admin user keeps full tooling on a different model id.
        //
        // Without tools, an unconstrained model still happily fabricates
        // "directory listings" when asked. So we also override the prompt
        // context to inject an explicit refusal instruction via the LTM slot
        // (which `buildSystemPrompt` already appends to the system prompt).
        let isReadonly = requestedModel.hasSuffix(":readonly")
            || requestedModel.hasSuffix("-readonly")
        let toolbox: ToolBox
        let promptContext: InferenceEngine.PromptContext
        if isReadonly {
            toolbox = ToolBox.empty
            let basePC = await promptContextProvider()
            let restrictionNote = """
            ## Access policy

            This conversation runs in **restricted text-only mode**. You have no file system access, no shell access, and no tools of any kind. If the user asks you to read a file, list a directory, run a command, search the disk, or otherwise touch the host machine — politely decline and explain you can't do that in this conversation. **Never fabricate file listings, file contents, command output, or anything else that would require host access.** Stick to general chat and reasoning.
            """
            // Strip working directory too — no point telling the model about a
            // folder it can't reach.
            promptContext = InferenceEngine.PromptContext(
                projectName: basePC.projectName,
                workingDirectory: nil,
                ltm: basePC.ltm.isEmpty
                    ? restrictionNote
                    : restrictionNote + "\n\n" + basePC.ltm
            )
        } else {
            toolbox = await toolboxProvider()
            promptContext = await promptContextProvider()
        }
        let eventStream = engine.generate(
            history: history,
            maxTokens: maxTokens,
            temperature: temperature,
            toolbox: toolbox,
            promptContext: promptContext
        )

        if stream {
            await runStreaming(
                eventStream: eventStream,
                completionId: completionId,
                model: responseModel,
                created: created,
                on: box
            )
        } else {
            await runNonStreaming(
                eventStream: eventStream,
                completionId: completionId,
                model: responseModel,
                created: created,
                on: box
            )
        }
    }

    /// OpenAI lets `content` be a string or an array of parts. We flatten
    /// parts down to a string — image inputs aren't supported here.
    private static func extractContent(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let parts = raw as? [[String: Any]] {
            return parts.compactMap { part in
                if let t = part["text"] as? String { return t }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Streaming response

    private func runStreaming(
        eventStream: AsyncThrowingStream<InferenceEvent, Error>,
        completionId: String,
        model: String,
        created: Int,
        on box: NWConnectionBox
    ) async {
        // SSE response headers.
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: keep-alive\r\n"
        head += "X-Accel-Buffering: no\r\n"
        for (k, v) in corsHeaders() { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        sendRaw(head.data(using: .utf8) ?? Data(), on: box)

        // Buffer-and-strip: some models emit `TOOL_CALL: { ... }` in the raw
        // token stream before our engine detects + stops on the complete JSON.
        // Hold back any tokens from the most recent unmatched `TOOL_CALL:`
        // onward (we can't yet tell where its closing `}` lands), strip every
        // balanced directive from what came before, and emit only that.
        var raw = ""           // every token received so far
        var emittedClean = ""  // total clean text emitted to client
        do {
            for try await event in eventStream {
                if case .token(let chunk) = event {
                    raw += chunk
                    let safeEnd = Self.safeStreamEnd(in: raw)
                    let safePrefix = String(raw.prefix(safeEnd))
                    let cleaned = Self.stripToolCallLines(safePrefix)
                    if cleaned.count > emittedClean.count,
                       cleaned.hasPrefix(emittedClean) {
                        let delta = String(cleaned.dropFirst(emittedClean.count))
                        if !delta.isEmpty {
                            sendSSEDelta(delta, completionId: completionId, model: model, created: created, on: box)
                        }
                        emittedClean = cleaned
                    }
                }
            }
            // End of stream: flush everything that's left, stripping any
            // trailing TOOL_CALL even if unbalanced (model gave up mid-call).
            let finalStripped = Self.stripToolCallLines(raw)
            if finalStripped.count > emittedClean.count,
               finalStripped.hasPrefix(emittedClean) {
                let delta = String(finalStripped.dropFirst(emittedClean.count))
                if !delta.isEmpty {
                    sendSSEDelta(delta, completionId: completionId, model: model, created: created, on: box)
                }
            }
            // Final stop chunk.
            let stop: [String: Any] = [
                "id": completionId,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [[
                    "index": 0,
                    "delta": [:],
                    "finish_reason": "stop"
                ]]
            ]
            sendSSEData(stop, on: box)
            sendRaw(Data("data: [DONE]\n\n".utf8), on: box)
        } catch {
            // Emit one final chunk with an error message so the client sees it
            // instead of a silent disconnect.
            let err: [String: Any] = [
                "id": completionId,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [[
                    "index": 0,
                    "delta": ["content": "\n\n[Hearth error: \(error.localizedDescription)]"],
                    "finish_reason": "stop"
                ]]
            ]
            sendSSEData(err, on: box)
            sendRaw(Data("data: [DONE]\n\n".utf8), on: box)
        }
        finishConnection(box)
    }

    // MARK: - Non-streaming response

    private func runNonStreaming(
        eventStream: AsyncThrowingStream<InferenceEvent, Error>,
        completionId: String,
        model: String,
        created: Int,
        on box: NWConnectionBox
    ) async {
        var raw = ""
        do {
            for try await event in eventStream {
                if case .token(let chunk) = event { raw += chunk }
            }
        } catch {
            let payload: [String: Any] = [
                "error": [
                    "message": error.localizedDescription,
                    "type": "engine_error"
                ]
            ]
            respondJSON(payload, status: .internalServerError, on: box)
            return
        }
        // Strip any TOOL_CALL: { ... } lines the model emitted in plain text
        // before our engine caught + stopped on the complete JSON.
        let full = Self.stripToolCallLines(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any] = [
            "id": completionId,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": full],
                "finish_reason": "stop"
            ]],
            "usage": [
                "prompt_tokens": 0,
                "completion_tokens": full.count / 4,
                "total_tokens": full.count / 4
            ]
        ]
        respondJSON(payload, status: .ok, on: box)
    }

    /// Strip every `TOOL_CALL: { ... }` directive from `text`. Uses a balanced-
    /// brace scan rather than a regex because the model sometimes runs its
    /// post-tool response right up against the closing `}}` with no newline,
    /// which line-anchored regexes can't handle. Skips strings so braces
    /// inside JSON values don't break the count.
    static func stripToolCallLines(_ text: String) -> String {
        let scalars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0
        let needle = Array("TOOL_CALL:")
        while i < scalars.count {
            // Try to match the literal "TOOL_CALL:" at this position.
            if i + needle.count <= scalars.count,
               Array(scalars[i..<i + needle.count]) == needle {
                // Skip whitespace up to the opening `{`.
                var j = i + needle.count
                while j < scalars.count, scalars[j].isWhitespace { j += 1 }
                if j < scalars.count, scalars[j] == "{" {
                    // Balanced-brace scan, respecting JSON string literals.
                    var depth = 0
                    var inString = false
                    var escape = false
                    while j < scalars.count {
                        let c = scalars[j]
                        if inString {
                            if escape { escape = false }
                            else if c == "\\" { escape = true }
                            else if c == "\"" { inString = false }
                        } else {
                            if c == "\"" { inString = true }
                            else if c == "{" { depth += 1 }
                            else if c == "}" {
                                depth -= 1
                                if depth == 0 { j += 1; break }
                            }
                        }
                        j += 1
                    }
                    if depth == 0 {
                        // Successfully matched; skip the directive entirely.
                        i = j
                        continue
                    }
                    // Unbalanced — leave the original text alone past this point.
                }
            }
            out.append(scalars[i])
            i += 1
        }
        return out
    }

    /// Returns the largest prefix length of `raw` that is safe to strip-and-
    /// emit during streaming. Rules:
    ///   - Walk every `TOOL_CALL:` occurrence. For each balanced one, the end
    ///     position (just past `}`) is a known-clean boundary.
    ///   - If we hit an unbalanced one, the safe end is the start of that
    ///     directive (the closing `}` hasn't been streamed yet).
    ///   - Otherwise the safe end is `max(end-of-last-balanced, count - 16)` —
    ///     the 16-char tail is held back so a partial "TOOL_CALL" string
    ///     materializing on the next token can be caught and held.
    static func safeStreamEnd(in raw: String) -> Int {
        let chars = Array(raw)
        let needle = Array("TOOL_CALL:")
        var lastBalancedEnd = 0
        var i = 0
        while i < chars.count {
            if i + needle.count <= chars.count, Array(chars[i..<i + needle.count]) == needle {
                var j = i + needle.count
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "{" {
                    var depth = 0
                    var inString = false
                    var escape = false
                    while j < chars.count {
                        let c = chars[j]
                        if inString {
                            if escape { escape = false }
                            else if c == "\\" { escape = true }
                            else if c == "\"" { inString = false }
                        } else {
                            if c == "\"" { inString = true }
                            else if c == "{" { depth += 1 }
                            else if c == "}" {
                                depth -= 1
                                if depth == 0 { j += 1; break }
                            }
                        }
                        j += 1
                    }
                    if depth == 0 {
                        lastBalancedEnd = j
                        i = j
                        continue
                    }
                    return i  // unbalanced — hold from here
                }
                return i  // "TOOL_CALL:" with no `{` yet — hold
            }
            i += 1
        }
        return max(lastBalancedEnd, chars.count - 16)
    }

    private func sendSSEDelta(_ content: String, completionId: String, model: String, created: Int, on box: NWConnectionBox) {
        let payload: [String: Any] = [
            "id": completionId,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [[
                "index": 0,
                "delta": ["content": content],
                "finish_reason": NSNull()
            ]]
        ]
        sendSSEData(payload, on: box)
    }

    // MARK: - Response writers

    private enum Status: Int {
        case ok = 200, badRequest = 400, unauthorized = 401, notFound = 404, internalServerError = 500
        var phrase: String {
            switch self {
            case .ok: return "OK"
            case .badRequest: return "Bad Request"
            case .unauthorized: return "Unauthorized"
            case .notFound: return "Not Found"
            case .internalServerError: return "Internal Server Error"
            }
        }
    }

    private func corsHeaders() -> [(String, String)] {
        [
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "Authorization, Content-Type")
        ]
    }

    private func respondPlain(_ status: Status, _ body: String, on box: NWConnectionBox, extraHeaders: [(String, String)] = []) {
        let bodyData = body.data(using: .utf8) ?? Data()
        var head = "HTTP/1.1 \(status.rawValue) \(status.phrase)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(bodyData)
        sendRaw(out, on: box)
        finishConnection(box)
    }

    private func respondJSON(_ payload: [String: Any], status: Status, on box: NWConnectionBox) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var head = "HTTP/1.1 \(status.rawValue) \(status.phrase)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in corsHeaders() { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(bodyData)
        sendRaw(out, on: box)
        finishConnection(box)
    }

    private func sendSSEData(_ payload: [String: Any], on box: NWConnectionBox) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = "data: \(json)\n\n"
        sendRaw(Data(line.utf8), on: box)
    }

    private func sendRaw(_ data: Data, on box: NWConnectionBox) {
        box.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finishConnection(_ box: NWConnectionBox) {
        box.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            box.connection.cancel()
            Task { await self?.drop(box) }
        })
    }

    // Constant-time compare so timing differences don't leak the token.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        if ab.count != bb.count { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}

// MARK: - HTTP request helper

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    var contentLength: Int? {
        guard let s = headers["content-length"] else { return nil }
        return Int(s)
    }

    var bearerToken: String? {
        guard let auth = headers["authorization"] else { return nil }
        let prefix = "bearer "
        guard auth.lowercased().hasPrefix(prefix) else { return nil }
        return String(auth.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    static func parse(_ headerString: String) -> HTTPRequest {
        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        var method = "GET"
        var path = "/"
        var headers: [String: String] = [:]
        if let first = lines.first {
            let parts = first.split(separator: " ", maxSplits: 2)
            if parts.count >= 2 {
                method = String(parts[0]).uppercased()
                path = String(parts[1])
            }
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            headers[name] = value
        }
        return HTTPRequest(method: method, path: path, headers: headers)
    }
}

// Wrapper so NWConnection (which isn't Hashable) plays with Set tracking.
private final class NWConnectionBox: Hashable {
    let id = UUID()
    let connection: NWConnection
    init(connection: NWConnection) { self.connection = connection }
    static func == (lhs: NWConnectionBox, rhs: NWConnectionBox) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
