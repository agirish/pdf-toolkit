import Foundation

/// The Split tool's visual grid defines its output as a set of *cut points* rather than typed ranges:
/// a value `k` means "cut after page k" (1-based), so pages `1...k` finish one file and page `k+1`
/// begins the next. This is the click-a-gap model behind the colored page groups.
///
/// Cuts map onto the exact same `[[Int]]` segments the two text modes and ``PDFToolkit/split(inputURL:into:baseName:segments:)``
/// already speak — one inner array per output file — so the visual grid is purely a friendlier UI over
/// the existing service; no service change is needed. Cuts are the single source of truth for Visual
/// mode; the segments (and every live count) are derived from them.
public enum SplitCuts {
    /// The consecutive, zero-based page groups a cut set produces — one inner array per output file,
    /// exactly the shape ``PDFToolkit/split(inputURL:into:baseName:segments:)`` consumes. Cuts outside
    /// `1..<pageCount` are ignored, so a stale cut left over from a longer document can never point
    /// past the current one (it just collapses back into a single trailing group).
    public static func segments(pageCount: Int, cuts: Set<Int>) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        let boundaries = cuts.filter { $0 >= 1 && $0 < pageCount }.sorted()
        var result: [[Int]] = []
        var start = 0
        for boundary in boundaries {
            // A cut after 1-based page `boundary` closes the zero-based run start..<boundary.
            result.append(Array(start..<boundary))
            start = boundary
        }
        result.append(Array(start..<pageCount))
        return result
    }

    /// Slices an ordered page list into per-file groups at the same boundaries ``segments(pageCount:cuts:)``
    /// uses, so the visual grid renders exactly the partition the export writes — one derivation, no
    /// second copy of the cut math. The i-th inner array is the i-th output file's pages, in order.
    public static func groups<Page>(_ pages: [Page], cuts: Set<Int>) -> [[Page]] {
        segments(pageCount: pages.count, cuts: cuts).map { segment in segment.map { pages[$0] } }
    }

    /// The cut set equivalent to "Every N pages" — a cut after every `chunkSize`-th page. Lets Visual
    /// mode and the every-N stepper draw the *same* colored groups from one derivation, and matches
    /// ``PageRangeParser/everyNPagesSegments(pageCount:chunkSize:)`` page-for-page. `chunkSize` is
    /// floored at 1 so a zero/negative value can't wedge the loop.
    public static func everyNCuts(pageCount: Int, chunkSize: Int) -> Set<Int> {
        let n = max(1, chunkSize)
        guard pageCount > 0 else { return [] }
        var cuts: Set<Int> = []
        var k = n
        while k < pageCount {
            cuts.insert(k)
            k += n
        }
        return cuts
    }
}
