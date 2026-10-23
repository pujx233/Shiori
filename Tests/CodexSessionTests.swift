import Foundation

// Compile with Core.swift, OCR.swift and CodexSession.swift. Uses a local protocol
// stub: no network requests, login state, or subscription quota are involved.
@main
struct CodexSessionTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-rpc-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json, sys, time, os
        from pathlib import Path
        with (Path(__file__).parent / "starts").open("a") as f: f.write(str(os.getpid()) + "\n")
        def emit(value):
            print(json.dumps(value, ensure_ascii=False), flush=True)
        def result(req, value):
            emit({'id': req['id'], 'result': value})
        def delta(thread, value):
            emit({'method':'item/agentMessage/delta', 'params':{'threadId':thread,'itemId':'message','delta':value}})
        thread = None
        for line in sys.stdin:
            req = json.loads(line)
            method = req['method']; p = req.get('params', {})
            if method == 'initialize': result(req, {})
            elif method == 'account/read': result(req, {'account': {'type':'chatgpt'}})
            elif method == 'model/list': result(req, {'data':[{'model':'model-a','displayName':'Model A','inputModalities':['text'],'supportedReasoningEfforts':[{'reasoningEffort':'low'}]}], 'nextCursor':None})
            elif method == 'config/read': result(req, {'config': {'mcp_servers': {'sample': {}}}})
            elif method == 'thread/start':
                assert p['ephemeral'] and p['model'] == 'model-a'
                assert p['config']['mcp_servers']['sample']['enabled'] is False
                assert p['sandbox'] == 'read-only' and p['approvalPolicy'] == 'never'
                thread = 'thread-' + str(req['id'])
                result(req, {'thread': {'id': thread}})
            elif method == 'turn/start':
                prompt = p['input'][0]['text']
                if prompt == 'disconnect': sys.exit(0)
                result(req, {'turn': {'id':'turn'}})
                delta('old-page', '{"status":"ok","message":"","translations":[{"id":"b1","text":"旧页"}]}')
                prefix = '{"status":"ok","message":"","translations":[{"id":"b1","text":"早上好"}'
                delta(thread, prefix)
                if prompt == 'disconnect-active': sys.exit(0)
                if prompt == 'slow': continue
                if prompt == 'fail':
                    emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'status':'failed','error':{'message':'network error'}}}})
                    continue
                suffix = ',{"id":"b2","text":"下雨了"}]}'
                delta(thread, suffix)
                emit({'method':'item/completed','params':{'threadId':thread,'item':{'type':'agentMessage','text':prefix+suffix}}})
                emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'status':'completed'}}})
            elif 'id' in req: result(req, {})
        """#
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let session = CodexSession(executable: stub, directory: root)
        defer { session.shutdown() }
        let options = TranslationOptions(model: "model-a", effort: "low")
        let bounds = DialogueBounds(x: 0, y: 0, width: 100, height: 100)
        let ocr = OCRPage(blocks: [OCRBlock(id: "b1", text: "おはよう", bounds: bounds),
                                   OCRBlock(id: "b2", text: "雨ですね", bounds: bounds)], skippedCount: 0, elapsed: 0)
        func run(_ prompt: String, runner: CommandRunner = CommandRunner()) throws -> TranslationReply {
            try session.translate(prompt: prompt, instructions: "Translate", schema: [:], options: options, runner: runner, onText: { _ in })
        }
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw AppError.message("FAIL: " + message) }
            print("PASS: " + message)
        }
        let catalog = try session.models()
        try check(catalog.first?.slug == "model-a" && catalog.first?.supported_reasoning_levels?.first?.effort == "low", "model catalog uses the live app-server schema")
        var counts: [Int] = [], values: [String] = []
        let reply = try session.translate(prompt: "normal", instructions: "Translate", schema: [:], options: options, runner: CommandRunner()) { text in
            if let page = TranslationStream.preview(text, ocr: ocr) {
                counts.append(page.dialogues.count); values += page.dialogues.map(\.translation)
            }
        }
        try check(counts.first == 1 && counts.contains(2) && !values.contains("旧页"), "streaming ignores late events from another page")
        try check(try reply.resolve(ocr: ocr).dialogues.count == 2, "streamed final result passes full ID validation")
        try check(try run("normal").resolve(ocr: ocr).dialogues.count == 2, "a warm connection accepts a fresh ephemeral page")
        let cancelled = CommandRunner(), began = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { cancelled.cancel() }
        do { _ = try run("slow", runner: cancelled); throw AppError.message("FAIL: cancellation ignored") }
        catch is CancellationError { try check(Date().timeIntervalSince(began) < 2, "page cancellation does not wait for process shutdown") }
        try check(try run("normal").resolve(ocr: ocr).dialogues.count == 2, "the page after cancellation completes")
        let starts = try String(contentsOf: root.appendingPathComponent("starts"), encoding: .utf8).split(separator: "\n")
        try check(starts.count == 1, "cancelling one page retains the warm app-server process")
        for prompt in ["disconnect", "disconnect-active", "fail"] {
            do { _ = try run(prompt); throw AppError.message("FAIL: broken stream accepted") }
            catch let error as AppError { try check(!error.localizedDescription.hasPrefix("FAIL"), "broken stream is surfaced without a retry loop: " + prompt) }
            try check(try run("normal").resolve(ocr: ocr).dialogues.count == 2, "the next page reconnects after " + prompt)
        }
    }
}
