import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// A unique scratch directory for a test's fixture files, removed when the test's holder is
/// deinitialized. Modeled on SyncCloud's `ContentSignalExtractorTests.FixtureDir` so operation
/// tests can write real PDFs to disk and clean up deterministically.
final class FixtureDir {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PdfToolkitTests-\(UUID().uuidString)", isDirectory: true)

    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// A child URL inside this fixture directory (the file need not exist yet).
    func url(_ name: String) -> URL { url.appendingPathComponent(name) }
    func path(_ name: String) -> String { url(name).path }
}

/// Builders and readers for real PDF fixtures. Pages carry a distinctive marker string drawn with
/// genuine text ops (via CoreText), so PDFKit's text extraction sees them and tests can assert on
/// page identity and order after an operation. The marker for page *i* (1-based) defaults to
/// `MARKERPAGE<i>` — a token unlikely to appear by accident.
enum PDFFixtures {
    /// US Letter, matching CoreGraphics' default and PDFKit's expectations.
    static let letter = CGSize(width: 612, height: 792)

    /// The canonical marker string drawn on page `oneBased`.
    static func marker(_ oneBased: Int) -> String { "MARKERPAGE\(oneBased)" }

    /// Writes a PDF whose page *i* draws `markers[i]` as a single line of real text.
    static func writePDF(markers: [String], to url: URL, size: CGSize = PDFFixtures.letter) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for line in markers {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: NSFont.systemFont(ofSize: 24)]
            )
            context.textPosition = CGPoint(x: 72, y: size.height / 2)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    /// Convenience: an `n`-page PDF whose pages carry the canonical `MARKERPAGE1…MARKERPAGEn` markers.
    @discardableResult
    static func writePDF(pageCount n: Int, to url: URL, size: CGSize = PDFFixtures.letter) throws -> [String] {
        let markers = (1...max(1, n)).map(marker)
        try writePDF(markers: markers, to: url, size: size)
        return markers
    }

    /// The PDF at `url` as a document a fixture can decorate — bookmarks, links, info fields — and
    /// then write. Its pages are copied into a FRESH `PDFDocument` rather than opened in place: on
    /// macOS 27, writing a document opened from a file whose page tree is unchanged re-emits that
    /// file's original outline (none, for a marker PDF) and ignores the one set in memory, and
    /// stamps no Producer or dates. Every outline fixture built the in-place way came back empty.
    static func authoringCopy(of url: URL) throws -> PDFDocument {
        let source = try #require(PDFDocument(url: url))
        let doc = PDFDocument()
        for i in 0..<source.pageCount {
            doc.insert(try #require(source.page(at: i)?.copy() as? PDFPage), at: doc.pageCount)
        }
        return doc
    }

    /// An `n`-page marker PDF carrying a top-level outline: one bookmark per `bookmarks` entry, each
    /// pointing at the given zero-based page (destination near that page's top edge). Lets
    /// outline-preservation tests build a source whose bookmarks a later operation must keep pointing
    /// at the CORRECT page. Built by writing the pages, then attaching the outline via PDFKit and
    /// rewriting — the same construction the metadata-clean test uses.
    @discardableResult
    static func writePDF(
        pageCount n: Int,
        bookmarks: [(label: String, pageIndex: Int)],
        to url: URL,
        size: CGSize = PDFFixtures.letter
    ) throws -> [String] {
        // Write the marker pages to a SEPARATE base file, load from it, then write the outlined
        // document to the final `url`. `PDFDocument(url:)` reads pages lazily, so writing the outline
        // back onto the very file being read races those reads and intermittently corrupts the output
        // (the same self-overwrite hazard `requireDistinctOutput` guards against in production). The
        // rotations fixture uses this same distinct-base dance for exactly this reason.
        let base = url.deletingLastPathComponent()
            .appendingPathComponent("outline-base-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: base) }
        let markers = try writePDF(pageCount: n, to: base, size: size)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        for (i, bookmark) in bookmarks.enumerated() {
            let child = PDFOutline()
            child.label = bookmark.label
            if let page = doc.page(at: bookmark.pageIndex) {
                child.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: size.height))
            }
            root.insertChild(child, at: i)
        }
        doc.outlineRoot = root
        #expect(doc.write(to: url))
        return markers
    }

    /// Raw bytes of a marker PDF, for callers that build documents in memory.
    static func pdfData(markers: [String], size: CGSize = PDFFixtures.letter) throws -> Data {
        let dir = FixtureDir()
        let url = dir.url("mem.pdf")
        try writePDF(markers: markers, to: url, size: size)
        return try Data(contentsOf: url)
    }

    /// A single US-Letter page carrying two well-separated text tokens: `top` drawn near the top edge
    /// and `bottom` near the bottom edge (PDF coordinates, origin bottom-left). A redaction rectangle
    /// over one half then covers exactly one token, so a pixel-level test can prove the black fill lands
    /// only where the mark is — the covered token gone, the other still rendered.
    static func writeTwoZonePage(top: String, bottom: String, to url: URL, size: CGSize = PDFFixtures.letter) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        for (line, y) in [(top, size.height - 100), (bottom, CGFloat(80))] {
            let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 24)])
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    /// A one-page marker PDF composed from any mix of: custom media size, intrinsic rotation, a
    /// first-page crop box (possibly with non-zero origin), and a green square annotation — for
    /// geometry tests that pin where content and annotations land on rebuilt pages.
    static func writePDF(
        markers: [String],
        size: CGSize = PDFFixtures.letter,
        rotations: [Int: Int] = [:],
        cropFirstPageTo crop: CGRect? = nil,
        greenSquareOnFirstPage annotationRect: CGRect? = nil,
        to url: URL
    ) throws {
        let base = url.deletingLastPathComponent()
            .appendingPathComponent("mix-base-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: base) }
        try writePDF(markers: markers, to: base, size: size)
        let doc = try #require(PDFDocument(url: base))
        if let crop {
            try #require(doc.page(at: 0)).setBounds(crop, for: .cropBox)
        }
        for (index, degrees) in rotations {
            try #require(doc.page(at: index)).rotation = degrees
        }
        if let annotationRect {
            let annotation = PDFAnnotation(bounds: annotationRect, forType: .square, withProperties: nil)
            annotation.color = .green
            annotation.interiorColor = .green
            try #require(doc.page(at: 0)).addAnnotation(annotation)
        }
        #expect(doc.write(to: url))
    }

    /// A file that is not a valid PDF, for "corrupt input" cases.
    static func writeCorrupt(to url: URL) throws {
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: url, options: .atomic)
    }

    /// A hand-authored minimal 1-page PDF that can carry catalog-level constructs PDFKit's writer can't
    /// produce: an XMP `/Metadata` packet (the metadata-leak vector) and/or an interactive `/AcroForm`.
    /// Byte offsets for the xref table are computed as the buffer is assembled, so the result loads as a
    /// real `PDFDocument` (and via CoreGraphics for catalog probing). See ``catalogHasEntry(_:at:)``.
    static func writeRawPDF(xmpCreator: String? = nil, includeAcroForm: Bool = false, to url: URL) throws {
        var catalog = "<< /Type /Catalog /Pages 2 0 R"
        if xmpCreator != nil { catalog += " /Metadata 5 0 R" }
        if includeAcroForm { catalog += " /AcroForm << /Fields [] >>" }
        catalog += " >>"

        var bodies = [
            catalog,
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            "<< /Length 0 >>\nstream\n\nendstream",
        ]
        if let xmpCreator {
            let packet = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
                + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
                + "<rdf:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
                + "<dc:creator><rdf:Seq><rdf:li>\(xmpCreator)</rdf:li></rdf:Seq></dc:creator>"
                + "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
            bodies.append("<< /Type /Metadata /Subtype /XML /Length \(packet.utf8.count) >>\nstream\n\(packet)\nendstream")
        }

        var pdf = "%PDF-1.5\n"
        var offsets: [Int] = []
        for (i, body) in bodies.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        let size = bodies.count + 1
        pdf += "xref\n0 \(size)\n0000000000 65535 f \n"
        for off in offsets { pdf += String(format: "%010d 00000 n \n", off) }
        pdf += "trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF"
        try Data(pdf.utf8).write(to: url, options: .atomic)
    }

    /// Whether the PDF's document catalog carries an entry under `name` (e.g. "Metadata" for the XMP
    /// packet, "AcroForm" for a form) — read straight off the CoreGraphics catalog, so it sees
    /// catalog-level constructs PDFKit doesn't surface. Presence-only; doesn't decode the value.
    static func catalogHasEntry(_ name: String, at url: URL) throws -> Bool {
        let doc = try #require(PDFDocument(url: url))
        guard let catalog = doc.documentRef?.catalog else { return false }
        var obj: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(catalog, name, &obj)
    }

    /// A marker PDF encrypted with an OWNER password only (empty user password): it opens with no
    /// prompt (`isLocked == false`) yet reports `isEncrypted == true` — the shape of third-party
    /// "restrictions-only" PDFs. PDFKit's writer can't produce one (`PDFToolkit.encrypt` always
    /// sets both passwords), so this builds it with CoreGraphics directly.
    static func writeOwnerRestrictedPDF(markers: [String], to url: URL, ownerPassword: String = "owner-secret") throws {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: letter)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let options: [CFString: Any] = [kCGPDFContextOwnerPassword: ownerPassword]
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, options as CFDictionary))
        for line in markers {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: NSFont.systemFont(ofSize: 24)]
            )
            context.textPosition = CGPoint(x: 72, y: letter.height / 2)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    // Note: the `emptyPDF` guards in `PDFToolkit` are deliberately not fixture-tested. PDFKit's
    // writer cannot persist a zero-page document — an empty (or fully emptied) `PDFDocument` reopens
    // as a one-blank-page file, and a hand-crafted zero-page PDF is rejected on load — so those
    // guards are defensive and unreachable through any constructible input.

    // MARK: Readers

    static func pageCount(at url: URL) throws -> Int {
        try #require(PDFDocument(url: url)).pageCount
    }

    /// The document's top-level outline as `(label, destinationPageIndex)` pairs, in order — read by
    /// OPENING the output and resolving each bookmark's destination back to a page index in that same
    /// document, so a test can assert a bookmark both survived AND still points at the correct page.
    /// A bookmark whose destination no longer resolves to a page in the document reports index `-1`.
    static func outlineBookmarks(at url: URL) throws -> [(label: String, pageIndex: Int)] {
        let doc = try #require(PDFDocument(url: url))
        guard let root = doc.outlineRoot else { return [] }
        var result: [(label: String, pageIndex: Int)] = []
        for i in 0..<root.numberOfChildren {
            guard let child = root.child(at: i) else { continue }
            let label = child.label ?? ""
            var index = -1
            if let page = child.destination?.page {
                let raw = doc.index(for: page)
                index = (raw == NSNotFound) ? -1 : raw
            }
            result.append((label, index))
        }
        return result
    }

    /// The trimmed extracted text of every page, in document order.
    static func pageTexts(at url: URL) throws -> [String] {
        let doc = try #require(PDFDocument(url: url))
        return (0..<doc.pageCount).map { i in
            doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// ``pageTexts(at:)`` for bytes that were never written to disk — the in-memory `*Data` cores.
    static func pageTexts(data: Data) throws -> [String] {
        let doc = try #require(PDFDocument(data: data))
        return (0..<doc.pageCount).map { i in
            doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// The `PDFPage.rotation` of every page, in document order.
    static func pageRotations(at url: URL) throws -> [Int] {
        let doc = try #require(PDFDocument(url: url))
        return (0..<doc.pageCount).map { doc.page(at: $0)?.rotation ?? 0 }
    }

    /// The media-box size of one page.
    static func pageSize(at url: URL, page index: Int = 0) throws -> CGSize {
        let doc = try #require(PDFDocument(url: url))
        return try #require(doc.page(at: index)).bounds(for: .mediaBox).size
    }

    /// Renders a page to a bitmap and returns a sampler from PDF-space points (origin bottom-left)
    /// to average brightness in 0…1 (0 = black, 1 = white), so geometry tests can assert *where*
    /// content, annotations, and redaction fills landed on the emitted page.
    static func brightnessSampler(at url: URL, page index: Int = 0) throws -> (CGFloat, CGFloat) -> CGFloat {
        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: index))
        let media = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: media.size, for: .mediaBox)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let sx = CGFloat(rep.pixelsWide) / media.width
        let sy = CGFloat(rep.pixelsHigh) / media.height
        return { pdfX, pdfY in
            let col = min(rep.pixelsWide - 1, max(0, Int(pdfX * sx)))
            let row = min(rep.pixelsHigh - 1, max(0, Int((media.height - pdfY) * sy)))   // flip: PDF y-up → image y-down
            guard let c = rep.colorAt(x: col, y: row)?.usingColorSpace(.deviceRGB) else { return 1 }
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
    }

    /// The darkest sample over a grid of PDF-space points — a cheap "are there glyph strokes in
    /// this band?" probe for asserting text rendered where the geometry says it should.
    static func darkestSample(
        _ sampler: (CGFloat, CGFloat) -> CGFloat,
        xRange: StrideThrough<CGFloat>,
        yValues: [CGFloat]
    ) -> CGFloat {
        var darkest: CGFloat = 1
        for x in xRange {
            for y in yValues {
                darkest = min(darkest, sampler(x, y))
            }
        }
        return darkest
    }
}

extension PDFFixtures {
    /// A 2-page PDF carrying a REAL catalog `/AcroForm` with one text field on page 1.
    ///
    /// Assembled byte by byte because PDFKit's writer will NOT produce an `/AcroForm` from widget
    /// annotations — a fixture built with `PDFAnnotation(forType: .widget)` reports
    /// `hasInteractiveForm == false`, so it silently tests nothing. Offsets are computed so the xref
    /// table is valid and PDFKit parses the file.
    static func writeAcroFormPDF(to url: URL) throws {
        let stream = "BT /Helv 24 Tf 72 396 Td (MARKERPAGE1) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] /Contents 6 0 R /Resources << /Font << /Helv 7 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /Helv 7 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (FullName) /V (typed value) /Rect [72 600 272 624] /DA (/Helv 12 Tf 0 g) /F 4 /P 3 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        guard let data = pdf.data(using: .ascii) else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        try data.write(to: url, options: .atomic)
    }


    /// Rebuilds `src` as an image-only PDF at `out` through Compress's **unbounded** core.
    ///
    /// `PDFToolkit.compress(inputURL:outputURL:quality:)` is a save path, so it is bounded by the
    /// input's size (see ``PDFToolkit/compressDataBounded(inputURL:quality:onProgress:isCancelled:)``):
    /// rasterizing a lean text fixture inflates it, so the public call correctly passes the ORIGINAL
    /// bytes through and the output still has its text layer. Tests that pin raster mechanics —
    /// rotation baked flat, annotations drawn in, displayed geometry — and fixtures that need a
    /// genuinely scanned-looking page must therefore drive the core directly. The save-path bound
    /// itself is covered by `PDFToolkitReviewFollowUpTests`.
    static func rasterize(_ src: URL, to out: URL, quality: Double = 1.0) throws {
        try PDFToolkit.compressData(inputURL: src, quality: quality).write(to: out, options: .atomic)
    }
}

extension PDFOperationError {
    /// A stable, associated-value-free tag so tests can assert *which* case was thrown without the
    /// type needing `Equatable` (its associated `URL`/`String`/`Int` payloads are inspected via
    /// `if case` where a test cares about them). Paired with swift-testing's
    /// `#expect(throws: PDFOperationError.self) { … }`, which returns the thrown error.
    var kind: String {
        switch self {
        case .couldNotOpen: return "couldNotOpen"
        case .couldNotWrite: return "couldNotWrite"
        case .outputMatchesInput: return "outputMatchesInput"
        case .invalidPageRange: return "invalidPageRange"
        case .pageOutOfBounds: return "pageOutOfBounds"
        case .pageRangeRequired: return "pageRangeRequired"
        case .cannotRemoveEveryPage: return "cannotRemoveEveryPage"
        case .fileAccessDenied: return "fileAccessDenied"
        case .noInputFiles: return "noInputFiles"
        case .noPagesSelected: return "noPagesSelected"
        case .compressionFailed: return "compressionFailed"
        case .emptyPDF: return "emptyPDF"
        case .noRedactions: return "noRedactions"
        case .redactionFailed: return "redactionFailed"
        case .watermarkTextRequired: return "watermarkTextRequired"
        case .watermarkImageRequired: return "watermarkImageRequired"
        case .watermarkFailed: return "watermarkFailed"
        case .noFillSignItems: return "noFillSignItems"
        case .fillSignFailed: return "fillSignFailed"
        case .passwordRequired: return "passwordRequired"
        case .incorrectPassword: return "incorrectPassword"
        case .notEncrypted: return "notEncrypted"
        case .protectionFailed: return "protectionFailed"
        case .metadataEncrypted: return "metadataEncrypted"
        case .couldNotOpenImage: return "couldNotOpenImage"
        case .cropTooSmall: return "cropTooSmall"
        case .ocrFailed: return "ocrFailed"
        case .encryptedInput: return "encryptedInput"
        case .permissionsForbidEditing: return "permissionsForbidEditing"
        case .couldNotEncodeOutput: return "couldNotEncodeOutput"
        }
    }
}
