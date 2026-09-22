import Foundation
import XCTest
import Shared
@testable import Storage

/// Covers the compressed WAL payload format:
/// - a stored frame is compressed on disk and decodes back byte-for-byte
/// - pre-existing raw BGRA records (legacy layout, identical header) read unchanged
/// - a record carrying the compressed signature that fails to decode is rejected
///   at the WAL boundary instead of being returned as an undersized "raw" frame
/// - when compression would not shrink a frame, it is stored raw (fallback)
final class WALManagerCompressedPayloadTests: XCTestCase {
    private var walRoot: URL!

    override func setUp() {
        super.setUp()
        walRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wal-compressed-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let walRoot {
            try? FileManager.default.removeItem(at: walRoot)
        }
        super.tearDown()
    }

    // MARK: - Compressed round-trip

    func testStoredFrameIsCompressedAndDecodesBackToBGRA() async throws {
        let wal = WALManager(walRoot: walRoot)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 1))
        let frame = Self.makeGradientFrame(width: 64, height: 64, seed: 30)

        try await wal.appendFrame(frame, to: &session)

        let framesSize = try Self.fileSize(session.framesURL)
        XCTAssertGreaterThan(framesSize, 0)
        XCTAssertLessThan(
            framesSize,
            frame.imageData.count,
            "frames.bin should hold a compressed payload, not raw BGRA"
        )

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.width, 64)
        XCTAssertEqual(read.height, 64)
        XCTAssertEqual(read.bytesPerRow, frame.bytesPerRow)
        XCTAssertEqual(read.imageData, frame.imageData, "lossless: decoded pixels must be byte-identical")
        XCTAssertEqual(read.metadata.appBundleID, frame.metadata.appBundleID)
        XCTAssertEqual(read.metadata.windowName, frame.metadata.windowName)
    }

    // MARK: - Backward compatibility

    func testLegacyRawRecordStillReadsUnchanged() async throws {
        let wal = WALManager(walRoot: walRoot)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 2))

        // A raw record as written by the previous (uncompressed) implementation.
        // Deliberately padded bytesPerRow so we can prove the raw path preserves it.
        let width = 8, height = 4, bytesPerRow = 40
        let raw = Data((0..<(bytesPerRow * height)).map { UInt8($0 % 251) })
        try Self.writeRecord(
            to: session.framesURL,
            payload: raw,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.imageData, raw, "raw payload must be returned byte-for-byte")
        XCTAssertEqual(read.width, width)
        XCTAssertEqual(read.height, height)
        XCTAssertEqual(read.bytesPerRow, bytesPerRow, "raw path must preserve the original bytesPerRow")
    }

    // MARK: - Malformed records

    func testCorruptCompressedRecordIsRejected() async throws {
        let wal = WALManager(walRoot: walRoot)
        let session = try await wal.createSession(videoID: VideoSegmentID(value: 3))

        // Carries the compressed signature and is not raw-sized, but is not valid LZ4.
        var corrupt = Data(WALManager.walLZ4Magic)
        corrupt.append(Data(repeating: 0x5A, count: 97))
        try Self.writeRecord(
            to: session.framesURL,
            payload: corrupt,
            width: 64,
            height: 64,
            bytesPerRow: 64 * 4
        )

        do {
            _ = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
            XCTFail("a corrupt compressed record must be rejected, not returned as a raw frame")
        } catch {
            // expected: rejected at the WAL boundary
        }
    }

    // MARK: - Fallback

    func testFrameThatDoesNotShrinkIsStoredRaw() async throws {
        let wal = WALManager(walRoot: walRoot)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 4))
        // Random pixels are incompressible, so LZ4 output (plus magic) exceeds raw.
        var frame = Self.makeGradientFrame(width: 8, height: 8, seed: 7)
        var rng = SystemRandomNumberGenerator()
        frame = CapturedFrame(
            timestamp: frame.timestamp,
            imageData: Data((0..<frame.imageData.count).map { _ in UInt8.random(in: 0...255, using: &rng) }),
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            metadata: frame.metadata
        )
        XCTAssertNil(WALManager.encodeWALPayload(frame))

        try await wal.appendFrame(frame, to: &session)

        let read = try await wal.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(read.imageData, frame.imageData, "raw fallback must be byte-for-byte")
        XCTAssertEqual(read.bytesPerRow, frame.bytesPerRow)
    }

    // MARK: - Helpers

    /// Blocky BGRA (8px runs, like UI content): at 64x64 (16KB raw) LZ4 output is comfortably smaller than raw.
    private static func makeGradientFrame(width: Int, height: Int, seed: UInt8) -> CapturedFrame {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    base[offset] = UInt8(min(255, (x / 8) * 32)) // B
                    base[offset + 1] = UInt8(min(255, (y / 8) * 32)) // G
                    base[offset + 2] = seed                   // R
                    base[offset + 3] = 255                    // A
                }
            }
        }
        return CapturedFrame(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            imageData: data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "Example",
                windowName: "Window \(seed)",
                browserURL: nil,
                displayID: 1
            )
        )
    }

    /// Writes one record in the on-disk layout: 36-byte header (native endianness,
    /// same field order as WALFrameHeader), no metadata strings, then the payload.
    /// dataSize is the payload length, so a raw-sized payload reads as raw and any
    /// other size is treated as compressed.
    private static func writeRecord(
        to framesURL: URL,
        payload: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws {
        var record = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { record.append(contentsOf: $0) }
        }
        append(Double(1_700_000_000))   // timestamp
        append(UInt32(width))
        append(UInt32(height))
        append(UInt32(bytesPerRow))
        append(UInt32(payload.count))   // dataSize
        append(UInt32(1))               // displayID
        append(UInt16(0))               // appBundleIDLength
        append(UInt16(0))               // appNameLength
        append(UInt16(0))               // windowNameLength
        append(UInt16(0))               // browserURLLength
        XCTAssertEqual(record.count, 36, "header must be 36 bytes")
        record.append(payload)
        try record.write(to: framesURL)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
