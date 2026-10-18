import Foundation
import Darwin

// One official app-server process, with a fresh ephemeral conversation per page.
// Only text/IDs cross this boundary; page geometry and erasure images stay local.
final class CodexSession: @unchecked Sendable {
    private let serial = NSLock()
    private let executable: URL
    private let directory: URL
    private var connection: CodexRPC?
    private var threadConfig: [String: Any] = [:]

    init(executable: URL, directory: URL) { self.executable = executable; self.directory = directory }
    deinit { shutdown() }

    func shutdown() {
        serial.lock(); defer { serial.unlock() }
        connection?.close(); connection = nil
    }

    func prepare() throws {
        serial.lock(); defer { serial.unlock() }
        _ = try connect(runner: CommandRunner())
    }

    private func connect(runner: CommandRunner) throws -> CodexRPC {
        if let connection, connection.isRunning { return connection }
        connection?.close(); connection = nil
        let rpc = try CodexRPC(executable: executable, directory: directory)
        do {
            _ = try rpc.request("initialize", params: [
                "clientInfo": ["name": "shiori", "title": "Shiori", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"],
                "capabilities": ["experimentalApi": true]
            ], runner: runner)
            try rpc.notify("initialized", params: [:])
            let account = try rpc.request("account/read", params: ["refreshToken": false], runner: runner)
            guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
                throw AppError.configuration("请先在 Codex 中登录 ChatGPT 账号，再重试。")
            }
            let config = try rpc.request("config/read", params: ["includeLayers": false], runner: runner)["config"] as? [String: Any] ?? [:]
            // Empty tables merge with user config. Explicitly disable each configured
            // MCP server for this translator's thread; never edit the user's settings.
            let servers = config["mcp_servers"] as? [String: Any] ?? [:]
            threadConfig = ["mcp_servers": Dictionary(uniqueKeysWithValues: servers.keys.map { ($0, ["enabled": false]) }),
                            "project_doc_max_bytes": 0, "web_search": "disabled", "notify": []]
            connection = rpc
            return rpc
        } catch { rpc.close(); throw error }
    }

    func models() throws -> [ModelInfo] {
        serial.lock(); defer { serial.unlock() }
        let runner = CommandRunner(), rpc = try connect(runner: CommandRunner())
        var catalog: [ModelInfo] = [], cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let reply = try rpc.request("model/list", params: params, runner: runner)
            for item in reply["data"] as? [[String: Any]] ?? [] {
                guard let slug = item["model"] as? String, item["hidden"] as? Bool != true else { continue }
                let modalities = item["inputModalities"] as? [String]
                guard modalities?.contains("text") ?? true else { continue }
                let efforts = (item["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap {
                    ($0["reasoningEffort"] as? String).map { ModelInfo.Effort(effort: $0) }
                }
                catalog.append(ModelInfo(slug: slug, display_name: item["displayName"] as? String ?? slug,
                                         visibility: "list", input_modalities: modalities, supported_reasoning_levels: efforts))
            }
            let next = reply["nextCursor"] as? String
            guard next != cursor else { break }
            cursor = next
        } while cursor != nil
        return catalog
    }

