import CoreGraphics
import Foundation
import PDFKit

/// Carrying the catalog entries PDFKit's writer cannot set onto a copy: **page labels, viewer
/// settings (layout, page mode, the opening view, viewer preferences), the language, and attached
/// files**, both the document's own and those attached to a page.
///
/// Every copy PDFKit writes from a fresh document, and every in-place write that changes the page
/// tree, comes back with a bare catalog (measured on macOS 27.0.1): Extract, Reorder, Delete,
/// Compress, Remove Password, Clean Metadata's copy, and the CGPDFContext rebuilds all lost a
/// document's "i, ii, 1, 2" page numbers, its two-up layout, its language and its attachments. On
/// macOS 26 (measured on the hosted 26.6.2 runner) every write loses them, Rotate's and a filled
/// form's in place too, so those are carried as well.
/// PDFKit has no API for any of them, so they are written here, in an incremental update appended
/// to PDFKit's output (``PDFAppendedUpdate``), with values read from the source's own catalog.
///
/// Deliberately not carried: tags (`/StructTreeRoot`, `/MarkInfo`), layers (`/OCProperties`) and
/// the colour output intent (`/OutputIntents`). Tags and layers name page content by marked-content
/// ids that a rebuilt page no longer has, and an output intent claims a conformance the copy no
/// longer meets. ``droppedCatalogParts(at:)`` says which of them a file has, for the tool to say so.
///
/// Fail-safe like ``restoringCatalog(_:from:restoreLinks:displayMappedPages:)``: anything
/// unexpected returns the copy as PDFKit wrote it. So does an encrypted copy — Protect's, and a
/// restricted form's — whose new strings would have to be encrypted: on macOS 26 those lose them.
extension PDFToolkit {
    /// What a file carries that no tool's copy keeps.
    public enum DroppedCatalogPart: String, CaseIterable, Sendable {
        /// Tags for screen readers and reflow (`/StructTreeRoot`).
        case tags
        /// Optional content (`/OCProperties`).
        case layers
        /// The colour output intent (`/OutputIntents`).
        case outputIntent
    }

    /// Which of the parts no copy keeps the PDF at `url` has, in ``DroppedCatalogPart`` order.
    /// Empty when it has none or can't be read. Opens the file, so call it on your PDF lane.
    /// A file locked to open needs its `password`.
    public static func droppedCatalogParts(at url: URL, password: String? = nil) -> [DroppedCatalogPart] {
        catalogSource(at: url, password: password).map(droppedCatalogParts(of:)) ?? []
    }

    /// ``droppedCatalogParts(at:password:)`` for a document already open — empty while it is
    /// locked, and on macOS 26 for one unlocked with a password (pass the password to
    /// ``droppedCatalogParts(at:password:)`` there).
    public static func droppedCatalogParts(in doc: PDFDocument) -> [DroppedCatalogPart] {
        guard !doc.isLocked, let cg = catalogSource(of: doc) else { return [] }
        return droppedCatalogParts(of: cg)
    }

