import Foundation
import CoreGraphics

// Exercises the production helper client and cancellation without loading an
// OCR model. Real-image/helper identity comparisons are separate opt-in runs.
@main
struct VisionHelperTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("shiori-helper-tests-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        let helper = root.appendingPathComponent("ShioriVision")
        let script = #"""
        #!/usr/bin/python3
        import json, os, signal, sys, time
        from pathlib import Path
        root = Path(__file__).resolve().parent
        with (root/'calls').open('a') as file: file.write(json.dumps(sys.argv[1:])+'\n')
        (root/'pid').write_text(str(os.getpid()))
        mode = (root/'mode').read_text()
        if sys.argv[1:] == ['--prepare']:
            print('[]'); sys.exit(0)
        assert sys.argv[1] == '--image'
        image = Path(sys.argv[2])
        assert image.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        (root/'last-input').write_text(str(image))
        if mode == 'slow':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True: time.sleep(.05)
        if mode == 'fail': sys.exit(7)
        if mode == 'invalid': print('not-json'); sys.exit(0)
        print(json.dumps([{'text':'今日は晴れです。','confidence':.99,'box':[1,2,3,4]}]))
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        guard let image = LocalOCR.visionPreparationImage() else { throw AppError.message("Cannot create fixture") }
        func mode(_ value: String) throws { try value.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw AppError.message("FAIL: " + message) }
            print("PASS: " + message)
        }
        func inputIsRemoved() throws -> Bool {
            let path = try String(contentsOf: root.appendingPathComponent("last-input"), encoding: .utf8)
            return !files.fileExists(atPath: path) && !files.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        }

        try mode("normal")
        let hints = LocalOCR.textHints(in: image, runner: CommandRunner(), helperURL: helper)
        try check(hints.count == 1 && hints[0]["text"] as? String == "今日は晴れです。", "helper returns structured local OCR hints")
        try check(try inputIsRemoved(), "successful helper request removes its private image directory")
        LocalOCR.prepareVision(runner: CommandRunner(), helperURL: helper)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        try check(calls.contains("--prepare"), "preparation invokes the same helper without a screen image")
        let resources = URL(fileURLWithPath: "/Applications/Shiori.app/Contents/Resources")
        try check(LocalOCR.visionHelperURL(resources: resources).path == "/Applications/Shiori.app/Contents/Helpers/ShioriVision",
                  "packaged resource path selects the stable bundled helper")

        let callerImage = root.appendingPathComponent("caller-page.png")
        let callerPNG = try CapturedPage(image: image).encoded(.png)
        try callerPNG.write(to: callerImage)
        let borrowed = LocalOCR.textHints(in: image, runner: CommandRunner(), helperURL: helper, imageFile: callerImage)
        let borrowedPath = try String(contentsOf: root.appendingPathComponent("last-input"), encoding: .utf8)
        try check(borrowed.count == 1 && borrowedPath == callerImage.path && (try Data(contentsOf: callerImage)) == callerPNG,
                  "existing PNG goes directly to the helper and remains owned by its caller")

        for failure in ["fail", "invalid"] {
            try mode(failure)
            let began = Date()
            let value = LocalOCR.textHints(in: image, runner: CommandRunner(), helperURL: helper)
            try check(value.isEmpty && Date().timeIntervalSince(began) < 1.5,
                      "helper " + failure + " does not restart OCR in process")
            try check(try inputIsRemoved(), "helper " + failure + " removes the temporary image")
            let borrowedFailure = LocalOCR.textHints(in: image, runner: CommandRunner(), helperURL: helper, imageFile: callerImage)
            try check(borrowedFailure.isEmpty && (try Data(contentsOf: callerImage)) == callerPNG,
                      "helper " + failure + " preserves the borrowed PNG")
        }
        try mode("slow")
        let runner = CommandRunner(), began = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runner.cancel() }
        let cancelled = LocalOCR.textHints(in: image, runner: runner, helperURL: helper)
        try check(cancelled.isEmpty && Date().timeIntervalSince(began) < 3.5,
                  "unresponsive cancelled helper is killed without an in-process fallback")
        try check(try inputIsRemoved(), "cancelled helper cannot leave a screenshot directory")
        let pid = Int32(try String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8))!
        try check(kill(pid, 0) != 0, "cancelled helper process has exited")
        try mode("normal")
        try check(LocalOCR.textHints(in: image, runner: CommandRunner(), helperURL: helper).count == 1,
                  "next page can immediately start a fresh helper after cancellation")

        try mode("slow")
        let timeoutRunner = CommandRunner(), timeoutBegan = Date()
        let timedOut = LocalOCR.textHints(in: image, runner: timeoutRunner, helperURL: helper, helperTimeout: 0.15)
        try check(timedOut.isEmpty && !timeoutRunner.isCancelled && Date().timeIntervalSince(timeoutBegan) < 3.5,
                  "helper timeout leaves the page runner alive to publish empty hints")
        try check(try inputIsRemoved(), "timed-out helper removes its temporary screenshot")
        try mode("normal")
        try check(LocalOCR.textHints(in: image, runner: timeoutRunner, helperURL: helper).count == 1,
                  "page runner remains reusable after a helper timeout")

        try mode("slow")
        let borrowedRunner = CommandRunner()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { borrowedRunner.cancel() }
        try check(LocalOCR.textHints(in: image, runner: borrowedRunner, helperURL: helper, imageFile: callerImage).isEmpty
                  && (try Data(contentsOf: callerImage)) == callerPNG,
                  "cancelling a helper request preserves the caller's image")
        let borrowedTimeoutRunner = CommandRunner()
        try check(LocalOCR.textHints(in: image, runner: borrowedTimeoutRunner, helperURL: helper,
                                     imageFile: callerImage, helperTimeout: 0.15).isEmpty
                  && !borrowedTimeoutRunner.isCancelled && (try Data(contentsOf: callerImage)) == callerPNG,
                  "helper timeout preserves the borrowed image and leaves its page runner reusable")
        try files.removeItem(at: callerImage)
        try mode("normal")
        let missingBegan = Date()
        try check(LocalOCR.textHints(in: image, runner: CommandRunner(), helperURL: helper, imageFile: callerImage).isEmpty
                  && !files.fileExists(atPath: callerImage.path) && Date().timeIntervalSince(missingBegan) < 1.5,
                  "removed job image cannot be recreated or replaced with a stale image fallback")

        // Exercise the actual mailbox-to-worker handoff, not just the helper
        // function's return value: a helper timeout must still finish the page.
        let engine = root.appendingPathComponent("OCR")
        for folder in ["venv/bin", "models/manga"] {
            try files.createDirectory(at: engine.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try files.createSymbolicLink(atPath: engine.appendingPathComponent("venv/bin/python").path,
                                     withDestinationPath: "/Library/Developer/CommandLineTools/usr/bin/python3")
        try Data().write(to: engine.appendingPathComponent("models/manga/pytorch_model.bin"))
        try Data().write(to: engine.appendingPathComponent("models/comictextdetector.pt"))
        let worker = #"""
        import json, sys, time
        from pathlib import Path
        for line in sys.stdin:
            directory = Path(json.loads(line)['directory'])
            deadline = time.monotonic()+5
            while not (directory/'hints.json').exists() and time.monotonic()<deadline:
                if (directory/'cancel').exists(): break
                time.sleep(.01)
            hints = json.loads((directory/'hints.json').read_text())
            assert hints == [] or hints[0]['text'] == '今日は晴れです。'
            assert (directory/'page.png').exists()
            state = {'phase':'done','page':{'blocks':[],'skippedCount':0,'elapsed':.1}}
            (directory/'state.tmp').write_text(json.dumps(state))
            (directory/'state.tmp').replace(directory/'state.json')
        """#
        try worker.write(to: root.appendingPathComponent("ocr_worker.py"), atomically: true, encoding: .utf8)
        try mode("slow")
        let ocr = try LocalOCR(support: root, resources: root, visionHints: { image, runner in
            LocalOCR.textHints(in: image, runner: runner, helperURL: helper, helperTimeout: 0.15)
        })
        let pageRunner = CommandRunner(), pageBegan = Date()
        let completed = try ocr.recognize(page: CapturedPage(image: image), runner: pageRunner, force: true, progress: { _ in })
        ocr.shutdown()
        try check(completed.blocks.isEmpty && !pageRunner.isCancelled && Date().timeIntervalSince(pageBegan) < 4,
                  "helper timeout publishes empty hints through the mailbox and the OCR page completes")

        // Use the packaged default, without either injectable Vision closure.
        // The worker verifies its PNG still exists after receiving the hints.
        let packagedResources = root.appendingPathComponent("Contents/Resources")
        let packagedHelper = LocalOCR.visionHelperURL(resources: packagedResources)
        try files.createDirectory(at: packagedResources, withIntermediateDirectories: true)
        try files.createDirectory(at: packagedHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: packagedHelper, withDestinationURL: helper)
        try worker.write(to: packagedResources.appendingPathComponent("ocr_worker.py"), atomically: true, encoding: .utf8)
        try mode("normal")
        let packagedOCR = try LocalOCR(support: root, resources: packagedResources, engineRoot: engine)
        _ = try packagedOCR.recognize(page: CapturedPage(image: image), runner: CommandRunner(), force: true, progress: { _ in })
        let jobImage = try String(contentsOf: root.appendingPathComponent("last-input"), encoding: .utf8)
        packagedOCR.shutdown()
        try check(jobImage.contains("/shiori-ocr-") && jobImage.hasSuffix("/page.png") && !files.fileExists(atPath: jobImage),
                  "production mailbox borrows the worker job PNG and job cleanup removes it after completion")

        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helper.path)
        let invalidBegan = Date()
        try check(LocalOCR.textHints(in: image, runner: CommandRunner(), helperURL: helper).isEmpty
                  && Date().timeIntervalSince(invalidBegan) < 0.1,
                  "present non-executable helper does not trigger the test fallback")
        let alreadyCancelled = CommandRunner(); alreadyCancelled.cancel()
        try check(LocalOCR.textHints(in: image, runner: alreadyCancelled,
                                    helperURL: root.appendingPathComponent("missing")).isEmpty,
                  "already-cancelled request does not enter missing-helper fallback")
    }
}
