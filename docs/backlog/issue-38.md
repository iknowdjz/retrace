title:	Performance & disk-space follow-ups (Fable 5 sweep, verified)
state:	OPEN
author:	grub-basket
labels:	
comments:	0
assignees:	
projects:	
milestone:	
number:	38
--
# Performance & disk-space follow-ups

Companion to the security tracking issue (#35). A **Fable 5** fleet swept the tree for perf wins and disk-space savings; each was independently verified. Already turned into PRs: **#37** (JPEG encode via `CGImageDestination`) and **#36** (dead-code removal).

> **📌 Maintainer — happy to split this up. This is one tracking issue for convenience, but I can file each candidate (or each area) as its own individually-trackable issue, or turn any of the 🟢 safe ones directly into PRs — just let me know.**


## ⚠️ Disclosure / verification status
**None of these are build-verified** — the review environment could not compile the macOS/ScreenCaptureKit/SQLCipher build. Legend: ✅ = inefficiency confirmed by reading the code + callers; 🔶 = plausible, confirm before acting. 🟢 = small/localized/clearly-correct by inspection; 🟡 = touches an always-on path / needs a profile or a schema migration, so measure/test before landing. Full per-candidate detail is in the Markdown report going to the maintainer privately.

## Disk-space (6)
- `StorageManager.swift:1090` ✅ — **Temp .mp4 symlinks from decodeAllFrames are never deleted**  
  _Create all decode symlinks under a dedicated app-owned subdirectory, e.g. temporaryDirectory/retrace-video-symlinks/, and (a) remove the symlink in a defer once the AVAssetReader loop finishes (the asset is fully read…_ (risk:low, 🟢 safe to land by inspection)
- `V1_InitialSchema.swift:333` ✅ — **idx_frame_processing_status indexes every frame though queries only target transient statuses**  
  _New migration: `DROP INDEX idx_frame_processing_status; CREATE INDEX idx_frame_processing_status ON frame(processingStatus) WHERE processingStatus != 2;` (verify all consumers filter on non-2 statuses so the partial…_ (risk:low, 🟢 safe to land by inspection)
- `SimpleTimelineViewModel.swift:3403` ✅ — **Timeline disk frame buffer has no size cap while the timeline is open — unbounded growth in Library/Caches**  
  _After the index insert in storeFrameDataInDiskFrameBuffer, if diskFrameBufferBytes exceeds a cap (e.g. 512 MB, matching SearchViewModel.thumbnailDiskCacheMaxBytes), evict timelineManaged entries with the lowest…_ (risk:low, 🟢 safe to land by inspection)
- `SpotlightSearchOverlay.swift:1320` ✅ — **Thumbnail cache key includes the search query, so the same frame is re-extracted and re-stored on disk for every distinct query**  
  _Key by segmentID + timestamp + the highlight rect when result.highlightNode is present (e.g. "seg_ts_x-y-w-h"), and just segmentID + timestamp otherwise. Non-highlighted thumbnails (the common case) then dedupe across…_ (risk:medium, 🟢 safe to land by inspection)
- `Logging.swift:389` ✅ — **Log cap allows up to 100MB on disk (50MB retrace.log + 50MB retrace.old.log)**  
  _Reduce maxFileSize to 10MB (20MB total with the .old file). One-character-class change: `private let maxFileSize: Int64 = 10 * 1024 * 1024`. Diagnostics (getRecentLogs maxCount 200) are unaffected._ (risk:low, 🟢 safe to land by inspection)
- `Schema.swift:105` ✅ — **auto_vacuum pragma is dead code; space reclamation relies on full VACUUM rewrites**  
  _Pick one: (a) actually enable incremental auto-vacuum — run setAutoVacuum before table creation for new DBs (existing DBs need one full VACUUM to convert), then replace routine full VACUUMs with cheap periodic `PRAGMA…_ (risk:medium, 🟡 wants a build/profile or migration)

## Performance (29)
- `WALManager.swift:244` ✅ — **Frame offset index cache invalidated on every WAL append, forcing full-file rescans**  
  _Instead of invalidating, extend the cached index incrementally: in appendFrame, capture the end-of-file offset before writing (fileHandle.seekToEnd() returns it), then append that offset to the cached…_ (risk:medium, 🟢 safe to land by inspection)
- `WALManager.swift:233` ✅ — **metadata.json atomically rewritten and frames.bin FileHandle reopened on every frame append**  
  _Throttle saveMetadata to every N frames (e.g. 30) or on width/height first-set and on finalize/durable-state updates only; recovery rebuild covers the gap. Optionally also cache the frames.bin FileHandle in WALSession…_ (risk:low, 🟢 safe to land by inspection)
- `CaptureManager.swift:857` ✅ — **Full similarity scan computed twice per captured frame**  
  _Compute similarity once: let similarity = lastKeptFrame.map { deduplicator.computeSimilarity(frame, $0) }; then derive keepBySimilarity locally as (lastKeptFrame == nil || frame.width != lastKeptFrame!.width ||…_ (risk:low, 🟢 safe to land by inspection)
- `CGWindowListCapture.swift:1020` ✅ — **Per-capture O(n^2) diagnostic loop and heavy Log.info string building in hot path**  
  _Demote the four Log.info calls at 1014-1017 to Log.debug (or gate behind a verbose flag), and wrap the 1020-1031 per-window detail loop in an 'if Log.isDebugEnabled' guard (or delete it — it duplicates info available…_ (risk:low, 🟢 safe to land by inspection)
- `CGWindowListCapture.swift:376` ✅ — **Full-frame BGRA conversion (~28-60MB alloc) performed before dedup decision**  
  _Two-stage option that avoids a big refactor: in CaptureManager, run the dedup similarity against a cheap downsampled representation first — e.g. add a method on the backend that draws the CGImage into a small (say…_ (risk:medium, 🟢 safe to land by inspection)
- `FTSManager.swift:296` ✅ — **Every FTS search full-scans doc_segment via GROUP BY subquery**  
  _Replace the subquery with a direct join driven by the FTS results: `JOIN doc_segment ds ON ds.docid = searchRanking.rowid` (uses index_doc_segment_on_docid_frameid). The MAX(docid)-per-frame dedupe is already guaranteed…_ (risk:medium, 🟢 safe to land by inspection)
- `ReadConnectionSupport.swift:149` ✅ — **Read-pool connections run with SQLite default 2MB cache and no mmap**  
  _In configureReadOnlyConnection add: `PRAGMA cache_size=-32000;` (32MB per read connection, tune to taste) and `PRAGMA mmap_size=268435456;` (256MB mmap — read-mostly workload benefits and it is shared across…_ (risk:low, 🟢 safe to land by inspection)
- `FTSQueries.swift:323` ✅ — **Per-row statement prepare inside docid orphan-check loop**  
  _Hoist the stillReferencedSQL prepare above the loop (like contentStatement at lines 298-309) and use sqlite3_reset/sqlite3_clear_bindings per iteration._ (risk:low, 🟢 safe to land by inspection)
- `FrameProcessingQueue.swift:2276` ❌ **MEASURED AND REJECTED (2026-08-17)** — **Redaction phrases re-loaded and re-normalized from UserDefaults on every frame**  
  _The per-frame prologue is `UserDefaults(suiteName:)` + one `string(forKey:)` that misses when no
  phrases are configured (the default, and this install's state). Measured over 20,000 iterations:
  **0.00063 ms/frame** — 0.0001% of the 655.8 ms mean frame OCR. Caching it would be measuring
  nothing. Revisit only if a user configures a large phrase list, where the JSON decode and
  normalisation actually run._  
  _Cache `[NormalizedPhraseRedactionPhrase]` (plus the enabled flag) in the FrameProcessingQueue actor, keyed by the raw defaults string; on each frame, read only the raw string (or subscribe to…_ (risk:low, 🟢 safe to land by inspection)
- `FrameProcessingQueue.swift:2130` ✅ — **Fuzzy token overlap allocates filter+sort inside triple-nested matching loop**  
  _Precompute the length-descending sorted token array for `rhs` once per call (it doesn't change), and track consumed tokens with the existing set; iterate the presorted array skipping consumed entries instead of…_ (risk:low, 🟢 safe to land by inspection)
- `SimpleTimelineViewModel.swift:2385` ✅ — **O(n) byte-total reduce runs on every disk-frame-buffer index mutation, including hot-path LRU touches**  
  _Drop the reduce from didSet and maintain diskFrameBufferBytes incrementally: += entry.sizeBytes on insert in storeFrameDataInDiskFrameBuffer/readFrameDataFromDiskFrameBuffer, -= on removal in…_ (risk:low, 🟢 safe to land by inspection)
- `SearchViewModel.swift:734` ✅ — **Full disk-cache directory scan (trimThumbnailDiskCache) runs after every single thumbnail write**  
  _Trim opportunistically: keep the trim in prepareThumbnailDiskCache (already runs at init), and in persistThumbnailToDisk only trim every N writes (e.g. a counter, every 64 writes) or when a running byte estimate crosses…_ (risk:low, 🟢 safe to land by inspection)
- `SimpleTimelineViewModel.swift:3136` ✅ — **Synchronous file deletion loop on the main actor when clearing the disk frame buffer**  
  _In removeDiskFrameBufferEntries, collect the file URLs to delete after updating the index synchronously (index correctness preserved), then delete them in a single Task.detached(priority: .utility). Same for…_ (risk:medium, 🟢 safe to land by inspection)
- `SimpleTimelineViewModel.swift:2482` ✅ — **In-memory JPEG frame cache is count-limited only — up to ~192 full-resolution JPEGs held with no byte budget**  
  _Set cache.totalCostLimit (e.g. 128 * 1024 * 1024) in makeInMemoryJPEGFrameCache and pass cost: data.count in storeInMemoryJPEGFrameData. countLimit can stay as a secondary bound._ (risk:low, 🟢 safe to land by inspection)
- `Logging.swift:56` ✅ — **Every log level (including DEBUG) does synchronous per-line file I/O in release builds**  
  _In release builds, skip stdout+file writes for DEBUG-level logs (wrap the printToConsole default in #if DEBUG, or add an early `guard level != .debug || isDebugBuild` in printFormatted). Keep INFO and above in the file…_ (risk:low, 🟢 safe to land by inspection)
- `RetentionManager.swift:231` ✅ — **cleanupOrphanedNodes runs a full-table anti-join scan every hourly cleanup even when zero frames were deleted**  
  _Guard step 5: only call cleanupOrphanedNodes() when deletedFrameCount > 0 (frames are the only thing deleted in this pass that can orphan nodes). Optionally also run it once at startup to catch historical orphans._ (risk:low, 🟢 safe to land by inspection)
- `AppCoordinator.swift:574` ✅ — **DB storage snapshot task runs a DB write + read query + Log.info every 60s forever**  
  _Raise the interval to 15 minutes (900_000_000_000) — still 96 samples/day for a daily-resolution table — and/or only Log.info when the delta summary is non-zero, using Log.debug otherwise. Keep the initialize/shutdown…_ (risk:low, 🟢 safe to land by inspection)
- `AppCoordinator.swift:1557` ✅ — **Orphaned-video cleanup polls WAL sessions + DB every 60 seconds for the life of the app**  
  _Keep an initial pass shortly after startup (when orphans from a previous crash actually exist), then raise the steady-state interval to 10 minutes: `let cleanupInterval: UInt64 = 600_000_000_000`. Worst case an orphan…_ (risk:medium, 🟢 safe to land by inspection)
- `SimpleTimelineViewModel.swift:10572` ✅ — **Full-resolution frame JPEG decode via NSImage(data:) on the main actor during scrubbing**  
  _Decode off-main: in a Task.detached, use CGImageSourceCreateWithData + CGImageSourceCreateImageAtIndex with kCGImageSourceShouldCacheImmediately: true to force decompression, then wrap the resulting CGImage (which is…_ (risk:medium, 🟡 wants a build/profile or migration)
- `SearchManager.swift:115` ✅ — **N+1 sequential database.getFrame per FTS match on every search**  
  _Add a batched database.getFrames(ids: [FrameID]) -> [FrameID: FrameRef] (single WHERE id IN (...) query) and build results from the returned map; or better, have ftsEngine.search return segmentID in the match row via a…_ (risk:medium, 🟡 wants a build/profile or migration)
- `FrameProcessingQueue.swift:992` ✅ — **enqueueBatch issues one DB call (and transaction) per frame**  
  _Add a DatabaseManager batch API (single transaction inserting all queue rows / one `UPDATE ... WHERE frame_id IN (...)` for status changes) and call it from enqueueBatch and markVideoRewritePlanStatus. Falls back to the…_ (risk:low, 🟡 wants a build/profile or migration)
- `FrameProcessingQueue.swift:1346` ❌ **MEASURED AND REJECTED (2026-08-17)** — **Per-frame memory-ledger snapshots dominate OCR queue overhead**  
  _Measured, not assumed. `OCRStageMemoryLedgerCostTests` mirrors the exact per-frame sequence
  (residual epoch + 4 `MemoryLedger.snapshot(waitForPendingUpdates:)` + the `setResidual` writes)
  against a production-sized 49-component ledger: **0.87 ms/frame** idle, **0.85 ms/frame** with a
  concurrent writer. The denominator comes from the live app's own log — 1,255 real OCR'd frames,
  **mean 667 ms/frame** (median 440 ms, p90 1.60 s). The ledger is therefore **0.13% of OCR time**;
  at the observed 589 frames/hour, gating it saves 0.51 s/hour, or 0.014% of one core. The premise
  "dominates OCR queue overhead" is false. Not worth the risk to an always-on path._  
  _Add a single cached instrumentation-enabled flag (e.g. `retrace.debug.ocrMemoryLedgerEnabled` UserDefaults read once, same pattern as OCRMemoryBackpressurePolicy). In performOCRStage and VisionOCR, when disabled: skip…_ (risk:low, 🟡 wants a build/profile or migration)
- `FrameQueries.swift:1218` ✅ — **N+1 per-frame delete loop in retention purge path**  
  _Batch by chunks of ~500 IDs: `SELECT docid FROM doc_segment WHERE frameId IN (...)`, `DELETE FROM doc_segment WHERE frameId IN (...)`, `DELETE FROM searchRanking WHERE rowid IN (...docids not still referenced...)`,…_ (risk:medium, 🟡 wants a build/profile or migration)
- `CGWindowListCapture.swift:964` ✅ — **CGWindowListCopyWindowInfo called twice per capture when any exclusion exists**  
  _Have computeExcludedWindowIDs return the windowList it already fetched inside ExclusionComputationResult (or pass it alongside), and change captureWithFiltering(displayID:excludedWindowIDs:forceMasking:) to accept the…_ (risk:low, 🟡 wants a build/profile or migration)
- `Logging.swift:454` 🔶 plausible — **readLastLines loads the entire (up to 50MB) log file into memory while holding the logging lock**  
  _Seek to max(0, fileSize - N) with a FileHandle and read only the tail chunk (e.g. 256KB — far more than 200 lines), decode, drop the first partial line, then split. Keeps the same signature and lock discipline._ (risk:low, 🟢 safe to land by inspection)
- `SimpleTimelineViewModel.swift:3371` 🔶 plausible — **Synchronous FileManager.fileExists on the main actor in the per-frame disk-buffer read path**  
  _Delete the fileExists pre-check and let the detached Data(contentsOf:) attempt fail; map ENOENT-style errors to the existing 'read missing file' removal path and other errors to 'read failure'. For line 10534, check…_ (risk:low, 🟡 wants a build/profile or migration)
- `FrameProcessingQueue.swift:1607` ❌ **PREMISE DISPROVED (2026-08-17)** — **Full BGRA re-render of every JPEG frame before OCR (double image materialization)**  
  _There is no double materialization. `convertJPEGToCapturedFrame` passes
  `kCGImageSourceShouldCacheImmediately: false`, so `CGImageSourceCreateImageAtIndex` does no
  decoding — the decode is deferred into the `context.draw`. Measured at 3440x1440, 10 runs:
  lazy = 0.11 ms decode + 19.22 ms draw; forcing the decode up front
  (`ShouldCacheImmediately: true`) = 10.12 ms decode + 7.41 ms draw. Same total work, just
  attributed differently. The image is materialized exactly once, and both Vision and
  `TileChangeDetector` need those pixels, so there is nothing to remove — only ~19 ms of
  unavoidable JPEG-to-pixels cost (~3% of frame OCR time)._  
  _Carry the decoded CGImage alongside (or instead of) the raw Data in CapturedFrame for the queue path, pass it straight to VNImageRequestHandler(cgImage:), and derive the change-detection buffer from a downscaled draw…_ (risk:medium, 🟡 wants a build/profile or migration)
- `FrameProcessingQueue.swift:2543` 🔶 plausible — **Phrase redaction sliding window materializes candidate sets/strings for every token position**  
  _Add a cheap pre-filter: skip a window start unless the token at `start` matches (or prefix-matches) the phrase's first token, and compute the node-order span incrementally instead of building a Set per window (node…_ (risk:medium, 🟡 wants a build/profile or migration)
- `HEVCEncoder.swift:540` 🔶 plausible — **Three filesystem stat calls per encoded frame on the encode hot path**  
  _Keep the size stat at line 546 (it drives durable-frontier tracking) but drop the two fileExists calls, or gate the deletion check to every ~30 frames / once per fragment. A deleted file is still caught by the size stat…_ (risk:medium, 🟡 wants a build/profile or migration)

### ⭐ Found by measurement, not in the original sweep (2026-08-17)
- `VisionOCR.swift:591` ✅ **LANDED** — **Region OCR paid for Vision's language-correction pass on every frame**  
  _The full-frame path already hardcoded `usesLanguageCorrection: false`; the region path — the one
  production actually uses (1,121 of 1,255 frames, mean 655.8 ms) — passed
  `ocrAccuracyLevel == .accurate`, i.e. always true. Measured **27.9% faster** with it off
  (1778.4 → 1283.0 ms on a 24-region frame) at **identical search-token recall** (35/36 code, 36/36
  prose) and slightly *more* text recognised. ~3.0% of one core, freed continuously. Now
  `ProcessingConfig.ocrLanguageCorrectionEnabled`, default off._

### Steady-state cost, measured (2026-08-17)
From the live app's own log, 1,255 real frames over ~2.13 h: OCR is **10.9% of one core**
(mean 667 ms/frame, median 440 ms, p90 1.60 s). Over three days that is ~471 CPU-minutes —
most of the 676 CPU-minutes that prompted this work. **OCR is the cost centre**; the ledger,
UserDefaults and image-conversion candidates above are all under 5% of it combined.

### Highest-impact picks (suggested order)
1. `WALManager.swift:233/244` — the always-on WAL write path rewrites `metadata.json` (atomic temp+rename) **and** rebuilds the full frame-offset index on **every captured frame** (O(n²) syscall traffic). Throttle metadata saves + extend the offset index incrementally. 🟡
2. `StorageManager.swift:1090` — temp `.mp4` decode symlinks never deleted; dedicated dir + startup sweep (also security finding #36).
3. `CGWindowListCapture.swift:376` — ~28–60 MB full-frame BGRA conversion done *before* the dedup decision; do it after. 🟡
4. `SimpleTimelineViewModel.swift:3403` / `Logging.swift:389` — timeline disk-buffer uncapped; log cap allows 100 MB. Add caps. 🟢

🤖 Filed via [Claude Code](https://claude.com/claude-code)
