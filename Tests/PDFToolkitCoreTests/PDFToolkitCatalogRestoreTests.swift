import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// The page-for-page rebuild operations (Watermark, OCR, Fill & Sign, Compress, Redact) emit their
/// result through a `CGPDFContext`, which knows only about pages — so everything on the PDF catalog
/// used to be lost: a source with 3 bookmarks came back with 0, the Title/Author were gone, and
/// every hyperlink was dead. These pin the catalog across each rebuild.
struct PDFToolkitCatalogRestoreTests {
    private static let bookmarkLabels = ["Chapter 1", "Chapter 2", "Chapter 3"]

    /// A 3-page PDF carrying 3 bookmarks, a Title/Author, an external link on page 1 and an
    /// internal link on page 2 pointing at page 3.
    private func richPDF(in dir: FixtureDir) throws -> URL {
        // Built from a plain fixture and written to a DIFFERENT path: a `PDFDocument` reads its
        // pages lazily, so writing back over its own source file fails (the same hazard
        // `requireDistinctOutput` exists to catch in production).
        let plain = dir.url("plain-source.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: plain)
        let url = dir.url("rich.pdf")
        let doc = try PDFFixtures.authoringCopy(of: plain)

        let root = PDFOutline()
        for (i, label) in Self.bookmarkLabels.enumerated() {
            let child = PDFOutline()
            child.label = label
            child.destination = PDFDestination(page: try #require(doc.page(at: i)), at: CGPoint(x: 0, y: 700))
            root.insertChild(child, at: root.numberOfChildren)
        }
        doc.outlineRoot = root
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Quarterly Report",
            PDFDocumentAttribute.authorAttribute: "Finance",
        ]

        let external = PDFAnnotation(bounds: CGRect(x: 72, y: 300, width: 200, height: 20),
                                     forType: .link, withProperties: nil)
        external.url = URL(string: "https://example.com/report")
        doc.page(at: 0)?.addAnnotation(external)

        let internalLink = PDFAnnotation(bounds: CGRect(x: 72, y: 250, width: 160, height: 20),
                                         forType: .link, withProperties: nil)
        internalLink.action = PDFActionGoTo(
            destination: PDFDestination(page: try #require(doc.page(at: 2)), at: CGPoint(x: 0, y: 500))
        )
        doc.page(at: 1)?.addAnnotation(internalLink)

        try #require(doc.write(to: url))
        return url
    }

    private func bookmarkLabels(_ doc: PDFDocument) -> [String] {
        guard let root = doc.outlineRoot else { return [] }
        return (0..<root.numberOfChildren).compactMap { root.child(at: $0)?.label }
    }

    private func linkCount(_ doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { total, i in
            total + (doc.page(at: i)?.annotations.filter { $0.type == "Link" }.count ?? 0)
        }
    }

    // MARK: Bookmarks + info dictionary survive every rebuild

    @Test(arguments: ["watermark", "compress", "ocr", "fillsign", "redact"])
    func rebuildKeepsBookmarksAndTitle(_ operation: String) throws {
        let dir = FixtureDir()
        let url = try richPDF(in: dir)

        let data: Data
        switch operation {
        case "watermark":
            var options = WatermarkOptions(text: "DRAFT", fontSize: 40, opacity: 0.3,
                                           rotationDegrees: 45, red: 1, green: 0, blue: 0, tiled: false)
            options.pageScope = .all
            data = try PDFToolkit.watermarkData(inputURL: url, options: options)
        case "compress":
            data = try PDFToolkit.compressData(inputURL: url, quality: 0.7)
        case "ocr":
            data = try PDFToolkit.ocrData(inputURL: url, options: OCROptions()).0
        case "fillsign":
            let item = FillSignItem(
                pageIndex: 0, rect: CGRect(x: 100, y: 100, width: 120, height: 30),
                content: .text(FillSignText(string: "signed", fontSize: 14, red: 0, green: 0, blue: 0))
            )
            data = try PDFToolkit.fillAndSignData(inputURL: url, items: [item])
        default:
            data = try PDFToolkit.redactData(
                inputURL: url,
                marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 60, y: 380, width: 300, height: 50))]
            )
        }

