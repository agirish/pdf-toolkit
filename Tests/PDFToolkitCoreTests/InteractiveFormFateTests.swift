import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// What actually happens to a real interactive form, per tool. These pin the behaviour the app's
/// warnings and the README/Pages matrix describe — the first version of that matrix was wrong
/// because the fixture used to build it had no catalog `/AcroForm` at all.
///
/// Three outcomes, all measured here:
/// - **kept** — catalog `/AcroForm` survives (Delete, Rotate: they mutate in place).
/// - **orphaned** — widgets survive, catalog form does not, so nothing is fillable any more
///   (Extract, Reorder, Crop, Merge, Split: they copy pages into a fresh document).
/// - **flattened** — neither survives; the appearance is painted into the page
///   (Watermark, OCR, Fill & Sign, Compress, Redact: they re-emit pages through a `CGPDFContext`).
struct InteractiveFormFateTests {

    private func formPDF(in dir: FixtureDir) throws -> URL {
        let url = dir.url("form.pdf")
        try PDFFixtures.writeAcroFormPDF(to: url)
        return url
    }

    private func fate(_ data: Data) throws -> (form: Bool, widgets: Int) {
        let doc = try #require(PDFDocument(data: data))
        let widgets = (0..<doc.pageCount).reduce(0) { total, i in
            total + (doc.page(at: i)?.annotations.filter { $0.type == "Widget" }.count ?? 0)
        }
        return (PDFToolkit.hasInteractiveForm(doc), widgets)
    }

    @Test func theFixtureReallyCarriesAnAcroForm() throws {
        let dir = FixtureDir()
        let url = try formPDF(in: dir)
        let doc = try #require(PDFDocument(url: url))
        #expect(PDFToolkit.hasInteractiveForm(doc), "fixture must have a catalog /AcroForm or it tests nothing")
        #expect(PDFToolkit.hasInteractiveForm(at: url))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 0)?.string?.contains("MARKERPAGE1") == true)
    }

    // MARK: kept

    @Test func deleteAndRotateKeepTheForm() throws {
        let dir = FixtureDir()
        let url = try formPDF(in: dir)
        let deleted = try fate(try PDFToolkit.deletePagesData(inputURL: url, pageIndices: [1]))
        #expect(deleted.form, "delete mutates in place, so the catalog form survives")
        let rotated = try fate(try PDFToolkit.rotateData(inputURL: url, pageIndices: [0], quarterTurns: 1))
        #expect(rotated.form, "rotate mutates in place, so the catalog form survives")
    }

    // MARK: orphaned — widgets remain, the form does not

    @Test func pageCopyRebuildsOrphanTheForm() throws {
        let dir = FixtureDir()
        let url = try formPDF(in: dir)

        let cases: [(String, Data)] = [
            ("extract", try PDFToolkit.extractData(inputURL: url, pageIndices: [0, 1])),
            ("reorder", try PDFToolkit.reorderData(inputURL: url, order: [1, 0])),
            ("crop", try PDFToolkit.cropData(inputURL: url, insets: CropInsets(top: 10, left: 10, bottom: 10, right: 10))),
            ("merge", try PDFToolkit.mergeData(inputURLs: [url])),
        ]
        for (name, data) in cases {
            let result = try fate(data)
            #expect(result.form == false, "\(name) is expected to drop the catalog /AcroForm")
            #expect(result.widgets > 0, "\(name) keeps the widget annotations — that's what 'orphaned' means")
        }
    }

    @Test func splitOrphansTheForm() throws {
        let dir = FixtureDir()
        let url = try formPDF(in: dir)
        let outDir = dir.url("parts")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let parts = try PDFToolkit.split(inputURL: url, into: outDir, baseName: "p", segments: [[0], [1]])
        let first = try fate(try Data(contentsOf: parts[0]))
        #expect(first.form == false)
        #expect(first.widgets == 1)
    }

    // MARK: flattened — nothing interactive remains

    @Test func vectorAndRasterRebuildsFlattenTheForm() throws {
        let dir = FixtureDir()
        let url = try formPDF(in: dir)

        var options = WatermarkOptions(text: "DRAFT", fontSize: 40, opacity: 0.3, rotationDegrees: 0,
                                       red: 1, green: 0, blue: 0, tiled: false)
        options.pageScope = .all
        let watermarked = try fate(try PDFToolkit.watermarkData(inputURL: url, options: options))
        #expect(watermarked.form == false)
        #expect(watermarked.widgets == 0, "a flattened form leaves no widget annotations behind")

        let compressed = try fate(try PDFToolkit.compressData(inputURL: url, quality: 0.7))
        #expect(compressed.form == false)
        #expect(compressed.widgets == 0)
    }

    // MARK: the warning matches the fate

    /// The whole point of the warning is that it fires for a file that really has a form and stays
    /// silent otherwise.
    @Test func theWarningFiresOnlyForAFileThatActuallyHasAForm() throws {
        let dir = FixtureDir()
        let withForm = try formPDF(in: dir)
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)

        for loss in [OutputFidelityWarning.Loss.formFlattened, .formOrphaned] {
            let fires = OutputFidelityWarning.detect(in: [withForm], formLoss: loss, checksBookmarks: false)
            #expect(fires?.losses == [loss])
            #expect(OutputFidelityWarning.detect(in: [plain], formLoss: loss, checksBookmarks: false) == nil)
        }

        // A tool that doesn't damage forms must stay silent even on the form fixture.
        #expect(OutputFidelityWarning.detect(in: [withForm], formLoss: nil, checksBookmarks: false) == nil)
    }

    /// Merge and Split lose both a form and bookmarks, so a file with both raises one warning
    /// carrying both losses.
    @Test func aFileWithBothRaisesBothLosses() throws {
        let dir = FixtureDir()
        let formURL = try formPDF(in: dir)

        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        let doc = try PDFFixtures.authoringCopy(of: plain)
        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "Chapter 1"
        child.destination = PDFDestination(page: try #require(doc.page(at: 0)), at: .zero)
        root.insertChild(child, at: 0)
        doc.outlineRoot = root
        let bookmarked = dir.url("bookmarked.pdf")
        try #require(doc.write(to: bookmarked))

        let warning = try #require(OutputFidelityWarning.detect(
            in: [formURL, bookmarked], formLoss: .formOrphaned, checksBookmarks: true
        ))
        #expect(warning.losses == [.formOrphaned, .bookmarks(total: 1, fileCount: 1)])
        #expect(warning.detailLines(toolTitle: "Merge").count == 2)
        #expect(warning.headline == "Some things won’t carry over")
        // The reassurance must not claim form fields are kept when they aren't.
        #expect(warning.keptLine.contains("form fields") == false)
    }

    /// A bookmarks-only warning must still promise form fields survive.
    @Test func bookmarksOnlyWarningSaysFormFieldsAreKept() throws {
        let warning = OutputFidelityWarning(losses: [.bookmarks(total: 3, fileCount: 1)])
        #expect(warning.keptLine.contains("form fields"))
        #expect(warning.headline == "Bookmarks won’t carry over")
    }

    /// A form-only warning must promise bookmarks survive — they now do.
    @Test func formOnlyWarningSaysBookmarksAreKept() {
        let warning = OutputFidelityWarning(losses: [.formFlattened])
        #expect(warning.keptLine.contains("Bookmarks"))
    }
}
