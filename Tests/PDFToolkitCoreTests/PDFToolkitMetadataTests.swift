import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// Read/write behavior of the Clean Metadata operation: fields round-trip, blank fields disappear,
/// stripping produces a file with no identifying info, and encrypted files are refused whole.
@Suite struct PDFToolkitMetadataTests {

    /// Writes a 2-page fixture whose info dictionary is populated, returns its URL.
    ///
    /// Written to a *fresh* path — `PDFDocument.write(to:)` back onto the file the document lazily
    /// reads from is unreliable (it intermittently fails outright). And note PDFKit stamps its own
    /// Producer and both dates on every write, so those three carry system values here, not ours.
    private func writePopulatedFixture(in dir: FixtureDir) throws -> URL {
        let base = dir.url.appendingPathComponent("base.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Q3 Review",
            PDFDocumentAttribute.authorAttribute: "A. Person",
            PDFDocumentAttribute.subjectAttribute: "Finance",
            PDFDocumentAttribute.keywordsAttribute: ["internal", "draft"],
            PDFDocumentAttribute.creatorAttribute: "Word 16.89",
        ]
        let url = dir.url.appendingPathComponent("populated.pdf")
        #expect(doc.write(to: url))
        return url
    }

    @Test func readsEveryStandardField() throws {
        let dir = FixtureDir()
        let url = try writePopulatedFixture(in: dir)

        let fields = try PDFToolkit.readMetadata(inputURL: url)
        #expect(fields.title == "Q3 Review")
        #expect(fields.author == "A. Person")
        #expect(fields.subject == "Finance")
        #expect(fields.keywords == "internal, draft")
        #expect(fields.creator == "Word 16.89")
        // PDFKit stamped these three on the fixture's own write.
        #expect(fields.producer.contains("Quartz"))
        #expect(fields.creationDate != nil)
        #expect(fields.modificationDate != nil)
        #expect(!fields.isCleared)
    }

    @Test func readsStringKeywordsFromLegacyProducers() throws {
        let dir = FixtureDir()
        let base = dir.url.appendingPathComponent("base.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: base)
        let doc = try #require(PDFDocument(url: base))
        // Some producers store keywords as one string rather than an array.
        doc.documentAttributes = [PDFDocumentAttribute.keywordsAttribute: "alpha, beta"]
        let url = dir.url.appendingPathComponent("legacy.pdf")
        #expect(doc.write(to: url))

        let fields = try PDFToolkit.readMetadata(inputURL: url)
        #expect(fields.keywords == "alpha, beta")
    }

    @Test func editedFieldsRoundTrip() throws {
        let dir = FixtureDir()
        let url = try writePopulatedFixture(in: dir)
        let out = dir.url.appendingPathComponent("edited.pdf")

        var fields = try PDFToolkit.readMetadata(inputURL: url)
        fields.title = "Renamed"
        fields.author = ""            // cleared → must vanish, not become ""
        fields.keywords = "one, two , three,"
        try PDFToolkit.writeMetadata(inputURL: url, outputURL: out, fields: fields)

        let reread = try PDFToolkit.readMetadata(inputURL: out)
        #expect(reread.title == "Renamed")
        #expect(reread.author.isEmpty)
        #expect(reread.keywords == "one, two, three")
        #expect(reread.creator == "Word 16.89")

        // The cleared author must be *absent* from the attributes, not present-but-empty.
        let attrs = try #require(PDFDocument(url: out)?.documentAttributes)
        #expect(attrs[PDFDocumentAttribute.authorAttribute] == nil)

        // Pages are untouched.
        #expect(try PDFFixtures.pageCount(at: out) == 2)
        #expect(try PDFFixtures.pageTexts(at: out) == PDFFixtures.pageTexts(at: url))
    }

    @Test func strippingClearsEveryIdentifyingField() throws {
        let dir = FixtureDir()
        let url = try writePopulatedFixture(in: dir)
        let out = dir.url.appendingPathComponent("stripped.pdf")

        try PDFToolkit.writeMetadata(inputURL: url, outputURL: out, fields: .cleared)

        let reread = try PDFToolkit.readMetadata(inputURL: out)
        #expect(reread.title.isEmpty)
        #expect(reread.author.isEmpty)
        #expect(reread.subject.isEmpty)
        #expect(reread.keywords.isEmpty)
        #expect(reread.creator.isEmpty)
        #expect(reread.isCleared)
        // The editable fields must be *absent*, not present-but-empty.
        let attrs = try #require(PDFDocument(url: out)?.documentAttributes)
        #expect(attrs[PDFDocumentAttribute.titleAttribute] == nil)
        #expect(attrs[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attrs[PDFDocumentAttribute.keywordsAttribute] == nil)
        // Producer and dates are PDFKit's own neutral write-time stamps — system values, so the
        // original tool name and timestamps are gone even though the keys exist.
        #expect(reread.producer.contains("Quartz"))
        #expect(reread.creationDate != nil)
    }

    @Test func refusesEncryptedInputWhole() throws {
        let dir = FixtureDir()
        let url = dir.url.appendingPathComponent("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: url)
        let locked = dir.url.appendingPathComponent("locked.pdf")
        try PDFToolkit.encrypt(inputURL: url, outputURL: locked, password: "pw")

        let readError = #expect(throws: PDFOperationError.self) {
            _ = try PDFToolkit.readMetadata(inputURL: locked)
        }
        #expect(readError?.kind == "metadataEncrypted")

        let writeError = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.writeMetadata(
                inputURL: locked,
                outputURL: dir.url.appendingPathComponent("out.pdf"),
                fields: .cleared
            )
        }
        #expect(writeError?.kind == "metadataEncrypted")
    }

