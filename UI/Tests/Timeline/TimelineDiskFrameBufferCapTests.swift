import XCTest
import Shared
@testable import Retrace

/// Covers the byte cap + LRU eviction on the timeline's on-disk frame buffer index,
/// and the incremental byte accounting that makes the cap check cheap.
@MainActor
final class TimelineDiskFrameBufferCapTests: XCTestCase {

    private typealias BufferIndex = SimpleTimelineViewModel.DiskFrameBufferIndex

    private var cap: Int64 { SimpleTimelineViewModel.diskFrameBufferMaxBytes }

    /// Entry payloads are never written in these tests — only index bookkeeping is
    /// exercised — but the URLs still point at a temp dir, never the real cache.
    private func fileURL(for rawFrameID: Int64) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceDiskFrameBufferCapTests", isDirectory: true)
            .appendingPathComponent("\(rawFrameID).jpg")
    }

    private func frameID(_ rawFrameID: Int64) -> FrameID {
        FrameID(value: rawFrameID)
    }

    private func insert(
        _ rawFrameID: Int64,
        bytes: Int64,
        origin: SimpleTimelineViewModel.DiskFrameBufferEntryOrigin = .timelineManaged,
        into index: inout BufferIndex
    ) {
        index.insert(
            frameID: frameID(rawFrameID),
            fileURL: fileURL(for: rawFrameID),
            sizeBytes: bytes,
            origin: origin
        )
    }

    /// Mirrors `enforceDiskFrameBufferByteCap` in the view model.
    @discardableResult
    private func enforceCap(
        on index: inout BufferIndex,
        protecting protectedFrameIDs: Set<FrameID> = []
    ) -> [FrameID] {
        let evicted = index.evictionCandidates(maxBytes: cap, protecting: protectedFrameIDs)
        for evictedFrameID in evicted {
            index.remove(evictedFrameID)
        }
        return evicted
    }

    // MARK: - Cap

    func testCapMatchesSearchThumbnailDiskCacheBudget() {
        XCTAssertEqual(cap, 512 * 1024 * 1024)
    }

    /// Inserts well past the cap and reports the peak bytes with and without eviction.
    func testByteCapBoundsBufferGrowthAndEvictsLeastRecentlyUsedFrames() {
        let frameCount: Int64 = 2_000
        let frameBytes: Int64 = 600 * 1024  // 614,400 bytes — a plausible full-res JPEG

        var unbounded = BufferIndex()
        var unboundedPeakBytes: Int64 = 0
        for rawFrameID in 1...frameCount {
            insert(rawFrameID, bytes: frameBytes, into: &unbounded)
            unboundedPeakBytes = max(unboundedPeakBytes, unbounded.totalBytes)
        }

        var capped = BufferIndex()
        var cappedTransientPeakBytes: Int64 = 0
        var cappedSteadyPeakBytes: Int64 = 0
        for rawFrameID in 1...frameCount {
            insert(rawFrameID, bytes: frameBytes, into: &capped)
            cappedTransientPeakBytes = max(cappedTransientPeakBytes, capped.totalBytes)
            // The just-stored frame is protected, exactly as the view model protects it.
            enforceCap(on: &capped, protecting: [frameID(rawFrameID)])
            cappedSteadyPeakBytes = max(cappedSteadyPeakBytes, capped.totalBytes)
            XCTAssertEqual(capped.totalBytes, capped.recomputedTotalBytes())
        }

        print(
            """
            [DiskFrameBufferCap] frames=\(frameCount) bytesPerFrame=\(frameBytes) cap=\(cap)
            [DiskFrameBufferCap] before(unbounded) peakBytes=\(unboundedPeakBytes) finalCount=\(unbounded.count)
            [DiskFrameBufferCap] after(capped) transientPeakBytes=\(cappedTransientPeakBytes) \
            steadyPeakBytes=\(cappedSteadyPeakBytes) finalBytes=\(capped.totalBytes) finalCount=\(capped.count)
            """
        )

        XCTAssertEqual(unboundedPeakBytes, frameCount * frameBytes)
        XCTAssertGreaterThan(unboundedPeakBytes, cap)

        // (a) total bytes stay at or under the cap
        XCTAssertLessThanOrEqual(capped.totalBytes, cap)
        XCTAssertLessThanOrEqual(cappedSteadyPeakBytes, cap)
        // The only overshoot is the single frame just written, before it is accounted for.
        XCTAssertLessThanOrEqual(cappedTransientPeakBytes, cap + frameBytes)

        // (b) the survivors are the most recently used frames — eviction took the oldest
        let survivingRawFrameIDs = Set(capped.frameIDs.map(\.value))
        let expectedSurvivors = Set(((frameCount - Int64(capped.count) + 1)...frameCount))
        XCTAssertEqual(survivingRawFrameIDs, expectedSurvivors)
    }

    func testEvictionPrefersLeastRecentlyUsedAfterTouches() {
        let frameBytes = cap / 4
        var index = BufferIndex()

        for rawFrameID: Int64 in 1...4 {
            insert(rawFrameID, bytes: frameBytes, into: &index)
        }
        XCTAssertEqual(index.totalBytes, cap)

        // Frame 1 is oldest by insertion, but a touch makes frame 2 the LRU victim.
        index.touch(frameID(1))
        insert(5, bytes: frameBytes, into: &index)

        let evicted = enforceCap(on: &index, protecting: [frameID(5)])

        XCTAssertEqual(evicted.map(\.value), [2])
        XCTAssertEqual(Set(index.frameIDs.map(\.value)), [1, 3, 4, 5])
        XCTAssertLessThanOrEqual(index.totalBytes, cap)
        XCTAssertEqual(index.totalBytes, index.recomputedTotalBytes())
    }

    func testEvictionNeverTakesProtectedOrExternallyOwnedEntries() {
        let frameBytes = cap / 2
        var index = BufferIndex()

        insert(1, bytes: frameBytes, origin: .externalCapture, into: &index)  // oldest, not ours
        insert(2, bytes: frameBytes, into: &index)                            // oldest evictable
        insert(3, bytes: frameBytes, into: &index)
        insert(4, bytes: frameBytes, into: &index)
        XCTAssertGreaterThan(index.totalBytes, cap)

        // Frame 2 is the LRU timeline-managed entry but is pinned by an in-flight read.
        let evicted = enforceCap(on: &index, protecting: [frameID(2), frameID(4)])

        XCTAssertEqual(evicted.map(\.value), [3])
        XCTAssertEqual(index[frameID(1)]?.origin, .externalCapture)
        XCTAssertNotNil(index[frameID(2)])
        XCTAssertNil(index[frameID(3)])
        XCTAssertNotNil(index[frameID(4)])
        XCTAssertEqual(index.totalBytes, index.recomputedTotalBytes())
    }

    func testEvictionReturnsNothingWhenOnlyExternalEntriesRemain() {
        var index = BufferIndex()
        insert(1, bytes: cap, origin: .externalCapture, into: &index)
        insert(2, bytes: cap, origin: .externalCapture, into: &index)

        XCTAssertGreaterThan(index.totalBytes, cap)
        XCTAssertTrue(index.evictionCandidates(maxBytes: cap, protecting: []).isEmpty)
        XCTAssertEqual(index.count, 2)
    }

    // MARK: - Incremental byte accounting

    // (c) byte accounting stays exact across insert / touch / remove / replace / clear
    func testByteAccountingStaysExactAcrossInsertTouchAndRemove() {
        var index = BufferIndex()
        XCTAssertEqual(index.totalBytes, 0)

        insert(1, bytes: 1_000, into: &index)
        insert(2, bytes: 2_500, into: &index)
        insert(3, bytes: 400, origin: .externalCapture, into: &index)
        XCTAssertEqual(index.totalBytes, 3_900)
        XCTAssertEqual(index.totalBytes, index.recomputedTotalBytes())

        // A touch moves recency without moving bytes.
        let bytesBeforeTouch = index.totalBytes
        index.touch(frameID(1))
        index.touch(frameID(999))  // unknown frame: no-op
        XCTAssertEqual(index.totalBytes, bytesBeforeTouch)
        XCTAssertEqual(index.totalBytes, index.recomputedTotalBytes())
        XCTAssertEqual(index.count, 3)

        // Re-storing a frame replaces its byte contribution instead of double-counting.
        insert(2, bytes: 700, into: &index)
        XCTAssertEqual(index.count, 3)
        XCTAssertEqual(index.totalBytes, 2_100)
        XCTAssertEqual(index.totalBytes, index.recomputedTotalBytes())

        XCTAssertEqual(index.remove(frameID(1))?.sizeBytes, 1_000)
        XCTAssertNil(index.remove(frameID(1)))  // second removal must not double-subtract
        XCTAssertEqual(index.totalBytes, 1_100)
        XCTAssertEqual(index.totalBytes, index.recomputedTotalBytes())

        index.removeAll()
        XCTAssertEqual(index.count, 0)
        XCTAssertEqual(index.totalBytes, 0)
        XCTAssertEqual(index.totalBytes, index.recomputedTotalBytes())
    }

    func testTouchKeepsRecencyOrderingMonotonic() {
        var index = BufferIndex()
        insert(1, bytes: 10, into: &index)
        insert(2, bytes: 10, into: &index)

        let firstSequence = index[frameID(1)]?.lastAccessSequence
        index.touch(frameID(1))
        let touchedSequence = index[frameID(1)]?.lastAccessSequence

        XCTAssertNotNil(firstSequence)
        XCTAssertNotNil(touchedSequence)
        XCTAssertGreaterThan(touchedSequence!, index[frameID(2)]!.lastAccessSequence)
        XCTAssertGreaterThan(touchedSequence!, firstSequence!)
    }
}
