import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// Fill & Sign's ``FillSignAnnotations/keep``: the pages' review comments come through the redraw
/// as annotations — whole dictionaries, appearance streams, popups and replies — instead of being
/// drawn into the page. ``FillSignAnnotations/flatten`` draws them in, as Fill & Sign always has.
///
/// The fixture is assembled by hand, like the catalog tests', so every comment is exactly what a
/// producer wrote (PDFKit's writer would rewrite their appearances), and it reads the same on
/// macOS 26 and 27. Everything is read back with CoreGraphics, apart from the code under test.
struct PDFToolkitKeepCommentsTests {
    static let filePayload = "COMMENT-ATTACHMENT-PAYLOAD"
    static let docPayload = "DOC-ATTACHMENT-PAYLOAD"

    /// One comment in the fixture. `nm` is its `/NM`, which the tests find it by; `extra` is the
    /// rest of its dictionary; `appearance` is its `/AP /N` drawing in a `/BBox` the rect's size.
    struct Comment {
        let nm: String
        let subtype: String
        let rect: CGRect
        var extra = ""
        var appearance: String? = "0.15 0.2 0.25 rg 0 0 W H re f"
        var page = 0
    }

    /// Page 1 is upright at a zero origin, so a kept comment comes through unchanged. Page 2 is
    /// turned 90° and cropped to an offset box, so a redraw moves its comments.
    static let page2Crop = CGRect(x: 50, y: 60, width: 512, height: 672)