        let out = try #require(PDFDocument(data: data))
        #expect(out.pageCount == 3)
        #expect(bookmarkLabels(out) == Self.bookmarkLabels, "\(operation) lost the outline")
        #expect(out.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Quarterly Report",
                "\(operation) lost the document title")
    }

    /// Each restored bookmark must still resolve to its own page, not collapse onto page 1.
    @Test func restoredBookmarksPointAtTheRightPages() throws {
        let dir = FixtureDir()
        let url = try richPDF(in: dir)
        var options = WatermarkOptions(text: "DRAFT", fontSize: 40, opacity: 0.3,
                                       rotationDegrees: 0, red: 1, green: 0, blue: 0, tiled: false)
        options.pageScope = .all
        let out = try #require(PDFDocument(data: try PDFToolkit.watermarkData(inputURL: url, options: options)))
        let root = try #require(out.outlineRoot)
        for i in 0..<root.numberOfChildren {
            let page = try #require(root.child(at: i)?.destination?.page)
            #expect(out.index(for: page) == i)
        }
    }

    // MARK: Links

    @Test(arguments: ["watermark", "compress", "ocr", "fillsign"])
    func rebuildKeepsWorkingLinks(_ operation: String) throws {
        let dir = FixtureDir()
        let url = try richPDF(in: dir)

        let data: Data
        switch operation {
        case "watermark":
            var options = WatermarkOptions(text: "DRAFT", fontSize: 40, opacity: 0.3,
                                           rotationDegrees: 0, red: 1, green: 0, blue: 0, tiled: false)
            options.pageScope = .all
            data = try PDFToolkit.watermarkData(inputURL: url, options: options)
        case "compress":
            data = try PDFToolkit.compressData(inputURL: url, quality: 0.7)
        case "ocr":
            data = try PDFToolkit.ocrData(inputURL: url, options: OCROptions()).0
        default:
            let item = FillSignItem(
                pageIndex: 0, rect: CGRect(x: 100, y: 100, width: 120, height: 30),
                content: .text(FillSignText(string: "signed", fontSize: 14, red: 0, green: 0, blue: 0))
            )
            data = try PDFToolkit.fillAndSignData(inputURL: url, items: [item])
        }

        let out = try #require(PDFDocument(data: data))
        #expect(linkCount(out) == 2, "\(operation) lost link annotations")

        let external = try #require(out.page(at: 0)?.annotations.first { $0.type == "Link" })
        #expect(external.url?.absoluteString == "https://example.com/report")

        let internalLink = try #require(out.page(at: 1)?.annotations.first { $0.type == "Link" })
        let target = internalLink.destination ?? (internalLink.action as? PDFActionGoTo)?.destination
        #expect(out.index(for: try #require(target?.page)) == 2)
    }

    /// Redaction is the exception: no link is *restored* onto a rasterized page, because a link's URL
    /// can itself disclose the value the user painted over and a live hotspot over a burned-in black
    /// box is recoverable content. Pages with no marks are plain page copies, so they legitimately
    /// keep their own links — nothing was redacted there. Bookmarks survive either way.
    @Test func redactionDropsLinksOnRedactedPagesOnly() throws {
        let dir = FixtureDir()
        let url = try richPDF(in: dir)
        let out = try #require(PDFDocument(data: try PDFToolkit.redactData(
            inputURL: url,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 60, y: 380, width: 300, height: 50))]
        )))
        // Page 1 was rasterized: its external link is gone and is not put back.
        #expect(out.page(at: 0)?.annotations.filter { $0.type == "Link" }.isEmpty == true)
        // Page 2 carried no marks, so it is copied whole — its internal link is untouched.
        #expect(out.page(at: 1)?.annotations.filter { $0.type == "Link" }.count == 1)
        #expect(bookmarkLabels(out) == Self.bookmarkLabels)
        // And the redaction itself still did its job.
        #expect((out.page(at: 0)?.string ?? "").contains(PDFFixtures.marker(1)) == false)
        #expect(out.page(at: 1)?.string?.contains(PDFFixtures.marker(2)) == true)
    }

    // MARK: Mixed-space output (Redact)

    /// Redact rasterizes only the MARKED pages and copies the rest whole, so its output is
    /// mixed-space: a rasterized page is upright at a zero origin, a copied page keeps the source's
    /// crop box and `/Rotate`. Applying one blanket display mapping to every destination moved
    /// bookmarks into the copied pages to the wrong spot — measured as (100, 400) becoming
    /// (340, 350) on a page with crop origin (50, 60) and rotation 90.
    @Test func redactKeepsBookmarkPositionsOnBothKindsOfPage() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        let doc = try PDFFixtures.authoringCopy(of: plain)

        // Both pages get an awkward geometry so a wrong mapping cannot hide.
        for index in 0..<2 {
            let page = try #require(doc.page(at: index))
            page.setBounds(CGRect(x: 50, y: 60, width: 400, height: 500), for: .cropBox)
            page.rotation = 90
        }
        let root = PDFOutline()
        for (index, label) in ["To page 1", "To page 2"].enumerated() {
            let child = PDFOutline()
            child.label = label
            child.destination = PDFDestination(page: try #require(doc.page(at: index)), at: CGPoint(x: 100, y: 400))
            root.insertChild(child, at: root.numberOfChildren)
        }
        doc.outlineRoot = root
        let url = dir.url("mixed.pdf")
        try #require(doc.write(to: url))

        // Mark page 1 only: page 1 is rasterized, page 2 is copied whole.
        let out = try #require(PDFDocument(data: try PDFToolkit.redactData(
            inputURL: url,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 100, y: 100, width: 200, height: 60))]
        )))

        // The rasterized page is emitted upright at a zero origin, so its destination is mapped.
        let marked = try #require(out.outlineRoot?.child(at: 0)?.destination)
        #expect(out.index(for: try #require(marked.page)) == 0)
        #expect(marked.point == PDFToolkit.displayPoint(
            CGPoint(x: 100, y: 400), cropBox: CGRect(x: 50, y: 60, width: 400, height: 500), rotation: 90
        ))

        // The copied page still uses the SOURCE's space, so its destination must be untouched.
        let copied = try #require(out.outlineRoot?.child(at: 1)?.destination)
        #expect(out.index(for: try #require(copied.page)) == 1)
        #expect(copied.point == CGPoint(x: 100, y: 400), "a copied page's destination must not be display-mapped")
    }

    /// A force-rasterized page carries no marks — it is rasterized precisely BECAUSE a match could
    /// not be boxed — but it goes down the same raster branch as a marked page and lands upright at
    /// a zero origin. Deriving the mapped set from the marks alone left it looking like a copied
    /// page, so a bookmark into it kept the source's space and pointed off the raster.
    @Test func redactMapsBookmarksIntoForceRasterizedPagesToo() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        let doc = try PDFFixtures.authoringCopy(of: plain)

        let cropBox = CGRect(x: 50, y: 60, width: 400, height: 500)
        for index in 0..<2 {
            let page = try #require(doc.page(at: index))
            page.setBounds(cropBox, for: .cropBox)
            page.rotation = 90
        }
        let root = PDFOutline()
        for (index, label) in ["To page 1", "To page 2"].enumerated() {
            let child = PDFOutline()
            child.label = label
            child.destination = PDFDestination(page: try #require(doc.page(at: index)), at: CGPoint(x: 100, y: 400))
            root.insertChild(child, at: root.numberOfChildren)
        }
        doc.outlineRoot = root
        let url = dir.url("forced.pdf")
        try #require(doc.write(to: url))

        // Page 1 is marked; page 2 carries no mark and is rasterized only to burn its text away.
        var options = PDFRedactionExportOptions.default
        options.forceRasterizePages = [1]
        let out = try #require(PDFDocument(data: try PDFToolkit.redactData(
            inputURL: url,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 100, y: 100, width: 200, height: 60))],
            options: options
        )))

        let expected = PDFToolkit.displayPoint(CGPoint(x: 100, y: 400), cropBox: cropBox, rotation: 90)
        for index in 0..<2 {
            let destination = try #require(out.outlineRoot?.child(at: index)?.destination)
            #expect(out.index(for: try #require(destination.page)) == index)
            #expect(destination.point == expected, "page \(index + 1) was rasterized, so its destination must be mapped")
        }
    }

    // MARK: Fast path

    /// A plain document with nothing on its catalog must skip the restore pass entirely — the
    /// Compress target sweep pays this once per quality rung.
    @Test func plainDocumentSkipsTheRestorePass() throws {
        let dir = FixtureDir()
        let url = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: url)
        let source = try #require(PDFDocument(url: url))
        let produced = try PDFToolkit.compressData(inputURL: url, quality: 0.7)
        #expect(PDFToolkit.restoringCatalog(produced, from: source, restoreLinks: true) == produced)
    }

    /// A bookmark's destination POINT is stored in the source's unrotated user space, but a rebuild
    /// emits every page upright at a zero origin — so a bookmark into a /Rotate 90 page has to go
    /// through the same display mapping the page content and the link bounds do. It used to be
    /// copied raw, landing the reader at the wrong spot (here: past the rebuilt page's height).
    @Test func restoredBookmarkPointIsMappedIntoTheRebuiltPagesSpace() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("rotated.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let page = try #require(doc.page(at: 0))
        page.rotation = 90
        let root = PDFOutline()
        let mark = PDFOutline()
        mark.label = "Top"
        // Top-left of the unrotated page: (0, 792) on a 612×792 crop box.
        mark.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: PDFFixtures.letter.height))
        root.insertChild(mark, at: 0)
        doc.outlineRoot = root
        #expect(doc.write(to: src))

        var options = WatermarkOptions(text: "DRAFT", fontSize: 40, opacity: 0.3,
                                       rotationDegrees: 0, red: 1, green: 0, blue: 0, tiled: false)
        options.pageScope = .all
        let out = try #require(PDFDocument(data: try PDFToolkit.watermarkData(inputURL: src, options: options)))
        let restored = try #require(out.outlineRoot?.child(at: 0)?.destination)
        // The rebuilt page is 792×612 (rotation flattened). Display-mapping (0, 792) under 90°
        // gives (792, 612) — the far corner — which then clamps into the page box, so the point
        // stays ON the page. The raw point's y of 792 would sit above a 612-tall page.
        let box = try #require(restored.page).bounds(for: .cropBox)
        #expect(box.size == CGSize(width: 792, height: 612))
        #expect(restored.point.y <= box.maxY)
        #expect(restored.point == PDFToolkit.displayPoint(
            CGPoint(x: 0, y: PDFFixtures.letter.height),
            cropBox: CGRect(origin: .zero, size: PDFFixtures.letter),
            rotation: 90))
    }

    /// A bookmark that opens a WEB page carries a `PDFActionURL` and no destination. The rebuild
    /// used to copy only the label, silently turning every such bookmark into dead text.
    @Test func rebuildKeepsURLOnlyBookmarks() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("weblink.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        let web = PDFOutline()
        web.label = "Our site"
        web.action = PDFActionURL(url: try #require(URL(string: "https://example.com/docs")))
        root.insertChild(web, at: 0)
        doc.outlineRoot = root
        #expect(doc.write(to: src))

        let out = try #require(PDFDocument(data: try PDFToolkit.compressData(inputURL: src, quality: 0.7)))
        let kept = try #require(out.outlineRoot?.child(at: 0))
        #expect(kept.label == "Our site")
        #expect((kept.action as? PDFActionURL)?.url?.absoluteString == "https://example.com/docs")
    }

    /// A "fit the page" link destination carries PDFKit's unspecified sentinel (+FLT_MAX) instead of
    /// a real coordinate. Running it through the display mapping of a rotated target page negated it
    /// into -FLT_MAX — which PDFKit reads as a real coordinate far off the page — so every Fit link
    /// into a rotated page turned into a jump to nowhere. The sentinel has to pass through untouched.
    @Test func restoredFitLinkIntoARotatedPageKeepsItsSentinel() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("fitlink.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let target = try #require(doc.page(at: 1))
        target.rotation = 90
        let sentinel = CGFloat(kPDFDestinationUnspecifiedValue)
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 300, width: 160, height: 20),
                                 forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(
            destination: PDFDestination(page: target, at: CGPoint(x: sentinel, y: sentinel))
        )
        doc.page(at: 0)?.addAnnotation(link)
        #expect(doc.write(to: src))

        var options = WatermarkOptions(text: "DRAFT", fontSize: 40, opacity: 0.3,
                                       rotationDegrees: 0, red: 1, green: 0, blue: 0, tiled: false)
        options.pageScope = .all
        let out = try #require(PDFDocument(data: try PDFToolkit.watermarkData(inputURL: src, options: options)))
        let restored = try #require(out.page(at: 0)?.annotations.first { $0.type == "Link" })
        let dest = try #require(restored.destination ?? (restored.action as? PDFActionGoTo)?.destination)
        #expect(out.index(for: try #require(dest.page)) == 1)
        #expect(dest.point.x == sentinel)
        #expect(dest.point.y == sentinel)
    }

    /// A rebuild whose page count doesn't match the source is left alone rather than mangled.
    @Test func mismatchedPageCountLeavesTheOutputUntouched() throws {
        let dir = FixtureDir()
        let source = try #require(PDFDocument(url: try richPDF(in: dir)))
        let other = dir.url("other.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: other)
        let produced = try Data(contentsOf: other)
        #expect(PDFToolkit.restoringCatalog(produced, from: source, restoreLinks: true) == produced)
    }
}
