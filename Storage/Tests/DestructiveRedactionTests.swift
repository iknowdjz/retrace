import XCTest
import CoreGraphics
import Shared
@testable import Storage

/// Redaction must destroy pixels, not rearrange them.
///
/// The previous implementation permuted 2-16px BGRA blocks into a key-seeded order. Every
/// original pixel survived in the stored frame, so a protected region was recoverable without
/// the master key -- by jigsaw/edge-matching reassembly, or for small regions simply by trying
/// the handful of possible arrangements. See docs/backlog/issue-34.md.
final class DestructiveRedactionTests: XCTestCase {
    private let width = 24
    private let height = 16

    /// Every pixel gets a distinct, recognisable value so survival is detectable.
    private func makeDistinctPatch() -> BGRAPatch {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        for row in 0..<height {
            for column in 0..<width {
                let index = row * bytesPerRow + column * 4
                let ordinal = row * width + column
                data[index] = UInt8((ordinal % 251) + 1)          // B, never 0
                data[index + 1] = UInt8(((ordinal * 7) % 251) + 1) // G, never 0
                data[index + 2] = UInt8(((ordinal * 13) % 251) + 1)// R, never 0
                data[index + 3] = 128                              // A
            }
        }
        return BGRAPatch(data: data, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    func testRedactionOverwritesEveryPixelWithOpaqueBlack() {
        var patch = makeDistinctPatch()
        BGRAImageUtilities.destructivelyRedactPatch(&patch)

        for row in 0..<height {
            for column in 0..<width {
                let index = row * patch.bytesPerRow + column * 4
                XCTAssertEqual(patch.data[index], 0, "blue survived at \(row),\(column)")
                XCTAssertEqual(patch.data[index + 1], 0, "green survived at \(row),\(column)")
                XCTAssertEqual(patch.data[index + 2], 0, "red survived at \(row),\(column)")
                XCTAssertEqual(patch.data[index + 3], 255, "alpha not opaque at \(row),\(column)")
            }
        }
    }

    /// The property the permutation violated: no original colour value may survive anywhere in
    /// the patch, at any position.
    func testNoOriginalPixelValueSurvivesAnywhereInTheRegion() {
        let original = makeDistinctPatch()
        var redacted = original
        BGRAImageUtilities.destructivelyRedactPatch(&redacted)

        var survivingColourBytes = 0
        for row in 0..<height {
            for column in 0..<width {
                let index = row * original.bytesPerRow + column * 4
                for channel in 0..<3 where original.data[index + channel] != 0 {
                    // Every original colour byte was seeded non-zero, so any non-zero colour
                    // byte left in the redacted patch is surviving content.
                    if redacted.data[index + channel] != 0 { survivingColourBytes += 1 }
                }
            }
        }
        XCTAssertEqual(survivingColourBytes, 0)

        // Non-vacuous: the source really did carry content to destroy.
        let originalColourBytes = (0..<height).reduce(0) { total, row in
            total + (0..<width).reduce(0) { rowTotal, column in
                let index = row * original.bytesPerRow + column * 4
                return rowTotal + (0..<3).filter { original.data[index + $0] != 0 }.count
            }
        }
        XCTAssertEqual(originalColourBytes, width * height * 3)
    }

    /// Documents *why* the old scheme was unsafe, so nobody reintroduces it: the permutation is
    /// content-preserving. The multiset of pixels is identical before and after, which is
    /// exactly what makes jigsaw/edge-matching reassembly possible without the key.
    func testPermutationPreservesAllContentWhichIsWhyItWasReplaced() {
        let side = 64
        let bytesPerRow = side * 4
        var original = Data(count: bytesPerRow * side)
        for index in 0..<original.count {
            original[index] = UInt8((index % 251) + 1)
        }

        var scrambled = original
        scrambleWithDeprecatedPermutation(
            &scrambled,
            width: side,
            height: side,
            bytesPerRow: bytesPerRow,
            frameID: 4242,
            nodeID: 7
        )

        XCTAssertNotEqual(scrambled, original, "expected the blocks to move")
        XCTAssertEqual(
            scrambled.sorted(),
            original.sorted(),
            "the permutation preserves every byte, so the region is recoverable without the key"
        )

        // And destroying the same region does not preserve content.
        var patch = BGRAPatch(data: original, width: side, height: side, bytesPerRow: bytesPerRow)
        BGRAImageUtilities.destructivelyRedactPatch(&patch)
        XCTAssertNotEqual(patch.data.sorted(), original.sorted())
    }

    /// The sharper failure: on small regions the permutation space is tiny, so the shuffle
    /// frequently lands on the identity and the "redacted" region is stored **completely
    /// untouched**. A 24x16 region maps to a 2x1 block layout -- two blocks, so identity or
    /// swap. Measured across 500 frame/node seeds it came out unchanged 227 times (45.4%).
    func testSmallRegionsWereOftenLeftEntirelyUnredacted() {
        let width = 24, height = 16, bytesPerRow = width * 4
        var unchangedCount = 0
        let trials = 200

        for seed in 0..<trials {
            var data = Data(count: bytesPerRow * height)
            for index in 0..<data.count { data[index] = UInt8((index % 251) + 1) }
            let original = data

            scrambleWithDeprecatedPermutation(
                &data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                frameID: Int64(seed),
                nodeID: seed % 13
            )
            if data == original { unchangedCount += 1 }
        }

        XCTAssertGreaterThan(
            unchangedCount,
            0,
            "expected the old scheme to leave small regions untouched at least sometimes"
        )

        // The replacement never leaves a region untouched, for any size or seed.
        for seed in 0..<trials {
            var data = Data(count: bytesPerRow * height)
            for index in 0..<data.count { data[index] = UInt8((index % 251) + 1) }
            let original = data
            var patch = BGRAPatch(
                data: data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            )
            BGRAImageUtilities.destructivelyRedactPatch(&patch)
            data = patch.data
            XCTAssertNotEqual(data, original, "region survived redaction at seed \(seed)")
        }
    }

    @available(*, deprecated)
    private func scrambleWithDeprecatedPermutation(
        _ data: inout Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        frameID: Int64,
        nodeID: Int
    ) {
        ReversibleOCRScrambler.scramblePatchBGRA(
            &data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            frameID: frameID,
            nodeID: nodeID,
            secret: "test-secret"
        )
    }
}