    @Test func refusesWritingOverTheInput() throws {
        let dir = FixtureDir()
        let url = try writePopulatedFixture(in: dir)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.writeMetadata(inputURL: url, outputURL: url, fields: .cleared)
        }
        #expect(error?.kind == "outputMatchesInput")
    }

    /// The privacy guarantee: clearing the Info dictionary alone leaves the catalog XMP `/Metadata`
    /// packet (which Adobe/Office duplicate identity into) — cleaning must drop that packet too.
    @Test func cleaningDropsTheCatalogXMPPacket() throws {
        let dir = FixtureDir()
        let src = dir.url("xmp.pdf"), out = dir.url("cleaned.pdf")
        try PDFFixtures.writeRawPDF(xmpCreator: "SECRET-XMP-CREATOR", to: src)
        #expect(try PDFFixtures.catalogHasEntry("Metadata", at: src))   // sanity: source carries XMP

        try PDFToolkit.writeMetadata(inputURL: src, outputURL: out, fields: .cleared)

        #expect(try PDFFixtures.catalogHasEntry("Metadata", at: out) == false)
        #expect(try PDFFixtures.pageCount(at: out) == 1)
    }

    /// The rebuild that sheds XMP would otherwise drop the outline (it lives on the catalog, not the
    /// pages); reattaching `outlineRoot` must keep bookmarks intact through a clean.
    @Test func cleaningPreservesBookmarks() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("outlined.pdf"), out = dir.url("cleaned.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        for (i, item) in [("Intro", 0), ("Appendix", 2)].enumerated() {
            let child = PDFOutline()
            child.label = item.0
            if let page = doc.page(at: item.1) {
                child.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 792))
            }
            root.insertChild(child, at: i)
        }
        doc.outlineRoot = root
        #expect(doc.write(to: src))
        #expect(try #require(PDFDocument(url: src)).outlineRoot?.numberOfChildren == 2)   // sanity

        try PDFToolkit.writeMetadata(inputURL: src, outputURL: out, fields: .cleared)

        let cleaned = try #require(PDFDocument(url: out))
        #expect(cleaned.outlineRoot?.numberOfChildren == 2)
        #expect(cleaned.outlineRoot?.child(at: 0)?.label == "Intro")
    }

    /// The form guard: a real catalog `/AcroForm` is detected so the rebuild is skipped for it (the
    /// rebuild would flatten the form), while ordinary PDFs report no form and take the XMP-dropping path.
    @Test func detectsInteractiveFormsInTheCatalog() throws {
        let dir = FixtureDir()
        let form = dir.url("form.pdf"), plain = dir.url("plain.pdf")
        try PDFFixtures.writeRawPDF(includeAcroForm: true, to: form)
        try PDFFixtures.writePDF(pageCount: 1, to: plain)

        #expect(try PDFFixtures.catalogHasEntry("AcroForm", at: form))   // sanity
        #expect(PDFToolkit.hasInteractiveForm(try #require(PDFDocument(url: form))) == true)
        #expect(PDFToolkit.hasInteractiveForm(try #require(PDFDocument(url: plain))) == false)
    }

    /// A form-bearing PDF skips the rebuild and cleans via the in-place Info clear — it must still
    /// succeed and keep its page (XMP may remain for that file; the documented tradeoff to keep the
    /// form fillable).
    @Test func formBearingPDFCleansViaTheInPlacePath() throws {
        let dir = FixtureDir()
        let form = dir.url("form.pdf"), out = dir.url("cleaned.pdf")
        try PDFFixtures.writeRawPDF(xmpCreator: "SECRET", includeAcroForm: true, to: form)

        try PDFToolkit.writeMetadata(inputURL: form, outputURL: out, fields: .cleared)

        #expect(try PDFFixtures.pageCount(at: out) == 1)
    }

    /// The public strip entry (shared by the export coordinator, batch runner, and Finder helper)
    /// drops the catalog XMP packet for an ordinary PDF via the fresh-document rebuild.
    @Test func strippingAllMetadataDropsXMPForANonFormPDF() throws {
        let dir = FixtureDir()
        let src = dir.url("xmp.pdf"), out = dir.url("clean.pdf")
        try PDFFixtures.writeRawPDF(xmpCreator: "SECRET-XMP-CREATOR", to: src)
        #expect(try PDFFixtures.catalogHasEntry("Metadata", at: src))   // sanity: source carries XMP

        try PDFToolkit.strippingAllMetadata(from: Data(contentsOf: src)).write(to: out)

        #expect(try PDFFixtures.catalogHasEntry("Metadata", at: out) == false)
        #expect(try PDFFixtures.pageCount(at: out) == 1)
    }

    /// A form-bearing PDF takes the in-place Info-only clear (the fresh-doc rebuild that sheds XMP is
    /// skipped for forms), so its embedded XMP `/Metadata` packet can survive the clean — the tradeoff
    /// the Metadata tool now discloses instead of claiming a complete strip. (PDFKit's own re-encode
    /// still drops the `/AcroForm`, so the form isn't truly preserved either — the disclosure only
    /// promises that some embedded metadata *may remain*, not that the form is kept.)
    @Test func strippingAllMetadataLeavesXMPOnFormBearingPDFs() throws {
        let dir = FixtureDir()
        let src = dir.url("form.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writeRawPDF(xmpCreator: "SECRET-XMP", includeAcroForm: true, to: src)
        #expect(try PDFFixtures.catalogHasEntry("Metadata", at: src))   // sanity: has XMP

        try PDFToolkit.strippingAllMetadata(from: Data(contentsOf: src)).write(to: out)

        // The XMP packet is NOT dropped for a form-bearing file — exactly what the disclosure warns.
        #expect(try PDFFixtures.catalogHasEntry("Metadata", at: out))
    }

    /// The URL-taking form check the Metadata tool uses to decide whether to disclose that XMP may
    /// remain — true for a real `/AcroForm`, false for an ordinary PDF.
    @Test func detectsInteractiveFormsFromAURL() throws {
        let dir = FixtureDir()
        let form = dir.url("form.pdf"), plain = dir.url("plain.pdf")
        try PDFFixtures.writeRawPDF(includeAcroForm: true, to: form)
        try PDFFixtures.writePDF(pageCount: 1, to: plain)

        #expect(PDFToolkit.hasInteractiveForm(at: form) == true)
        #expect(PDFToolkit.hasInteractiveForm(at: plain) == false)
    }

    /// `strippingAllMetadata` is the entry point the GLOBAL "Strip metadata on export" setting hooks
    /// into — every batch write and every Finder right-click passes through it, unlike the metadata
    /// tool's `writeMetadata`. It rebuilds the document page by page, so a review argued it must be
    /// shredding bookmarks on every export. It does not: labels AND destinations survive, while the
    /// author really is gone. Pinning both halves so a future rebuild change can't quietly make the
    /// privacy setting a document corrupter.
    @Test func strippingAllMetadataKeepsBookmarksPointingAtTheRightPages() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("outlined.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        for (i, item) in [("Intro", 0), ("Appendix", 2)].enumerated() {
            let child = PDFOutline()
            child.label = item.0
            child.destination = PDFDestination(page: try #require(doc.page(at: item.1)), at: CGPoint(x: 0, y: 792))
            root.insertChild(child, at: i)
        }
        doc.outlineRoot = root
        doc.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Private Person"]
        #expect(doc.write(to: src))

        let out = try #require(PDFDocument(data: try PDFToolkit.strippingAllMetadata(from: try Data(contentsOf: src))))
        let indices: [Int] = (0..<(out.outlineRoot?.numberOfChildren ?? 0)).map { i in
            guard let page = out.outlineRoot?.child(at: i)?.destination?.page else { return -1 }
            let raw = out.index(for: page)
            return raw == NSNotFound ? -1 : raw
        }
        #expect((0..<(out.outlineRoot?.numberOfChildren ?? 0)).compactMap { out.outlineRoot?.child(at: $0)?.label } == ["Intro", "Appendix"])
        #expect(indices == [0, 2])
        #expect(out.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)
    }
}
