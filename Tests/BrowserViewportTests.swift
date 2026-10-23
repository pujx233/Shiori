import AppKit
import Foundation

// Exercises current-tree membership and fresh values with an injected AX tree.
// No accessibility permission, browser session, or screen capture is required.
@main
struct BrowserViewportTests {
    final class Node {
        var role: String
        var hidden = false
        var children: [Node]
        var url: String?
        init(_ role: String, _ children: [Node] = [], url: String? = nil) {
            self.role = role; self.children = children; self.url = url
        }
    }
    struct Value { let url: String? }
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw AppError.message("FAIL: " + label) }
            checks += 1; print("PASS: " + label)
        }
        var reads = 0, budget = 10_000
        func accessed() { reads += 1; budget -= 1 }
        let search = BrowserViewportSearch<Node, Value>(
            role: { accessed(); return $0.role },
            hidden: { accessed(); return $0.hidden },
            children: { accessed(); return $0.children },
            value: { accessed(); return Value(url: $0.url) },
            withinBudget: { budget > 0 })
        let web = Node("AXWebArea", url: "https://reader.example/one")
        let root = Node("AXWindow", (0..<30).map { _ in Node("AXGroup", [Node("AXButton"), Node("AXStaticText")]) }
                        + [Node("AXGroup", [web])])
        let found = search.resolve(root: root, cachedPath: nil)!
        let discoveryReads = reads
        try check(found.value.url == web.url && found.path == [30, 0], "discovery returns the current document and reusable tree route")
        reads = 0
        let cached = search.resolve(root: root, cachedPath: found.path)!
        try check(cached.value.url == web.url && reads < discoveryReads/4, "cached lookup avoids unrelated browser branches")
        print("AX fixture reads: discovery \(discoveryReads), cached \(reads)")
        web.url = "https://reader.example/two"
        try check(search.resolve(root: root, cachedPath: found.path)?.value.url == web.url, "same AX element rereads changed URL instead of caching page identity")
        let replacement = Node("AXWebArea", url: "https://other.example/")
        root.children[30].children = [replacement]
        try check(search.resolve(root: root, cachedPath: found.path)?.value.url == replacement.url,
                  "replaced tab cannot reuse an old AXWebArea that is still alive")
        replacement.url = nil
        try check(search.resolve(root: root, cachedPath: found.path)?.value.url == nil, "missing URL does not inherit the last document URL")
        replacement.hidden = true
        let visible = Node("AXWebArea", url: "https://visible.example/")
        root.children.append(Node("AXGroup", [visible]))
        let changed = search.resolve(root: root, cachedPath: found.path)
        try check(changed?.value.url == visible.url && changed?.path == [31, 0], "hidden cached tab is rediscovered from the current tree")
        root.children[31].hidden = true
        try check(search.resolve(root: root, cachedPath: changed?.path) == nil, "hidden ancestor invalidates an otherwise visible web area")
        let freshRoot = Node("AXWindow", [Node("AXGroup", [Node("AXWebArea", url: "https://new-window.example/")])])
        try check(search.resolve(root: freshRoot, cachedPath: found.path)?.value.url == "https://new-window.example/",
                  "a missing route falls back to discovery in the new window")
        let toolbar = Node("AXToolbar", [Node("AXWebArea", url: "https://suggestion.example/")])
        try check(search.resolve(root: Node("AXWindow", [toolbar]), cachedPath: nil) == nil,
                  "address-suggestion toolbar subtrees are excluded")
        try check(search.resolve(root: Node("AXWindow", [toolbar]), cachedPath: [0, 0]) == nil,
                  "cached routes cannot bypass toolbar pruning")
        var deep = Node("AXWebArea", url: "https://too-deep.example/")
        for _ in 0..<14 { deep = Node("AXGroup", [deep]) }
        try check(search.resolve(root: deep, cachedPath: nil) == nil, "discovery keeps its maximum depth")
        budget = 1
        try check(search.resolve(root: root, cachedPath: nil) == nil, "expired traversal budget stops without returning partial identity")
        var retry = BrowserViewportRetryPolicy()
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let first = retry.begin(processID: 1, windowFrame: frame, now: 0)
        retry.finish(success: false)
        let second = retry.begin(processID: 1, windowFrame: frame, now: 0.7)
        retry.finish(success: false)
        let recovery = retry.begin(processID: 1, windowFrame: frame, now: 1.4)
        retry.finish(success: false)
        try check(first.total == 0.45 && second.message == 0.08 && recovery.total == 1.2 && recovery.message == 0.2,
                  "two failed fast queries allow bounded longer discovery")
        let throttled = retry.begin(processID: 1, windowFrame: frame, now: 2.1)
        retry.finish(success: false)
        let again = retry.begin(processID: 1, windowFrame: frame, now: 3.5)
        retry.finish(success: true)
        try check(throttled.total == 0.45 && again.total == 1.2, "longer recovery runs at most once every two seconds")
        try check(retry.begin(processID: 1, windowFrame: frame, now: 4).total == 0.45, "successful discovery immediately restores fast limits")
        retry.finish(success: false); retry.finish(success: false)
        try check(retry.begin(processID: 2, windowFrame: frame, now: 5).total == 0.45, "a different browser does not inherit recovery state")
        retry.finish(success: false); retry.finish(success: false)
        try check(retry.begin(processID: 2, windowFrame: frame.offsetBy(dx: 20, dy: 0), now: 6).total == 0.45,
                  "a changed window begins a fresh discovery budget")
        let firstWindow = Node("AXWindow"), secondWindow = Node("AXWindow"), detachedWindow = Node("AXWindow")
        typealias WindowSearch = BrowserViewportSearch<Node, Value>
        try check(WindowSearch.selectWindow(from: [firstWindow, secondWindow], focused: secondWindow,
            same: { $0 === $1 }, matches: { _ in true }) === secondWindow,
            "focused current window wins when two windows have identical frames")
        try check(WindowSearch.selectWindow(from: [firstWindow, secondWindow], focused: nil,
            same: { $0 === $1 }, matches: { _ in true }) == nil,
            "missing focus cannot authorize one of two overlapping windows")
        try check(WindowSearch.selectWindow(from: [firstWindow, secondWindow], focused: detachedWindow,
            same: { $0 === $1 }, matches: { _ in true }) == nil,
            "a focused reference outside the current window list is rejected")
        try check(WindowSearch.selectWindow(from: [firstWindow, secondWindow], focused: firstWindow,
            same: { $0 === $1 }, matches: { $0 === secondWindow }) === secondWindow,
            "a different focused frame permits only the uniquely matching screenshot window")
        print("\(checks) viewport checks passed")
    }
}
