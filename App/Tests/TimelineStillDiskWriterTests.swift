import XCTest
import Shared
@testable import App

final class TimelineStillDiskWriterTests: XCTestCase {
    private func makeCapturedFrame(marker: UInt8) -> CapturedFrame {
        CapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(marker)),
            imageData: Data(repeating: marker, count: 16),
            width: 2,
            height: 2,
            bytesPerRow: 8,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Frame \(marker)",
                browserURL: "https://example.com/\(marker)",
                displayID: 1
            )
        )
    }

    func testTimelineStillDiskWriterDropsBackloggedFramesAndKeepsNewestPendingFrame() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillDiskWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let writer = TimelineStillDiskWriter(
            bufferLimit: 1,
            destinationResolver: { frameID in
                outputDirectory.appendingPathComponent("\(frameID).jpg")
            },
            encoder: { frame in
                Thread.sleep(forTimeInterval: 0.05)
                return frame.imageData
            },
            warningLogger: { _ in }
        )

        for marker in UInt8(1)...5 {
            await writer.enqueue(frameID: Int64(marker), frame: makeCapturedFrame(marker: marker))
        }

        await writer.shutdown()

        let diagnostics = await writer.diagnosticsSnapshot()
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        XCTAssertGreaterThanOrEqual(diagnostics.droppedCount, 1)
        XCTAssertEqual(diagnostics.failureCount, 0)
        XCTAssertEqual(diagnostics.terminatedEnqueueCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.writtenCount, 2)
        XCTAssertLessThanOrEqual(fileURLs.count, 2)

        let newestFrameURL = outputDirectory.appendingPathComponent("5.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newestFrameURL.path))
        XCTAssertEqual(try Data(contentsOf: newestFrameURL), Data(repeating: 5, count: 16))
    }

    private func makeStill(in directory: URL, name: String, bytes: Int, ageSeconds: TimeInterval, now: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ageSeconds)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStillSweepTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testSweepRemovesStillsPastMaximumAgeAndKeepsYoungerOnes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()

        let old = try makeStill(in: directory, name: "1.jpg", bytes: 100, ageSeconds: 3 * 3600, now: now)
        let recent = try makeStill(in: directory, name: "2.jpg", bytes: 100, ageSeconds: 15 * 60, now: now)
        let unrelated = try makeStill(in: directory, name: "notes.jpg", bytes: 100, ageSeconds: 3 * 3600, now: now)

        let retention = TimelineStillDiskWriter.Retention(directoryURL: directory, maximumBytes: 1_000_000)
        let result = TimelineStillDiskWriter.sweep(retention, now: now)

        XCTAssertEqual(result.removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testSweepEnforcesByteCapOldestFirstButSparesStillsYoungerThanMinimumAge() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()

        let oldest = try makeStill(in: directory, name: "10.jpg", bytes: 4096, ageSeconds: 18 * 60, now: now)
        let middle = try makeStill(in: directory, name: "11.jpg", bytes: 4096, ageSeconds: 15 * 60, now: now)
        let fresh1 = try makeStill(in: directory, name: "12.jpg", bytes: 4096, ageSeconds: 60, now: now)
        let fresh2 = try makeStill(in: directory, name: "13.jpg", bytes: 4096, ageSeconds: 30, now: now)

        let retention = TimelineStillDiskWriter.Retention(directoryURL: directory, maximumBytes: 1)
        let result = TimelineStillDiskWriter.sweep(retention, now: now)

        XCTAssertEqual(result.removedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh2.path))
    }

    func testSweepStopsAtByteCapWithoutRemovingMoreThanNeeded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()

        let oldest = try makeStill(in: directory, name: "20.jpg", bytes: 4096, ageSeconds: 18 * 60, now: now)
        let newer = try makeStill(in: directory, name: "21.jpg", bytes: 4096, ageSeconds: 15 * 60, now: now)
        let sizes = try [oldest, newer].map {
            Int64(try $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 4096)
        }

        let retention = TimelineStillDiskWriter.Retention(directoryURL: directory, maximumBytes: sizes[1])
        let result = TimelineStillDiskWriter.sweep(retention, now: now)

        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.remainingBytes, sizes[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
    }

    func testWriterSweepsStaleStillsOnFirstWrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = try makeStill(in: directory, name: "1.jpg", bytes: 100, ageSeconds: 3 * 3600, now: Date())

        let writer = TimelineStillDiskWriter(
            bufferLimit: 4,
            retention: .init(directoryURL: directory),
            destinationResolver: { directory.appendingPathComponent("\($0).jpg") },
            encoder: { $0.imageData },
            warningLogger: { _ in }
        )
        await writer.enqueue(frameID: 99, frame: makeCapturedFrame(marker: 9))
        await writer.shutdown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("99.jpg").path))
    }
}