    static let comments: [Comment] = [
        Comment(nm: "note", subtype: "Text", rect: CGRect(x: 72, y: 600, width: 20, height: 20),
                extra: "/Contents (Sticky note text) /T (Ada) /C [1 1 0] /Name /Comment /F 28 /M (D:20261025120000Z) /Popup @popup"),
        Comment(nm: "popup", subtype: "Popup", rect: CGRect(x: 100, y: 640, width: 200, height: 80),
                extra: "/Parent @note /Open false", appearance: nil),
        Comment(nm: "reply", subtype: "Text", rect: CGRect(x: 100, y: 600, width: 20, height: 20),
                extra: "/Contents (A reply) /T (Bo) /IRT @note /RT /R /C [0 1 1] /F 4"),
        Comment(nm: "freetext", subtype: "FreeText", rect: CGRect(x: 150, y: 520, width: 150, height: 30),
                extra: "/Contents (Free text) /DA (/Helv 12 Tf 0 0 1 rg) /C [0 0 1] /F 4"),
        Comment(nm: "highlight", subtype: "Highlight", rect: CGRect(x: 72, y: 450, width: 128, height: 20),
                extra: "/QuadPoints [72 470 200 470 72 450 200 450] /C [1 1 0] /Contents (Highlighted) /T (Ada) /F 4"),
        Comment(nm: "underline", subtype: "Underline", rect: CGRect(x: 220, y: 450, width: 120, height: 20),
                extra: "/QuadPoints [220 470 340 470 220 450 340 450] /C [0 0.5 0] /F 4"),
        Comment(nm: "strikeout", subtype: "StrikeOut", rect: CGRect(x: 360, y: 450, width: 120, height: 20),
                extra: "/QuadPoints [360 470 480 470 360 450 480 450] /C [1 0 0] /F 4"),
        Comment(nm: "squiggly", subtype: "Squiggly", rect: CGRect(x: 72, y: 410, width: 128, height: 20),
                extra: "/QuadPoints [72 430 200 430 72 410 200 410] /C [1 0 1] /F 4"),
        Comment(nm: "ink", subtype: "Ink", rect: CGRect(x: 220, y: 400, width: 120, height: 40),
                extra: "/InkList [[230 410 260 430 330 405]] /C [1 0 0] /BS << /W 2 >> /F 4"),
        Comment(nm: "square", subtype: "Square", rect: CGRect(x: 360, y: 400, width: 60, height: 40),
                extra: "/C [0 0 1] /IC [0 1 0] /RD [1 2 3 4] /F 4"),
        Comment(nm: "circle", subtype: "Circle", rect: CGRect(x: 440, y: 400, width: 60, height: 40),
                extra: "/C [0 0 1] /F 4"),
        Comment(nm: "line", subtype: "Line", rect: CGRect(x: 72, y: 340, width: 128, height: 40),
                extra: "/L [80 350 190 370] /LE [/None /OpenArrow] /C [0 0 0] /F 4"),
        Comment(nm: "polygon", subtype: "Polygon", rect: CGRect(x: 220, y: 340, width: 120, height: 40),
                extra: "/Vertices [230 345 330 345 280 375] /C [0 0 0] /F 4"),
        Comment(nm: "polyline", subtype: "PolyLine", rect: CGRect(x: 360, y: 340, width: 120, height: 40),
                extra: "/Vertices [370 345 420 375 470 345] /C [0 0 0] /F 4"),
        Comment(nm: "stamp", subtype: "Stamp", rect: CGRect(x: 72, y: 260, width: 128, height: 60),
                extra: "/Name /Approved /Contents (Approved) /F 4"),
        Comment(nm: "caret", subtype: "Caret", rect: CGRect(x: 220, y: 280, width: 20, height: 20),
                extra: "/RD [0 0 0 0] /Contents (Insert here) /F 4"),
        Comment(nm: "attachment", subtype: "FileAttachment", rect: CGRect(x: 260, y: 280, width: 20, height: 20),
                extra: "/Name /PushPin /Contents (A file) /F 4 /FS << /Type /Filespec /F (c.txt) /UF (c.txt) /EF << /F @file >> >>"),
        Comment(nm: "redact", subtype: "Redact", rect: CGRect(x: 300, y: 260, width: 120, height: 60),
                extra: "/OverlayText (Gone) /F 4"),
        Comment(nm: "sound", subtype: "Sound", rect: CGRect(x: 440, y: 280, width: 20, height: 20),
                extra: "/Sound @sound /Name /Speaker /F 4"),
        // Page 2, turned: an appearance that fills only the left half of its box, so a turn shows.
        Comment(nm: "turned-square", subtype: "Square", rect: CGRect(x: 100, y: 100, width: 60, height: 40),
                extra: "/C [0 0 1] /RD [1 2 3 4] /F 4", appearance: "0.1 0.1 0.1 rg 0 0 30 40 re f", page: 1),
        Comment(nm: "turned-ink", subtype: "Ink", rect: CGRect(x: 200, y: 100, width: 100, height: 100),
                extra: "/InkList [[210 110 290 190] [210 190 290 110]] /C [1 0 0] /F 4", page: 1),
        Comment(nm: "turned-highlight", subtype: "Highlight", rect: CGRect(x: 100, y: 500, width: 200, height: 20),
                extra: "/QuadPoints [100 520 300 520 100 500 300 500] /C [1 1 0] /F 4", page: 1),
        // NoRotate (flag 16): stays upright, pinned at its upper-left corner.
        Comment(nm: "turned-note", subtype: "Text", rect: CGRect(x: 300, y: 300, width: 20, height: 30),
                extra: "/Contents (Upright note) /F 28 /Name /Note", page: 1),
    ]

