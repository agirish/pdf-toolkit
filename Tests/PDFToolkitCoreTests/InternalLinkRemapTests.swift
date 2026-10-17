import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

// Internal links on copied pages must follow their target page to its new position.
//
// A link's destination lives outside the page it sits on: as a named destination it lives in the
// catalog (`/Dests`, or a `/Names /Dests` tree), and even as an explicit array it names a page
// object of the SOURCE document. The page-copy rebuilds keep the annotation but not that, and before
// the remap a Chrome-printed book came out with every internal link dead (Extract, Reorder, Crop,
// Redact) or pointing at the wrong page (Auto-crop) — and the corpus's explicit-array link pointed
// at the wrong page after a reorder. See ``PDFToolkit/remapInternalLinks``.

/// Reading a document's internal links as the page indices they land on.
enum InternalLinks {
    /// Every internal link on every page, in annotation order, as the index of the page it lands on
    /// — or -1 for one that no longer resolves. URL and other page-independent links are skipped.
    static func targets(in doc: PDFDocument) -> [[Int]] {
        (0..<doc.pageCount).map { index in
            (doc.page(at: index)?.annotations ?? []).compactMap { annotation in
                guard annotation.type == "Link", annotation.url == nil else { return nil }
                let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
                guard destination != nil || annotation.action == nil else { return nil }
                return destination?.page.map { doc.index(for: $0) } ?? -1
            }
        }
    }

    /// What ``targets(in:)`` must report for an output whose page *k* is a copy of source page
    /// `order[k]`: each link follows its target to the first output position that page took, and a
    /// link whose target page was not kept is gone. Assumes no link in the source is already dead,
    /// which each caller checks.
    static func expected(from source: PDFDocument, order: [Int]) -> [[Int]] {
        var firstPosition: [Int: Int] = [:]
        for (position, page) in order.enumerated() where firstPosition[page] == nil {
            firstPosition[page] = position
        }
        let sourceTargets = targets(in: source)
        return order.map { page in sourceTargets[page].compactMap { firstPosition[$0] } }
    }
}

// MARK: - On real files

struct RealCorpusInternalLinkTests {
    private func open(_ data: Data) throws -> PDFDocument { try #require(PDFDocument(data: data)) }

    /// The precondition every test here leans on: PDFKit resolves the book's named destinations in
    /// the SOURCE, so a link that dies in an output was killed by the operation.
    @Test func theBookResolvesEveryNamedDestinationInTheSource() throws {
        let book = try RealCorpus.linkedBook.document()
        #expect(InternalLinks.targets(in: book) == [[1, 2, 3, 4], [2, 0], [3], [4, 1], [0]])
    }

    /// Every page moves one slot to the left, so no link anywhere can land right by keeping its old
    /// index — and each corpus file's links are named (`linkedBook`, `chromeArticle`) or explicit
    /// arrays (`outlineNested`), the two shapes producers write.
    @Test(arguments: [RealCorpus.linkedBook, .chromeArticle, .outlineNested])
    func reorderingFollowsEveryInternalLinkToItsTargetsNewPosition(_ file: RealCorpus) throws {
        let source = try file.document()
        #expect(!InternalLinks.targets(in: source).joined().contains(-1))
        let order = Array(1..<source.pageCount) + [0]

        let doc = try open(try PDFToolkit.reorderData(inputURL: file.url, order: order))
        #expect(InternalLinks.targets(in: doc) == InternalLinks.expected(from: source, order: order))
    }

    /// The real check, on text rather than indices: each link in a shuffled book lands on the page
    /// carrying its own target's marker.
    @Test func everyLinkInAShuffledBookLandsOnItsOwnTargetsText() throws {
        let order = [2, 0, 4, 1, 3]
        let doc = try open(try PDFToolkit.reorderData(inputURL: RealCorpus.linkedBook.url, order: order))
        let source = try RealCorpus.linkedBook.document()
        let sourceTargets = InternalLinks.targets(in: source)
        let targets = InternalLinks.targets(in: doc)

        for (position, page) in order.enumerated() {
            #expect(targets[position].count == sourceTargets[page].count)
            for (landed, wanted) in zip(targets[position], sourceTargets[page]) {
                let text = landed >= 0 ? doc.page(at: landed)?.string ?? "" : ""
                #expect(text.contains("CORPUSTOKEN-BOOK-\(wanted)"),
                        "a link on source page \(page) should reach page \(wanted), landed on \(landed)")
            }
        }
    }

