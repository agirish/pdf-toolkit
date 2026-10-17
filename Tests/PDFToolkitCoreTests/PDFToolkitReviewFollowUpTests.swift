import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// Follow-ups from the 2026-07-23 document-integrity review.
struct PDFToolkitReviewFollowUpTests {

    // MARK: #1 — the page-copy rebuilds keep the document's user-set info fields

    private func titledPDF(in dir: FixtureDir, pages: Int = 3) throws -> URL {
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: pages, to: plain)
        let doc = try #require(PDFDocument(url: plain))
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Quarterly Report",
            PDFDocumentAttribute.authorAttribute: "Finance",
            PDFDocumentAttribute.subjectAttribute: "Q3",
        ]
        let url = dir.url("titled.pdf")
        try #require(doc.write(to: url))
        return url
    }

    private func title(of data: Data) throws -> String? {
        let doc = try #require(PDFDocument(data: data))
        return doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
    }

    @Test func extractKeepsTheDocumentTitle() throws {
        let dir = FixtureDir()
        let url = try titledPDF(in: dir)
        #expect(try title(of: try PDFToolkit.extractData(inputURL: url, pageIndices: [0, 2])) == "Quarterly Report")
    }

    @Test func reorderKeepsTheDocumentTitle() throws {
        let dir = FixtureDir()
        let url = try titledPDF(in: dir)
        #expect(try title(of: try PDFToolkit.reorderData(inputURL: url, order: [2, 1, 0])) == "Quarterly Report")
    }

    @Test func cropKeepsTheDocumentTitle() throws {
        let dir = FixtureDir()
        let url = try titledPDF(in: dir)
        let data = try PDFToolkit.cropData(inputURL: url, insets: CropInsets(top: 20, left: 20, bottom: 20, right: 20))
        #expect(try title(of: data) == "Quarterly Report")
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Finance")
    }

    @Test func autoCropKeepsTheDocumentTitle() throws {
        let dir = FixtureDir()
        let url = try titledPDF(in: dir)
        #expect(try title(of: try PDFToolkit.autoCropData(inputURL: url, padding: 12, unified: false)) == "Quarterly Report")
    }

    /// Delete mutates in place, so its info dictionary was never at risk — pinned so a future
    /// rewrite of the delete path can't quietly regress it alongside the others.
    @Test func deleteKeepsTheDocumentTitle() throws {
        let dir = FixtureDir()
        let url = try titledPDF(in: dir)
        #expect(try title(of: try PDFToolkit.deletePagesData(inputURL: url, pageIndices: [1])) == "Quarterly Report")
    }

    /// Merge has no single obvious source, so the combined document takes the FIRST file's
    /// Title/Author — the user's chosen policy, and predictable since the output is already named
    /// after the first file.
    @Test func mergeTakesTheFirstFilesTitle() throws {
        let dir = FixtureDir()
        let first = try titledPDF(in: dir, pages: 2)

        let secondPlain = dir.url("second-plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: secondPlain)
        let secondDoc = try #require(PDFDocument(url: secondPlain))
        secondDoc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Appendix"]
        let second = dir.url("second.pdf")
        try #require(secondDoc.write(to: second))

        let merged = try PDFToolkit.mergeData(inputURLs: [first, second])
        #expect(try title(of: merged) == "Quarterly Report")
        #expect(try #require(PDFDocument(data: merged)).pageCount == 4)
    }

    /// A merge whose first file has no title must not inherit a later file's — the policy is "the
    /// first file's", not "the first title found".
    @Test func mergeLeavesTheTitleBlankWhenTheFirstFileHasNone() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        let titled = try titledPDF(in: dir, pages: 2)
        #expect(try title(of: try PDFToolkit.mergeData(inputURLs: [plain, titled])) == nil)
    }

    /// Every split part is the same document cut up, so each inherits the source's info fields.
    @Test func splitPartsInheritTheSourceTitle() throws {
        let dir = FixtureDir()
        let url = try titledPDF(in: dir, pages: 4)
        let outputDir = dir.url("parts")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let parts = try PDFToolkit.split(inputURL: url, into: outputDir, baseName: "part",
                                         segments: [[0, 1], [2, 3]])
        #expect(parts.count == 2)
        for part in parts {
            #expect(try title(of: try Data(contentsOf: part)) == "Quarterly Report")
        }
    }

    // MARK: #5 — a Fit-style bookmark stays a Fit bookmark through a crop

    /// `kPDFDestinationUnspecifiedValue` (FLT_MAX) means "no explicit scroll position" — a `/FitH`
    /// style destination. It round-trips through PDFKit, so crop's clamp used to treat it as a real
    /// coordinate and pin it to the trimmed box's corner: every "fit the page" bookmark silently
    /// became "scroll to the top-right corner".
    @Test func cropLeavesUnspecifiedDestinationCoordinatesAlone() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        let doc = try #require(PDFDocument(url: plain))

        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "Fit bookmark"
        let unspecified = CGFloat(kPDFDestinationUnspecifiedValue)
        child.destination = PDFDestination(page: try #require(doc.page(at: 1)),
                                           at: CGPoint(x: unspecified, y: unspecified))
        root.insertChild(child, at: 0)
        doc.outlineRoot = root
        let url = dir.url("fit.pdf")
        try #require(doc.write(to: url))

        let cropped = try PDFToolkit.cropData(inputURL: url, insets: CropInsets(top: 30, left: 30, bottom: 30, right: 30))
        let out = try #require(PDFDocument(data: cropped))
        let dest = try #require(out.outlineRoot?.child(at: 0)?.destination)
        #expect(dest.point.x == unspecified)
        #expect(dest.point.y == unspecified)
        #expect(out.index(for: try #require(dest.page)) == 1)
    }

    /// The clamp must still do its job for a real coordinate outside the trimmed box.
    @Test func cropStillClampsRealDestinationPoints() throws {
        let box = CGRect(x: 30, y: 30, width: 552, height: 732)
        #expect(PDFToolkit.clampedDestinationCoordinate(792, low: box.minY, high: box.maxY) == box.maxY)
        #expect(PDFToolkit.clampedDestinationCoordinate(0, low: box.minX, high: box.maxX) == box.minX)
        #expect(PDFToolkit.clampedDestinationCoordinate(400, low: box.minX, high: box.maxX) == 400)
        let unspecified = CGFloat(kPDFDestinationUnspecifiedValue)
        #expect(PDFToolkit.clampedDestinationCoordinate(unspecified, low: box.minX, high: box.maxX) == unspecified)
    }

    // MARK: #6 — a save never produces a file bigger than its input

    /// A lean vector/text PDF inflates when rasterized. The save-only bounded wrapper must fall back
    /// to the source bytes; the raw core must NOT, so the strength-estimate cards keep differing.
    @Test func boundedCompressNeverExceedsTheSource() throws {
        let dir = FixtureDir()
        let url = dir.url("lean.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: url)
        let sourceBytes = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        for quality in [0.2, 0.5, 0.9] {
            let bounded = try PDFToolkit.compressDataBounded(inputURL: url, quality: quality)
            #expect(bounded.count <= sourceBytes, "quality \(quality) inflated past the source")
        }
    }

    /// The bound carries a margin: a save is either meaningfully smaller (under 95% of the source)
    /// or it is the source, byte for byte. Nothing in between ships.
    ///
    /// "Not bigger than the input" alone let a pointless save through — a 600-dpi JPEG2000 scan
    /// re-encoded at the top of the range came out 0.3% smaller and at less than half the linear
    /// resolution, and was written anyway. Stated as an invariant rather than against one contrived
    /// fixture, so it holds for whatever the ramp produces: a lean vector page (which inflates) and a
    /// genuine raster page (which compresses well) must both land on one side or the other.
    @Test func boundedCompressIsEitherWorthwhileOrTheOriginal() throws {
        let dir = FixtureDir()
        let lean = dir.url("lean.pdf")
        let scan = dir.url("scan.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: lean)
        try PDFFixtures.rasterize(lean, to: scan, quality: 1.0)

        for url in [lean, scan] {
            let original = try Data(contentsOf: url)
            for quality in [0.2, 0.5, 0.85, 1.0] {
                let bounded = try PDFToolkit.compressDataBounded(inputURL: url, quality: quality)
                if bounded == original { continue }
                let detail = "\(url.lastPathComponent) at quality \(quality) saved a \(bounded.count)-byte "
                    + "file over a \(original.count)-byte source — inside the margin, so the original should have won"
                #expect(Double(bounded.count) < Double(original.count) * 0.95, Comment(rawValue: detail))
            }
        }
    }

    @Test func boundedCompressPassesTheSourceThroughUnchangedWhenItWins() throws {
        let dir = FixtureDir()
        let url = dir.url("lean.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: url)
        let original = try Data(contentsOf: url)
        let raw = try PDFToolkit.compressData(inputURL: url, quality: 0.9)
        let bounded = try PDFToolkit.compressDataBounded(inputURL: url, quality: 0.9)
        if raw.count >= original.count {
            #expect(bounded == original, "inflated output should fall back to the source bytes")
        } else {
            #expect(bounded == raw)
        }
    }

    /// The estimate path stays unbounded on purpose — if it clamped, every strength card would
    /// report the same source size and the picker would look broken.
    @Test func rawCompressStaysUnboundedForTheEstimateCards() throws {
        let dir = FixtureDir()
        let url = dir.url("lean.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: url)
        let low = try PDFToolkit.compressData(inputURL: url, quality: 0.2)
        let high = try PDFToolkit.compressData(inputURL: url, quality: 0.9)
        #expect(low.count != high.count, "quality rungs must still produce distinct estimates")
    }

    // MARK: #7 — rotation values are always quarter turns

    /// PDFKit's own `page.rotation` setter snaps to a quarter turn (45 → 90, 100 → 90, −30 → 0), so
    /// a malformed `/Rotate` is normalized before our math ever sees it, and our math only ever adds
    /// multiples of 90. Pinned because the display/raster paths assume 0/90/180/270.
    @Test func rotationIsAlwaysAQuarterTurn() throws {
        let dir = FixtureDir()
        let url = dir.url("s.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: url)
        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: 0))
        for odd in [45, 100, -30, 200, 359] {
            page.rotation = odd
            #expect([0, 90, 180, 270].contains(PDFToolkit.normalizedRotation(page.rotation)),
                    "setting \(odd) left a non-quarter-turn rotation")
        }
        for turns in [1, 2, 3, 4, -1, 7] {
            let data = try PDFToolkit.rotateData(inputURL: url, pageIndices: [0], quarterTurns: turns)
            let out = try #require(PDFDocument(data: data))
            let rotation = PDFToolkit.normalizedRotation(try #require(out.page(at: 0)).rotation)
            #expect([0, 90, 180, 270].contains(rotation))
        }
    }
}
