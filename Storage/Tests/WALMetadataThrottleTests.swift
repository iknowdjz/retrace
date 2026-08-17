import Foundation
import XCTest
@testable import Shared
@testable import Storage

/// Covers the throttled `metadata.json` sidecar rewrite in `WALManager.appendFrame`.
///
/// The throttle is only safe because `metadata.json` is never the source of truth for
/// frame data — recovery rebuilds the frame set by scanning `frames.bin`. These tests
/// pin both halves of that contract: the write reduction, and the guarantee that a crash
/// mid-throttle-window still recovers every appended frame.
final class WALMetadataThrottleTests: XCTestCase {

    // MARK: - Write reduction

    /// Before this change: 100 appends => 100 sidecar rewrites (one per frame).
    /// After: forced write on the first append, then one every 30 appends.
    func testOneHundredAppendsWriteFourSidecarsInsteadOfOneHundred() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let walManager = WALManager(walRoot: root.appendingPathComponent("wal", isDirectory: true))
        try await walManager.initialize()

        let videoID = VideoSegmentID(value: 8_100)
        var session = try await walManager.createSession(videoID: videoID)
        let metadataURL = session.sessionDir.appendingPathComponent("metadata.json")

        let sidecarsAfterCreate = await walManager.debugMetadataSaveCount(for: videoID)
        XCTAssertEqual(sidecarsAfterCreate, 1, "createSession should write the initial sidecar exactly once")
        await walManager.resetDebugMetadataSaveCounts(for: videoID)

        // Independently observe real filesystem writes: `Data.write(options: .atomic)`
        // renames a fresh temp file over the sidecar, so every actual write changes the inode.
        var observedInodeChanges = 0
        var previousInode = try inode(of: metadataURL)

        for index in 0..<100 {
            try await walManager.appendFrame(
                makeFrame(timestamp: Date(timeIntervalSince1970: 1_720_000_000 + Double(index))),
                to: &session
            )
            let currentInode = try inode(of: metadataURL)
            if currentInode != previousInode {
                observedInodeChanges += 1
                previousInode = currentInode
            }
        }

