import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// The catalog entries a tool's copy keeps that PDFKit cannot write: page labels, viewer settings,
/// the language, and attached files (the document's own and a page's). Every copy below lost all
/// of them before (measured on macOS 27.0.1 with the same fixture), while Rotate, Protect and
/// filling a form kept them. Tags, layers and the output intent still go, and are reported by
/// ``PDFToolkit/droppedCatalogParts(at:)`` so a tool can say so.
struct PDFToolkitCatalogCarryTests {
    static let docPayload = "DOC-ATTACHMENT-PAYLOAD"
    static let pagePayload = "PAGE-ATTACHMENT-PAYLOAD"
    /// The four pages' labels: "i", "ii", then "A-1", "A-2".
    static let labels = ["i", "ii", "A-1", "A-2"]

    // MARK: Fixture

    /// A 4-page PDF whose catalog carries every part at stake, assembled by hand because PDFKit's
    /// writer produces none of them. It opens at page 3 (index 2), 150%, scrolled to (36, 400).
    ///
    /// - Parameter openAction: the `/OpenAction` value; object 3 + i is page i.
    /// - Parameter rotateThirdPage: turn page 3 by 90° and crop it to an offset box, so its
    ///   coordinates change when a rebuild emits it upright at a zero origin.
    static func write(to url: URL, openAction: String = "[5 0 R /XYZ 36 400 1.5]", form: Bool = false,
                      rotateThirdPage: Bool = false) throws {
        let pageCount = 4
        let pages = (0..<pageCount).map { 3 + $0 }               // objects 3...6
        let content = 7, font = 8, docFile = 9, docStream = 10, pageStream = 11
        let outline = 12, bookmark = 13, structRoot = 14, layer = 15, intent = 16, info = 17, widget = 18, icon = 19
        func body(_ text: String) -> String { "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream" }

        var catalog = "<< /Type /Catalog /Pages 2 0 R"
            + " /PageLabels << /Nums [0 << /S /r >> 2 << /S /D /P (A-) >>] >>"
            + " /ViewerPreferences << /DisplayDocTitle true /HideToolbar true >>"
            + " /PageMode /UseAttachments /PageLayout /TwoColumnLeft /OpenAction \(openAction) /Lang (fr-FR)"
            + " /Names << /EmbeddedFiles << /Names [(doc.txt) \(docFile) 0 R] >>"
            + " /Dests << /Kids [<< /Limits [(chap3) (chap3)] /Names [(chap3) [\(pages[2]) 0 R /XYZ 36 400 1.5]] >>] >> >>"
            + " /Outlines \(outline) 0 R /MarkInfo << /Marked true >> /StructTreeRoot \(structRoot) 0 R"
            + " /OCProperties << /OCGs [\(layer) 0 R] /D << /Order [\(layer) 0 R] >> >>"
            + " /OutputIntents [\(intent) 0 R]"
        if form { catalog += " /AcroForm << /Fields [\(widget) 0 R] /DA (/Helv 0 Tf 0 g) >>" }
        catalog += " >>"

        var objects: [Int: String] = [
            1: catalog,
            2: "<< /Type /Pages /Kids [\(pages.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pageCount) >>",
            content: body("BT /F1 18 Tf 72 700 Td (Hello page) Tj ET"),
            font: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            docFile: "<< /Type /Filespec /F (doc.txt) /UF (doc.txt) /Desc (the document's) /EF << /F \(docStream) 0 R >> >>",
            docStream: "<< /Type /EmbeddedFile /Subtype /text#2Fplain /Params << /Size \(docPayload.utf8.count) >> /Length \(docPayload.utf8.count) >>\nstream\n\(docPayload)\nendstream",
            pageStream: "<< /Type /EmbeddedFile /Length \(pagePayload.utf8.count) >>\nstream\n\(pagePayload)\nendstream",
            outline: "<< /Type /Outlines /First \(bookmark) 0 R /Last \(bookmark) 0 R /Count 1 >>",
            bookmark: "<< /Title (Heading) /Parent \(outline) 0 R /Dest [\(pages[3]) 0 R /XYZ 72 500 0] >>",
            structRoot: "<< /Type /StructTreeRoot /K [] >>",
            layer: "<< /Type /OCG /Name (Layer1) >>",
            intent: "<< /Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB) >>",
            info: "<< /Title (Labelled) /Producer (Hand) >>",
            // The attachment's icon: a black square.
            icon: "<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length 18 >>\nstream\n0 g 0 0 20 20 re f\nendstream",
            widget: "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Ada) /Rect [72 600 300 630] /P \(pages[1]) 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
        ]
        for (i, number) in pages.enumerated() {
            var page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(content) 0 R"
                + " /Resources << /Font << /F1 \(font) 0 R >> >>"
            if i == 0 {
                page += " /Annots [<< /Type /Annot /Subtype /FileAttachment /Rect [400 700 420 720] /Contents (note)"
                    + " /Name /PushPin /AP << /N \(icon) 0 R >> /FS << /Type /Filespec /F (page.txt) /EF << /F \(pageStream) 0 R >> >> >>]"
            }
            if i == 1, form { page += " /Annots [\(widget) 0 R]" }
            if i == 2, rotateThirdPage { page += " /Rotate 90 /CropBox [50 60 562 732]" }
            objects[number] = page + " >>"
        }

        let count = objects.keys.max()!
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for number in 1...count {
            offsets.append(pdf.utf8.count)
            pdf += "\(number) 0 obj\n\(objects[number] ?? "null")\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(count + 1) /Root 1 0 R /Info \(info) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: url, options: .atomic)
    }

    // MARK: Reading a copy back

    /// What a copy's catalog says, read with CoreGraphics and PDFKit — never the code under test.
    struct Report {
        var labels: [String] = []
        var displayDocTitle = false
        var pageMode: String?
        var pageLayout: String?
        var lang: String?
        /// The page index the copy opens at, the view, and its numbers (nil for `null`).
        var opening: (page: Int, view: String, numbers: [CGFloat?])?
        var docAttachment: String?
        var docAttachmentDescription: String?
        /// Each page's attached files' contents.
        var pageAttachments: [Int: [String]] = [:]
        var has: Set<String> = []

        init(_ data: Data, password: String? = nil) throws {
            let doc = try #require(PDFDocument(data: data))
            if let password { _ = doc.unlock(withPassword: password) }
            labels = (0..<doc.pageCount).map { doc.page(at: $0)?.label ?? "" }
            // Read apart from PDFKit: on macOS 26 a document it unlocked doesn't unlock its catalog.
            let provider = try #require(CGDataProvider(data: data as CFData))
            let cg = try #require(CGPDFDocument(provider))
            if let password { _ = cg.unlockWithPassword(password) }
            let catalog = try #require(cg.catalog)
            for key in ["StructTreeRoot", "MarkInfo", "OCProperties", "OutputIntents", "Metadata", "AcroForm", "Outlines"] {
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(catalog, key, &object) { has.insert(key) }
            }
            var prefs: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "ViewerPreferences", &prefs), let prefs {
                var flag: CGPDFBoolean = 0
                displayDocTitle = CGPDFDictionaryGetBoolean(prefs, "DisplayDocTitle", &flag) && flag != 0
            }
            pageMode = Self.name(catalog, "PageMode")
            pageLayout = Self.name(catalog, "PageLayout")
            var lang: CGPDFStringRef?
            if CGPDFDictionaryGetString(catalog, "Lang", &lang), let lang {
                self.lang = CGPDFStringCopyTextString(lang) as String?
            }
            let pageDictionaries = (0..<cg.numberOfPages).map { cg.page(at: $0 + 1)?.dictionary }
            var open: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(catalog, "OpenAction", &open), let open {
                var page: CGPDFDictionaryRef?
                var view: UnsafePointer<CChar>?
                if CGPDFArrayGetDictionary(open, 0, &page), let page, CGPDFArrayGetName(open, 1, &view), let view,
                   let index = pageDictionaries.firstIndex(where: { $0 == page }) {
                    let numbers: [CGFloat?] = (2..<CGPDFArrayGetCount(open)).map { i in
                        var value: CGPDFReal = 0
                        return CGPDFArrayGetNumber(open, i, &value) ? value : nil
                    }
                    opening = (index, String(cString: view), numbers)
                }
            }
            var names: CGPDFDictionaryRef?
            var files: CGPDFDictionaryRef?
            var list: CGPDFArrayRef?
            var spec: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
               CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &files), let files,
               CGPDFDictionaryGetArray(files, "Names", &list), let list,
               CGPDFArrayGetDictionary(list, 1, &spec), let spec {
                docAttachment = Self.contents(ofFileSpec: spec)
                var description: CGPDFStringRef?
                if CGPDFDictionaryGetString(spec, "Desc", &description), let description {
                    docAttachmentDescription = CGPDFStringCopyTextString(description) as String?
                }
            }
            for (index, page) in pageDictionaries.enumerated() {
                var annots: CGPDFArrayRef?
                guard let page, CGPDFDictionaryGetArray(page, "Annots", &annots), let annots else { continue }
                for i in 0..<CGPDFArrayGetCount(annots) {
                    var annotation: CGPDFDictionaryRef?
                    var fs: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(annots, i, &annotation), let annotation,
                          Self.name(annotation, "Subtype") == "FileAttachment" else { continue }
                    let text = CGPDFDictionaryGetDictionary(annotation, "FS", &fs) ? fs.flatMap(Self.contents(ofFileSpec:)) : nil
                    pageAttachments[index, default: []].append(text ?? "(no file)")
                }
            }
        }

