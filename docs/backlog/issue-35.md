title:	Security & code review: tracking issue (5 PRs + follow-ups)
state:	OPEN
author:	grub-basket
labels:	
comments:	0
assignees:	
projects:	
milestone:	
number:	35
--
# Security & code review — tracking issue

Whole-repo (not just-the-diff) security + code-quality review of Retrace, focused on what matters for an always-on total-recall recorder: **secrets never leaking to logs/disk/network, encryption/redaction that actually holds, correct deletion/retention, no injection.**

## How this was produced
- **Lead pass:** Claude **Opus 4.8** read the crypto/DB core directly (`MasterKeyManager`, `ReversibleOCRScrambler`, DB keying).
- **Fan-out:** **57 Claude Fable 5** subagents swept the tree per-module; **every finding was adversarially re-verified** by an independent agent that tried to refute it. ~215K LOC / 378 Swift files.
- ⚠️ **Could not compile** the macOS/ScreenCaptureKit/SQLCipher build in the review environment. Every linked PR is surgical but **needs a CI/build pass before merge**.

**Headline:** crypto *primitives* are sound (256-bit CryptoKit master key, keychain `ThisDeviceOnly`/non-syncable, AES-GCM for OCR text, checksummed recovery phrase). Risk is in the **plumbing**: a plaintext log everything leaks into (and that's uploaded with feedback), encryption/redaction that fails *open*, and a DB-key lifecycle that can brick or silently disable encryption.

> **📌 Maintainer — happy to split this up. This is a single tracking issue for convenience, but I'm glad to file each finding (or each theme, e.g. the plaintext-logging cluster) as its own separate, individually-trackable issue with its `file:line` references and a scoped fix — just say the word and I'll open them and link back here. Same offer for converting any item straight into a PR.**


## PRs opened against `main` (from `grub-basket:fix/*`)
| PR | Area | |
|----|------|--|
| #29 | **DB key lifecycle** — stop destroying the SQLCipher key on transient Keychain errors; throw + verify instead of silent plaintext fallback | ✅ |
| #30 | **FTS keying** — apply `PRAGMA key` so search works when encryption is on | ✅ |
| #31 | **`SQLITE_TRANSIENT` binds** — 7 sites bound a temporary `NSString.utf8String` with `SQLITE_STATIC` | ✅ |
| #32 | **Key redaction in errors** — `execSQL` leaked `PRAGMA key`/password into thrown/logged error text | ✅ |
| #33 | **Redaction fail-closed** — masking failures returned the *unmasked* frame; now drop it | ✅ |

**Priority:** #29 first (irreversible data loss, unconditional) → #30/#33 → #32/#31.

- **#34** — Pixel "redaction" is reversible obfuscation, not encryption (3 findings). Split out because it needs a redaction-format change + a backlog migration + UI.

## ⚠️ Disclosure / verification status
The findings below are **confirmed but NOT yet fixed** (no PR). To avoid publishing an attacker playbook, each is listed at **summary level** (location + one-line). **Full per-finding failure scenarios and verification evidence are in a Markdown report being sent to the maintainer privately.** ✅ = code-traced & reachable; 🔶 = real but conditional, verify with a repro before fixing. **None of this is build-verified** (see above).

### High — confirmed, unfixed
- `App/AppCoordinator.swift:2290` — **Unencrypted JPEG screenshots persisted to ~/Library/Caches, outside the encrypted store, with no retention enforcement** — ✅ verified
- `Shared/Logging.swift:494` — **User search queries (and captured app names) written to plaintext logs that are uploaded with feedback** — ✅ verified
- `Processing/ProcessingManager.swift:206` — **Accessibility text is read at processing time, not capture time — wrong app's text and metadata attached to queued frames** — ✅ verified
- `UI/Views/Feedback/FeedbackLogSnapshotter.swift:53` — **Feedback submission uploads raw logs containing visited URLs and excluded-app window titles** — ✅ verified
- `Capture/ScreenCapture/PrivateWindowDetector.swift:417` — **Private-window titles, excluded-window titles, redaction patterns, and URL fragments written to plaintext log file** — ✅ verified
- `Storage/SegmentWriterImpl.swift:57` — **Screen recordings are stored unencrypted at rest despite the app advertising encryption** — 🔶 plausible (needs a repro)

### Medium
- `UI/Components/UpdaterManager.swift:240` — **NSAttributedString HTML import (WebKit-backed, main-thread-only) executed on a background task with attacker-influenced appcast HTML** — ✅ verified
- `UI/ViewModels/SimpleTimelineViewModel.swift:11205` — **Full captured browser URLs written to persistent logs that are uploaded in feedback diagnostics** — ✅ verified
- `UI/ViewModels/SimpleTimelineViewModel.swift:11574` — **OCR/DOM-derived URLs opened via NSWorkspace.open with no scheme allowlist** — ✅ verified
- `App/ModelManager.swift:195` — **Model downloads have no checksum/signature verification** — ✅ verified
- `Shared/Logging.swift:93` — **All os_log interpolations forced to privacy: .public, defeating unified-logging redaction** — ✅ verified
- `Search/SearchManager.swift:69` — **Raw search queries and OCR snippet text written to plaintext persistent logs (privacy: .public)** — ✅ verified
- `App/ModelManager.swift:215` — **Downloaded ML models are not integrity-checked (size ±10% only)** — ✅ verified
- `Processing/FrameProcessingQueue.swift:2453` — **Phrase-level redaction silently disabled when master key is unavailable; frames indexed unredacted and marked completed** — ✅ verified
- `Database/DatabaseManager.swift:3727` — **Encryption on/off decided per-launch by an unprotected UserDefaults flag** — ✅ verified
- `Database/FTSManager.swift:423` — **OCR'd screen content (search snippets) logged to plaintext log file in release builds** — ✅ verified
- `App/ModelManager.swift:204` — **ML model downloads have no integrity verification (no checksum or signature)** — ✅ verified
- `UI/Components/FaviconProvider.swift:290` — **Favicon disk cache is a plaintext browsing-history index outside the encrypted store** — ✅ verified
- `UI/Views/Feedback/FeedbackLogSnapshotter.swift:5` — **Feedback upload ships raw capture logs (private-window titles, redaction rules) to the vendor endpoint** — ✅ verified
- `Database/ReadConnectionSupport.swift:131` — **SQLCipher password interpolated unescaped into PRAGMA key SQL** — 🔶 plausible (needs a repro)
- `Search/SearchManager.swift:173` — **getSuggestions interpolates raw user prefix into FTS5 query with no sanitization** — 🔶 plausible (needs a repro)
- `Search/QueryParser/QueryTokenizer.swift:36` — **sanitizeFTSTerm leaves FTS5 structural characters and operators, so common queries break or change semantics** — 🔶 plausible (needs a repro)
- `App/RetentionManager.swift:218` — **Video segment file deleted before its database row; a DB failure leaves permanently dangling frame references** — 🔶 plausible (needs a repro)

### Low
- `UI/Components/MilestoneCelebrationView.swift:866` — **Milestone dialog silently phones out to retrace.to and discord.com without user action** — ✅ verified
- `App/AppLifecycle.swift:123` — **AppLifecycle actor is dead code containing a dormant auto-resume-after-user-pause bug** — ✅ verified
- `Shared/MasterKeyManager.swift:187` — **Raw master key hex handed out as the 'scramble secret' string and cached in unzeroizable memory** — ✅ verified
- `UI/Components/FaviconProvider.swift:119` — **Favicon provider replays the user's browsing domains over the network** — ✅ verified
- `Storage/StorageManager.swift:1096` — **Temp-directory .mp4 symlinks are created and never cleaned up in three code paths** — ✅ verified
- `Capture/CaptureManager.swift:335` — **frameStream obtained before startCapture is orphaned by startCapture** — ✅ verified
- `UI/Components/FaviconProvider.swift:209` — **Favicon download follows plaintext http:// hrefs, leaking visited domains over cleartext** — 🔶 plausible (needs a repro)
- `UI/Components/FaviconProvider.swift:347` — **clearCache drops in-flight completion handlers, permanently orphaning callers** — 🔶 plausible (needs a repro)

### Cross-cutting theme (several of the above share one root cause)
**The plaintext log is a privacy sink.** `Shared/Logging.swift` hardcodes `printToConsole = true` in release and stamps every `os_log` `privacy: .public`; search queries, browser URLs, incognito/excluded-window titles, OCR snippets, redaction patterns, and (pre-#32) the DB key all land in `~/Library/Logs/Retrace/retrace.log`, which `FeedbackLogSnapshotter` uploads (up to 10k lines, `fullLogs` on by default) to `retrace.to` — contradicting the "No user data" promise. Recommend: gate file logging to DEBUG/opt-in, `privacy: .private` by default, stop logging query/URL/title/snippet text, default `fullLogs` off + redact. (PR #32 only fixes the key-hex slice.)

## Verified clean
Interpolated SQL uses only `Int64`/`?`-placeholders (no injection outside the plausible FTS-tokenizer items above); no hardcoded credentials; master-key error paths log the error, not key material.

🤖 Filed via [Claude Code](https://claude.com/claude-code)