    /// The 2-page fixture: the comments above, a link on page 1, page labels "i", "ii", and a
    /// document attachment.
    static func write(to url: URL) throws {
        var bodies: [String] = []
        func add(_ body: String) -> Int { bodies.append(body); return bodies.count }
        func stream(_ dictionary: String, _ text: String) -> String {
            "<< \(dictionary) /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream"
        }
        _ = add("catalog")                                   // 1, filled in last
        _ = add("pages")                                     // 2
        let pages = [add("page"), add("page")]               // 3, 4
        let content = add(stream("", "BT /F1 18 Tf 72 740 Td (Hello page) Tj ET"))
        let font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let file = add(stream("/Type /EmbeddedFile", filePayload))
        let docFile = add(stream("/Type /EmbeddedFile", docPayload))
        let sound = add(stream("/Type /Sound /R 8000", "SOUNDBYTES"))
        var numbers: [String: Int] = [:]
        for comment in comments { numbers[comment.nm] = add("annotation") }
        for comment in comments {
            var body = "<< /Type /Annot /Subtype /\(comment.subtype) /NM (\(comment.nm))"
                + " /Rect [\(comment.rect.minX) \(comment.rect.minY) \(comment.rect.maxX) \(comment.rect.maxY)]"
                + " /P \(pages[comment.page]) 0 R " + comment.extra
            if let appearance = comment.appearance {
                let drawing = "% AP-\(comment.nm)\n" + appearance
                    .replacingOccurrences(of: "W", with: "\(Int(comment.rect.width))")
                    .replacingOccurrences(of: "H", with: "\(Int(comment.rect.height))")
                let ap = add(stream("/Type /XObject /Subtype /Form /BBox [0 0 \(Int(comment.rect.width)) \(Int(comment.rect.height))]",
                                    drawing))
                body += " /AP << /N \(ap) 0 R >>"
            }
            for (name, number) in numbers { body = body.replacingOccurrences(of: "@\(name)", with: "\(number) 0 R") }
            body = body.replacingOccurrences(of: "@file", with: "\(file) 0 R")
                .replacingOccurrences(of: "@sound", with: "\(sound) 0 R")
            bodies[numbers[comment.nm]! - 1] = body + " >>"
        }
        let link = add("<< /Type /Annot /Subtype /Link /Rect [400 720 500 740] /Border [0 0 0] /A << /S /URI /URI (https://example.com/) >> >>")
        for (index, page) in pages.enumerated() {
            let annots = comments.filter { $0.page == index }.map { "\(numbers[$0.nm]!) 0 R" } + (index == 0 ? ["\(link) 0 R"] : [])
            var body = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(content) 0 R"
                + " /Resources << /Font << /F1 \(font) 0 R >> >> /Annots [\(annots.joined(separator: " "))]"
            if index == 1 {
                body += " /Rotate 90 /CropBox [\(page2Crop.minX) \(page2Crop.minY) \(page2Crop.maxX) \(page2Crop.maxY)]"
            }
            bodies[page - 1] = body + " >>"
        }
        bodies[0] = "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r >>] >>"
            + " /Names << /EmbeddedFiles << /Names [(doc.txt) << /Type /Filespec /F (doc.txt) /EF << /F \(docFile) 0 R >> >>] >> >> >>"
        bodies[1] = "<< /Type /Pages /Kids [\(pages.map { "\($0) 0 R" }.joined(separator: " "))] /Count 2 >>"

        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, body) in bodies.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: url, options: .atomic)
    }

    /// A dark patch on page 1, where no comment is: the item Fill & Sign draws.
    static let patch = FillSignItem(pageIndex: 0, rect: CGRect(x: 400, y: 100, width: 50, height: 30),
                                    content: .patch(FillSignPatch(red: 0.1, green: 0.1, blue: 0.1)))

    // MARK: Reading back

    /// A PDF's comments by `/NM`, read with CoreGraphics: each one's dictionary, page index, and a
    /// canonical text of its whole dictionary — streams by their decoded bytes, a page by its index,
    /// another annotation by its `/NM` — so a source's and a copy's can be compared whole.
    final class Comments {
        let document: CGPDFDocument
        var byName: [String: (dictionary: CGPDFDictionaryRef, page: Int)] = [:]
        /// Each page's `/Annots` subtypes, in order.
        var subtypes: [[String]] = []
        private var pageIndex: [UnsafeRawPointer: Int] = [:]

        init(_ data: Data) throws {
            let provider = try #require(CGDataProvider(data: data as CFData))
            document = try #require(CGPDFDocument(provider))
            for index in 0..<document.numberOfPages {
                let page = try #require(document.page(at: index + 1)?.dictionary)
                pageIndex[Self.identity(page)] = index
                var annots: CGPDFArrayRef?
                var names: [String] = []
                if CGPDFDictionaryGetArray(page, "Annots", &annots), let annots {
                    for i in 0..<CGPDFArrayGetCount(annots) {
                        var annotation: CGPDFDictionaryRef?
                        guard CGPDFArrayGetDictionary(annots, i, &annotation), let annotation else { continue }
                        names.append(Self.name(annotation, "Subtype") ?? "?")
                        if let nm = Self.string(annotation, "NM") { byName[nm] = (annotation, index) }
                    }
                }
                subtypes.append(names)
            }
        }

        static func identity<T>(_ ref: T) -> UnsafeRawPointer { unsafeBitCast(ref, to: UnsafeRawPointer.self) }

        static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var value: UnsafePointer<CChar>?
            return CGPDFDictionaryGetName(dictionary, key, &value) ? value.map { String(cString: $0) } : nil
        }

        static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var value: CGPDFStringRef?
            guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
            return CGPDFStringCopyTextString(value) as String?
        }

        static func numbers(_ dictionary: CGPDFDictionaryRef, _ key: String) -> [CGFloat]? {
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, key, &array), let array else { return nil }
            return (0..<CGPDFArrayGetCount(array)).map { i in
                var value: CGPDFReal = .nan
                _ = CGPDFArrayGetNumber(array, i, &value)
                return value
            }
        }

        /// The decoded bytes of a comment's `/AP /N` stream, and that stream's `/Matrix`.
        static func appearance(_ dictionary: CGPDFDictionaryRef) -> (data: Data, matrix: [CGFloat]?)? {
            var ap: CGPDFDictionaryRef?
            var stream: CGPDFStreamRef?
            var format = CGPDFDataFormat.raw
            guard CGPDFDictionaryGetDictionary(dictionary, "AP", &ap), let ap,
                  CGPDFDictionaryGetStream(ap, "N", &stream), let stream,
                  let data = CGPDFStreamCopyData(stream, &format) as Data?,
                  let header = CGPDFStreamGetDictionary(stream) else { return nil }
            return (data, numbers(header, "Matrix"))
        }

        func canonical(_ nm: String, skipping: Set<String> = []) -> String? {
            byName[nm].map { dictionary($0.dictionary, skipping: skipping, depth: 0) }
        }

        private func dictionary(_ dictionary: CGPDFDictionaryRef, skipping: Set<String>, depth: Int) -> String {
            if let index = pageIndex[Self.identity(dictionary)] { return "page#\(index)" }
            if depth > 0, let nm = Self.string(dictionary, "NM") { return "annot:\(nm)" }
            guard depth < 12 else { return "…" }
            var entries: [(String, CGPDFObjectRef)] = []
            CGPDFDictionaryApplyBlock(dictionary, { key, object, _ in
                entries.append((String(cString: key), object))
                return true
            }, nil)
            return "<<" + entries.sorted { $0.0 < $1.0 }.filter { !skipping.contains($0.0) }
                .map { "/\($0.0) \(value($0.1, depth: depth + 1))" }.joined(separator: " ") + ">>"
        }

        private func value(_ object: CGPDFObjectRef, depth: Int) -> String {
            switch CGPDFObjectGetType(object) {
            case .null: return "null"
            case .boolean:
                var v: CGPDFBoolean = 0
                _ = CGPDFObjectGetValue(object, .boolean, &v)
                return v != 0 ? "true" : "false"
            case .integer, .real:
                var v: CGPDFReal = 0
                _ = CGPDFObjectGetValue(object, .real, &v)
                return "\(v)"
            case .name:
                var v: UnsafePointer<CChar>?
                _ = CGPDFObjectGetValue(object, .name, &v)
                return "/" + (v.map { String(cString: $0) } ?? "")
            case .string:
                var v: CGPDFStringRef?
                _ = CGPDFObjectGetValue(object, .string, &v)
                return "(" + (v.flatMap { CGPDFStringCopyTextString($0) as String? } ?? "") + ")"
            case .array:
                var v: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &v), let v else { return "[]" }
                return "[" + (0..<CGPDFArrayGetCount(v)).map { i in
                    var item: CGPDFObjectRef?
                    return CGPDFArrayGetObject(v, i, &item) && item != nil ? value(item!, depth: depth + 1) : "null"
                }.joined(separator: " ") + "]"
            case .dictionary:
                var v: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &v), let v else { return "<<>>" }
                return dictionary(v, skipping: [], depth: depth)
            case .stream:
                var v: CGPDFStreamRef?
                var format = CGPDFDataFormat.raw
                guard CGPDFObjectGetValue(object, .stream, &v), let v,
                      let header = CGPDFStreamGetDictionary(v),
                      let data = CGPDFStreamCopyData(v, &format) as Data? else { return "stream?" }
                return "stream" + dictionary(header, skipping: ["Length", "Filter", "DecodeParms"], depth: depth)
                    + data.base64EncodedString()
            @unknown default: return "?"
            }
        }
    }

    /// The darkest point inside each rect (inset 3 pt) of page `index` drawn WITHOUT its annotations:
    /// what the page's own content puts there.
    static func pageContentDarkness(_ data: Data, page index: Int, rects: [CGRect], dir: FixtureDir) throws -> [CGFloat] {
        let doc = try #require(PDFDocument(data: data))
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            for annotation in page.annotations { page.removeAnnotation(annotation) }
        }
        let bare = dir.url("bare-\(UUID().uuidString).pdf")
        try #require(doc.write(to: bare))
        let sample = try PDFFixtures.brightnessSampler(at: bare, page: index)
        return rects.map { rect in
            let r = rect.insetBy(dx: 3, dy: 3)
            return PDFFixtures.darkestSample(sample, xRange: stride(from: r.minX, through: r.maxX, by: 2),
                                             yValues: Array(stride(from: r.minY, through: r.maxY, by: 2)))
        }
    }

    // MARK: Keep

    @Test func everyCommentIsKeptWholeOnItsPage() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let output = try PDFToolkit.fillAndSignData(inputURL: url, items: [Self.patch], annotations: .keep)
        #expect(output.annotations == .keep)
        let source = try Comments(try Data(contentsOf: url))
        let copy = try Comments(output.data)

        let page1 = Self.comments.filter { $0.page == 0 }
        for comment in page1 {
            let kept = try #require(copy.byName[comment.nm], "\(comment.nm) was not carried")
            #expect(kept.page == 0)
            // The whole dictionary, appearance stream bytes, popup and reply links, contents and
            // colour included — and `/P` names the copy's page 1, as the source's named its own.
            #expect(copy.canonical(comment.nm) == source.canonical(comment.nm), "\(comment.nm)")
            #expect(Comments.identity(try #require(copy.document.page(at: 1)?.dictionary)) == {
                var p: CGPDFDictionaryRef?
                return CGPDFDictionaryGetDictionary(kept.dictionary, "P", &p) ? p.map(Comments.identity) : nil
            }(), "\(comment.nm)'s /P")
        }
        // Spelled out, what the canonical comparison covers.
        let note = try #require(copy.byName["note"]?.dictionary)
        #expect(Comments.string(note, "Contents") == "Sticky note text")
        #expect(Comments.numbers(note, "C") == [1, 1, 0])
        var popup: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(note, "Popup", &popup))
        #expect(popup.map(Comments.identity) == copy.byName["popup"].map { Comments.identity($0.dictionary) })
        var parent: CGPDFDictionaryRef?
        let popupDictionary = try #require(copy.byName["popup"]?.dictionary)
        #expect(CGPDFDictionaryGetDictionary(popupDictionary, "Parent", &parent))
        #expect(parent.map(Comments.identity) == Comments.identity(note))
        var answered: CGPDFDictionaryRef?
        let reply = try #require(copy.byName["reply"]?.dictionary)
        #expect(CGPDFDictionaryGetDictionary(reply, "IRT", &answered))
        #expect(answered.map(Comments.identity) == Comments.identity(note))
        for comment in Self.comments where comment.appearance != nil {
            let original = try #require(source.byName[comment.nm].flatMap { Comments.appearance($0.dictionary) })
            let carried = try #require(copy.byName[comment.nm].flatMap { Comments.appearance($0.dictionary) })
            #expect(carried.data == original.data, "\(comment.nm)'s appearance")
            #expect(String(decoding: carried.data, as: UTF8.self).hasPrefix("% AP-\(comment.nm)\n"))
        }

        // Each comment once, after the link the copy already had.
        #expect(copy.subtypes[0] == ["Link"] + page1.map(\.subtype))
        #expect(copy.subtypes[1] == Self.comments.filter { $0.page == 1 }.map(\.subtype))
        // The attached file, file and all; the page labels and the document's attachment beside them.
        let report = try PDFToolkitCatalogCarryTests.Report(output.data)
        #expect(report.pageAttachments == [0: [Self.filePayload]])
        #expect(report.labels == ["i", "ii"])
        #expect(report.docAttachment == Self.docPayload)
    }

    /// PDFKit — the app's own reader — sees the kept comments as the comments they were.
    @Test func pdfKitReadsTheKeptComments() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let output = try PDFToolkit.fillAndSignData(inputURL: url, items: [Self.patch], annotations: .keep)
        let doc = try #require(PDFDocument(data: output.data))
        let page = try #require(doc.page(at: 0))
        let byType = Dictionary(grouping: page.annotations, by: { $0.type ?? "" })
        for type in ["Text", "FreeText", "Highlight", "Underline", "StrikeOut", "Ink", "Square", "Circle", "Line",
                     "Stamp", "FileAttachment", "Link"] {
            #expect(byType[type] != nil, "PDFKit does not see the \(type)")
        }
        let note = try #require(byType["Text"]?.first { $0.contents == "Sticky note text" })
        #expect(note.userName == "Ada")
        #expect(note.popup != nil)
        #expect(page.annotations.first { $0.type == "Link" }?.url == URL(string: "https://example.com/"))
    }

    /// The page's own content holds none of the kept comments' drawing — only the item placed. With
    /// `.flatten` the same spots are drawn on: what this check would see were they drawn in.
    @Test(arguments: [FillSignAnnotations.keep, .flatten])
    func onlyAFlattenedCommentIsDrawnIntoThePage(_ choice: FillSignAnnotations) throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let output = try PDFToolkit.fillAndSignData(inputURL: url, items: [Self.patch], annotations: choice)
        #expect(output.annotations == choice)
        // Every comment with an appearance but the attachment, whose icon is never drawn in.
        let page1 = Self.comments.filter { $0.page == 0 && $0.appearance != nil && $0.subtype != "FileAttachment" }
        let darkness = try Self.pageContentDarkness(output.data, page: 0, rects: page1.map(\.rect) + [Self.patch.rect], dir: dir)
        // Flattening draws what PDFKit lists, which is PDFKit's to decide; keeping draws none.
        let listed = Set(try #require(PDFDocument(url: url)?.page(at: 0)).annotations.compactMap(\.type))
        for (comment, dark) in zip(page1, darkness) {
            if choice == .keep {
                #expect(dark > 0.9, "\(comment.nm) is drawn into the page")
            } else if listed.contains(comment.subtype) {
                #expect(dark < 0.5, "\(comment.nm) is not drawn into the page")
            }
        }
        if choice == .flatten { #expect(listed.isSuperset(of: ["Text", "Highlight", "Ink", "Square", "Stamp"])) }
        #expect(darkness.last! < 0.3, "the placed item is missing")
        let turned = Self.comments.filter { $0.page == 1 }
        let mapped = turned.map { PDFToolkit.displayRect($0.rect, cropBox: Self.page2Crop, rotation: 90) }
        for (comment, dark) in zip(turned, try Self.pageContentDarkness(output.data, page: 1, rects: mapped, dir: dir)) {
            #expect((dark > 0.9) == (choice == .keep), "\(comment.nm) on the turned page")
        }

        let copy = try Comments(output.data)
        if choice == .flatten {
            // As before: only the attachment comes back as an annotation, beside the link.
            #expect(copy.subtypes == [["Link", "FileAttachment"], []])
        }
    }

    /// `.flatten` is what `fillAndSignData(inputURL:items:)` has always done.
    @Test func flattenIsTheOldCall() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let old = try Comments(try PDFToolkit.fillAndSignData(inputURL: url, items: [Self.patch]))
        let new = try Comments(try PDFToolkit.fillAndSignData(inputURL: url, items: [Self.patch], annotations: .flatten).data)
        #expect(old.subtypes == new.subtypes)
        #expect(old.byName.keys.sorted() == new.byName.keys.sorted())
    }

    // MARK: A turned, offset page

    @Test func aTurnedPagesCommentsMoveWithIt() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let output = try PDFToolkit.fillAndSignData(inputURL: url, items: [Self.patch], annotations: .keep)
        let source = try Comments(try Data(contentsOf: url))
        let copy = try Comments(output.data)
        let crop = Self.page2Crop
        func point(_ x: CGFloat, _ y: CGFloat) -> [CGFloat] {
            let p = PDFToolkit.displayPoint(CGPoint(x: x, y: y), cropBox: crop, rotation: 90)
            return [p.x, p.y]
        }
        func rect(_ r: CGRect) -> [CGFloat] {
            let m = PDFToolkit.displayRect(r, cropBox: crop, rotation: 90)
            return [m.minX, m.minY, m.maxX, m.maxY]
        }
        let moved: Set<String> = ["Rect", "QuadPoints", "InkList", "RD", "AP"]
        for comment in Self.comments where comment.page == 1 {
            let kept = try #require(copy.byName[comment.nm])
            #expect(kept.page == 1)
            #expect(copy.canonical(comment.nm, skipping: moved) == source.canonical(comment.nm, skipping: moved), "\(comment.nm)")
        }

        let square = try #require(copy.byName["turned-square"]?.dictionary)
        #expect(Comments.numbers(square, "Rect") == rect(CGRect(x: 100, y: 100, width: 60, height: 40)))
        // Left 1, bottom 2, right 3, top 4 on the page; turned, the bottom inset is on the left.
        #expect(Comments.numbers(square, "RD") == [2, 3, 4, 1])
        let appearance = try #require(Comments.appearance(square))
        #expect(appearance.matrix == [0, -1, 1, 0, 0, 0])
        #expect(appearance.data == source.byName["turned-square"].flatMap { Comments.appearance($0.dictionary) }?.data)

        let ink = try #require(copy.byName["turned-ink"]?.dictionary)
        var inkList: CGPDFArrayRef?
        #expect(CGPDFDictionaryGetArray(ink, "InkList", &inkList))
        var strokes: [[CGFloat]] = []
        for i in 0..<(inkList.map(CGPDFArrayGetCount) ?? 0) {
            var stroke: CGPDFArrayRef?
            guard CGPDFArrayGetArray(inkList!, i, &stroke), let stroke else { continue }
            strokes.append((0..<CGPDFArrayGetCount(stroke)).map { j in
                var v: CGPDFReal = .nan
                _ = CGPDFArrayGetNumber(stroke, j, &v)
                return v
            })
        }
        #expect(strokes == [point(210, 110) + point(290, 190), point(210, 190) + point(290, 110)])

        let highlight = try #require(copy.byName["turned-highlight"]?.dictionary)
        #expect(Comments.numbers(highlight, "QuadPoints") == point(100, 520) + point(300, 520) + point(100, 500) + point(300, 500))

        // Upright: its size kept, its upper-left corner where the turned page showed it, its
        // appearance not turned.
        let note = try #require(copy.byName["turned-note"]?.dictionary)
        let corner = point(300, 330)
        #expect(Comments.numbers(note, "Rect") == [corner[0], corner[1] - 30, corner[0] + 20, corner[1]])
        #expect(Comments.appearance(note)?.matrix == nil)
    }

    /// The turned appearance draws as the turned page showed it: the left half of the square's box
    /// on the page is its top half once the page is upright.
    @Test func aTurnedAppearanceDrawsAsTheTurnedPageShowedIt() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let output = try PDFToolkit.fillAndSignData(inputURL: url, items: [Self.patch], annotations: .keep)
        let out = dir.url("out.pdf")
        try output.data.write(to: out)
        let sample = try PDFFixtures.brightnessSampler(at: out, page: 1)
        let box = PDFToolkit.displayRect(CGRect(x: 100, y: 100, width: 60, height: 40), cropBox: Self.page2Crop, rotation: 90)
        #expect(sample(box.midX, box.minY + box.height * 0.75) < 0.3, "the drawn half is not on top")
        #expect(sample(box.midX, box.minY + box.height * 0.25) > 0.9, "the bottom half is drawn")
    }

    // MARK: When they can't be kept

    /// When the comments can't be carried, the pages are drawn again with them in, and the output
    /// says so.
    @Test func aCarryThatFailsFallsBackToFlattening() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let output = try PDFToolkit.fillAndSignData(inputURL: url, items: [Self.patch], annotations: .keep) { data, source, keep in
            keep ? (data, false) : PDFToolkit.restoringCatalog(data, from: source, restoreLinks: true, keepingComments: false)
        }
        #expect(output.annotations == .flatten)
        let note = try #require(Self.comments.first { $0.nm == "note" })
        let darkness = try Self.pageContentDarkness(output.data, page: 0, rects: [note.rect], dir: dir)
        #expect(darkness[0] < 0.5, "the comment was neither kept nor drawn")
    }

    /// An encrypted copy can't take new objects without encrypting their strings: the carry gives
    /// up, returns the copy as it was, and says the comments didn't come.
    @Test func anEncryptedCopyDoesNotKeepThem() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let encrypted = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: encrypted as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, [
            kCGPDFContextOwnerPassword: "owner", kCGPDFContextUserPassword: "",
        ] as CFDictionary))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        let cg = try #require(PDFToolkit.catalogSource(at: url))
        let result = PDFToolkit.carryingCatalogPartsReporting(encrypted as Data, from: cg, outputToSource: [0, 1],
                                                             displayMappedPages: [0, 1], comments: true)
        #expect(!result.commentsKept)
        #expect(result.data == encrypted as Data)
        // With nothing to keep, nothing is lost.
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        let none = PDFToolkit.carryingCatalogPartsReporting(encrypted as Data, from: try #require(PDFToolkit.catalogSource(at: plain)),
                                                           outputToSource: [0, 1], comments: true)
        #expect(none.commentsKept)
    }

    /// A file with no comments comes out as `.keep` asked: nothing was flattened.
    @Test func aFileWithoutCommentsIsKept() throws {
        let dir = FixtureDir()
        let url = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: url)
        let output = try PDFToolkit.fillAndSignData(inputURL: url, items: [Self.patch], annotations: .keep)
        #expect(output.annotations == .keep)
        #expect(try PDFFixtures.pageTexts(data: output.data)[0].contains("MARKERPAGE1"))
    }
}
