import XCTest
import CoreGraphics
import CoreText
import Foundation
import Shared
@testable import Capture

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║              PROXY DEDUPLICATION TESTS (issue-38: CGWindowListCapture:376)   ║
// ║                                                                              ║
// ║  The capture path used to build a full-resolution BGRA buffer for every      ║
// ║  captured frame BEFORE deciding whether to keep it, then discard 37.4% of    ║
// ║  them. It now decides using a small point-sampled proxy and only builds the  ║
// ║  full buffer for frames it keeps.                                           ║
// ║                                                                              ║
// ║  These tests pin the thing that could silently break: that deciding from     ║
// ║  the proxy reaches the SAME keep/drop verdict as deciding from the full      ║
// ║  buffer, including for the small localized changes (a caret, a few edited    ║
// ║  characters) that an averaging downsample would blur away.                   ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class CaptureProxyDeduplicationTests: XCTestCase {

    private let deduplicator = FrameDeduplicator()
    /// The production default (`CaptureConfig.deduplicationThreshold` on the reference
    /// machine reads 99.85% in the capture logs).
    private let threshold = 0.9985

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Keep/Drop Equivalence                             │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// Screen-like frame pairs spanning the range the capture path actually sees.
    private func equivalenceCases() -> [(name: String, a: CGImage, b: CGImage)] {
        let base = makeScreenLikeImage()
        return [
            ("identical", base, makeScreenLikeImage()),
            ("caret blink", base, makeScreenLikeImage(caret: true)),
            ("one word edited", base, makeScreenLikeImage(editedLine: 7)),
            ("several lines edited", base, makeScreenLikeImage(editedLine: 3, extraEditedLine: 11)),
            ("scrolled by one line", base, makeScreenLikeImage(scrollOffset: 22)),
            ("entirely different", base, makeScreenLikeImage(background: 0.85, textRows: 4)),
        ]
    }

    func testProxyDeduplication_MatchesFullResolutionVerdict() {
        var checked = 0
        var verdicts: Set<Bool> = []

        for testCase in equivalenceCases() {
            guard let fullA = fullResolutionFrame(from: testCase.a),
                  let fullB = fullResolutionFrame(from: testCase.b) else {
                XCTFail("Could not build full-resolution frame for '\(testCase.name)'")
                continue
            }
            guard let proxyA = CGWindowListCapture.makeDeduplicationProxy(testCase.a),
                  let proxyB = CGWindowListCapture.makeDeduplicationProxy(testCase.b) else {
                XCTFail("Could not build dedup proxy for '\(testCase.name)'")
                continue
            }

            let fullSimilarity = deduplicator.computeSimilarity(fullA, fullB)
            let proxySimilarity = deduplicator.computeSimilarity(proxyA, proxyB)

            let fullVerdict = CaptureManager.shouldKeepFrameForSimilarity(
                frameSize: FrameSize(width: fullA.width, height: fullA.height),
                referenceSize: FrameSize(width: fullB.width, height: fullB.height),
                similarity: fullSimilarity,
                threshold: threshold
            )
            let proxyVerdict = CaptureManager.shouldKeepFrameForSimilarity(
                frameSize: FrameSize(width: testCase.a.width, height: testCase.a.height),
                referenceSize: FrameSize(width: testCase.b.width, height: testCase.b.height),
                similarity: proxySimilarity,
                threshold: threshold
            )

            XCTAssertEqual(
                proxyVerdict, fullVerdict,
                """
                '\(testCase.name)': proxy verdict \(proxyVerdict ? "keep" : "drop") \
                disagrees with full-resolution verdict \(fullVerdict ? "keep" : "drop") \
                (full similarity \(fullSimilarity), proxy similarity \(proxySimilarity), \
                threshold \(threshold))
                """
            )
            verdicts.insert(fullVerdict)
            checked += 1
        }

        XCTAssertEqual(checked, 6, "Every equivalence case must be evaluated")
        // Guards against a vacuous pass: if every case resolved the same way, agreeing
        // with the full-resolution path would prove nothing about the proxy.
        XCTAssertEqual(
            verdicts, [true, false],
            "Equivalence cases must produce both keep and drop verdicts to be meaningful"
        )
    }

    /// The reason nearest-neighbour is required rather than an averaging downsample:
    /// the proxy must report a small localized change at the same magnitude the
    /// full-resolution comparison does, not blur it away.
    ///
    /// This asserts tracking, not an absolute verdict. At the production threshold a
    /// single edited line out of 24 is currently deduplicated by BOTH paths — see
    /// `testDeduplicationThreshold_DropsSingleLineEdits`, which documents that
    /// pre-existing behaviour rather than changing it here.
    func testProxyDeduplication_TracksFullResolutionOnSmallLocalizedChange() {
        let unchanged = makeScreenLikeImage()
        let edited = makeScreenLikeImage(editedLine: 7)

        guard let fullA = fullResolutionFrame(from: unchanged),
              let fullB = fullResolutionFrame(from: edited),
              let proxyA = CGWindowListCapture.makeDeduplicationProxy(unchanged),
              let proxyB = CGWindowListCapture.makeDeduplicationProxy(edited) else {
            return XCTFail("Could not build frames")
        }

        let fullSimilarity = deduplicator.computeSimilarity(fullA, fullB)
        let proxySimilarity = deduplicator.computeSimilarity(proxyA, proxyB)

        // Both must see a change (neither reports "identical").
        XCTAssertLessThan(fullSimilarity, 1.0, "Full-resolution comparison must see the edit")
        XCTAssertLessThan(proxySimilarity, 1.0, "Proxy must see the edit, not average it away")

        // And they must agree on how big it is. An averaging downsample would push the
        // proxy materially closer to 1.0 than the full-resolution comparison.
        XCTAssertEqual(
            proxySimilarity, fullSimilarity, accuracy: 0.002,
            "Proxy similarity (\(proxySimilarity)) must track full-resolution "
                + "similarity (\(fullSimilarity)) for a small localized change"
        )
    }

    /// Documents pre-existing deduplication behaviour that this change does NOT alter:
    /// at the production threshold a single edited line out of 24 falls below the
    /// keep bar and the frame is discarded — on the full-resolution path as much as
    /// through the proxy. Recorded here because it is a content-loss question worth
    /// deciding deliberately, not one to settle inside a performance change.
    func testDeduplicationThreshold_DropsSingleLineEdits() {
        guard let fullA = fullResolutionFrame(from: makeScreenLikeImage()),
              let fullB = fullResolutionFrame(from: makeScreenLikeImage(editedLine: 7)) else {
            return XCTFail("Could not build frames")
        }

        let similarity = deduplicator.computeSimilarity(fullA, fullB)
        XCTAssertGreaterThan(
            similarity, threshold,
            "Expected the full-resolution path to also drop a single-line edit "
                + "(similarity \(similarity), threshold \(threshold))"
        )
    }

    func testProxyDeduplication_IdenticalFramesAreDropped() {
        guard let proxyA = CGWindowListCapture.makeDeduplicationProxy(makeScreenLikeImage()),
              let proxyB = CGWindowListCapture.makeDeduplicationProxy(makeScreenLikeImage()) else {
            return XCTFail("Could not build dedup proxies")
        }

        let similarity = deduplicator.computeSimilarity(proxyA, proxyB)
        XCTAssertGreaterThan(
            similarity, threshold,
            "Two renders of identical content must deduplicate (similarity \(similarity))"
        )
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                       Proxy Grid Properties                              │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// The proxy must mirror the grid FrameDeduplicator.computeSimilarity samples,
    /// so it carries one pixel per pixel the comparison would have read.
    func testProxyGrid_MirrorsSimilaritySamplingGrid() {
        let grid = CGWindowListCapture.deduplicationProxyGrid(width: 3440, height: 1440)

        // Derivation in FrameDeduplicator.computeSimilarity for a 3440x1440 frame.
        let aspect = 3440.0 / 1440.0
        let expectedRows = Int((10_000.0 / aspect).squareRoot())
        let expectedCols = Int(Double(expectedRows) * aspect)

        XCTAssertEqual(grid.rows, expectedRows)
        XCTAssertEqual(grid.cols, expectedCols)
        XCTAssertLessThan(
            grid.cols * grid.rows * 4, 64 * 1024,
            "Proxy must stay tiny relative to the 19,814,400-byte full frame"
        )
    }

    /// A display smaller than the sampling grid must not be "reduced" to something
    /// larger than the image it came from.
    func testProxyGrid_ClampsToSourceDimensions() {
        let grid = CGWindowListCapture.deduplicationProxyGrid(width: 40, height: 30)
        XCTAssertLessThanOrEqual(grid.cols, 40)
        XCTAssertLessThanOrEqual(grid.rows, 30)

        let degenerate = CGWindowListCapture.deduplicationProxyGrid(width: 0, height: 0)
        XCTAssertEqual(degenerate.cols, 0)
        XCTAssertEqual(degenerate.rows, 0)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                            Measurement                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// Records the per-frame cost avoided for every frame the capture path discards.
    func testProxyDeduplication_CostOfDeferringConversion() {
        let width = 3440
        let height = 1440
        let image = makeScreenLikeImage(width: width, height: height)
        let iterations = 20

        _ = fullResolutionFrame(from: image)
        let fullStart = DispatchTime.now()
        for _ in 0..<iterations { _ = fullResolutionFrame(from: image) }
        let fullMs = Double(DispatchTime.now().uptimeNanoseconds - fullStart.uptimeNanoseconds) / 1_000_000

        _ = CGWindowListCapture.makeDeduplicationProxy(image)
        let proxyStart = DispatchTime.now()
        for _ in 0..<iterations { _ = CGWindowListCapture.makeDeduplicationProxy(image) }
        let proxyMs = Double(DispatchTime.now().uptimeNanoseconds - proxyStart.uptimeNanoseconds) / 1_000_000

        let grid = CGWindowListCapture.deduplicationProxyGrid(width: width, height: height)
        let fullBytes = width * height * 4
        let proxyBytes = grid.cols * grid.rows * 4

        print("""
        [issue-38 CGWindowListCapture:376] work avoided per discarded frame (\(width)x\(height))
          full BGRA conversion: \(String(format: "%.3f", fullMs / Double(iterations))) ms, \(fullBytes) bytes
          dedup proxy:          \(String(format: "%.3f", proxyMs / Double(iterations))) ms, \(proxyBytes) bytes
          time:       \(String(format: "%.1f", fullMs / proxyMs))x cheaper
          allocation: \(String(format: "%.0f", Double(fullBytes) / Double(proxyBytes)))x smaller
        """)

        XCTAssertLessThan(proxyMs, fullMs, "Proxy must be cheaper than the full conversion")
        XCTAssertLessThan(proxyBytes * 100, fullBytes, "Proxy must be far smaller than the full frame")
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                           Test Helpers                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// Mirrors `CGWindowListCapture.convertCGImageToBGRAData` so the comparison is
    /// against the buffer the capture path used to build.
    private func fullResolutionFrame(from image: CGImage) -> CapturedFrame? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixelData = Data(count: bytesPerRow * height)

        let success = pixelData.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard success else { return nil }
        return CapturedFrame(
            timestamp: Date(),
            imageData: pixelData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: .empty
        )
    }

    /// Renders text-on-background content approximating a screen of an editor or
    /// browser, which is what the capture path actually deduplicates.
    private func makeScreenLikeImage(
        width: Int = 1720,
        height: Int = 720,
        background: CGFloat = 0.12,
        textRows: Int = 24,
        editedLine: Int? = nil,
        extraEditedLine: Int? = nil,
        caret: Bool = false,
        scrollOffset: CGFloat = 0
    ) -> CGImage {
        let bytesPerRow = width * 4
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!

        context.setFillColor(red: background, green: background, blue: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let lineHeight = 22.0
        let baseText = "let frame = await backend.captureCandidate(displayID: displayID)"
        let editText = "let frame = await backend.materializePendingFrame() // edited"

        for row in 0..<textRows {
            let y = Double(height) - 40 - Double(row) * lineHeight + Double(scrollOffset)
            guard y > 0, y < Double(height) else { continue }

            let isEdited = (row == editedLine) || (row == extraEditedLine)
            let text = isEdited ? editText : baseText
            let attributed = NSAttributedString(
                string: "\(row): \(text)",
                attributes: [
                    .font: font,
                    .foregroundColor: CGColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1),
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(line, context)
        }

        if caret {
            context.setFillColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)
            context.fill(CGRect(x: 520, y: Double(height) - 40 - 7 * lineHeight, width: 2, height: 15))
        }

        return context.makeImage()!
    }
}
