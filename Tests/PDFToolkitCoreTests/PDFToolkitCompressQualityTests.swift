import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// The "distinct qualities → distinct sizes" claim the Compress strength cards rest on, pinned
/// end-to-end against a real Letter fixture. The cards' bucketing and reduction math live with the UI
/// and are tested there.
@Suite struct PDFToolkitCompressQualityTests {

    // MARK: - Distinct sizes per quality (the strength cards' core claim)

    @Test func distinctQualitiesProduceDistinctMonotoneSizes() throws {
        // The three cards advertise *different* projected sizes; that rests on `compressData` returning
        // a strictly larger file at higher quality (on a standard page the JPEG-encoding factor is the
        // active size lever). Pinned on a real multi-page Letter fixture at the exact card qualities.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 6, to: src)

        let basic = try PDFToolkit.compressData(inputURL: src, quality: 0.85).count
        let balanced = try PDFToolkit.compressData(inputURL: src, quality: 0.6).count
        let strong = try PDFToolkit.compressData(inputURL: src, quality: 0.35).count

        #expect(basic > balanced)
        #expect(balanced > strong)
        // And all three are genuinely distinct — no two cards would show the same number.
        #expect(Set([basic, balanced, strong]).count == 3)
    }
}
