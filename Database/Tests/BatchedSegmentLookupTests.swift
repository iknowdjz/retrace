import XCTest
import Foundation
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║      BATCHED SEGMENT LOOKUP TESTS (issue-38: SearchManager.swift:115)         ║
// ║                                                                              ║
// ║  SearchManager built each SearchResult by calling getFrame for that match --  ║
// ║  one database round trip and one full row hydration per result row -- and     ║
// ║  used exactly one field from it, segmentID.                                   ║
// ║                                                                              ║
// ║  The behaviour that must survive batching: a match whose frame has since      ║
// ║  been deleted is SKIPPED, not surfaced with a bogus segment.                  ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class BatchedSegmentLookupTests: XCTestCase {

    private var database: DatabaseManager!

    override func setUp() async throws {
        database = DatabaseManager()
        try await database.initialize()
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    func testBatchedLookup_ReturnsSegmentForEveryKnownFrame() async throws {
        let (segmentID, frameIDs) = try await insertFrames(count: 12)

        let map = try await database.getSegmentIDsForFrames(ids: frameIDs.map { FrameID(value: $0) })

        XCTAssertEqual(map.count, 12)
        for frameID in frameIDs {
            XCTAssertEqual(map[FrameID(value: frameID)]?.value, segmentID)
        }
    }

    /// The skip semantics SearchManager depends on.
    func testBatchedLookup_OmitsUnknownFrames() async throws {
        let (_, frameIDs) = try await insertFrames(count: 3)
        let missing = FrameID(value: 999_999_999)

        let map = try await database.getSegmentIDsForFrames(
            ids: frameIDs.map { FrameID(value: $0) } + [missing]
        )

        XCTAssertEqual(map.count, 3, "A frame that does not exist must be absent, not defaulted")
        XCTAssertNil(map[missing])
    }

    func testBatchedLookup_EmptyInputIsANoOp() async throws {
        let map = try await database.getSegmentIDsForFrames(ids: [])
        XCTAssertTrue(map.isEmpty)
    }

    /// More ids than the 500-per-statement chunk, so the chunking loop is exercised
    /// and cannot silently drop a chunk.
    func testBatchedLookup_HandlesMoreIdsThanOneChunk() async throws {
        let (segmentID, frameIDs) = try await insertFrames(count: 1200)

        let map = try await database.getSegmentIDsForFrames(ids: frameIDs.map { FrameID(value: $0) })

        XCTAssertEqual(map.count, 1200, "Every chunk must contribute to the result")
        XCTAssertEqual(map[FrameID(value: frameIDs.last!)]?.value, segmentID)
    }

    /// The batched lookup must agree with the per-frame path it replaces.
    func testBatchedLookup_MatchesPerFrameLookupAndIsCheaper() async throws {
        let (_, frameIDs) = try await insertFrames(count: 300)
        let ids = frameIDs.map { FrameID(value: $0) }

        // Before: one getFrame per match.
        let beforeStart = DispatchTime.now()
        var perFrame: [FrameID: AppSegmentID] = [:]
        for id in ids {
            if let frame = try await database.getFrame(id: id) {
                perFrame[id] = frame.segmentID
            }
        }
        let beforeMs = Double(DispatchTime.now().uptimeNanoseconds - beforeStart.uptimeNanoseconds) / 1_000_000

        // After: one query per 500 ids.
        let afterStart = DispatchTime.now()
        let batched = try await database.getSegmentIDsForFrames(ids: ids)
        let afterMs = Double(DispatchTime.now().uptimeNanoseconds - afterStart.uptimeNanoseconds) / 1_000_000

        XCTAssertEqual(batched, perFrame, "Batched lookup must produce the identical mapping")

        print("""
        [issue-38 SearchManager:115] resolving segments for \(ids.count) search matches
          before: \(String(format: "%.2f", beforeMs)) ms (\(ids.count) getFrame round trips)
          after:  \(String(format: "%.2f", afterMs)) ms (1 query)
          reduction: \(String(format: "%.1f", (1 - afterMs / beforeMs) * 100))% \
        (\(String(format: "%.1f", beforeMs / afterMs))x)
        """)

        XCTAssertLessThan(
            afterMs, beforeMs,
            "Batched lookup must beat the per-frame loop (before \(beforeMs) ms, after \(afterMs) ms)"
        )
    }

    // MARK: - Helpers

    private func insertFrames(count: Int) async throws -> (segmentID: Int64, frameIDs: [Int64]) {
        let start = Date(timeIntervalSince1970: 1_781_000_000)
        let segmentID = try await database.insertSegment(
            bundleID: "com.test.segmentlookup",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        var ids: [Int64] = []
        ids.reserveCapacity(count)
        for index in 0..<count {
            let reference = FrameReference(
                id: FrameID(value: 0),
                timestamp: start.addingTimeInterval(Double(index)),
                segmentID: AppSegmentID(value: segmentID),
                videoID: VideoSegmentID(value: 0),
                frameIndexInSegment: index,
                metadata: FrameMetadata(
                    appBundleID: "com.test.segmentlookup",
                    appName: "Segment Lookup Test",
                    windowName: "Window \(index)"
                ),
                source: .native
            )
            ids.append(try await database.insertFrame(reference))
        }
        return (segmentID, ids)
    }
}