        let sidecarWrites = await walManager.debugMetadataSaveCount(for: videoID)
        XCTAssertEqual(sidecarWrites, 4, "expected sidecar writes at appends 1, 31, 61 and 91")
        XCTAssertEqual(
            observedInodeChanges,
            4,
            "inode transitions must corroborate the instrumented counter"
        )
        XCTAssertEqual(session.metadata.frameCount, 100, "in-memory frame count stays exact")
    }

    /// Every append still opens `frames.bin` for writing — the FileHandle is deliberately
    /// not cached (see the report/notes on `cancelPreservingRecoveryData`). Pinned so a
    /// future change to that decision is a conscious one.
    func testFramesFileGrowsByExactlyOneRecordPerAppendWithoutSidecarWrite() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let walManager = WALManager(walRoot: root.appendingPathComponent("wal", isDirectory: true))
        try await walManager.initialize()

        var session = try await walManager.createSession(videoID: VideoSegmentID(value: 8_101))
        var previousSize: Int64 = 0

        for index in 0..<40 {
            try await walManager.appendFrame(
                makeFrame(timestamp: Date(timeIntervalSince1970: 1_720_100_000 + Double(index))),
                to: &session
            )
            let size = try await walManager.framesFileSize(for: session)
            XCTAssertGreaterThan(size, previousSize, "append \(index) must reach frames.bin regardless of the sidecar throttle")
            previousSize = size
        }

        let recoverable = try await walManager.recoverableFrameCount(for: session)
        XCTAssertEqual(recoverable, 40)
    }

    // MARK: - Crash recovery

    /// The load-bearing test. Crash at append 47 — 16 appends past the last sidecar write —
    /// then start over with a fresh `WALManager` (all in-memory throttle state lost, exactly
    /// as after a process restart) and verify nothing was lost.
    func testCrashMidThrottleWindowStillRecoversEveryAppendedFrame() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let videoID = VideoSegmentID(value: 8_102)
        let appendedCount = 47
        let baseTimestamp = Date(timeIntervalSince1970: 1_720_200_000)

        var sessionDir: URL

        // ---- Pre-crash process ----
        do {
            let walManager = WALManager(walRoot: walRoot)
            try await walManager.initialize()
            var session = try await walManager.createSession(videoID: videoID)
            sessionDir = session.sessionDir

            for index in 0..<appendedCount {
                try await walManager.appendFrame(
                    makeFrame(
                        timestamp: baseTimestamp.addingTimeInterval(Double(index)),
                        fillByte: UInt8(index % 251)
                    ),
                    to: &session
                )
            }
            // Process dies here: no finalize, no flush, `session` is discarded.
        }

        // The on-disk sidecar is genuinely stale — this is the gap the throttle introduces.
        let staleSidecar = try loadSidecar(from: sessionDir)
        XCTAssertEqual(staleSidecar.frameCount, 31, "sidecar should lag behind the 47 appended frames")
        XCTAssertEqual(staleSidecar.width, 6, "dimensions are written on first set, never throttled")
        XCTAssertEqual(staleSidecar.height, 4)

        // ---- Post-crash process ----
        let recoveredManager = WALManager(walRoot: walRoot)
        let sessions = try await recoveredManager.listActiveSessions()
        XCTAssertEqual(sessions.count, 1)
        let recoveredSession = try XCTUnwrap(sessions.first)

        // frames.bin is the authority, and listActiveSessions reconciles the sidecar to it
        // before RecoveryManager ever reads `metadata.frameCount`.
        XCTAssertEqual(
            recoveredSession.metadata.frameCount,
            appendedCount,
            "reconciled frame count must match what frames.bin actually holds"
        )

        let recoverableCount = try await recoveredManager.recoverableFrameCount(for: recoveredSession)
        XCTAssertEqual(recoverableCount, appendedCount)

        let recoveryIndex = try await recoveredManager.recoveryIndex(for: recoveredSession)
        XCTAssertEqual(recoveryIndex.recoverableOffsets.count, appendedCount)

        // Every frame is byte-for-byte intact, in order — not just countable.
        let frames = try await recoveredManager.readFrames(from: recoveredSession)
        XCTAssertEqual(frames.count, appendedCount)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(
                frame.timestamp.timeIntervalSince1970,
                baseTimestamp.addingTimeInterval(Double(index)).timeIntervalSince1970,
                accuracy: 0.000_1,
                "frame \(index) timestamp"
            )
            XCTAssertEqual(frame.width, 6)
            XCTAssertEqual(frame.height, 4)
            XCTAssertEqual(frame.metadata.appBundleID, "com.apple.Safari")
            XCTAssertEqual(
                frame.imageData,
                Data(repeating: UInt8(index % 251), count: 24 * 4),
                "frame \(index) pixel payload"
            )
        }
    }

    /// A session whose frames are all unrecoverable must keep `frameCount > 0` so recovery
    /// quarantines the residue for inspection instead of deleting it. Reconciliation must
    /// never drag the count down to zero.
    func testReconciliationNeverZeroesFrameCountForUnrecoverableResidue() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let videoID = VideoSegmentID(value: 8_103)

        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()
        var session = try await walManager.createSession(videoID: videoID)
        try await walManager.appendFrame(
            makeFrame(timestamp: Date(timeIntervalSince1970: 1_720_300_000)),
            to: &session
        )
        XCTAssertEqual(try loadSidecar(from: session.sessionDir).frameCount, 1)

        // Truncate to a partial header: bytes on disk, zero recoverable frames.
        let handle = try FileHandle(forUpdating: session.framesURL)
        try handle.truncate(atOffset: 12)
        try handle.close()

        let recoveredManager = WALManager(walRoot: walRoot)
        let sessions = try await recoveredManager.listActiveSessions()
        let listed = try XCTUnwrap(sessions.first)

        let residueRecoverableCount = try await recoveredManager.recoverableFrameCount(for: listed)
        XCTAssertEqual(residueRecoverableCount, 0)
        XCTAssertGreaterThan(
            listed.metadata.frameCount,
            0,
            "residue must stay quarantinable, not be reconciled away to zero"
        )
    }

    // MARK: - Forced (unthrottled) writes

    /// Durable-state transitions are never throttled, and a subsequent throttled append
    /// must not regress the frontier recovery uses to trust/trim the fMP4 prefix.
    func testDurableVideoStateSurvivesSubsequentThrottledAppends() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let videoID = VideoSegmentID(value: 8_104)

        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()
        var session = try await walManager.createSession(videoID: videoID)

        for index in 0..<10 {
            try await walManager.appendFrame(
                makeFrame(timestamp: Date(timeIntervalSince1970: 1_720_400_000 + Double(index))),
                to: &session
            )
        }

        try await walManager.updateDurableVideoState(
            videoID: videoID,
            readableFrameCount: 7,
            durableVideoFileSizeBytes: 4_096
        )
        XCTAssertEqual(try loadSidecar(from: session.sessionDir).durableReadableFrameCount, 7)

        // Keep appending across a full throttle window so a sidecar rewrite definitely happens.
        for index in 10..<45 {
            try await walManager.appendFrame(
                makeFrame(timestamp: Date(timeIntervalSince1970: 1_720_400_000 + Double(index))),
                to: &session
            )
        }

        let sidecar = try loadSidecar(from: session.sessionDir)
        XCTAssertEqual(sidecar.durableReadableFrameCount, 7, "append must not clobber the durable frontier")
        XCTAssertEqual(sidecar.durableVideoFileSizeBytes, 4_096)

        let recoveredManager = WALManager(walRoot: walRoot)
        let reloadedSessions = try await recoveredManager.listActiveSessions()
        let listed = try XCTUnwrap(reloadedSessions.first)
        XCTAssertEqual(listed.metadata.durableReadableFrameCount, 7)
        XCTAssertEqual(listed.metadata.durableVideoFileSizeBytes, 4_096)
        XCTAssertEqual(listed.metadata.frameCount, 45)
    }

    /// Finalize is the successful-encode path: the WAL is consumed and removed, leaving no
    /// stale sidecar behind, and it resets the throttle so a fresh session writes on frame 1.
    func testFinalizeConsumesSessionAndResetsThrottleState() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let videoID = VideoSegmentID(value: 8_105)

        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()
        var session = try await walManager.createSession(videoID: videoID)
        for index in 0..<15 {
            try await walManager.appendFrame(
                makeFrame(timestamp: Date(timeIntervalSince1970: 1_720_500_000 + Double(index))),
                to: &session
            )
        }

        try await walManager.finalizeSession(session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: session.sessionDir.path))
        let remaining = try await walManager.listActiveSessions()
        XCTAssertTrue(remaining.isEmpty, "finalized session must leave nothing for recovery to find")

        // A brand-new session on the same manager gets a fresh, correct sidecar immediately.
        await walManager.resetDebugMetadataSaveCounts(for: videoID)
        var reused = try await walManager.createSession(videoID: videoID)
        try await walManager.appendFrame(
            makeFrame(timestamp: Date(timeIntervalSince1970: 1_720_600_000), fillByte: 0x11),
            to: &reused
        )

        let sidecar = try loadSidecar(from: reused.sessionDir)
        XCTAssertEqual(sidecar.frameCount, 1, "first append of a new session is never throttled")
        XCTAssertEqual(sidecar.width, 6)
        XCTAssertEqual(sidecar.height, 4)
        XCTAssertEqual(sidecar.durableReadableFrameCount, 0, "durable state must not leak across sessions")
        let sidecarWritesForReusedSession = await walManager.debugMetadataSaveCount(for: videoID)
        XCTAssertEqual(sidecarWritesForReusedSession, 2, "createSession + forced first append")
    }

    // MARK: - Helpers

    private func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wal-metadata-throttle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFrame(timestamp: Date, fillByte: UInt8 = 0xAB) -> CapturedFrame {
        let width = 6
        let height = 4
        let bytesPerRow = width * 4
        return CapturedFrame(
            timestamp: timestamp,
            imageData: Data(repeating: fillByte, count: bytesPerRow * height),
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Window",
                browserURL: "https://example.com",
                displayID: 1
            )
        )
    }

    private func loadSidecar(from sessionDir: URL) throws -> WALMetadata {
        let data = try Data(contentsOf: sessionDir.appendingPathComponent("metadata.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WALMetadata.self, from: data)
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
