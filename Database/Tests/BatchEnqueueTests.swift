import XCTest
import Foundation
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║        BATCH ENQUEUE TESTS (issue-38: FrameProcessingQueue.swift:992)         ║
// ║                                                                              ║
// ║  enqueueBatch called enqueueFrameForProcessing in a loop: one prepared        ║
// ║  statement and one implicit transaction per frame. Profiling the app's        ║
// ║  startup burst put FrameProcessingQueue among the hottest symbols alongside   ║
// ║  sqlite3Prepare / sqlite3RunParser.                                          ║
// ║                                                                              ║
// ║  It also had a correctness problem worth more than the speed: the per-frame   ║
// ║  call THROWS for a frame that is not eligible (processingStatus != 0), so one ║
// ║  already-processed frame aborted the loop and every frame after it was never  ║
// ║  enqueued. On the startup recovery path those frames never got OCR'd, so      ║
// ║  their text never became searchable.                                         ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class BatchEnqueueTests: XCTestCase {

    private var database: DatabaseManager!

    override func setUp() async throws {
        database = DatabaseManager()
        try await database.initialize()
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Behaviour that must hold                          │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testBatchEnqueue_EnqueuesEveryEligibleFrame() async throws {
        let frameIDs = try await insertFrames(count: 25)

        let enqueued = try await database.enqueueFramesForProcessing(frameIDs: frameIDs)

        XCTAssertEqual(enqueued, 25)
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(depth, 25, "Every eligible frame should be queued")
    }

    /// The regression this change fixes. An ineligible frame in the middle of a batch
    /// must not prevent the frames after it from being enqueued.
    func testBatchEnqueue_SkipsIneligibleFramesWithoutAbandoningTheRest() async throws {
        let frameIDs = try await insertFrames(count: 10)

        // Mark the 4th frame as already processed.
        try await database.updateFrameProcessingStatus(frameID: frameIDs[3], status: 2)

        let enqueued = try await database.enqueueFramesForProcessing(frameIDs: frameIDs)

        XCTAssertEqual(enqueued, 9, "The already-processed frame is skipped, the other nine are not")
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(depth, 9, "Frames after the ineligible one must still be queued")
    }

    /// Pins the old behaviour so the difference is explicit: the per-frame call still
    /// throws for an ineligible frame, which is exactly why looping it lost work.
    func testPerFrameEnqueue_StillThrowsForAnIneligibleFrame() async throws {
        let frameIDs = try await insertFrames(count: 3)
        try await database.updateFrameProcessingStatus(frameID: frameIDs[1], status: 2)

        try await database.enqueueFrameForProcessing(frameID: frameIDs[0])

        do {
            try await database.enqueueFrameForProcessing(frameID: frameIDs[1])
            XCTFail("Expected an ineligible frame to throw on the per-frame path")
        } catch {
            // Expected. In a loop this is what abandoned frameIDs[2].
        }
    }

    func testBatchEnqueue_EmptyBatchIsANoOp() async throws {
        let enqueued = try await database.enqueueFramesForProcessing(frameIDs: [])
        XCTAssertEqual(enqueued, 0)
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(depth, 0)
    }

    func testBatchEnqueue_IneligibleOnlyBatchEnqueuesNothing() async throws {
        let frameIDs = try await insertFrames(count: 4)
        for id in frameIDs {
            try await database.updateFrameProcessingStatus(frameID: id, status: 2)
        }

        let enqueued = try await database.enqueueFramesForProcessing(frameIDs: frameIDs)

        XCTAssertEqual(enqueued, 0)
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(depth, 0)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                            Measurement                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testBatchEnqueue_CostVersusPerFrameEnqueue() async throws {
        let batchCount = 400
        let perFrameIDs = try await insertFrames(count: batchCount)
        let batchIDs = try await insertFrames(count: batchCount)

        // Before: one prepared statement and one implicit transaction per frame.
        let beforeStart = DispatchTime.now()
        for frameID in perFrameIDs {
            try await database.enqueueFrameForProcessing(frameID: frameID)
        }
        let beforeMs = Double(DispatchTime.now().uptimeNanoseconds - beforeStart.uptimeNanoseconds) / 1_000_000

        // After: one of each for the whole batch.
        let afterStart = DispatchTime.now()
        let enqueued = try await database.enqueueFramesForProcessing(frameIDs: batchIDs)
        let afterMs = Double(DispatchTime.now().uptimeNanoseconds - afterStart.uptimeNanoseconds) / 1_000_000

        XCTAssertEqual(enqueued, batchCount)

        print("""
        [issue-38 FrameProcessingQueue:992] enqueueing \(batchCount) frames
          before: \(String(format: "%.2f", beforeMs)) ms (\(batchCount) prepares, \(batchCount) transactions)
          after:  \(String(format: "%.2f", afterMs)) ms (1 prepare, 1 transaction)
          reduction: \(String(format: "%.1f", (1 - afterMs / beforeMs) * 100))% \
        (\(String(format: "%.1f", beforeMs / afterMs))x)
        """)

        XCTAssertLessThan(
            afterMs, beforeMs,
            "Batched enqueue must beat the per-frame loop (before \(beforeMs) ms, after \(afterMs) ms)"
        )
    }

    // MARK: - Helpers

    /// Frames are inserted with processingStatus = 4 by FrameQueries.insert, and the
    /// queue only accepts status 0, so each frame is reset to pending here. The
    /// segment is real because frame.segmentId carries a foreign key.
    private func insertFrames(count: Int) async throws -> [Int64] {
        let segmentStart = Date(timeIntervalSince1970: 1_780_000_000)
        let segmentID = try await database.insertSegment(
            bundleID: "com.test.batchenqueue",
            startDate: segmentStart,
            endDate: segmentStart.addingTimeInterval(3600),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        var ids: [Int64] = []
        ids.reserveCapacity(count)
        for index in 0..<count {
            let reference = FrameReference(
                id: FrameID(value: 0),
                timestamp: Date(timeIntervalSince1970: 1_780_000_000 + Double(index)),
                segmentID: AppSegmentID(value: segmentID),
                videoID: VideoSegmentID(value: 0),
                frameIndexInSegment: index,
                metadata: FrameMetadata(
                    appBundleID: "com.test.batchenqueue",
                    appName: "Batch Enqueue Test",
                    windowName: "Window \(index)"
                ),
                source: .native
            )
            let frameID = try await database.insertFrame(reference)
            try await database.updateFrameProcessingStatus(frameID: frameID, status: 0)
            ids.append(frameID)
        }
        return ids
    }
}
