import XCTest
import Foundation
import Shared
@testable import Processing

/// Measures what the per-frame memory-ledger instrumentation in `performOCRStage` costs.
///
/// The sequence below mirrors `FrameProcessingQueue.performOCRStage` call for call: one
/// residual epoch, a transient-residual reset, four `MemoryLedger.snapshot(waitForPendingUpdates:)`
/// round-trips, and the `setResidual` writes each snapshot feeds. Benchmarks that do not mirror
/// production lie, so the ledger is first populated with the same number of components the real
/// app carries (49 distinct `MemoryLedger.set` tags exist in the tree) — `snapshot()` sorts and
/// reduces over every entry, so component count is the dominant term.
final class OCRStageMemoryLedgerCostTests: XCTestCase {
    private static let productionComponentCount = 49
    private static let measuredFrames = 200

    /// One full-resolution frame, matching the size the ledger records on this machine.
    private static let activeFrameBytes: Int64 = 19_814_400

    private func populateLedgerLikeProduction() async {
        for index in 0..<Self.productionComponentCount {
            MemoryLedger.set(
                tag: "benchmark.component.\(index)",
                bytes: Int64(index + 1) * 1_024,
                count: index,
                unit: "items",
                function: "benchmark.function.\(index % 7)",
                kind: "benchmark-kind"
            )
        }
        await MemoryLedger.flushPendingUpdates()
    }

    /// The exact instrumentation `performOCRStage` runs for one frame.
    private func runOneFrameOfStageInstrumentation() async {
        let epoch = await MemoryLedger.beginResidualEpoch(
            ownerFunction: "processing.ocr.stage",
            candidateConcurrentFunctions: ["capture.screen_capture"]
        )
        OCRStageMemoryLedger.clearTransientStageResiduals(reason: "processing.ocr.stage")
        let stageBaselineSnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)

        let postFrameLoadSnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
        let frameLoadResidualBytes = OCRStageMemoryLedger.measuredResidualBytes(
            before: stageBaselineSnapshot,
            after: postFrameLoadSnapshot
        )
        OCRStageMemoryLedger.setResidual(
            tag: "processing.ocr.stageFrameLoadResidual",
            function: "processing.ocr.stage_load",
            kind: "stage-frame-load-residual",
            note: "observed-footprint-delta",
            bytes: frameLoadResidualBytes,
            reason: "processing.ocr.stage_frame_load"
        )

        OCRStageMemoryLedger.beginActiveFrame(
            bytes: Self.activeFrameBytes,
            reason: "processing.ocr.stage"
        )

        let postExtractSnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
        let extractResidualBytes = max(
            0,
            OCRStageMemoryLedger.measuredResidualBytes(
                before: postFrameLoadSnapshot,
                after: postExtractSnapshot
            ) - ProcessingExtractMemoryLedger.currentStageResidualExclusionBytes()
        )
        await ProcessingExtractMemoryLedger.clearObservedResidualsForHandoff(
            reason: "processing.ocr.stage_extract"
        )
        OCRStageMemoryLedger.setResidual(
            tag: "processing.ocr.stageExtractResidual",
            function: "processing.ocr.stage_extract",
            kind: "stage-extract-residual",
            note: "observed-footprint-delta-net-active-extract-residuals",
            bytes: extractResidualBytes,
            reason: "processing.ocr.stage_extract"
        )

        OCRStageMemoryLedger.endActiveFrame(
            bytes: Self.activeFrameBytes,
            reason: "processing.ocr.stage"
        )

