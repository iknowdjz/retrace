# Intermittent `swift test` stall in `TimelineHeadlessPrerenderStateTests`

**Status:** reproducible, not root-caused. Two hypotheses eliminated.

## Symptom

A full `swift test` run stops advancing. No failure, no timeout, no crash — the run
simply never finishes. Always in `RetraceTests.TimelineHeadlessPrerenderStateTests`,
always late in the run (observed at 934, 951 and ~960 completed tests), and only ever
while the machine was under heavy load.

## Reproducer

It does not reproduce on an idle machine — five consecutive clean attempts. Saturate
the CPU first and it appears in roughly one run in five to seven:

```bash
# 16 spinners on an 18-core machine, then the suite in a loop; sample the moment
# the test output stops growing for 90s.
for _ in $(seq 1 16); do ( while :; do :; done ) & done
swift test > run.log 2>&1 &
# ...poll run.log; when it stops growing:
sample "$(pgrep -f 'xctest.*RetracePackageTests')" 5 -f stall.txt
```

**Two traps when doing this.** A stalled `xctest` survives as an orphan (`ppid` 1)
after its `swift test` driver is killed, so `pgrep | head -1` will happily hand you a
*previous* run's wedged process and you will sample the wrong thing — match on the
`.build` path, or kill orphans between runs. And the run's own log file is the only
trustworthy stall signal, since the orphan makes process-based checks ambiguous.

## What the samples show

Sampled at both `d279a53` (pre-`MemoryLedger`-bound) and `e22d807` (post). The
signature is identical at both.

- The process is **~99.8% idle**: 4,342 samples over 5s, fewer than 10 showing any
  work at all. Every worker thread sits in `__workq_kernreturn`.
- The main thread is parked in `+[XCTWaiter _synchronouslyWaitForTimeInterval:]`,
  i.e. XCTest waiting for the async test method to return. It never does.
- The only live activity is `ProcessingExtractMemoryLedger`'s settled-residual probe:
  `ExtractMemoryInstrumentation.swift:874` → `:892` → `synchronizedLedgerSnapshot()`
  → `MemoryLedger.snapshot()`. It re-arms itself every 0.75s (`:929` → `:859`) for as
  long as the residual stays above zero, so it keeps the process breathing without
  advancing anything.

This is a **lost wakeup**, not a backlog or a livelock.

## Eliminated

1. **Not a pending-write backlog.** The prior leading hypothesis was
   `MemoryLedger.flushPendingUpdates()` awaiting an unbounded chain. A backlog would
   show busy workers; the workers are idle. Bounding that chain (`e22d807`) also did
   not stop the stall — it still reproduced at HEAD with the same signature.
2. **Not the test body.** `testReadyFrameEvictsExternalStillAndUsesDecodedPath` and
   `testShiftDragOnProcessingStatus4FrameRunsTransientStillOCR` (both observed) use
   bounded polls of 50 x 10ms. Neither can hang on its own; the suspension is at the
   async-test boundary.
3. **Not the real database.** Checked previously: `DatabaseManager.init` only stores a
   lazy connection factory, and `lsof` confirmed the real DB is never opened.

## Where to look next

The test method is suspended and never resumed while the cooperative pool is idle.
Candidates not yet excluded: the `Task.sleep(for:clock: .continuous)` resumption path
under load; main-actor isolation of `SimpleTimelineViewModel` interacting with the
CFRunLoop that `XCTWaiter` spins; or the 19 real `AppCoordinator()` instances the
class constructs leaving background work alive across tests.
