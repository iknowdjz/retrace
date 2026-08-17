title:	Pixel 'redaction' is reversible obfuscation, not encryption — fix forward + migrate the existing backlog
state:	OPEN
author:	grub-basket
labels:	
comments:	0
assignees:	
projects:	
milestone:	
number:	34
--
## Summary
Image-region "redaction" (`Shared/ReversibleOCRScrambler.applyPermutation`, applied at `Storage/StorageManager.swift:248`) is **obfuscation, not encryption**. It `memcpy`s intact 2–16px BGRA blocks into a key-seeded shuffled order. **All original pixels survive in the stored video/stills** — only their positions change — so protected regions are recoverable **without the master key**:

- **Jigsaw / edge-matching reassembly** is a well-studied, largely automated attack on block-permuted images, especially for text on uniform backgrounds.
- **Small regions** have tiny permutation spaces (`bestBlockDimension` biases toward ~16px blocks; a small patch can yield 2×2 = 24 arrangements, guard only requires `blockCount > 1`) — brute-forceable by eye.
- Even unreassembled, large blocks often expose whole glyphs/digits.

This contrasts with the OCR **text** path, which uses genuine `AES.GCM` (`encryptOCRText`) — so the confidentiality intent is clear, but the image path doesn't deliver it. A user who resets/loses the master key believing redacted regions are unrecoverable is **wrong**. (The legacy `revealOCRText` fallback for pre-`rtx1.` text is likewise a trivially-broken character anagram and should be migrated in the same pass.)

Confirmed independently by manual review + an automated review fleet.

## Recommended fix (forward path)
Pick based on the intended semantics of "redaction":

**Option A — Reversible, truly confidential (recommended, preserves today's "reveal with key" behavior).** In the stored frame, replace the sensitive region with an opaque placeholder (solid fill/blur), and store the **original patch AES-GCM-encrypted in a sidecar** keyed from the master key (reuse the `textProtectionKey` KDF pattern). Reveal decrypts the sidecar and composites the region back.

**Option B — Destructive redaction (simpler, if redaction is meant to permanently remove).** Overwrite the region with a solid opaque fill in the stored frame; no key, no reversibility. Drop the reveal path for these regions.

Either way: **stop permuting pixels for confidentiality.** (Note: because segments are re-encoded lossy HEVC, exact pixel reversal was never bit-perfect anyway — fine for redaction, another reason Option A's sidecar beats in-place pixel tricks.)

## The part that needs a dev + UI (the reason this is an issue, not just a PR)
Existing stored data already contains permutation-only ("obfuscated") regions. A forward fix does **not** protect what's already on disk. We need a **one-time backfill/migration** that walks the backlog and re-protects it:

1. **Enumerate** frames/nodes carrying redaction regions (query by `redactionReason` / node metadata; also the legacy non-`rtx1.` text rows).
2. For each: **descramble** the region with the master key → **re-protect** under the new scheme (encrypt to sidecar for Option A, or destroy for Option B) → **rewrite** the segment/still.
3. **Idempotent + resumable**: stamp a per-frame protection-scheme version (or a global cursor) so interrupted runs continue and re-runs are no-ops.
4. **Safe rewrite**: write-new-then-atomic-swap; never lose the region mid-migration.
5. **Throttled / background**: don't thrash disk/CPU during active capture; respect the existing pause-on-battery posture.
6. **Master-key-absent handling**: skip and retry later (don't silently drop protection).
7. **UI (dev to design)**: a migration progress indicator + a settings entry point; surface "N protected regions upgraded". This is the piece I'm explicitly leaving to the maintainer.

## Acceptance
- New redactions use real encryption or destructive fill — never a recoverable permutation.
- A resumable background pass upgrades all pre-existing obfuscated regions (and legacy anagram text).
- After a master-key reset, previously-redacted content is genuinely unrecoverable from stored data.

_Severity: medium. From the whole-repo security review — see the tracking issue._

🤖 Filed via [Claude Code](https://claude.com/claude-code)

