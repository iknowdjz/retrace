# Retrace stability fork — kickoff prompt

Paste the block below into a fresh Claude Code session started in
`/Users/zachmoss/Developer/codeProjects/retrace`.

---

You are working on a **fork of [haseab/retrace](https://github.com/haseab/retrace)** (MIT),
a macOS screen-recording / searchable-timeline app. Upstream's last commit was
**2026-06-04** and eight PRs have sat unmerged since **2026-07-09**, so we are maintaining
our own line. Branch **`stability`** already has all eight upstream PRs merged cleanly
(#29–#33, #36, #37, #39). `main` tracks upstream.

## The goal

Make this build **stable and cheap enough to run all day** on a heavily loaded Mac. It is
the daily driver — it must keep working, so correctness beats cleverness everywhere.

## Why — the real-world failure, measured

On a 64 GB M4 Max running ~180 Chrome processes and a dozen editors, Retrace:

- burned **676 CPU-minutes in ~3 days**, and sat at **404% CPU** for minutes after launch
- **froze its own main thread** and self-quit via its watchdog. Its emergency diagnostics
  (`~/Library/Application Support/Retrace/crash_reports/`) caught the machine at
  `Memory Pressure: critical (1% free pages)`, `Swap: 55.0 / 56.0 GB`, and
  `Main thread probe: NO RESPONSE after 50ms (main thread is FROZEN)`
- did this repeatedly: 20 crash reports, clustered on the days the machine was busiest

Retrace is **not** the machine's memory hog (≈150 MB compressed of a 71 GB total). It is a
**CPU and allocation-churn** problem, and it wedges when the machine is already stressed.
So the bar is: *reduce per-frame CPU and per-frame allocation, and never block the main
thread on I/O.* Do not chase resident-memory reduction — that is not where the pain is.

## The backlog

`docs/backlog/issue-38.md` — **35 verified candidates** (6 disk-space, 29 performance) from
a prior review sweep, each with file:line, a diagnosis, and a proposed fix. Legend in the
doc: ✅ = confirmed by reading code + callers, 🔶 = plausible/confirm first, 🟢 = safe by
inspection, 🟡 = touches an always-on path or needs a migration.

**Start with these five — they are the ones that map directly to the measured symptom:**

1. `CGWindowListCapture.swift:376` — full-frame **BGRA conversion (~28–60 MB alloc)** runs
   *before* the dedup decision, so it allocates that for frames it then discards. Biggest
   single win; the issue proposes dedup against a cheap downsample first.
2. `CaptureManager.swift:857` — full similarity scan computed **twice** per captured frame.
3. `CGWindowListCapture.swift:1020` — per-capture **O(n²) diagnostic loop** plus eager
   `Log.info` string building in the hot path.
4. `WALManager.swift:233` — `metadata.json` atomically rewritten **and** the `frames.bin`
   FileHandle reopened **on every frame append**.
5. `SimpleTimelineViewModel.swift:3403` — timeline disk frame buffer has **no size cap**,
   growing without bound in `Library/Caches`.

Then work the rest of issue-38 in risk order (🟢 before 🟡).

Also read `docs/backlog/issue-35.md` (security tracking) and `docs/backlog/issue-34.md`
(pixel redaction is reversible obfuscation, not encryption) — **34 is a real security bug,
not a perf item.** Fix it only deliberately and with tests; do not fold it into a perf commit.

## Reported by others — worth reproducing

From upstream issues and <https://feedback.worklouder.cc>-style reports on the Retrace
tracker: timeline windows not closing across displays, low-storage banner not updating,
FTS search failing when encryption is on (PR #30 addresses this), and IME composition being
eaten in spotlight search (PR #39). Confirm each still reproduces on `stability` before
spending time on it — several may already be fixed by the merged PRs.

## Build

Toolchain is already installed and verified working (xcodegen present, Xcode 26.6, target
macOS 13, Swift 5.9). Dependencies are pure SPM — Sparkle 2.8.1 and
skiptools/swift-sqlcipher 1.7.0 — so there is **no system SQLCipher to fight**.

```bash
xcodegen generate                 # regenerate Retrace.xcodeproj after touching project.yml
xcodebuild -project Retrace.xcodeproj -scheme Retrace -configuration Debug build
./dev.sh                          # debug build + run with hot reload
./build_and_sign.sh               # release
```

Ignore the `CoreSimulator is out of date` warning from `xcodebuild` — this is a macOS
target and has no simulator.

⚠️ **Check free memory before kicking off a full build.** This machine has been running at
96% swap; a cold whole-module build will spike it. `sysctl vm.swapusage` first.

## Rules

- **Measure, don't assume.** Every perf claim needs a before/after number — Instruments
  (Time Profiler / Allocations) or a counter you add. "Should be faster" is not a result.
- **The capture path is always-on.** A regression there costs the user their timeline. Any
  change to capture/dedup/WAL gets a test or a documented manual verification.
- **Never weaken encryption or redaction to gain speed.** PRs #29–#33 exist because those
  paths were subtly wrong; do not undo them. Redaction must fail *closed*.
- **Schema changes need a migration**, and the DB holds months of the user's real history.
  Back it up before running anything destructive against it.
- One logical change per commit, with the issue-38 bullet referenced in the message.
- Do not push to `upstream`. Push to `origin` only.

## First step

Read `docs/backlog/issue-38.md` in full, then build `stability` clean to confirm a green
baseline before changing anything. Report the build result and your plan for item 1 before
you start editing.