    /// A link into a page that was not extracted is removed — not left dead, and not left pointing
    /// at whatever page now has its old index. The external link beside it is untouched.
    @Test func extractingRemovesTheLinksWhoseTargetWasNotKept() throws {
        let subset = try open(try PDFToolkit.extractData(inputURL: RealCorpus.linkedBook.url, pageIndices: [1, 3]))
        // Siting's links go to Power and the contents, neither kept; Uplink's go to the index (not
        // kept) and Siting (now page 0).
        #expect(InternalLinks.targets(in: subset) == [[], [0]])

        let last = try open(try PDFToolkit.extractData(inputURL: RealCorpus.linkedBook.url, pageIndices: [4]))
        #expect(InternalLinks.targets(in: last) == [[]])
        let urls = (last.page(at: 0)?.annotations ?? []).compactMap { $0.url?.absoluteString }
        #expect(urls == ["https://example.org/handbook"])
    }

    /// A page extracted twice gets its links re-pointed on BOTH copies, each at the first position
    /// its target took.
    @Test func aPageCopiedTwiceHasBothCopiesRepointed() throws {
        let order = [3, 1, 3]
        let source = try RealCorpus.linkedBook.document()
        let doc = try open(try PDFToolkit.extractData(inputURL: RealCorpus.linkedBook.url, pageIndices: order))
        #expect(InternalLinks.targets(in: doc) == InternalLinks.expected(from: source, order: order))
        #expect(InternalLinks.targets(in: doc) == [[1], [], [1]])
    }

    /// The rebuilds that copy every page in order. Their links can't move, but they lost the catalog
    /// that named destinations resolve through, so Crop came back with every link dead and Auto-crop
    /// with most of them pointing at the wrong page.
    @Test(arguments: ["crop", "autoCrop", "cleanMetadata", "removePassword"])
    func wholeDocumentRebuildsKeepEveryInternalLink(_ operation: String) throws {
        let url = RealCorpus.linkedBook.url
        let data: Data
        switch operation {
        case "crop":
            data = try PDFToolkit.cropData(inputURL: url, insets: CropInsets(top: 12, left: 12, bottom: 12, right: 12))
        case "autoCrop":
            data = try PDFToolkit.autoCropData(inputURL: url, padding: 6, unified: true)
        case "cleanMetadata":
            data = PDFToolkit.strippingAllMetadata(from: try RealCorpus.linkedBook.data)
        default:
            let dir = FixtureDir()
            let locked = dir.url("locked.pdf")
            try PDFToolkit.writeOutput(
                try PDFToolkit.encryptData(
                    inputURL: url, options: .addPassword(restrictEditing: false, password: "open-sesame")
                ),
                to: locked
            )
            data = try PDFToolkit.removePasswordData(inputURL: locked, password: "open-sesame")
        }
        let doc = try open(data)
        #expect(InternalLinks.targets(in: doc) == [[1, 2, 3, 4], [2, 0], [3], [4, 1], [0]], "\(operation)")
    }

