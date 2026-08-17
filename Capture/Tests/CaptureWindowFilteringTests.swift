import XCTest
import CoreGraphics
import Foundation
@testable import Capture

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║           WINDOW FILTERING TESTS (issue-38: CGWindowListCapture:1020)        ║
// ║                                                                              ║
// ║  captureWithFiltering ran a second pass over the whole window list purely to ║
// ║  emit a per-window Log.debug line, testing membership with contains() on an  ║
// ║  Array -- O(n^2) in the number of on-screen windows, on every capture that   ║
// ║  has any exclusion configured. It also built four eager Log.info strings per ║
// ║  capture, one of which interpolated the entire excluded-ID set.              ║
// ║                                                                              ║
// ║  SCOPE NOTE: this whole path is skipped when no exclusions are configured    ║
// ║  (captureWithFiltering returns a plain CGDisplayCreateImage early). On the   ║
// ║  reference machine there are zero exclusions and the live log contains zero  ║
// ║  [Filtering] lines, so this fix contributes nothing to that machine's        ║
// ║  measured CPU time. It matters for users who exclude apps or use private     ║
// ║  windows. The measurement below is therefore synthetic, by construction.     ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class CaptureWindowFilteringTests: XCTestCase {

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Filtering Correctness                             │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testIncludedWindowIDs_KeepsOnlyVisibleLayerZeroWindows() {
        let windowList: [[String: Any]] = [
            makeWindow(id: 1),
            makeWindow(id: 2, layer: 3),                 // system window
            makeWindow(id: 3, layer: -2147483601),       // extreme layer, breaks the API
            makeWindow(id: 4, alpha: 0),                 // fully transparent
            makeWindow(id: 5, isOnScreen: false),        // offscreen
            makeWindow(id: 6),
        ]

        let included = CGWindowListCapture.includedWindowIDs(from: windowList, excluding: [])

        XCTAssertEqual(included, [1, 6], "Only visible layer-0 windows are eligible")
    }

    func testIncludedWindowIDs_DropsExcludedWindows() {
        let windowList: [[String: Any]] = (1...6).map { makeWindow(id: CGWindowID($0)) }

        let included = CGWindowListCapture.includedWindowIDs(from: windowList, excluding: [2, 4])

        XCTAssertEqual(included, [1, 3, 5, 6], "Excluded window IDs must not be composited")
    }

    /// Redaction depends on this: an excluded window must never survive filtering,
    /// including when it is the only window on screen.
    func testIncludedWindowIDs_ExcludingEverythingYieldsNothing() {
        let windowList: [[String: Any]] = (1...4).map { makeWindow(id: CGWindowID($0)) }

        let included = CGWindowListCapture.includedWindowIDs(from: windowList, excluding: [1, 2, 3, 4])

        XCTAssertTrue(included.isEmpty, "Excluding every window must composite nothing")
    }

    func testIncludedWindowIDs_SkipsEntriesWithoutAWindowNumber() {
        let windowList: [[String: Any]] = [
            [kCGWindowLayer as String: 0],  // no window number at all
            makeWindow(id: 9),
        ]

        let included = CGWindowListCapture.includedWindowIDs(from: windowList, excluding: [])

        XCTAssertEqual(included, [9])
    }

    func testIncludedWindowIDs_PreservesWindowListOrder() {
        let windowList: [[String: Any]] = [7, 3, 11, 5].map { makeWindow(id: CGWindowID($0)) }

        let included = CGWindowListCapture.includedWindowIDs(from: windowList, excluding: [])

        XCTAssertEqual(included, [7, 3, 11, 5], "Compositing order follows the window list (front to back)")
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                            Measurement                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// Compares the removed shape (filter pass + O(n^2) diagnostic pass with eager
    /// string building) against the current one (filter pass only).
    ///
    /// The reproduction below deliberately does NOT call Log.debug: emitting would
    /// write a line to retrace.log per window per capture, which would both pollute the
    /// developer's real log during a test run and make the number machine-dependent.
    /// The measured saving is therefore a LOWER BOUND — it counts the redundant scan
    /// and the string construction, but not the file I/O that followed each one.
    func testDiagnosticPassRemoval_ScalesWithWindowCount() {
        let windowCount = 300
        let windowList: [[String: Any]] = (1...windowCount).map {
            makeWindow(id: CGWindowID($0), name: "Window \($0)", owner: "App \($0 % 20)")
        }
        let excluded: Set<CGWindowID> = [5, 25, 125]
        let iterations = 50

        // After: one pass.
        _ = CGWindowListCapture.includedWindowIDs(from: windowList, excluding: excluded)
        let afterStart = DispatchTime.now()
        for _ in 0..<iterations {
            _ = CGWindowListCapture.includedWindowIDs(from: windowList, excluding: excluded)
        }
        let afterMs = Double(DispatchTime.now().uptimeNanoseconds - afterStart.uptimeNanoseconds) / 1_000_000

        // Before: the same pass, plus the diagnostic pass that was removed.
        let beforeStart = DispatchTime.now()
        for _ in 0..<iterations {
            let included = CGWindowListCapture.includedWindowIDs(from: windowList, excluding: excluded)
            var sink = 0
            for windowInfo in windowList {
                guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else { continue }
                if included.contains(windowID) {   // O(n) membership test on an Array
                    let name = windowInfo[kCGWindowName as String] as? String ?? "(no name)"
                    let owner = windowInfo[kCGWindowOwnerName as String] as? String ?? "(no owner)"
                    let layer = windowInfo[kCGWindowLayer as String] as? Int ?? -1
                    let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any]
                    let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? -1
                    let onScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
                    let message = "[Filtering] Including window \(windowID): '\(name)' from \(owner), "
                        + "layer=\(layer), alpha=\(alpha), onScreen=\(onScreen), bounds=\(bounds ?? [:])"
                    sink += message.count
                }
            }
            XCTAssertGreaterThan(sink, 0)
        }
        let beforeMs = Double(DispatchTime.now().uptimeNanoseconds - beforeStart.uptimeNanoseconds) / 1_000_000

        print("""
        [issue-38 CGWindowListCapture:1020] per capture with exclusions, \(windowCount) on-screen windows
          before: \(String(format: "%.3f", beforeMs / Double(iterations))) ms \
        (filter pass + O(n^2) diagnostic pass, string building only, no log I/O)
          after:  \(String(format: "%.3f", afterMs / Double(iterations))) ms (filter pass only)
          reduction: \(String(format: "%.1f", (1 - afterMs / beforeMs) * 100))% \
        (\(String(format: "%.1f", beforeMs / afterMs))x)
          log lines written per capture: \(windowCount - excluded.count) debug + 5 info -> 0
        """)

        XCTAssertLessThan(
            afterMs, beforeMs * 0.5,
            "Dropping the diagnostic pass should at least halve this work "
                + "(before \(beforeMs) ms, after \(afterMs) ms)"
        )
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                           Test Helpers                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    private func makeWindow(
        id: CGWindowID,
        layer: Int = 0,
        alpha: Double = 1.0,
        isOnScreen: Bool = true,
        name: String = "Window",
        owner: String = "App"
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowIsOnscreen as String: isOnScreen,
            kCGWindowName as String: name,
            kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 800, "Height": 600],
        ]
    }
}