    private static func droppedCatalogParts(of cg: CGPDFDocument) -> [DroppedCatalogPart] {
        guard let catalog = cg.catalog else { return [] }
        var object: CGPDFObjectRef?
        return DroppedCatalogPart.allCases.filter { part in
            switch part {
            case .tags: return CGPDFDictionaryGetObject(catalog, "StructTreeRoot", &object)
            case .layers: return CGPDFDictionaryGetObject(catalog, "OCProperties", &object)
            case .outputIntent:
                var intents: CGPDFArrayRef?
                return CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents)
                    && intents.map { CGPDFArrayGetCount($0) > 0 } == true
            }
        }
    }

    /// Returns `data` — a copy PDFKit wrote of `source`'s pages — with `source`'s page labels,
    /// viewer settings, language and (when `attachments`) attached files written into its catalog.
    ///
    /// - Parameter outputToSource: for each page of the copy, the source page it came from. Page
    ///   labels follow their pages: a page keeps the label it had, so an extract of "iii" and "4"
    ///   still shows "iii" and "4". An opening view on a page the copy lacks opens the copy's first
    ///   page instead.
    /// - Parameter displayMappedPages: the copy's pages emitted in display space (upright, zero
    ///   origin), whose coordinates have to be mapped — every page of a CGPDFContext rebuild, the
    ///   rasterized ones of a redaction, none of a page copy.
    /// - Parameter attachments: false where an attachment could hold what the tool removes (a
    ///   redaction).
    static func carryingCatalogParts(
        _ data: Data,
        from source: PDFDocument,
        outputToSource: [Int],
        displayMappedPages: Set<Int> = [],
        attachments: Bool = true
    ) -> Data {
        guard let cg = catalogSource(of: source) else { return data }
        return carryingCatalogParts(data, from: cg, outputToSource: outputToSource,
                                    displayMappedPages: displayMappedPages, attachments: attachments)
    }

    /// The source's catalog as CoreGraphics reads it, unlocked: the open document's own, or — on
    /// macOS 26, where unlocking a `PDFDocument` with a password leaves its `documentRef` locked —
    /// a second read of its file.
    static func catalogSource(of document: PDFDocument) -> CGPDFDocument? {
        if let cg = document.documentRef, cg.isUnlocked { return cg }
        return document.documentURL.flatMap { catalogSource(at: $0) }
    }

    /// The file at `url` as CoreGraphics reads it, unlocked with `password` — or with none, which
    /// opens a file that only restricts editing.
    static func catalogSource(at url: URL, password: String? = nil) -> CGPDFDocument? {
        guard let cg = CGPDFDocument(url as CFURL) else { return nil }
        if !cg.isUnlocked { _ = cg.unlockWithPassword(password ?? "") }
        if !cg.isUnlocked, password != nil { _ = cg.unlockWithPassword("") }
        return cg.isUnlocked ? cg : nil
    }

    /// ``carryingCatalogParts(_:from:outputToSource:displayMappedPages:attachments:)`` from the
    /// source as CoreGraphics reads it.
    static func carryingCatalogParts(
        _ data: Data,
        from cg: CGPDFDocument,
        outputToSource: [Int],
        displayMappedPages: Set<Int> = [],
        attachments: Bool = true
    ) -> Data {
        guard cg.isUnlocked, let catalog = cg.catalog else { return data }
        let cgPages = (0..<cg.numberOfPages).compactMap { cg.page(at: $0 + 1) }
        let sourcePages = cgPages.compactMap(\.dictionary)
        guard sourcePages.count == cg.numberOfPages else { return data }
        let carry = SourceCatalog(catalog: catalog, pages: sourcePages, cgPages: cgPages, attachments: attachments)
        guard carry.hasAnything else { return data }

        do {
            let update = try PDFAppendedUpdate(data)
            guard !update.isEncrypted else { return data }
            let outputPages = try update.pageObjects()
            guard outputPages.count == outputToSource.count,
                  outputToSource.allSatisfy({ $0 >= 0 && $0 < sourcePages.count })
            else { return data }

            var firstOutput: [Int: Int] = [:]
            for (output, source) in outputToSource.enumerated() where firstOutput[source] == nil {
                firstOutput[source] = output
            }
            var pageObjectOf: [UnsafeRawPointer: Int] = [:]
            for (index, page) in sourcePages.enumerated() {
                if let output = firstOutput[index] { pageObjectOf[identity(of: page)] = outputPages[output] }
            }
            let writer = CatalogObjectWriter(update: update, pageObjects: pageObjectOf)
            let isIdentity = outputToSource == Array(0..<sourcePages.count)

            let root = try update.rootObject()
            // A copy of every page in order keeps what PDFKit already wrote — an in-place write on
            // macOS 27 keeps it all — so only what's missing is added; anything else is written
            // afresh, since a label or an opening page that moved must be moved.
            var present = Set<String>()
            if case .dict(let existing) = try update.object(root).value {
                present = Set(existing.map(\.key))
            }
            var entries: [(String, String)] = []
            if let labels = carry.pageLabels(for: outputToSource) { entries.append(("PageLabels", labels)) }
            if let preferences = carry.viewerPreferences {
                // A print range names pages by index, which only stays true when no page moved.
                let skipping: Set<String> = isIdentity ? [] : ["PrintPageRange"]
                entries.append(("ViewerPreferences", writer.dictionary(preferences, skipping: skipping)))
            }
            // `/UseOC` opens the layers panel, and the layers don't come along; `/UseAttachments`
            // would open an empty panel when the attachments don't either.
            if let mode = carry.pageMode, mode != "UseOC", mode != "UseAttachments" || attachments {
                entries.append(("PageMode", "/" + PDFAppendedUpdate.escapedName(mode)))
            }
            if let layout = carry.pageLayout {
                entries.append(("PageLayout", "/" + PDFAppendedUpdate.escapedName(layout)))
            }
            if let destination = carry.openingDestination,
               let opening = openingView(destination, carry: carry, writer: writer, outputPages: outputPages,
                                         firstOutput: firstOutput, displayMappedPages: displayMappedPages) {
                entries.append(("OpenAction", opening))
            }
            if let lang = carry.lang { entries.append(("Lang", writer.value(lang))) }
            if let files = carry.associatedFiles { entries.append(("AF", writer.value(files))) }
            for (key, value) in entries where !(isIdentity && present.contains(key)) {
                writer.update.setRaw(key, to: value, inObject: root)
            }
            if let embedded = carry.embeddedFiles {
                let tree = writer.dictionary(embedded)
                // Kept beside whatever `/Names` the copy already has, never in place of it.
                if let names = try writer.update.rawValue("Names", inObject: root) {
                    // Bytes, not a String: the copy's own strings in there need not be UTF-8.
                    var dictionary = names
                    if case .ref(let number, _)? = try writer.update.object(root).value["Names"] {
                        dictionary = try writer.update.rawObject(number)
                    }
                    while let last = dictionary.last, [0, 9, 10, 12, 13, 32].contains(last) { dictionary.removeLast() }
                    let hasFiles = dictionary.firstRange(of: Array("/EmbeddedFiles".utf8)) != nil
                    if dictionary.suffix(2) == Array(">>".utf8), !hasFiles {
                        writer.update.setRaw("Names", to: dictionary.dropLast(2) + Array(" /EmbeddedFiles \(tree) >>".utf8),
                                             inObject: root)
                    }
                } else {
                    writer.update.setRaw("Names", to: "<< /EmbeddedFiles \(tree) >>", inObject: root)
                }
            }

            try carryPageAttachments(carry: carry, writer: writer, outputPages: outputPages,
                                     outputToSource: outputToSource, displayMappedPages: displayMappedPages)

            let carried = try writer.update.appended()
            // Belt and braces: the result must open, with the same pages.
            guard let provider = CGDataProvider(data: carried as CFData),
                  let reopened = CGPDFDocument(provider),
                  reopened.numberOfPages == outputPages.count
            else { return data }
            return carried
        } catch {
            return data
        }
    }

    /// The copy's `/OpenAction`: the source's opening view, pointed at the page it named in the
    /// copy — or at the copy's first page when that page didn't come along, keeping only the zoom.
    private static func openingView(
        _ destination: CGPDFArrayRef,
        carry: SourceCatalog,
        writer: CatalogObjectWriter,
        outputPages: [Int],
        firstOutput: [Int: Int],
        displayMappedPages: Set<Int>
    ) -> String? {
        let count = CGPDFArrayGetCount(destination)
        guard count >= 2 else { return nil }
        var sourceIndex: Int?
        var pageDictionary: CGPDFDictionaryRef?
        var pageNumber: CGPDFInteger = 0
        if CGPDFArrayGetDictionary(destination, 0, &pageDictionary), let pageDictionary {
            sourceIndex = carry.pages.firstIndex { identity(of: $0) == identity(of: pageDictionary) }
        } else if CGPDFArrayGetInteger(destination, 0, &pageNumber) {
            sourceIndex = Int(pageNumber)
        }
        guard let sourceIndex else { return nil }
        var viewName: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(destination, 1, &viewName), let viewName else { return nil }
        let view = String(cString: viewName)
        var numbers: [CGFloat?] = (2..<count).map { i in
            var real: CGPDFReal = 0
            return CGPDFArrayGetNumber(destination, i, &real) ? real : nil
        }

        guard let output = firstOutput[sourceIndex] else {
            // The page didn't come along: open the first page, with the same zoom.
            let first = "\(outputPages[0]) 0 R"
            switch view {
            case "XYZ": return "[\(first) /XYZ null null \(format(numbers.count > 2 ? numbers[2] : nil))]"
            case "FitH", "FitBH", "FitV", "FitBV": return "[\(first) /\(view) null]"
            case "FitB": return "[\(first) /FitB]"
            default: return "[\(first) /Fit]"
            }
        }
        // A rebuilt page was emitted upright at a zero origin, so its coordinates move with it.
        var cropBox = CGRect.zero
        var rotation = 0
        if displayMappedPages.contains(output), let page = carry.cgPage(sourceIndex) {
            cropBox = page.getBoxRect(.cropBox)
            rotation = normalizedRotation(Int(page.rotationAngle))
        }
        if cropBox.origin != .zero || rotation != 0 {
            switch view {
            case "XYZ" where numbers.count >= 2:
                if rotation == 0 {
                    numbers[0] = numbers[0].map { $0 - cropBox.minX }
                    numbers[1] = numbers[1].map { $0 - cropBox.minY }
                } else if let x = numbers[0], let y = numbers[1] {
                    let point = displayPoint(CGPoint(x: x, y: y), cropBox: cropBox, rotation: rotation)
                    numbers[0] = point.x
                    numbers[1] = point.y
                } else {
                    numbers[0] = nil
                    numbers[1] = nil
                }
            case "FitH" where rotation == 0 && !numbers.isEmpty, "FitBH" where rotation == 0 && !numbers.isEmpty:
                numbers[0] = numbers[0].map { $0 - cropBox.minY }
            case "FitV" where rotation == 0 && !numbers.isEmpty, "FitBV" where rotation == 0 && !numbers.isEmpty:
                numbers[0] = numbers[0].map { $0 - cropBox.minX }
            case "FitR" where rotation == 0 && numbers.count == 4:
                numbers = [numbers[0].map { $0 - cropBox.minX }, numbers[1].map { $0 - cropBox.minY },
                           numbers[2].map { $0 - cropBox.minX }, numbers[3].map { $0 - cropBox.minY }]
            case "Fit", "FitB":
                break
            default:
                // A side or a rectangle on a turned page: fit the page rather than guess.
                return "[\(outputPages[output]) 0 R /Fit]"
            }
        }
        let tail = numbers.map(format).joined(separator: " ")
        return "[\(outputPages[output]) 0 R /\(PDFAppendedUpdate.escapedName(view))\(tail.isEmpty ? "" : " " + tail)]"
    }

    /// Re-attaches each source page's attached files to its page in the copy. PDFKit's page copy
    /// keeps a FileAttachment annotation but not its file (measured on macOS 27.0.1), and a rebuild
    /// keeps neither, so the copy's own FileAttachment annotations are replaced with the source's.
    private static func carryPageAttachments(
        carry: SourceCatalog,
        writer: CatalogObjectWriter,
        outputPages: [Int],
        outputToSource: [Int],
        displayMappedPages: Set<Int>
    ) throws {
        guard carry.attachments else { return }
        for (output, sourceIndex) in outputToSource.enumerated() {
            let attached = carry.fileAttachments(onPage: sourceIndex)
            guard !attached.isEmpty else { continue }
            let pageObject = outputPages[output]
            // Already there, file and all: an in-place write kept them.
            let existing = try writer.update.annotationObjects(ofPage: pageObject)
            let complete = try existing.filter { number in
                let annotation = try writer.update.object(number).value
                guard case .name("FileAttachment")? = annotation["Subtype"] else { return false }
                return annotation["FS"] != nil
            }
            if complete.count == attached.count { continue }
            var cropBox = CGRect.zero
            var rotation = 0
            if displayMappedPages.contains(output), let page = carry.cgPage(sourceIndex) {
                cropBox = page.getBoxRect(.cropBox)
                rotation = normalizedRotation(Int(page.rotationAngle))
            }
            var references: [String] = []
            for annotation in attached {
                var rect = CGRect.zero
                var rectArray: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(annotation, "Rect", &rectArray), let rectArray,
                   CGPDFArrayGetCount(rectArray) == 4 {
                    var v = [CGPDFReal](repeating: 0, count: 4)
                    for i in 0..<4 { _ = CGPDFArrayGetNumber(rectArray, i, &v[i]) }
                    rect = CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
                }
                if cropBox.origin != .zero || rotation != 0 {
                    rect = displayRect(rect, cropBox: cropBox, rotation: rotation)
                }
                // A popup is an annotation of its own, pointing back at this one; a structure
                // parent indexes tags that don't come along. On a turned page the icon's drawn
                // appearance would come out turned, so the reader draws its own.
                var skipping: Set<String> = ["P", "Popup", "Parent", "StructParent", "Rect"]
                if rotation != 0 { skipping.insert("AP") }
                let body = writer.dictionary(annotation, skipping: skipping, adding: [
                    ("P", "\(pageObject) 0 R"),
                    ("Rect", "[\(format(rect.minX)) \(format(rect.minY)) \(format(rect.maxX)) \(format(rect.maxY))]"),
                ])
                references.append("\(writer.update.addObject(Array(body.utf8))) 0 R")
            }
            var kept: [String] = []
            for number in existing {
                if case .name("FileAttachment")? = try writer.update.object(number).value["Subtype"] { continue }
                kept.append("\(number) 0 R")
            }
            let array = "[" + (kept + references).joined(separator: " ") + "]"
            if case .ref(let arrayObject, _)? = try writer.update.object(pageObject).value["Annots"] {
                writer.update.replaceObject(arrayObject, with: Array(array.utf8))
            } else {
                writer.update.setRaw("Annots", to: array, inObject: pageObject)
            }
        }
    }

    /// A number as PDF writes it: no exponent, no trailing zeros; `null` for none.
    static func format(_ value: CGFloat?) -> String {
        guard let value, value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.6f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

/// The address of a CoreGraphics PDF object, which is its identity: CoreGraphics hands back the
/// same object however it is reached (measured: an `/OpenAction`'s page is its page's dictionary).
/// A bit cast, since the SDKs differ on whether these refs are pointers or wrappers of one.
private func identity<Ref>(of ref: Ref) -> UnsafeRawPointer {
    unsafeBitCast(ref, to: UnsafeRawPointer.self)
}

/// The parts of a source catalog a copy carries, read once.
private struct SourceCatalog {
    let catalog: CGPDFDictionaryRef
    let pages: [CGPDFDictionaryRef]
    let cgPages: [CGPDFPage]
    let attachments: Bool

    var viewerPreferences: CGPDFDictionaryRef? { dictionary("ViewerPreferences") }
    var pageMode: String? { name("PageMode") }
    var pageLayout: String? { name("PageLayout") }
    var lang: CGPDFObjectRef? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(catalog, "Lang", &object), let object,
              CGPDFObjectGetType(object) == .string else { return nil }
        return object
    }

    var embeddedFiles: CGPDFDictionaryRef? {
        guard attachments, let names = dictionary("Names") else { return nil }
        var tree: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &tree) ? tree : nil
    }

    var associatedFiles: CGPDFObjectRef? {
        guard attachments else { return nil }
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(catalog, "AF", &object), let object,
              CGPDFObjectGetType(object) == .array else { return nil }
        return object
    }

    var hasAnything: Bool {
        labelRanges != nil || viewerPreferences != nil || pageMode != nil || pageLayout != nil
            || openingDestination != nil || lang != nil || embeddedFiles != nil || associatedFiles != nil
            || pages.indices.contains { !fileAttachments(onPage: $0).isEmpty }
    }

    func cgPage(_ index: Int) -> CGPDFPage? {
        guard index >= 0, index < pages.count else { return nil }
        return cgPages[index]
    }

    // MARK: Opening view

    /// The explicit destination the file opens at: an `/OpenAction` array, or a GoTo action's,
    /// with a named destination looked up. A script or any other action is not carried.
    var openingDestination: CGPDFArrayRef? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(catalog, "OpenAction", &object), let object else { return nil }
        var array: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &array), let array { return array }
        var action: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &action), let action else { return nil }
        var kind: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(action, "S", &kind), let kind, String(cString: kind) == "GoTo" else { return nil }
        var target: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(action, "D", &target), let target else { return nil }
        return resolvedDestination(target)
    }

    /// A destination as an explicit array: itself, or a named one looked up in `/Dests` or the
    /// `/Names /Dests` tree (whose value may be a dictionary holding it under `/D`).
    private func resolvedDestination(_ object: CGPDFObjectRef) -> CGPDFArrayRef? {
        var array: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &array), let array { return array }
        var key: [UInt8]?
        var string: CGPDFStringRef?
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .string, &string), let string {
            key = CatalogObjectWriter.bytes(of: string)
        } else if CGPDFObjectGetValue(object, .name, &name), let name {
            key = Array(String(cString: name).utf8)
        }
        guard let key else { return nil }
        var found: CGPDFObjectRef?
        if let dests = dictionary("Dests") {
            var dest: CGPDFObjectRef?
            let k = String(decoding: key, as: UTF8.self)
            if CGPDFDictionaryGetObject(dests, k, &dest) { found = dest }
        }
        if found == nil, let names = dictionary("Names") {
            var tree: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "Dests", &tree), let tree {
                found = Self.lookUp(key, inNameTree: tree, depth: 0)
            }
        }
        guard let found else { return nil }
        if CGPDFObjectGetValue(found, .array, &array), let array { return array }
        var holder: CGPDFDictionaryRef?
        if CGPDFObjectGetValue(found, .dictionary, &holder), let holder,
           CGPDFDictionaryGetArray(holder, "D", &array), let array { return array }
        return nil
    }

    private static func lookUp(_ key: [UInt8], inNameTree node: CGPDFDictionaryRef, depth: Int) -> CGPDFObjectRef? {
        guard depth < 32 else { return nil }
        var names: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &names), let names {
            var i = 0
            while i + 1 < CGPDFArrayGetCount(names) {
                var string: CGPDFStringRef?
                var value: CGPDFObjectRef?
                if CGPDFArrayGetString(names, i, &string), let string, CatalogObjectWriter.bytes(of: string) == key,
                   CGPDFArrayGetObject(names, i + 1, &value) {
                    return value
                }
                i += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for i in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, i, &kid), let kid,
                   let found = lookUp(key, inNameTree: kid, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: Page labels

    /// One page's label: a numbering style (`D`, `R`, `r`, `A`, `a`, or none), a prefix, a number.
    struct PageLabel: Equatable {
        var style: String?
        var prefix: [UInt8]?
        var number: Int
    }

    /// The source's label ranges, sorted by first page, or nil when it has none.
    var labelRanges: [(start: Int, style: String?, prefix: [UInt8]?, first: Int)]? {
        guard let tree = dictionary("PageLabels") else { return nil }
        var ranges: [(start: Int, style: String?, prefix: [UInt8]?, first: Int)] = []
        func walk(_ node: CGPDFDictionaryRef, depth: Int) {
            guard depth < 32 else { return }
            var nums: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Nums", &nums), let nums {
                var i = 0
                while i + 1 < CGPDFArrayGetCount(nums) {
                    var start: CGPDFInteger = 0
                    var label: CGPDFDictionaryRef?
                    if CGPDFArrayGetInteger(nums, i, &start), CGPDFArrayGetDictionary(nums, i + 1, &label), let label {
                        var style: UnsafePointer<CChar>?
                        var prefix: CGPDFStringRef?
                        var first: CGPDFInteger = 1
                        _ = CGPDFDictionaryGetName(label, "S", &style)
                        _ = CGPDFDictionaryGetString(label, "P", &prefix)
                        if !CGPDFDictionaryGetInteger(label, "St", &first) || first < 1 { first = 1 }
                        ranges.append((Int(start), style.map { String(cString: $0) },
                                       prefix.map(CatalogObjectWriter.bytes(of:)), Int(first)))
                    }
                    i += 2
                }
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
                for i in 0..<CGPDFArrayGetCount(kids) {
                    var kid: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(kids, i, &kid), let kid { walk(kid, depth: depth + 1) }
                }
            }
        }
        walk(tree, depth: 0)
        return ranges.isEmpty ? nil : ranges.sorted { $0.start < $1.start }
    }

    /// The label source page `index` shows. A page before the first range shows its plain number.
    func label(ofPage index: Int, ranges: [(start: Int, style: String?, prefix: [UInt8]?, first: Int)]) -> PageLabel {
        guard let range = ranges.last(where: { $0.start <= index }) else {
            return PageLabel(style: "D", prefix: nil, number: index + 1)
        }
        return PageLabel(style: range.style, prefix: range.prefix, number: range.first + index - range.start)
    }

    /// The copy's `/PageLabels`: every page keeps the label it had in the source, so a range
    /// starts wherever a page's label doesn't follow on from the one before it.
    func pageLabels(for outputToSource: [Int]) -> String? {
        guard let ranges = labelRanges else { return nil }
        var nums: [String] = []
        var previous: PageLabel?
        for (output, source) in outputToSource.enumerated() {
            let label = label(ofPage: source, ranges: ranges)
            let followsOn = previous.map {
                $0.style == label.style && $0.prefix == label.prefix
                    && (label.style == nil || $0.number + 1 == label.number)
            } ?? false
            if !followsOn {
                var entry = "<<"
                if let style = label.style { entry += " /S /" + PDFAppendedUpdate.escapedName(style) }
                if let prefix = label.prefix { entry += " /P " + CatalogObjectWriter.hex(prefix) }
                if label.style != nil, label.number != 1 { entry += " /St \(label.number)" }
                nums.append("\(output) \(entry) >>")
            }
            previous = label
        }
        return "<< /Nums [" + nums.joined(separator: " ") + "] >>"
    }

    // MARK: Attached files

    /// Source page `index`'s FileAttachment annotations.
    func fileAttachments(onPage index: Int) -> [CGPDFDictionaryRef] {
        guard attachments, index >= 0, index < pages.count else { return [] }
        var annots: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(pages[index], "Annots", &annots), let annots else { return [] }
        return (0..<CGPDFArrayGetCount(annots)).compactMap { i in
            var annotation: CGPDFDictionaryRef?
            var subtype: UnsafePointer<CChar>?
            guard CGPDFArrayGetDictionary(annots, i, &annotation), let annotation,
                  CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "FileAttachment" else { return nil }
            return annotation
        }
    }

    // MARK: Lookups

    private func dictionary(_ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(catalog, key, &value) ? value : nil
    }

    private func name(_ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(catalog, key, &value) ? value.map { String(cString: $0) } : nil
    }
}

