import XCTest
import Shared
@testable import Retrace

/// Covers the retirement of `cpu_process_usage.jsonl`, the per-sample CPU log that was appended on
/// every sampler tick but never read back.
final class ProcessCPULegacyLogCleanupTests: XCTestCase {
    private var logsDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        logsDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessCPULegacyLogCleanupTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let logsDirectoryURL {
            try? FileManager.default.removeItem(at: logsDirectoryURL.deletingLastPathComponent())
        }
        logsDirectoryURL = nil
        try super.tearDownWithError()
    }

    private var legacyLogURL: URL {
        ProcessCPULegacyLogCleanup.legacyLogFileURL(in: logsDirectoryURL)
    }

    private var tallyURL: URL {
        logsDirectoryURL.appendingPathComponent("cpu_process_usage_tally.json", isDirectory: false)
    }

    private func fileSizeBytes(at fileURL: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: - Cleanup

    func testRemoveLegacyLogReclaimsAnExistingFile() throws {
        // Stand in for the multi-GB file older builds leave behind.
        let payload = Data(repeating: UInt8(ascii: "{"), count: 128 * 1024)
        try payload.write(to: legacyLogURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyLogURL.path))

        let reclaimedBytes = ProcessCPULegacyLogCleanup.removeLegacyLogIfPresent(at: legacyLogURL)

        XCTAssertEqual(reclaimedBytes, UInt64(payload.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLogURL.path))
    }

    func testRemoveLegacyLogIsANoOpWhenTheFileIsAlreadyGone() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLogURL.path))
        XCTAssertEqual(ProcessCPULegacyLogCleanup.removeLegacyLogIfPresent(at: legacyLogURL), 0)
    }

    // MARK: - Live sampling path

    func testSamplerBuildsSnapshotFromTallyWithoutWritingTheLegacyLog() async throws {
        let sampler = ProcessCPULogSampler(logsDirectoryURL: logsDirectoryURL)

        // The first tick only primes the per-PID baselines; the second produces a real entry.
        _ = await sampler.sampleAndMaybeLoadSnapshot(
            windowDuration: 3_600,
            expectedIntervalSeconds: 1,
            shouldBuildSnapshot: true
        )
        try await Task.sleep(nanoseconds: 250_000_000)
        let snapshot = await sampler.sampleAndMaybeLoadSnapshot(
            windowDuration: 3_600,
            expectedIntervalSeconds: 1,
            shouldBuildSnapshot: true
        )

        let unwrappedSnapshot = try XCTUnwrap(snapshot)
        XCTAssertTrue(
            unwrappedSnapshot.hasRenderableMemoryData,
            "The in-memory tally must still feed the snapshot once the log write is gone"
        )
        XCTAssertGreaterThan(unwrappedSnapshot.sampleDurationSeconds, 0)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyLogURL.path),
            "Sampling must not create \(ProcessCPULegacyLogCleanup.legacyLogFileName)"
        )
        XCTAssertGreaterThan(
            try fileSizeBytes(at: tallyURL),
            0,
            "The tally file remains the sampler's only on-disk state"
        )
    }

    func testResetClearsTallyStateAndReclaimsALegacyLogLeftOnDisk() async throws {
        let sampler = ProcessCPULogSampler(logsDirectoryURL: logsDirectoryURL)

        _ = await sampler.sampleAndMaybeLoadSnapshot(
            windowDuration: 3_600,
            expectedIntervalSeconds: 1,
            shouldBuildSnapshot: true
        )
        try await Task.sleep(nanoseconds: 250_000_000)
        _ = await sampler.sampleAndMaybeLoadSnapshot(
            windowDuration: 3_600,
            expectedIntervalSeconds: 1,
            shouldBuildSnapshot: true
        )
        XCTAssertGreaterThan(try fileSizeBytes(at: tallyURL), 0)

        // Simulate a legacy file that survived into this install (restored backup, downgrade/upgrade).
        try Data(repeating: UInt8(ascii: "{"), count: 4_096).write(to: legacyLogURL)

        _ = await sampler.resetAndLoadSnapshot(windowDuration: 3_600, expectedIntervalSeconds: 1)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyLogURL.path),
            "resetSampler must reclaim the retired log rather than rewrite it"
        )
        XCTAssertEqual(
            try fileSizeBytes(at: tallyURL),
            0,
            "resetSampler must still truncate the tally state file"
        )
    }
}
