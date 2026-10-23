import AppKit
import Foundation

// Compile with Core.swift, CodexSession.swift, GoogleTranslation.swift and OCR.swift.
// Exercises the real per-job file protocol without loading OCR models or capturing a screen.
@main
struct LocalOCRTests {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--hints" {
            guard let image = NSImage(contentsOfFile: CommandLine.arguments[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw AppError.message("Cannot read image")
            }
            let data = try JSONSerialization.data(withJSONObject: LocalOCR.textHints(in: image))
            FileHandle.standardOutput.write(data)
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-ocr-protocol-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["OCR/venv/bin", "OCR/models/manga"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let python = ProcessInfo.processInfo.environment["SHIORI_TEST_PYTHON"] ?? "/Library/Developer/CommandLineTools/usr/bin/python3"
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("OCR/venv/bin/python").path, withDestinationPath: python)
        for name in ["OCR/models/manga/pytorch_model.bin", "OCR/models/comictextdetector.pt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let script = #"""
        import json, sys, time, base64, os
        from pathlib import Path
        root = Path(sys.argv[1]).parent
        if (root/'mode').read_text() == 'broken-pipe':
            os.close(0)
            time.sleep(1)
            sys.exit(0)
        def write(path, value):
            temporary = path.with_suffix('.tmp')
            temporary.write_text(json.dumps(value))
            temporary.replace(path)
        for line in sys.stdin:
            directory = Path(json.loads(line)['directory'])
            with (root/'jobs').open('a') as log: log.write('job\n')
            mode = (root/'mode').read_text()
            while not (directory/'hints.json').exists(): time.sleep(.01)
            block = {'id':'b1','text':'おはよう','bounds':{'x':10,'y':20,'width':100,'height':200},'replacementAllowed':False}
            draft = {'blocks':[block], 'skippedCount':0, 'elapsed':.1}
            if mode != 'legacy':
                write(directory/'text.json', draft)
                write(directory/'state.json', {'phase':'repairing'})
            if mode == 'cancel':
                while directory.exists() and not (directory/'cancel').exists(): time.sleep(.01)
                if directory.exists(): write(directory/'state.json', {'phase':'cancelled'})
                continue
            if mode == 'normal': time.sleep(.5)
            block['replacementAllowed'] = True
            block['replacementPNG'] = base64.b64encode(b'patch').decode()
            write(directory/'state.json', {'phase':'done','page':{'blocks':[block],'skippedCount':0,'elapsed':.6}})
        """#
        try script.write(to: root.appendingPathComponent("ocr_worker.py"), atomically: true, encoding: .utf8)
        let image = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let page = try CapturedPage(image: image)
        let ocr = try LocalOCR(support: root, resources: root)
        defer { ocr.shutdown() }
        func mode(_ value: String) throws {
            try value.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        }
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw AppError.message("FAIL: " + message) }
            print("PASS: " + message)
        }
        try mode("normal")
        var callbacks: [OCRPage] = [], readyAt: Date?
        let result = try ocr.recognize(page: page, runner: CommandRunner(), progress: { _ in }, onTextReady: {
            callbacks.append($0); readyAt = Date()
        })
        try check(callbacks.count == 1 && callbacks[0].blocks[0].replacementAllowed == false,
                  "text-ready callback fires once and draft cannot erase source pixels")
        try check(Date().timeIntervalSince(readyAt!) > 0.15 && result.blocks[0].replacementPNG == Data("patch".utf8),
                  "text arrives before delayed repairs and final carries repaired pixels")
        var cachedCalls = 0
        _ = try ocr.recognize(page: page, runner: CommandRunner(), progress: { _ in }, onTextReady: { value in
            cachedCalls += 1
            assert(value.blocks[0].replacementPNG != nil)
        })
        let jobs = try String(contentsOf: root.appendingPathComponent("jobs"), encoding: .utf8)
        try check(cachedCalls == 1 && jobs.split(separator: "\n").count == 1, "cache hit emits one complete page without worker job")
        for value in ["fast", "legacy"] {
            try mode(value); callbacks = []
            _ = try ocr.recognize(page: page, runner: CommandRunner(), force: true, progress: { _ in }, onTextReady: { callbacks.append($0) })
            try check(callbacks.count == 1, "fast completion and done-only workers cannot lose or duplicate callback: " + value)
        }
        try mode("cancel")
        let runner = CommandRunner(), began = Date()
        var cancelledCalls = 0
        do {
            _ = try ocr.recognize(page: page, runner: runner, force: true, progress: { _ in }, onTextReady: { _ in
                cancelledCalls += 1; runner.cancel()
            })
            throw AppError.message("FAIL: cancellation ignored")
        } catch is CancellationError {
            try check(cancelledCalls == 1 && Date().timeIntervalSince(began) < 1.5,
                      "cancellation after text-ready does not wait for repair completion")
        }
        try mode("normal")
        _ = try ocr.recognize(page: page, runner: CommandRunner(), force: true, progress: { _ in })
        try check(true, "warm worker accepts the page after cancellation")
        try mode("cancel")
        let beforeVision = CommandRunner()
        let newImage = NSImage(size: NSSize(width: 81, height: 80), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let newPage = try CapturedPage(image: newImage)
        let beforeVisionStart = Date()
        var earlyCallbacks = 0
        do {
            _ = try ocr.recognize(page: newPage, runner: beforeVision, force: true, progress: { text in
                if text == "检查文字…" { beforeVision.cancel() }
            }, onTextReady: { _ in earlyCallbacks += 1 })
            throw AppError.message("FAIL: pre-Vision cancellation ignored")
        } catch is CancellationError {
            let cacheFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Recognition"), includingPropertiesForKeys: nil)
            try check(earlyCallbacks == 0 && !cacheFiles.contains { $0.lastPathComponent.hasPrefix(newPage.digest) }
                      && Date().timeIntervalSince(beforeVisionStart) < 1.5,
                      "cancellation before Vision still acknowledges the worker and never emits or caches the cancelled page")
        }
        try mode("normal")
        _ = try ocr.recognize(page: newPage, runner: CommandRunner(), force: true, progress: { _ in })
        try check(true, "worker and serial OCR queue remain usable after cancellation before Vision")
        let alreadyCancelled = CommandRunner(); alreadyCancelled.cancel()
        var badCallbacks = 0
        do {
            _ = try ocr.recognize(page: page, runner: alreadyCancelled, progress: { _ in }, onTextReady: { _ in badCallbacks += 1 })
            throw AppError.message("FAIL: cancelled cache request returned")
        } catch is CancellationError {
            try check(badCallbacks == 0, "cancelled cache lookup never emits text")
        }

        try mode("fast")
        let preparationQueue = DispatchQueue(label: "test.ocr.preparation")
        let preparationEntered = DispatchSemaphore(value: 0), preparationCancelled = DispatchSemaphore(value: 0)
        let preparationRelease = DispatchSemaphore(value: 0), preparationFinished = DispatchSemaphore(value: 0)
        let preparation = OCRVisionPreparation(queue: preparationQueue) { runner in
            let token = runner.addCancellationHandler { preparationCancelled.signal() }
            defer { runner.removeCancellationHandler(token); preparationFinished.signal() }
            preparationEntered.signal()
            _ = preparationRelease.wait(timeout: .now() + 4)
        }
        let preparedOCR = try LocalOCR(support: root, resources: root, visionPreparation: preparation)
        defer { preparedOCR.shutdown() }
        try preparedOCR.prepare(); try preparedOCR.prepare()
        try check(preparationEntered.wait(timeout: .now() + 2) == .success, "prepare launches one asynchronous Vision initialization attempt")
        let hitStart = ProcessInfo.processInfo.systemUptime
        _ = try preparedOCR.recognize(page: page, runner: CommandRunner(), progress: { _ in })
        try check(ProcessInfo.processInfo.systemUptime - hitStart < 0.2 && preparationCancelled.wait(timeout: .now()) == .timedOut,
                  "cached page returns immediately while preparation continues")
        var cancelledBeforeRecognition = false
        _ = try preparedOCR.recognize(page: page, runner: CommandRunner(), force: true, progress: { text in
            if text == "检查文字…" { cancelledBeforeRecognition = preparationCancelled.wait(timeout: .now()) == .success }
        })
        try check(cancelledBeforeRecognition && preparationFinished.wait(timeout: .now()) == .timedOut,
                  "uncached page cancels preparation before Vision without waiting for its completion")
        preparationRelease.signal(); preparationQueue.sync {}
        try preparedOCR.prepare(); preparationQueue.sync {}
        try check(preparationEntered.wait(timeout: .now()) == .timedOut, "prepare after real recognition cannot schedule a replacement warmup")
        preparedOCR.shutdown()

        let shutdownQueue = DispatchQueue(label: "test.ocr.preparation.shutdown")
        let shutdownEntered = DispatchSemaphore(value: 0), shutdownCancelled = DispatchSemaphore(value: 0)
        let shutdownRelease = DispatchSemaphore(value: 0), shutdownFinished = DispatchSemaphore(value: 0)
        let shutdownPreparation = OCRVisionPreparation(queue: shutdownQueue) { runner in
            let token = runner.addCancellationHandler { shutdownCancelled.signal() }
            defer { runner.removeCancellationHandler(token); shutdownFinished.signal() }
            shutdownEntered.signal()
            _ = shutdownRelease.wait(timeout: .now() + 4)
        }
        let shutdownOCR = try LocalOCR(support: root, resources: root, visionPreparation: shutdownPreparation)
        try shutdownOCR.prepare()
        try check(shutdownEntered.wait(timeout: .now() + 2) == .success, "shutdown test begins with preparation still running")
        shutdownOCR.shutdown()
        try check(shutdownCancelled.wait(timeout: .now()) == .success && shutdownFinished.wait(timeout: .now()) == .timedOut,
                  "shutdown cancels preparation and cleans the worker without joining the warmup")
        shutdownRelease.signal(); shutdownQueue.sync {}

        ocr.shutdown()
        try mode("broken-pipe")
        try ocr.prepare()
        Thread.sleep(forTimeInterval: 0.25)
        do {
            _ = try ocr.recognize(page: page, runner: CommandRunner(), force: true, progress: { _ in })
            throw AppError.message("FAIL: broken input accepted")
        } catch {
            try check(!error.localizedDescription.hasPrefix("FAIL:"), "closed worker input returns an error instead of killing the application")
        }
        try mode("normal")
        _ = try ocr.recognize(page: page, runner: CommandRunner(), force: true, progress: { _ in })
        try check(true, "a broken input connection is cleaned up and the next page restarts its worker")
    }
}