        let postReleaseSnapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
        let releaseResidualBytes = OCRStageMemoryLedger.measuredResidualBytes(
            before: postExtractSnapshot,
            after: postReleaseSnapshot
        )
        OCRStageMemoryLedger.setResidual(
            tag: "processing.ocr.stageReleaseResidual",
            function: "processing.ocr.stage_release",
            kind: "stage-release-residual",
            note: "observed-footprint-delta",
            bytes: releaseResidualBytes,
            reason: "processing.ocr.stage_release"
        )
        _ = ProcessingExtractMemoryLedger.settleObservedResidualAtStageRelease(
            snapshot: postReleaseSnapshot,
            reason: "processing.ocr.stage_release"
        )
        let settledHandoffObservedResidualBytes =
            ProcessingExtractMemoryLedger.currentHandoffObservedResidualBytes()
        let stageObservedResidualBytes = OCRStageMemoryLedger.stageObservedResidualBytes(
            settledHandoffObservedResidualBytes: settledHandoffObservedResidualBytes,
            currentUnattributedBytes: OCRStageMemoryLedger.currentUnattributedBytes(postReleaseSnapshot),
            activeOCRFrameCount: OCRStageMemoryLedger.currentActiveFrameCount()
        )
        OCRStageMemoryLedger.setResidual(
            tag: "processing.ocr.stageObservedResidual",
            function: "processing.ocr.stage",
            kind: "stage-observed-residual",
            note: "observed-current-unattributed-after-stage-release",
            bytes: stageObservedResidualBytes,
            reason: "processing.ocr.stage_release",
            delay: 0.8
        )

        await MemoryLedger.endResidualEpoch(epoch)
    }

    func testPerFrameStageInstrumentationCost() async throws {
        await populateLedgerLikeProduction()

        // Warm up so first-call actor/task setup is not attributed to the measurement.
        for _ in 0..<10 {
            await runOneFrameOfStageInstrumentation()
        }

        let start = ContinuousClock.now
        for _ in 0..<Self.measuredFrames {
            await runOneFrameOfStageInstrumentation()
        }
        let elapsed = ContinuousClock.now - start

        let totalMs = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
            + Double(elapsed.components.seconds) * 1_000.0
        let perFrameMs = totalMs / Double(Self.measuredFrames)

        print(String(
            format: "[BENCH] OCR stage ledger instrumentation: %.4f ms/frame (%d frames, %d components, total %.1f ms)",
            perFrameMs,
            Self.measuredFrames,
            Self.productionComponentCount,
            totalMs
        ))

        // Non-vacuous: the sequence must actually have done ledger work.
        let snapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
        XCTAssertGreaterThanOrEqual(snapshot.componentCount, Self.productionComponentCount)
    }

    /// Same sequence, but with other subsystems writing to the ledger concurrently.
    ///
    /// `snapshot(waitForPendingUpdates: true)` drains the serialized pending-write chain, so an
    /// idle-ledger measurement would understate the cost if capture/extract/Vision writes are in
    /// flight. This runs a writer alongside the stage to put that on the record.
    func testPerFrameStageInstrumentationCostUnderConcurrentLedgerWrites() async throws {
        await populateLedgerLikeProduction()

        let stopWriting = ManagedAtomicFlag()
        let writer = Task.detached(priority: .utility) {
            var counter = 0
            while !stopWriting.isSet {
                MemoryLedger.set(
                    tag: "benchmark.concurrent.\(counter % 12)",
                    bytes: Int64(counter % 4_096),
                    function: "capture.screen_capture",
                    kind: "concurrent-writer"
                )
                counter += 1
                // Throttled to a production-like write rate. An unthrottled loop enqueues an
                // unbounded chain of pending-write tasks and crashes the process (signal 10),
                // which measures the benchmark rather than the app.
                try? await Task.sleep(for: .milliseconds(1), clock: .continuous)
            }
        }

        for _ in 0..<10 {
            await runOneFrameOfStageInstrumentation()
        }

        let start = ContinuousClock.now
        for _ in 0..<Self.measuredFrames {
            await runOneFrameOfStageInstrumentation()
        }
        let elapsed = ContinuousClock.now - start

        stopWriting.set()
        _ = await writer.result

        let totalMs = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
            + Double(elapsed.components.seconds) * 1_000.0
        let perFrameMs = totalMs / Double(Self.measuredFrames)

        print(String(
            format: "[BENCH] OCR stage ledger instrumentation UNDER CONTENTION: %.4f ms/frame (%d frames, total %.1f ms)",
            perFrameMs,
            Self.measuredFrames,
            totalMs
        ))

        let snapshot = await MemoryLedger.snapshot(waitForPendingUpdates: true)
        XCTAssertGreaterThanOrEqual(snapshot.componentCount, Self.productionComponentCount)
    }
}

/// Minimal thread-safe flag; the package has no atomics dependency.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
