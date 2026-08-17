import XCTest
import Foundation
import SQLCipher
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║            FTS deleteForFrame TESTS (issue-38: FTSQueries.swift:323)          ║
// ║                                                                              ║
// ║  deleteForFrame prepared its "is this docid still referenced?" statement      ║
// ║  inside the per-docid loop, re-parsing and re-planning the same SQL for       ║
// ║  every docid. It is itself called once per frame by the retention purge       ║
// ║  (FrameQueries.deleteFramesByIDs), so the parse cost multiplied out across    ║
// ║  every frame in a purge. Profiling the app's startup burst showed             ║
// ║  sqlite3Prepare / sqlite3RunParser / sqlite3LockAndPrepare among the hottest  ║
// ║  symbols -- SQL being parsed, not executed.                                   ║
// ║                                                                              ║
// ║  These tests pin the behaviour that must not change (a docid is only removed  ║
// ║  from the FTS table once nothing references it) and record the parse cost.    ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class FTSDeleteForFrameTests: XCTestCase {

    private var db: OpaquePointer!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("fts_delete_\(UUID().uuidString).sqlite").path

        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        db = handle

        exec("CREATE TABLE doc_segment (docid INTEGER NOT NULL, frameId INTEGER NOT NULL);")
        // Mirrors production's index_doc_segment_on_docid_frameid. Without it the
        // "still referenced?" lookup degrades to a full table scan, which swamps the
        // statement-preparation cost this test set is measuring and makes the
        // benchmark unrepresentative of the real schema.
        exec("CREATE INDEX index_doc_segment_on_docid_frameid ON doc_segment(docid, frameId);")
        exec("CREATE VIRTUAL TABLE searchRanking USING fts5(mainText);")
    }

    override func tearDownWithError() throws {
        if db != nil { sqlite3_close(db) }
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Behaviour that must hold                          │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// The whole point of the per-docid loop: an FTS row is only removed once no
    /// remaining frame references it. Losing this would silently destroy search
    /// content that other frames still point at.
    func testDeleteForFrame_RemovesOnlyOrphanedDocids() throws {
        // docid 10 belongs to frame 1 alone. docid 11 is shared with frame 2.
        insertFTSRow(rowid: 10, text: "orphan after the delete")
        insertFTSRow(rowid: 11, text: "still referenced by frame 2")
        exec("INSERT INTO doc_segment (docid, frameId) VALUES (10, 1), (11, 1), (11, 2);")

        try FTSQueries.deleteForFrame(db: db, frameId: 1)

        XCTAssertEqual(scalar("SELECT COUNT(*) FROM doc_segment WHERE frameId = 1;"), 0,
                       "Junction rows for the deleted frame must be gone")
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM doc_segment WHERE frameId = 2;"), 1,
                       "Another frame's junction rows must survive")
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM searchRanking WHERE rowid = 10;"), 0,
                       "An orphaned docid must be removed from the FTS table")
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM searchRanking WHERE rowid = 11;"), 1,
                       "A docid still referenced by another frame must be retained")
    }

    func testDeleteForFrame_NoDocidsIsANoOp() throws {
        insertFTSRow(rowid: 10, text: "untouched")
        exec("INSERT INTO doc_segment (docid, frameId) VALUES (10, 1);")

        try FTSQueries.deleteForFrame(db: db, frameId: 999)

        XCTAssertEqual(scalar("SELECT COUNT(*) FROM doc_segment;"), 1)
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM searchRanking;"), 1)
    }

    /// Many docids on one frame is the shape the hoisted statement is reused across.
    func testDeleteForFrame_HandlesManyDocidsAndRepeatedCalls() throws {
        let docidCount = 200
        for docid in 1...docidCount {
            insertFTSRow(rowid: Int64(docid), text: "row \(docid)")
            exec("INSERT INTO doc_segment (docid, frameId) VALUES (\(docid), 1);")
        }
        // Pin every other docid to a second frame so both loop branches are taken.
        for docid in stride(from: 2, through: docidCount, by: 2) {
            exec("INSERT INTO doc_segment (docid, frameId) VALUES (\(docid), 2);")
        }

        try FTSQueries.deleteForFrame(db: db, frameId: 1)

        XCTAssertEqual(scalar("SELECT COUNT(*) FROM searchRanking;"), Int64(docidCount / 2),
                       "Only the docids no longer referenced should be removed")
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM searchRanking WHERE rowid = 1;"), 0,
                       "Odd docids were orphaned")
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM searchRanking WHERE rowid = 2;"), 1,
                       "Even docids are still referenced by frame 2")

        // Calling again must be safe and must not disturb the surviving rows.
        try FTSQueries.deleteForFrame(db: db, frameId: 1)
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM searchRanking;"), Int64(docidCount / 2))
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                            Measurement                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// Isolates exactly what changed: preparing the same statement once per docid
    /// versus preparing it once and resetting it. This is the parse cost the
    /// startup profile was dominated by, measured directly rather than inferred.
    func testStatementReuse_AvoidsPerDocidParseCost() throws {
        let rows = 2000
        for docid in 1...rows {
            exec("INSERT INTO doc_segment (docid, frameId) VALUES (\(docid), 7);")
        }
        let sql = "SELECT 1 FROM doc_segment WHERE docid = ? LIMIT 1;"

        // Before: prepare + finalize inside the loop.
        let beforeStart = DispatchTime.now()
        for docid in 1...rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_int64(stmt, 1, Int64(docid))
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        let beforeMs = Double(DispatchTime.now().uptimeNanoseconds - beforeStart.uptimeNanoseconds) / 1_000_000

        // After: prepare once, reset per iteration.
        let afterStart = DispatchTime.now()
        var reused: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &reused, nil), SQLITE_OK)
        for docid in 1...rows {
            sqlite3_reset(reused)
            sqlite3_clear_bindings(reused)
            sqlite3_bind_int64(reused, 1, Int64(docid))
            _ = sqlite3_step(reused)
        }
        sqlite3_finalize(reused)
        let afterMs = Double(DispatchTime.now().uptimeNanoseconds - afterStart.uptimeNanoseconds) / 1_000_000

        print("""
        [issue-38 FTSQueries:323] statement prepares for \(rows) docids
          before: \(String(format: "%.2f", beforeMs)) ms (\(rows) prepares)
          after:  \(String(format: "%.2f", afterMs)) ms (1 prepare + \(rows) resets)
          reduction: \(String(format: "%.1f", (1 - afterMs / beforeMs) * 100))% \
        (\(String(format: "%.1f", beforeMs / afterMs))x)
        """)

        XCTAssertLessThan(
            afterMs, beforeMs,
            "Reusing the statement must beat re-preparing it (before \(beforeMs) ms, after \(afterMs) ms)"
        )
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                           Test Helpers                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    private func exec(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(error) }
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            XCTFail("SQL failed: \(sql) — \(error.map { String(cString: $0) } ?? "unknown")")
        }
    }

    private func insertFTSRow(rowid: Int64, text: String) {
        exec("INSERT INTO searchRanking (rowid, mainText) VALUES (\(rowid), '\(text)');")
    }

    private func scalar(_ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("Could not prepare: \(sql)")
            return -1
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(stmt, 0)
    }
}