/// Writes CoreGraphics' view of source objects as PDF syntax for an appended update. Each stream
/// becomes a new object (written once however often it is reached); dictionaries and arrays are
/// written in place. A source page becomes a reference to its copy, or `null` when it didn't come
/// along, and the page tree is never followed — so nothing drags the source's pages in.
private final class CatalogObjectWriter {
    var update: PDFAppendedUpdate
    private let pageObjects: [UnsafeRawPointer: Int]
    private var streams: [UnsafeRawPointer: Int] = [:]
    private var inProgress = Set<UnsafeRawPointer>()

    init(update: PDFAppendedUpdate, pageObjects: [UnsafeRawPointer: Int]) {
        self.update = update
        self.pageObjects = pageObjects
    }

    func value(_ object: CGPDFObjectRef) -> String {
        switch CGPDFObjectGetType(object) {
        case .null: return "null"
        case .boolean:
            var value: CGPDFBoolean = 0
            return CGPDFObjectGetValue(object, .boolean, &value) && value != 0 ? "true" : "false"
        case .integer:
            var value: CGPDFInteger = 0
            return CGPDFObjectGetValue(object, .integer, &value) ? String(value) : "0"
        case .real:
            var value: CGPDFReal = 0
            return CGPDFObjectGetValue(object, .real, &value) ? PDFToolkit.format(value) : "0"
        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value else { return "null" }
            return "/" + PDFAppendedUpdate.escapedName(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(value).assumingMemoryBound(to: UInt8.self), count: strlen(value)))
        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value else { return "null" }
            return Self.hex(Self.bytes(of: value))
        case .array:
            var value: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &value), let value else { return "null" }
            return array(value)
        case .dictionary:
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { return "null" }
            return dictionary(value)
        case .stream:
            var value: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &value), let value else { return "null" }
            return stream(value)
        @unknown default:
            return "null"
        }
    }

    func array(_ array: CGPDFArrayRef) -> String {
        let key = identity(of: array)
        guard inProgress.insert(key).inserted, inProgress.count < 64 else { return "null" }
        defer { inProgress.remove(key) }
        var items: [String] = []
        for i in 0..<CGPDFArrayGetCount(array) {
            var object: CGPDFObjectRef?
            items.append(CGPDFArrayGetObject(array, i, &object) && object != nil ? value(object!) : "null")
        }
        return "[" + items.joined(separator: " ") + "]"
    }

    /// `dictionary` without the keys in `skipping`, with `adding`'s raw entries after its own.
    func dictionary(_ dictionary: CGPDFDictionaryRef, skipping: Set<String> = [],
                    adding: [(String, String)] = []) -> String {
        if let number = pageObjects[identity(of: dictionary)] { return "\(number) 0 R" }
        var type: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "Type", &type), let type {
            let kind = String(cString: type)
            // A page that didn't come along, or the page tree itself.
            if kind == "Page" || kind == "Pages" { return "null" }
        }
        let key = identity(of: dictionary)
        guard inProgress.insert(key).inserted, inProgress.count < 64 else { return "null" }
        defer { inProgress.remove(key) }
        var entries: [(String, CGPDFObjectRef)] = []
        CGPDFDictionaryApplyBlock(dictionary, { name, object, _ in
            entries.append((String(cString: name), object))
            return true
        }, nil)
        var out = "<<"
        for (name, object) in entries.sorted(by: { $0.0 < $1.0 }) where !skipping.contains(name) {
            out += " /" + PDFAppendedUpdate.escapedName(name) + " " + value(object)
        }
        for (name, raw) in adding {
            out += " /" + PDFAppendedUpdate.escapedName(name) + " " + raw
        }
        return out + " >>"
    }

    /// A stream as a new object, its data decoded and deflated again — or a JPEG's left as it was.
    func stream(_ stream: CGPDFStreamRef) -> String {
        let key = identity(of: stream)
        if let number = streams[key] { return "\(number) 0 R" }
        guard let streamDictionary = CGPDFStreamGetDictionary(stream) else { return "null" }
        var format = CGPDFDataFormat.raw
        guard let decoded = CGPDFStreamCopyData(stream, &format) as Data? else { return "null" }
        let payload: Data
        let filter: String?
        switch format {
        case .jpegEncoded: payload = decoded; filter = "/DCTDecode"
        case .JPEG2000: payload = decoded; filter = "/JPXDecode"
        default:
            if let deflated = Self.zlib(decoded), deflated.count < decoded.count {
                payload = deflated
                filter = "/FlateDecode"
            } else {
                payload = decoded
                filter = nil
            }
        }
        // Reserved first, so a stream reached again from inside itself refers to itself.
        let placeholder = update.addObject([])
        streams[key] = placeholder
        var adding = [("Length", String(payload.count))]
        if let filter { adding.append(("Filter", filter)) }
        let header = dictionary(streamDictionary,
                                skipping: ["Length", "Filter", "DecodeParms", "F", "FFilter", "FDecodeParms"],
                                adding: adding)
        update.replaceAdded(placeholder, with: Array(header.utf8) + Array("\nstream\n".utf8) + [UInt8](payload) + Array("\nendstream".utf8))
        return "\(placeholder) 0 R"
    }

    static func bytes(of string: CGPDFStringRef) -> [UInt8] {
        guard let pointer = CGPDFStringGetBytePtr(string) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: CGPDFStringGetLength(string)))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
    }

    /// `data` deflated with a zlib header and checksum, as `/FlateDecode` expects.
    static func zlib(_ data: Data) -> Data? {
        guard !data.isEmpty, let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        var out = Data([0x78, 0x9C])
        out.append(deflated)
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
    }
}