    /// Redact copies the pages it doesn't mark, and their links must keep working — including the
    /// ones INTO the page it rasterized. The rasterized page's own links are deliberately not
    /// restored (a URL can disclose what was painted over).
    @Test func redactingKeepsTheLinksOnTheUntouchedPages() throws {
        let mark = RedactionMark(pageIndex: 2, rect: CGRect(x: 72, y: 600, width: 200, height: 40))
        let doc = try open(try PDFToolkit.redactData(inputURL: RealCorpus.linkedBook.url, marks: [mark]))
        #expect(InternalLinks.targets(in: doc) == [[1, 2, 3, 4], [2, 0], [], [4, 1], [0]])
    }
}

// MARK: - On the other two ways a destination can be written

struct InternalLinkRemapTests {
    /// Three blank pages whose internal links resolve through a catalog `/Names /Dests` NAME TREE —
    /// the form PDF 1.2+ producers use instead of Chrome's `/Dests` dictionary — one as a link
    /// `/Dest` and one as a GoTo action's `/D`. Byte-authored, because neither Quartz nor PDFKit
    /// writes a name tree: Quartz resolves its own named destinations to arrays as it writes.
    ///
    /// Page 0 links to "last" (page 2); page 2 links to "first" (page 0); page 1 has none.
    static func nameTreePDF() -> Data {
        let page = "/Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
        let link = "/Type /Annot /Subtype /Link /Rect [72 72 200 100] /Border [0 0 0]"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Names << /Dests 6 0 R >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< \(page) /Annots [7 0 R] >>",
            "<< \(page) >>",
            "<< \(page) /Annots [8 0 R] >>",
            "<< /Names [(first) [3 0 R /XYZ 0 700 null] (last) [5 0 R /XYZ 0 600 null]] >>",
            "<< \(link) /Dest (last) >>",
            "<< \(link) /A << /S /GoTo /D (first) >> >>",
        ]
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    @Test func linksThroughANameTreeFollowTheirTargets() throws {
        let dir = FixtureDir()
        let url = dir.url("name-tree.pdf")
        try Self.nameTreePDF().write(to: url)
        let source = try #require(PDFDocument(url: url))
        try #require(InternalLinks.targets(in: source) == [[2], [], [0]], "PDFKit did not resolve the name tree")

        let reordered = try #require(PDFDocument(data: try PDFToolkit.reorderData(inputURL: url, order: [2, 0, 1])))
        #expect(InternalLinks.targets(in: reordered) == [[1], [0], []])

        let firstOnly = try #require(PDFDocument(data: try PDFToolkit.extractData(inputURL: url, pageIndices: [0])))
        #expect(InternalLinks.targets(in: firstOnly) == [[]])

        let cropped = try #require(PDFDocument(data: try PDFToolkit.cropData(
            inputURL: url, insets: CropInsets(top: 10, left: 10, bottom: 10, right: 10)
        )))
        #expect(InternalLinks.targets(in: cropped) == [[2], [], [0]])
    }

    /// Quartz's own named destinations come out as an INDIRECT explicit array (`/Dest 5 0 R`), a
    /// third shape. Each of 4 pages links to the next, wrapping round.
    @Test func quartzWrittenDestinationsFollowTheirTargets() throws {
        let dir = FixtureDir()
        let url = dir.url("quartz-dests.pdf")
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 0..<4 {
            context.beginPDFPage(nil)
            context.addDestination("page\(index)" as CFString, at: CGPoint(x: 0, y: 700))
            context.setDestination("page\((index + 1) % 4)" as CFString, for: CGRect(x: 72, y: 72, width: 128, height: 28))
            context.endPDFPage()
        }
        context.closePDF()
        let source = try #require(PDFDocument(url: url))
        try #require(InternalLinks.targets(in: source) == [[1], [2], [3], [0]])

        let order = [3, 2, 1, 0]
        let reversed = try #require(PDFDocument(data: try PDFToolkit.reorderData(inputURL: url, order: order)))
        #expect(InternalLinks.targets(in: reversed) == InternalLinks.expected(from: source, order: order))
        #expect(InternalLinks.targets(in: reversed) == [[3], [0], [1], [2]])
    }
}