    func translate(prompt: String, instructions: String, schema: Any, options: TranslationOptions,
                   runner: CommandRunner, onText: @escaping (String) throws -> Void) throws -> TranslationReply {
        serial.lock(); defer { serial.unlock() }
        try runner.checkCancellation()
        let rpc = try connect(runner: runner)
        var threadID: String?, turnID: String?
        var turnFinished = false
        do {
            let started = try rpc.request("thread/start", params: [
                "model": options.model, "modelProvider": "openai", "cwd": directory.path,
                "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true,
                "baseInstructions": instructions, "developerInstructions": "", "config": threadConfig,
                "environments": [], "allowProviderModelFallback": false
            ], runner: runner)
            guard let id = (started["thread"] as? [String: Any])?["id"] as? String else {
                throw AppError.message("Codex 未能开始翻译。")
            }
            threadID = id
            let deadline = Date().addingTimeInterval(180)
            var messageID: String?, text = "", finalText: String?, completed = false
            let receive: ([String: Any]) throws -> Void = { event in
                guard let params = event["params"] as? [String: Any], params["threadId"] as? String == id else { return }
                switch event["method"] as? String {
                case "item/agentMessage/delta":
                    guard let itemID = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
                    if messageID != itemID { messageID = itemID; text = "" }
                    guard text.utf8.count + delta.utf8.count <= 1024 * 1024 else { throw AppError.message("译文超出单页长度限制。") }
                    text += delta
                    try onText(text)
                case "item/completed":
                    if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                       let value = item["text"] as? String {
                        finalText = value
                        try onText(value)
                    }
                case "turn/completed":
                    guard let turn = params["turn"] as? [String: Any] else { return }
                    turnFinished = true
                    if turn["status"] as? String == "interrupted" { throw CancellationError() }
                    guard turn["status"] as? String == "completed" else {
                        let error = turn["error"] as? [String: Any]
                        throw AppError.translationFailure(error?["message"] as? String ?? "Codex 未完成此页。")
                    }
                    completed = true
                default: break
                }
            }
            let turn = try rpc.request("turn/start", params: [
                "threadId": id, "input": [["type": "text", "text": prompt]],
                "model": options.model, "effort": options.effort, "outputSchema": schema
            ], runner: runner, deadline: deadline, onEvent: receive)
            turnID = (turn["turn"] as? [String: Any])?["id"] as? String
            while !completed { try receive(rpc.next(runner: runner, deadline: deadline)) }
            try runner.checkCancellation()
            guard let data = (finalText ?? (text.isEmpty ? nil : text))?.data(using: .utf8),
                  let result = try? JSONDecoder().decode(TranslationReply.self, from: data) else {
                throw AppError.message("模型没有返回完整译文，请重试。")
            }
            // Unsubscribing releases this ephemeral page without accumulating a reading history.
            _ = try rpc.send("thread/unsubscribe", params: ["threadId": id])
            return result
        } catch {
            if let threadID, rpc.isRunning, turnFinished || (error is CancellationError && turnID != nil) {
                do {
                    if !turnFinished, let turnID {
                        _ = try rpc.send("turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
                    }
                    _ = try rpc.send("thread/unsubscribe", params: ["threadId": threadID])
                    // Late events are filtered by thread ID; a page turn keeps the warm connection.
                } catch { rpc.close(); connection = nil }
            } else { rpc.close(); connection = nil }
            throw error
        }
    }
}

// A bounded stdio JSON-RPC transport. It never connects to the desktop app's
// shared daemon and never reads or copies login credentials itself.
private final class CodexRPC: @unchecked Sendable {
    private let condition = NSCondition()
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var pending = Data()
    private var events: [[String: Any]] = []
    private var ended = false
    private var overflow = false
    private var sequence = 0

    var isRunning: Bool { process.isRunning }