        static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var value: UnsafePointer<CChar>?
            return CGPDFDictionaryGetName(dictionary, key, &value) ? value.map { String(cString: $0) } : nil
        }

        static func contents(ofFileSpec spec: CGPDFDictionaryRef) -> String? {
            var ef: CGPDFDictionaryRef?
            var stream: CGPDFStreamRef?
            var format = CGPDFDataFormat.raw
            guard CGPDFDictionaryGetDictionary(spec, "EF", &ef), let ef,
                  CGPDFDictionaryGetStream(ef, "F", &stream), let stream,
                  let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Every part kept, on a copy of all four pages in their order.
    private func expectEverythingKept(_ report: Report, openingAt page: Int = 2) {
        #expect(report.labels == Self.labels)
        #expect(report.displayDocTitle)
        #expect(report.pageMode == "UseAttachments")
        #expect(report.pageLayout == "TwoColumnLeft")
        #expect(report.lang == "fr-FR")
        #expect(report.opening?.page == page)
        #expect(report.opening?.view == "XYZ")
        #expect(report.opening?.numbers == [36, 400, 1.5])
        #expect(report.docAttachment == Self.docPayload)
        #expect(report.docAttachmentDescription == "the document's")
        #expect(report.pageAttachments == [0: [Self.pagePayload]])
    }

    private func expectDropped(_ report: Report) {
        #expect(!report.has.contains("StructTreeRoot"))
        #expect(!report.has.contains("OCProperties"))
        #expect(!report.has.contains("OutputIntents"))
    }

    // MARK: Every page, in order

    @Test(arguments: ["cleanMetadata", "cleanMetadataCleared", "compress", "fillAndSign", "watermark",
                      "pictures", "removePassword", "crop"])
    func aWholeCopyKeepsLabelsViewerSettingsLanguageAndAttachments(_ tool: String) throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let item = FillSignItem(pageIndex: 1, rect: CGRect(x: 72, y: 300, width: 200, height: 30),
                                content: .text(FillSignText(string: "Signed", fontSize: 14, red: 0, green: 0, blue: 0)))
        let data: Data
        switch tool {
        case "cleanMetadata": data = try PDFToolkit.writeMetadataData(inputURL: url, fields: try PDFToolkit.readMetadata(inputURL: url))
        case "cleanMetadataCleared": data = try PDFToolkit.writeMetadataData(inputURL: url, fields: .cleared)
        case "compress": data = try PDFToolkit.compressData(inputURL: url, quality: 0.6)
        case "fillAndSign": data = try PDFToolkit.fillAndSignData(inputURL: url, items: [item])
        case "watermark":
            data = try PDFToolkit.watermarkData(inputURL: url, options: WatermarkOptions(
                text: "DRAFT", fontSize: 40, opacity: 0.3, rotationDegrees: 45, red: 1, green: 0, blue: 0, tiled: false))
        case "pictures":
            data = try PDFToolkit.redactData(inputURL: url, marks: [], options: PDFRedactionExportOptions(
                stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 1000, forceRasterizePages: [0]))
        case "removePassword":
            let locked = dir.url("locked.pdf")
            try PDFToolkit.encryptData(inputURL: url, options: .addPassword(restrictEditing: false, password: "pw"))
                .write(to: locked)
            data = try PDFToolkit.removePasswordData(inputURL: locked, password: "pw")
        case "crop": data = try PDFToolkit.cropData(inputURL: url, insets: CropInsets(top: 10, left: 10, bottom: 10, right: 10))
        default: Issue.record("unknown tool \(tool)"); return
        }
        let report = try Report(data)
        expectEverythingKept(report)
        expectDropped(report)
        if tool.hasPrefix("cleanMetadata") { #expect(!report.has.contains("Metadata")) }
        // The bookmark, which the copies kept before, still comes along.
        #expect(report.has.contains("Outlines"))
    }

    /// The tools that write in place keep everything — including the tags, layers and output
    /// intent on macOS 27. On macOS 26 the write loses all of it, and the four parts are carried.
    @Test(arguments: ["rotate", "fillForm"])
    func anInPlaceWriteKeepsTheFourParts(_ tool: String) throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url, form: tool == "fillForm")
        let data = tool == "rotate"
            ? try PDFToolkit.rotateData(inputURL: url, pageIndices: [1], quarterTurns: 1)
            : try PDFToolkit.fillFormData(inputURL: url, values: ["name": .text("Bo")])
        expectEverythingKept(try Report(data))
    }

    /// Protect's copy is encrypted, which an appended update can't add to without encrypting its
    /// strings, so it keeps what PDFKit's write keeps: everything on macOS 27, none of it on 26.
    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
                   "macOS 26's PDFKit drops these from an encrypted write"),
          arguments: ["rotate", "protect", "fillForm"])
    func anInPlaceWriteStillKeepsEverything(_ tool: String) throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url, form: tool == "fillForm")
        let data: Data
        var password: String?
        switch tool {
        case "rotate": data = try PDFToolkit.rotateData(inputURL: url, pageIndices: [1], quarterTurns: 1)
        case "protect":
            data = try PDFToolkit.encryptData(inputURL: url, options: .addPassword(restrictEditing: false, password: "pw"))
            password = "pw"
        case "fillForm": data = try PDFToolkit.fillFormData(inputURL: url, values: ["name": .text("Bo")])
        default: Issue.record("unknown tool \(tool)"); return
        }
        let report = try Report(data, password: password)
        expectEverythingKept(report)
        #expect(report.has.isSuperset(of: ["StructTreeRoot", "OCProperties", "OutputIntents"]))
    }

    // MARK: Pages that move or go

    @Test func anExtractKeepsEachPagesOwnLabel() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let report = try Report(try PDFToolkit.extractData(inputURL: url, pageIndices: [3, 1, 2]))
        #expect(report.labels == ["A-2", "ii", "A-1"])
        // The opening page came along, to the third place.
        #expect(report.opening?.page == 2)
        #expect(report.opening?.numbers == [36, 400, 1.5])
        #expect(report.pageAttachments.isEmpty)
        #expect(report.docAttachment == Self.docPayload)
        #expect(report.lang == "fr-FR")
        expectDropped(report)
    }

    @Test func anExtractWithoutTheOpeningPageOpensAtItsFirstPageAtTheSameZoom() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let report = try Report(try PDFToolkit.extractData(inputURL: url, pageIndices: [0, 1]))
        #expect(report.labels == ["i", "ii"])
        #expect(report.opening?.page == 0)
        #expect(report.opening?.view == "XYZ")
        #expect(report.opening?.numbers == [nil, nil, 1.5])
        #expect(report.pageAttachments == [0: [Self.pagePayload]])
    }

    @Test func aSavedPageOrderKeepsEachPagesOwnLabel() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let report = try Report(try PDFToolkit.reorderData(inputURL: url, order: [3, 2, 1, 0]))
        #expect(report.labels == ["A-2", "A-1", "ii", "i"])
        #expect(report.opening?.page == 1)
        #expect(report.pageAttachments == [3: [Self.pagePayload]])
        #expect(report.pageLayout == "TwoColumnLeft")
    }

    @Test func deletingPagesKeepsTheRestsLabels() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let report = try Report(try PDFToolkit.deletePagesData(inputURL: url, pageIndices: [0, 2]))
        #expect(report.labels == ["ii", "A-2"])
        #expect(report.opening?.page == 0)
        #expect(report.opening?.numbers == [nil, nil, 1.5])
        #expect(report.pageAttachments.isEmpty)
        #expect(report.docAttachment == Self.docPayload)
        expectDropped(report)
    }

    @Test func deletingAPageBeforeTheOpeningOneFollowsIt() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let report = try Report(try PDFToolkit.deletePagesData(inputURL: url, pageIndices: [1]))
        #expect(report.labels == ["i", "A-1", "A-2"])
        #expect(report.opening?.page == 1)
        #expect(report.opening?.numbers == [36, 400, 1.5])
        #expect(report.pageAttachments == [0: [Self.pagePayload]])
    }

    // MARK: The opening view

    /// A GoTo to a named destination, in a name tree with kids: looked up and written explicitly,
    /// since the copy has no `/Dests` to look it up in.
    @Test func aNamedOpeningViewIsWrittenOut() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url, openAction: "<< /S /GoTo /D (chap3) >>")
        let report = try Report(try PDFToolkit.extractData(inputURL: url, pageIndices: [2, 3]))
        #expect(report.opening?.page == 0)
        #expect(report.opening?.numbers == [36, 400, 1.5])
    }

    /// A script that runs on opening is not an opening view, and is not carried.
    @Test func aScriptOnOpeningIsNotCarried() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url, openAction: "<< /S /JavaScript /JS (app.alert(1)) >>")
        let data = try PDFToolkit.extractData(inputURL: url, pageIndices: [0, 1, 2, 3])
        let report = try Report(data)
        #expect(report.opening == nil)
        #expect(data.range(of: Data("app.alert".utf8)) == nil)
        #expect(report.labels == Self.labels)
    }

    /// A rebuild emits a turned, cropped page upright at a zero origin, so the point the file
    /// opens at, and a page's attachment, move with its content.
    @Test func aRebuiltTurnedPageKeepsItsOpeningPoint() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url, rotateThirdPage: true)
        let report = try Report(try PDFToolkit.compressData(inputURL: url, quality: 0.6))
        let expected = PDFToolkit.displayPoint(CGPoint(x: 36, y: 400), cropBox: CGRect(x: 50, y: 60, width: 512, height: 672), rotation: 90)
        #expect(report.opening?.page == 2)
        #expect(report.opening?.numbers == [expected.x, expected.y, 1.5])
        // A page copy keeps the page's own space.
        let copied = try Report(try PDFToolkit.extractData(inputURL: url, pageIndices: [0, 1, 2, 3]))
        #expect(copied.opening?.numbers == [36, 400, 1.5])
    }

    // MARK: What doesn't come along

    /// A redaction keeps no attached file — one can hold what was painted over — but keeps the
    /// labels and viewer settings.
    @Test func aRedactionDropsAttachmentsButKeepsLabels() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let mark = RedactionMark(pageIndex: 1, rect: CGRect(x: 60, y: 690, width: 200, height: 30))
        let report = try Report(try PDFToolkit.redactData(inputURL: url, marks: [mark], options: PDFRedactionExportOptions(
            stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 1000, forceRasterizePages: [])))
        #expect(report.labels == Self.labels)
        #expect(report.pageLayout == "TwoColumnLeft")
        #expect(report.docAttachment == nil)
        #expect(!report.pageAttachments.values.joined().contains(Self.pagePayload))
    }

    @Test func droppedPartsAreReported() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        #expect(PDFToolkit.droppedCatalogParts(at: url) == [.tags, .layers, .outputIntent])
        // Locked, it can't be read: nothing is claimed.
        let locked = dir.url("locked.pdf")
        try PDFToolkit.encryptData(inputURL: url, options: .addPassword(restrictEditing: false, password: "pw")).write(to: locked)
        #expect(PDFToolkit.droppedCatalogParts(at: locked).isEmpty)
        #expect(PDFToolkit.droppedCatalogParts(at: locked, password: "pw") == [.tags, .layers, .outputIntent])
        let open = try #require(PDFDocument(url: url))
        #expect(PDFToolkit.droppedCatalogParts(in: open) == [.tags, .layers, .outputIntent])
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        #expect(PDFToolkit.droppedCatalogParts(at: plain).isEmpty)
    }

    /// A rebuild draws a page's annotations into it — but not a file attachment's icon, which the
    /// attachment itself brings back. Drawn too, the page would show it twice.
    @Test func aRebuildPutsBackOneAttachmentNotADrawingOfIt() throws {
        let dir = FixtureDir()
        let url = dir.url("source.pdf")
        try Self.write(to: url)
        let item = FillSignItem(pageIndex: 1, rect: CGRect(x: 72, y: 300, width: 200, height: 30),
                                content: .text(FillSignText(string: "Signed", fontSize: 14, red: 0, green: 0, blue: 0)))
        let data = try PDFToolkit.fillAndSignData(inputURL: url, items: [item])
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        #expect(page.annotations.filter { $0.type == "FileAttachment" }.count == 1)
        // The page's own drawing has no icon where the attachment sits: without its annotations,
        // the spot is blank.
        for annotation in page.annotations { page.removeAnnotation(annotation) }
        let bare = dir.url("bare.pdf")
        try #require(doc.write(to: bare))
        let sample = try PDFFixtures.brightnessSampler(at: bare)
        #expect(PDFFixtures.darkestSample(sample, xRange: stride(from: 400, through: 420, by: 2), yValues: Array(stride(from: 700, through: 720, by: 2))) > 0.9)
    }
}
