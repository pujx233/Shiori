import AppKit
import Foundation
import Vision

// No OCR models or network access. The controlled Vision request blocks until
// its actual cancel override is called, exposing cancellation wiring races.
@main
struct CancellationTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    final class Capture {}
    final class Request: VNRecognizeTextRequest, @unchecked Sendable {
        let cancellations = Counter()
        let stopped = DispatchSemaphore(value: 0)
        override func cancel() {
            cancellations.increment()
            super.cancel()
            stopped.signal()
        }
    }
    static func main() throws {
        if CommandLine.arguments.contains("--preparation-smoke") {
            let queue = DispatchQueue(label: "test.vision.preparation.smoke", qos: .utility)
            let finished = DispatchSemaphore(value: 0), recognized = Counter()
            queue.async {
                defer { finished.signal() }
                guard !Thread.isMainThread, let image = LocalOCR.visionPreparationImage() else { return }
                let started = ProcessInfo.processInfo.systemUptime
                let hints = LocalOCR.textHints(in: image)
                guard hints.contains(where: { ($0["text"] as? String)?.contains("今日は晴れ") == true }) else { return }
                recognized.increment()
                print("Vision preparation fixture smoke: Japanese recognized, seconds=\(ProcessInfo.processInfo.systemUptime - started)")
            }
            guard finished.wait(timeout: .now() + 30) == .success, recognized.value == 1 else {
                throw AppError.message("Vision did not recognize the internal Japanese fixture on its background queue")
            }
            return
        }
        if CommandLine.arguments.contains("--vision-smoke") {
            let image = NSImage(size: NSSize(width: 320, height: 96), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                ("こんにちは。今日は晴れ。" as NSString).draw(at: NSPoint(x: 6, y: 30), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
                return true
            }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let runner = CommandRunner(), request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["ja-JP", "en-US"]
            let entered = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                if entered.wait(timeout: .now() + 2) == .success {
                    Thread.sleep(forTimeInterval: 0.05); runner.cancel()
                }
                finished.signal()
            }
            let began = Date()
            var errorCode: Int?
            let accepted = LocalOCR.performVision(request, runner: runner) {
                entered.signal()
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { errorCode = (error as NSError).code; throw error }
            }
            _ = finished.wait(timeout: .now() + 2)
            print("Vision cancellation smoke: accepted=\(accepted), elapsed=\(Date().timeIntervalSince(began)), errorCode=\(errorCode.map(String.init) ?? "none"), observations=\(request.results?.count ?? 0)")
            guard !accepted else { throw AppError.message("Vision completed before cancellation; test inconclusive") }
            return
        }
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw AppError.message("FAIL: " + label) }
            checks += 1; print("PASS: " + label)
        }
        let runner = CommandRunner(), calls = Counter()
        runner.addCancellationHandler {
            // These reentrant calls would deadlock if callbacks held its lock.
            if runner.isCancelled { calls.increment() }
            let late = runner.addCancellationHandler { calls.increment() }
            runner.removeCancellationHandler(late)
        }
        runner.cancel(); runner.cancel()
        try check(calls.value == 2, "callbacks run outside the lock; late registration runs immediately and cancellation is once-only")

        let removedRunner = CommandRunner(), removedCalls = Counter()
        let removed = removedRunner.addCancellationHandler { removedCalls.increment() }
        removedRunner.removeCancellationHandler(removed); removedRunner.cancel()
        try check(removedCalls.value == 0, "removed handler is not invoked")

        let owner = CommandRunner()
        var capture: Capture? = Capture()
        weak var weakCapture = capture
        let registration = owner.addCancellationHandler { [held = capture!] in withExtendedLifetime(held) {} }
        capture = nil
        try check(weakCapture != nil, "active handler owns its captured request")
        owner.removeCancellationHandler(registration)
        try check(weakCapture == nil, "completed registration releases its capture")
        capture = Capture(); weakCapture = capture
        owner.addCancellationHandler { [held = capture!] in withExtendedLifetime(held) {} }
        capture = nil; owner.cancel()
        try check(weakCapture == nil, "cancellation clears handler captures")

        let concurrent = CommandRunner(), concurrentCalls = Counter()
        concurrent.addCancellationHandler { concurrentCalls.increment() }
        DispatchQueue.concurrentPerform(iterations: 50) { _ in concurrent.cancel() }
        try check(concurrentCalls.value == 1, "racing cancellation invokes a handler once")
        let racedCalls = Counter()
        for _ in 0..<100 {
            let raced = CommandRunner()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { raced.addCancellationHandler { racedCalls.increment() } }
                else { raced.cancel() }
            }
        }
        try check(racedCalls.value == 100, "registration racing cancellation is neither lost nor duplicated")

        let visionRunner = CommandRunner(), request = Request()
        let entered = DispatchSemaphore(value: 0), cancelFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if entered.wait(timeout: .now() + 2) == .success { visionRunner.cancel() }
            cancelFinished.signal()
        }
        let began = Date()
        let accepted = LocalOCR.performVision(request, runner: visionRunner) {
            entered.signal()
            if request.stopped.wait(timeout: .now() + 2) != .success { throw AppError.message("request was not cancelled") }
        }
        _ = cancelFinished.wait(timeout: .now() + 2)
        try check(!accepted && request.cancellations.value == 1 && Date().timeIntervalSince(began) < 0.5,
                  "a blocked Vision operation receives cancel directly and its result is discarded")

        let completedRunner = CommandRunner(), completed = Request(), refinement = Request()
        try check(LocalOCR.performVision(completed, runner: completedRunner, perform: {}), "successful Vision operation is accepted")
        let refined = LocalOCR.performVision(refinement, runner: completedRunner) { completedRunner.cancel() }
        try check(!refined && refinement.cancellations.value == 1 && completed.cancellations.value == 0,
                  "refinement cancellation targets only the active request, never the completed full-page request")
        let nextRunner = CommandRunner(), next = Request()
        try check(LocalOCR.performVision(next, runner: nextRunner, perform: {}) && next.cancellations.value == 0,
                  "old page cancellation cannot affect the next page")

        let cancelled = CommandRunner(), neverStarted = Request()
        cancelled.cancel(); var performed = false
        let skipped = LocalOCR.performVision(neverStarted, runner: cancelled) { performed = true }
        try check(!skipped && !performed && neverStarted.cancellations.value == 1,
                  "already-cancelled registration cancels the exact request and skips perform")
        let failedRunner = CommandRunner(), failed = Request()
        let failedResult = LocalOCR.performVision(failed, runner: failedRunner) { throw AppError.message("Vision failed") }
        failedRunner.cancel()
        try check(!failedResult && failed.cancellations.value == 0, "failed Vision operation also removes its callback")
        try check(LocalOCR.performVision(Request(), runner: nil, perform: {}), "standalone text-hint helpers retain optional-runner behavior")

        let queued = DispatchQueue(label: "test.vision.preparation.once")
        let gate = DispatchSemaphore(value: 0), starts = Counter()
        queued.async { _ = gate.wait(timeout: .now() + 3) }
        let once = OCRVisionPreparation(queue: queued) { _ in starts.increment() }
        DispatchQueue.concurrentPerform(iterations: 30) { _ in once.schedule() }
        try check(starts.value == 0, "preparation is dispatched rather than performed by its caller")
        gate.signal(); queued.sync {}
        once.schedule(); queued.sync {}
        try check(starts.value == 1, "concurrent and repeated preparation runs once, including after completion")

        let delayed = DispatchQueue(label: "test.vision.preparation.delayed")
        let delayedGate = DispatchSemaphore(value: 0), delayedStarts = Counter()
        delayed.async { _ = delayedGate.wait(timeout: .now() + 3) }
        let suppressed = OCRVisionPreparation(queue: delayed) { _ in delayedStarts.increment() }
        suppressed.schedule(); suppressed.cancel(); suppressed.schedule()
        delayedGate.signal(); delayed.sync {}
        try check(delayedStarts.value == 0, "reading cancels queued preparation and a late prepare cannot restart it")
        let beforeSchedule = OCRVisionPreparation(queue: delayed) { _ in delayedStarts.increment() }
        beforeSchedule.cancel(); beforeSchedule.schedule(); delayed.sync {}
        try check(delayedStarts.value == 0, "reading before prepare permanently closes its preparation gate")

        let activeQueue = DispatchQueue(label: "test.vision.preparation.active")
        let activeEntered = DispatchSemaphore(value: 0), unwind = DispatchSemaphore(value: 0)
        let activeRequest = Request(), activeAccepted = Counter()
        let active = OCRVisionPreparation(queue: activeQueue) { runner in
            if LocalOCR.performVision(activeRequest, runner: runner, perform: {
                activeEntered.signal()
                // Keep the old request unwinding after cancel to expose joins.
                _ = unwind.wait(timeout: .now() + 3)
            }) { activeAccepted.increment() }
        }
        active.schedule()
        try check(activeEntered.wait(timeout: .now() + 2) == .success, "controlled preparation request is active")
        let cancellationStart = ProcessInfo.processInfo.systemUptime
        active.cancel(); active.cancel()
        let pageRequest = Request(), pageRunner = CommandRunner()
        let pageAccepted = LocalOCR.performVision(pageRequest, runner: pageRunner, perform: {})
        try check(ProcessInfo.processInfo.systemUptime - cancellationStart < 0.2 && activeRequest.cancellations.value == 1,
                  "preparation cancellation targets its active request once without waiting for it to unwind")
        unwind.signal(); activeQueue.sync {}; active.cancel()
        try check(activeAccepted.value == 0 && pageAccepted && pageRequest.cancellations.value == 0,
                  "late preparation completion is discarded and cannot cancel the real page request")

        let fixtureQueue = DispatchQueue(label: "test.vision.preparation.fixture")
        let fixtureFinished = DispatchSemaphore(value: 0), fixtureValid = Counter()
        fixtureQueue.async {
            defer { fixtureFinished.signal() }
            guard !Thread.isMainThread, let image = LocalOCR.visionPreparationImage(), image.width == 320, image.height == 96,
                  let bytes = image.dataProvider?.data as Data? else { return }
            // White background and dark CoreText glyphs must both exist.
            if bytes.contains(0) && bytes.contains(255) { fixtureValid.increment() }
        }
        try check(fixtureFinished.wait(timeout: .now() + 2) == .success && fixtureValid.value == 1,
                  "internal Japanese fixture can be rendered off the main thread without a screen")
        print("\(checks) cancellation checks passed")
    }
}