    init(executable: URL, directory: URL) throws {
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.environment = CommandRunner.environment()
        var arguments = ["--no-daemon", "app-server", "--stdio", "-c", "model_provider=\"openai\"",
                         "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
                         "-c", "developer_instructions=\"\"", "-c", "notify=[]"]
        for feature in ["apps", "shell_tool", "multi_agent", "hooks", "remote_plugin", "plugins",
                        "memories", "goals", "skill_search", "sleep_tool"] { arguments += ["--disable", feature] }
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw AppError.message("无法建立 Codex 数据通道，请重新打开助手。")
        }
        let readFD = output.fileHandleForReading.fileDescriptor
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        output.fileHandleForReading.readabilityHandler = { [weak self] _ in
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard !self.ended else { return }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(readFD, &bytes, bytes.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            if count <= 0 { self.ended = true; self.condition.broadcast(); return }
            self.pending.append(contentsOf: bytes.prefix(count))
            while let newline = self.pending.firstIndex(of: 10) {
                let line = self.pending.prefix(upTo: newline)
                if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    let method = event["method"] as? String
                    if event["id"] != nil || ["item/agentMessage/delta", "item/completed", "turn/completed"].contains(method) {
                        self.events.append(event)
                    }
                }
                self.pending.removeSubrange(...newline)
            }
            if self.pending.count > 2 * 1024 * 1024 || self.events.count > 2048 { self.overflow = true; self.pending.removeAll(); self.events.removeAll() }
            self.condition.broadcast()
        }
        do { try process.run() } catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // Do not make a new page wait for the CLI's shutdown grace period.
            let child = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        condition.lock(); ended = true; events.removeAll(); pending.removeAll()
        try? output.fileHandleForReading.close()
        condition.broadcast(); condition.unlock()
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func notify(_ method: String, params: [String: Any]) throws { try write(["method": method, "params": params]) }
    func send(_ method: String, params: [String: Any]) throws -> Int {
        sequence += 1
        try write(["id": sequence, "method": method, "params": params])
        return sequence
    }
    func next(runner: CommandRunner, deadline: Date) throws -> [String: Any] {
        while true {
            try runner.checkCancellation()
            guard Date() < deadline else { throw AppError.message("这页翻译超时，已停止。翻页后会继续。") }
            condition.lock()
            if overflow { condition.unlock(); throw AppError.message("Codex 返回的数据过多，已停止此页。") }
            if !events.isEmpty {
                let event = events.removeFirst(); condition.unlock()
                if event["method"] != nil, let id = event["id"] {
                    // Translation needs no tools, approvals, or interactive prompts.
                    try write(["id": id, "error": ["code": -32601, "message": "This translation client does not support tool requests."]])
                    throw AppError.message("Codex 请求了翻译之外的操作，已停止此页。")
                }
                return event
            }
            if ended || !process.isRunning { condition.unlock(); throw AppError.message("Codex 连接已中断，请重试此页。") }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
            condition.unlock()
        }
    }
    func request(_ method: String, params: [String: Any], runner: CommandRunner,
                 deadline: Date = Date().addingTimeInterval(20),
                 onEvent: ([String: Any]) throws -> Void = { _ in }) throws -> [String: Any] {
        let id = try send(method, params: params)
        while true {
            let event = try next(runner: runner, deadline: deadline)
            if event["id"] as? Int == id {
                if let error = event["error"] as? [String: Any] {
                    throw AppError.translationFailure(error["message"] as? String ?? "Codex 请求失败。")
                }
                return event["result"] as? [String: Any] ?? [:]
            }
            try onEvent(event)
        }
    }
}

// Only complete JSON item boundaries may be previewed. Quotes, escaped braces,
// and split Unicode characters cannot turn an incomplete sentence into an item.
enum TranslationStream {
    static func preview(_ text: String, ocr: OCRPage) -> PageTranslation? {
        let bytes = Array(text.utf8)
        guard bytes.count <= 1024 * 1024 else { return nil }
        var closings: [UInt8] = [], quoted = false, escaped = false
        var checkpoint: (Int, [UInt8])?
        for (index, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true; continue }
            if byte == 123 { closings.append(125) }
            else if byte == 91 { closings.append(93) }
            else if byte == 125 || byte == 93 {
                guard closings.popLast() == byte else { return nil }
                if byte == 125 && (closings == [125, 93] || closings.isEmpty) { checkpoint = (index + 1, Array(closings.reversed())) }
            }
        }
        guard let (end, suffix) = checkpoint,
              let reply = try? JSONDecoder().decode(TranslationReply.self, from: Data(bytes[..<end] + suffix)) else { return nil }
        return try? reply.resolve(ocr: ocr, allowIncomplete: true)
    }
}
