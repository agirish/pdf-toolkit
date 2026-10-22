import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

public struct PDFRedactionExportOptions: Sendable {
    /// When true, removes every annotation (highlights, comments, ink, etc.) from pages that are copied without rasterization.
    /// Redacted pages are always rebuilt as images, so their prior content under the marks is gone.
    var stripAnnotationsFromUnredactedPages: Bool
    /// Target length in **pixels** of the page’s longest edge when rasterizing a redacted page (higher = sharper, larger files and slower export).
    /// Unlike compression, this **supersamples** past 1× PDF points so text stays crisp (e.g. 4000 ≈ ~5× on US Letter height).
    var maxPixelDimension: CGFloat
    /// Zero-based pages to rasterize even though they carry no marks, destroying their text layer.
    ///
    /// Find & redact can match a value it cannot place a box on (no selection geometry, or the match
    /// clips into a cropped-out margin). Such a page would otherwise be copied through as vector and
    /// keep the matched text verbatim — detected, reported, and still readable in the export. The
    /// user is shown which pages are affected and chooses; when they choose removal, those indices
    /// arrive here. Never inferred: rasterizing a page the user never marked costs text selection,
    /// accessibility and file size, and produces no visible black box explaining why.
    var forceRasterizePages: Set<Int> = []

    /// The memberwise initializer, spelled out so it can be public.
    public init(stripAnnotationsFromUnredactedPages: Bool, maxPixelDimension: CGFloat, forceRasterizePages: Set<Int> = []) {
        self.stripAnnotationsFromUnredactedPages = stripAnnotationsFromUnredactedPages
        self.maxPixelDimension = maxPixelDimension
        self.forceRasterizePages = forceRasterizePages
    }

    public static let `default` = PDFRedactionExportOptions(
        stripAnnotationsFromUnredactedPages: false,
        maxPixelDimension: 4000
    )
}

/// How a Protect run encrypts a file. Plain values (no PDFKit objects) so the config crosses the PDF
/// serial queue and can be snapshotted into a batch operation.
///
/// Two styles express the same struct:
/// - **Lock to open** — `userPassword == ownerPassword`, `permissionBits == nil`. One password opens
///   the file and, once open, grants full access; the original single-password behavior.
/// - **Restrict editing** — `userPassword == ""`, `ownerPassword` set, `permissionBits` set. The file
///   opens (and prints) freely, but copying/editing/assembly need the owner password.
public struct ProtectionOptions: Sendable {
    /// The password required to *open* the file. Empty means the file opens without a password.
    public var userPassword: String
    /// The password required to change permissions or remove protection. Always required (an empty
    /// owner password throws `passwordRequired`).
    public var ownerPassword: String
    /// Raw `PDFAccessPermissions` bits to record, or `nil` to write none (full owner access — the
    /// single-password lock). See ``PDFPermissionPreset``.
    public var permissionBits: UInt?

    /// The memberwise initializer, spelled out so it can be public.
    public init(userPassword: String, ownerPassword: String, permissionBits: UInt? = nil) {
        self.userPassword = userPassword
        self.ownerPassword = ownerPassword
        self.permissionBits = permissionBits
    }
}

/// Named `PDFAccessPermissions` bitmasks for ``ProtectionOptions``. Built from raw bit values because
/// `PDFAccessPermissions` is imported as an `NS_ENUM` rather than an `OptionSet`, so the members are
/// combined by OR-ing their `rawValue`s.
public enum PDFPermissionPreset {
    /// Opens and prints freely; copying text, editing, annotating, and page assembly all require the
    /// owner password. Accessibility extraction stays allowed so screen readers keep working.
    public static var openAndPrintOnly: UInt {
        PDFAccessPermissions.allowsLowQualityPrinting.rawValue
            | PDFAccessPermissions.allowsHighQualityPrinting.rawValue
            | PDFAccessPermissions.allowsContentAccessibility.rawValue
    }
}

extension ProtectionOptions {
    /// The options for Protect's Add-password styles. The single source both the tool's single-file
    /// run and the batch builder derive from, so a change to a style can't silently make the two paths
    /// encrypt differently. `restrictEditing` picks the style (see ``ProtectionOptions``).
    public static func addPassword(restrictEditing: Bool, password: String) -> ProtectionOptions {
        restrictEditing
            ? ProtectionOptions(userPassword: "", ownerPassword: password, permissionBits: PDFPermissionPreset.openAndPrintOnly)
            : ProtectionOptions(userPassword: password, ownerPassword: password, permissionBits: nil)
    }
}

/// How a file on disk is protected, as far as removing that protection is concerned.
///
/// The distinction matters because the two states are enforced very differently. A `lockedToOpen`
/// file is genuinely encrypted against the reader: without the user password its content can't be
/// decoded at all, so Remove-password must verify the secret before it can do anything. A
/// `restrictedOnly` file — what Add-password's "Restrict editing" style writes — opens and decodes
/// with no password; the permission bits are a *request* to conforming readers, not encryption. Any
/// PDF reader can already read, copy and re-emit those pages, and PDFKit offers no way to check an
/// owner password on a document that isn't locked. So Remove-password can't verify anything there,
/// and the UI says so rather than asking for a password it will silently ignore.
public enum PDFEncryptionState: Sendable {
    /// No encryption dictionary — there is nothing to remove.
    case none
    /// A user password is required to open the file (PDFKit reports `isLocked`).
    case lockedToOpen
    /// Encrypted, but it opens without a password: owner restrictions only, which are advisory.
    case restrictedOnly
}

/// A decoded logo carried by value so ``WatermarkOptions`` stays `Sendable` across the PDF serial
/// queue and can be snapshotted into a batch operation. The `CGImage` is immutable and only ever
/// read (drawn), so `@unchecked Sendable` is safe — nothing mutates it after decode.
public struct WatermarkImage: @unchecked Sendable {
    public let cgImage: CGImage

    /// The memberwise initializer, spelled out so it can be public.
    public init(cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

/// How a watermark is stamped onto the chosen pages. RGB components (not `NSColor`) and a decoded
/// `CGImage` (not a URL) keep this `Sendable` for the background PDF queue and for a batch snapshot.
///
/// New fields are all defaulted so the original text-watermark call sites keep compiling unchanged;
/// `content == .text` with `pageScope == .all` reproduces the pre-existing behavior exactly.
public struct WatermarkOptions: Sendable {
    /// Whether this watermark stamps text or a logo image. Image is the smallpdf-beating addition.
    public enum Content: Sendable {
        case text
        case image
    }

    /// Which pages receive the mark. Resolved against each document's real page count at stamp
    /// time (so it stays correct per-file in a batch), never pre-expanded here.
    public enum PageScope: Sendable, Equatable {
        case all
        case firstPageOnly
        /// `PageRangeParser` syntax, e.g. "1, 3-5, 8". Empty text is an error, not "all pages".
        case custom(String)
    }

    public var text: String
    public var fontSize: CGFloat
    /// 0…1 fill opacity of the stamp (applied to text fill and, for images, composited with the
    /// logo's own alpha so a transparent PNG fades correctly).
    public var opacity: CGFloat
    public var rotationDegrees: CGFloat
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    /// When true, the mark is repeated across the whole page; otherwise it is drawn once, centered.
    public var tiled: Bool
    // --- Additive: all defaulted so existing initializers stay source-compatible ---
    /// Text vs. image. Defaults to `.text`, the original behavior.
    public var content: Content = .text
    /// Font family (display or PostScript name) for text marks; `nil` = bold system font (default).
    public var fontName: String? = nil
    /// The decoded logo for `.image` content; `nil` for text marks.
    public var image: WatermarkImage? = nil
    /// Logo size as a fraction of the page, aspect-fit inside `imageScale × page` (0…1). Only used
    /// for `.image` content.
    var imageScale: CGFloat = 0.4
    /// Which pages get the mark. Defaults to every page.
    public var pageScope: PageScope = .all

    /// The memberwise initializer, spelled out so it can be public.
    public init(
        text: String,
        fontSize: CGFloat,
        opacity: CGFloat,
        rotationDegrees: CGFloat,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        tiled: Bool,
        content: Content = .text,
        fontName: String? = nil,
        image: WatermarkImage? = nil,
        imageScale: CGFloat = 0.4,
        pageScope: PageScope = .all
    ) {
        self.text = text
        self.fontSize = fontSize
        self.opacity = opacity
        self.rotationDegrees = rotationDegrees
        self.red = red
        self.green = green
        self.blue = blue
        self.tiled = tiled
        self.content = content
        self.fontName = fontName
        self.image = image
        self.imageScale = imageScale
        self.pageScope = pageScope
    }
}

public enum PDFToolkit {
    /// Quick page count for UI summaries; the URL must already be readable (e.g. under active security scope).
    public static func pageCount(at url: URL) -> Int? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return doc.pageCount
    }

    /// Wraps any degree value into 0…359, handling negatives (both PDFKit's `page.rotation` and our
    /// quarter-turn math can go negative). Centralizes the `((x % 360) + 360) % 360` idiom that
    /// rotate, crop, watermark, and page-replay each inlined.
    public static func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    /// Opens a PDF for a content operation, refusing password-locked documents.
    ///
    /// A locked `PDFDocument` opens "successfully" and even reports its real page count, but its
    /// pages are inaccessible placeholders: `page.copy()` yields blank US-Letter pages (verified
    /// empirically — merge/extract/split/reorder silently emitted contentless output), `pageRef`
    /// is nil (compress/watermark/fill-sign fail with generic errors), and `write(to:)` on the
    /// mutated document just returns false (rotate/delete reported "could not save"). Refusing up
    /// front turns silent data loss and misleading failures into one clear, actionable error.
    /// Encrypted-but-not-locked documents (empty user password) pass through: PDFKit unlocks them
    /// implicitly and their pages are fully accessible. Internal so the per-tool extensions
    /// (Crop, OCR, …) open through the same guard.
    static func openUnlockedDocument(at url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw PDFOperationError.couldNotOpen(url)
        }
        guard !doc.isLocked else {
            throw PDFOperationError.encryptedInput(url)
        }
        return doc
    }

    /// Opens a PDF for an operation that MUTATES the loaded document in place (rotate, delete),
    /// refusing one whose permissions forbid it.
    ///
    /// A PDF encrypted with only an *owner* password — common in the wild (statements, corporate
    /// reports) and exactly what this app's own Protect ▸ "Restrict editing" mode writes — opens
    /// freely and is NOT `isLocked`, so ``openUnlockedDocument(at:)`` lets it through. But PDFKit
    /// silently refuses to mutate it: `page.rotation = …` and `removePage(at:)` become no-ops that
    /// only log to the console, and the subsequent `dataRepresentation()` succeeds — so the
    /// operation "succeeded" and landed an UNCHANGED file under a `-rotated`/`-deleted` name
    /// (verified empirically: rotations stayed `[0, 0]`, the deleted page was still there). For
    /// Delete that is a silent disclosure: the user believes a page is gone and ships a file that
    /// still contains it. Refuse up front instead, with a message that points at the fix.
    ///
    /// Only the in-place mutators need this. Every other operation rebuilds by copying pages into a
    /// fresh document (extract, reorder, merge, crop, watermark, redact, fill & sign) — verified to
    /// produce correct output on a restricted input — so they keep working through
    /// ``openUnlockedDocument(at:)``.
    static func openEditableDocument(at url: URL) throws -> PDFDocument {
        let doc = try openUnlockedDocument(at: url)
        // `allowsDocumentAssembly` is the permission PDFKit checks for both page rotation and page
        // removal; it is `true` on every unencrypted document, so this only ever fires on a
        // genuinely restricted file.
        guard !doc.isEncrypted || doc.allowsDocumentAssembly else {
            throw PDFOperationError.permissionsForbidEditing(url)
        }
        return doc
    }

    /// Refuses to write an operation's result on top of one of its own inputs.
    ///
    /// Every write path here targets a *fresh* file, so this only fires on caller misuse — but the
    /// consequences of that misuse are silent and unrecoverable: `deletePages`/`rotate` mutate the
    /// loaded `PDFDocument` and then `write(to:)` back over the very file it lazily reads from,
    /// producing an unopenable, zero-recoverable-pages source; the CoreGraphics paths (watermark)
    /// fully materialize the output in memory and would overwrite the original with the transformed
    /// copy. Called before the source is ever opened, this converts that data-losing accident into a
    /// clear error while the source is still untouched. Paths are compared after resolving symlinks
    /// and `.`/`..` so `/var`↔`/private/var`-style aliases don't slip through.
    // Internal (not private): operation extensions in sibling files (e.g. metadata) share this guard.
    public static func requireDistinctOutput(_ output: URL, from inputs: [URL]) throws {
        let target = output.resolvingSymlinksInPath().standardizedFileURL
        for input in inputs where input.resolvingSymlinksInPath().standardizedFileURL == target {
            throw PDFOperationError.outputMatchesInput(output)
        }
    }

    /// Lands a core's in-memory result at `outputURL` atomically, mapping any write failure to the
    /// operation-level `couldNotWrite` the URL API has always thrown. The one write path every
    /// URL wrapper shares now that the operations build their result as `Data`.
    // Internal (not private): operation extensions in sibling files (Crop, Metadata, …) share it.
    public static func writeOutput(_ data: Data, to outputURL: URL) throws {
        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Merges whole PDFs in the order given, copying every source page into the result.
    public static func merge(inputURLs: [URL], outputURL: URL) throws {
        try requireDistinctOutput(outputURL, from: inputURLs)
        try writeOutput(try mergeData(inputURLs: inputURLs), to: outputURL)
    }

    /// Merges a per-input page selection in list order.
    public static func merge(inputs: [(url: URL, pageIndices: [Int]?)], outputURL: URL) throws {
        try requireDistinctOutput(outputURL, from: inputs.map(\.url))
        try writeOutput(try mergeData(inputs: inputs), to: outputURL)
    }

    /// In-memory core of ``merge(inputURLs:outputURL:)`` — whole files, every page.
    internal static func mergeData(inputURLs: [URL]) throws -> Data {
        try mergeData(inputs: inputURLs.map { (url: $0, pageIndices: nil) })
    }

    /// In-memory core of the merge, with a per-input page selection — the tool views consume the
    /// bytes directly, skipping the temp-file round trip.
    ///
    /// Each input carries `pageIndices`: `nil` copies **every** page of that file (the whole-file
    /// default), a non-nil array copies exactly those zero-based pages **in the order given**
    /// (duplicates allowed, so a caller can reorder or repeat within a file), and an empty array
    /// contributes no pages from that input. At least one page must survive across all inputs, or
    /// `noPagesSelected` is thrown — PDFKit cannot persist a zero-page document.
    ///
    /// Uses `page.copy()` rather than moving the original page out of its document — the same
    /// approach as `extract`/`split`. Inserting a page that still belongs to another live
    /// `PDFDocument` hangs on macOS 26 (PDFKit spins building an `NSOrderedSet` inside
    /// `insertPage:atIndex:`), which would freeze every merge; copying detaches the page first and
    /// sidesteps it.
    public static func mergeData(inputs: [(url: URL, pageIndices: [Int]?)]) throws -> Data {
        guard !inputs.isEmpty else { throw PDFOperationError.noInputFiles }

        let merged = PDFDocument()
        // The combined document takes the FIRST input's Title/Author (the user's choice): a merge
        // has no single obvious source, and the output is already named after the first file, so
        // this is the predictable answer. Without it a merge silently dropped every input's title.
        var mergedAttributes: [AnyHashable: Any] = [:]
        for (index, input) in inputs.enumerated() {
            let doc = try openUnlockedDocument(at: input.url)
            // The FIRST file's fields specifically — not the first non-empty set found. If file 1
            // is untitled the merge stays untitled rather than silently adopting file 3's title.
            if index == 0 { mergedAttributes = restorableAttributes(of: doc) }
            let indices = input.pageIndices ?? Array(0..<doc.pageCount)
            for i in indices {
                guard i >= 0, i < doc.pageCount else {
                    throw PDFOperationError.pageOutOfBounds(i + 1)
                }
                guard let copy = doc.page(at: i)?.copy() as? PDFPage else {
                    throw PDFOperationError.couldNotOpen(input.url)
                }
                merged.insert(copy, at: merged.pageCount)
            }
        }

        // NOTE: source outlines (bookmarks) are intentionally dropped for now. A merge concatenates
        // pages from possibly MANY documents, each with its own outline, at shifting page offsets and
        // under per-input page selections — a correct combined outline would remap every source's
        // destinations into its slice of the merged page range and reconcile clashing roots. That is
        // feasible but non-trivial; until it's built, dropping is safer than a misdirected reassign.
        // (Interactive `/AcroForm` fields are likewise not carried across the page-copy rebuild.)
        //
        // A selection that copies nothing (every page dropped/filtered out) would otherwise be
        // written as a one-blank-page file by PDFKit's writer — refuse it with a clear error instead.
        guard merged.pageCount > 0 else { throw PDFOperationError.noPagesSelected }
        if !mergedAttributes.isEmpty { merged.documentAttributes = mergedAttributes }
        guard let data = merged.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
    }

    /// Splits a PDF into several files, one per segment. Each `segment` is a list of zero-based
    /// page indices copied (in order) into its own document. Files are written into `directory`
    /// as `baseName-01.pdf`, `baseName-02.pdf`, … (index width grows with the part count) and the
    /// produced URLs are returned in order. A name clash with an existing file is numbered via
    /// ``uniqueURL(inDirectory:filename:fileManager:)`` — never overwritten.
    public static func split(inputURL: URL, into directory: URL, baseName: String, segments: [[Int]]) throws -> [URL] {
        guard !segments.isEmpty else { throw PDFOperationError.noPagesSelected }
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        // NOTE: the source outline (bookmarks) is intentionally dropped from every part for now.
        // Each part is a different subset of pages, so a correct remap would have to rebuild a
        // per-part outline (like `extractData` does via `remapOutline`) and decide how a bookmark
        // spanning parts is split — deferred until that behavior is specified. Reattaching the whole
        // source outline naively would point every part's bookmarks at the wrong pages, so we keep
        // dropping it rather than ship a misdirected one.
        let width = max(2, String(segments.count).count)
        // Every part is the same document cut up, so each inherits the source's Title/Author rather
        // than being written with an empty info dictionary.
        let sourceAttributes = restorableAttributes(of: source)
        var outputs: [URL] = []
        do {
            for (partIndex, segment) in segments.enumerated() {
                guard !segment.isEmpty else { continue }
                let out = PDFDocument()
                var insertAt = 0
                for i in segment {
                    guard let src = source.page(at: i) else {
                        throw PDFOperationError.pageOutOfBounds(i + 1)
                    }
                    guard let copy = src.copy() as? PDFPage else {
                        throw PDFOperationError.couldNotOpen(inputURL)
                    }
                    out.insert(copy, at: insertAt)
                    insertAt += 1
                }
                if !sourceAttributes.isEmpty { out.documentAttributes = sourceAttributes }
                let suffix = String(format: "%0\(width)d", partIndex + 1)
                let url = uniqueURL(
                    inDirectory: directory,
                    filename: "\(baseName)-\(suffix).pdf"
                )
                try requireDistinctOutput(url, from: [inputURL])
                // Materialize the bytes and write them atomically — the one write path here that
                // still used PDFKit's non-atomic `write(to:)`, which can leave a torn part file on a
                // mid-write failure. A crash now leaves either the whole part or nothing.
                guard let partData = out.dataRepresentation() else {
                    throw PDFOperationError.couldNotEncodeOutput
                }
                do {
                    try partData.write(to: url, options: .atomic)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw PDFOperationError.couldNotWrite(url)
                }
                outputs.append(url)
            }
        } catch {
            // Unwind parts already written so a failed split never leaves a half set behind.
            // Safe to delete: uniqueURL guarantees every path here was created by this call.
            for url in outputs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        guard !outputs.isEmpty else { throw PDFOperationError.noPagesSelected }
        return outputs
    }

    /// Copies listed pages (zero-based) into a new PDF.
    public static func extract(inputURL: URL, outputURL: URL, pageIndices: [Int]) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try extractData(inputURL: inputURL, pageIndices: pageIndices), to: outputURL)
    }

    /// In-memory core of ``extract(inputURL:outputURL:pageIndices:)``.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func extractData(inputURL: URL, pageIndices: [Int]) throws -> Data {
        guard !pageIndices.isEmpty else { throw PDFOperationError.noPagesSelected }
        let source = try openUnlockedDocument(at: inputURL)

        let out = PDFDocument()
        // Which output position each *source* page first landed at — the map the outline remap needs
        // to move a bookmark's destination onto the page's new slot (first occurrence wins when a
        // page is copied more than once).
        var sourceToOutput: [Int: Int] = [:]
        var insertAt = 0
        for i in pageIndices {
            guard let src = source.page(at: i) else {
                throw PDFOperationError.pageOutOfBounds(i + 1)
            }
            guard let copy = src.copy() as? PDFPage else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
            out.insert(copy, at: insertAt)
            if sourceToOutput[i] == nil { sourceToOutput[i] = insertAt }
            insertAt += 1
        }

        // Bookmarks reference source pages by their catalog destinations; this is a SUBSET/REORDER,
        // so the source indices no longer line up with the output. A naive `out.outlineRoot =
        // source.outlineRoot` would keep the old indices and silently point bookmarks at the wrong
        // page (or off the end). Rebuild each destination against the retained output page instead,
        // dropping bookmarks whose target page wasn't extracted. (An interactive `/AcroForm` still
        // does not survive the page-copy rebuild — out of scope here.)
        remapOutline(from: source, to: out, sourceToOutput: sourceToOutput)
        // Internal links have the same problem one level down: a copied link still aims at its
        // target's SOURCE index, or at a named destination in a catalog the fresh document lacks.
        remapInternalLinks(
            from: source,
            to: out,
            copiedPages: pageIndices.enumerated().map { ($0.offset, $0.element) },
            sourceToOutput: sourceToOutput
        )
        // The fresh document starts with an empty info dictionary, so extracting (or reordering)
        // used to silently strip the document's Title/Author — the same catalog loss the rebuild
        // family had, and one that contradicts "Strip metadata on export" defaulting to OFF.
        let attributes = restorableAttributes(of: source)
        if !attributes.isEmpty { out.documentAttributes = attributes }

        guard let data = out.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        // Each page keeps its own label, so an extract of "iii" and "4" still reads "iii" and "4".
        return carryingCatalogParts(data, from: source, outputToSource: pageIndices)
    }

    /// Rebuilds `source`'s outline onto `output`, whose pages are a subset and/or reordering of
    /// `source`'s (extract/reorder). `sourceToOutput` maps a source page index to the output index
    /// it now occupies. Each surviving bookmark's destination is rebuilt to point at the matching
    /// `output` page; a bookmark whose target page was dropped is removed and its still-retained
    /// descendants are promoted to its parent, so a kept child under a dropped folder survives.
    ///
    /// Why rebuild rather than reassign: PDFKit serializes an outline destination by the index of
    /// its page *within that page's own document*. When every page is copied 1:1 in order (the
    /// crop / remove-password path) those indices are unchanged, so a plain `outlineRoot` reassign
    /// is correct. For a subset or reorder the indices shift, and only rebuilt destinations point
    /// where the reader expects — never a dangling or misdirected bookmark.
    ///
    /// A *structural* node — a grouping folder with no destination of its own — is kept whenever any
    /// of its descendants survive, so a well-organized outline keeps its shape instead of being
    /// flattened into a single level (the same rule ``pruneOutlineForDeletion`` applies for delete).
    /// It is dropped only when nothing beneath it survived, rather than left as an empty folder.
    ///
    /// Bookmarks expressed as GoTo *actions* (rather than an explicit `destination`) carry no
    /// `destination` here. A node with a destination whose target page wasn't retained is dropped;
    /// explicit destinations are the common case and the one the tools produce.
    private static func remapOutline(
        from source: PDFDocument,
        to output: PDFDocument,
        sourceToOutput: [Int: Int]
    ) {
        guard let sourceRoot = source.outlineRoot else { return }

        func appendRemapped(of node: PDFOutline, into parent: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                var mapped: PDFPage?
                if let destPage = child.destination?.page {
                    let srcIndex = source.index(for: destPage)
                    if srcIndex != NSNotFound,
                       let outIndex = sourceToOutput[srcIndex],
                       let outPage = output.page(at: outIndex) {
                        mapped = outPage
                    }
                }
                if let outPage = mapped {
                    let kept = PDFOutline()
                    kept.label = child.label
                    let point = child.destination?.point ?? CGPoint(x: 0, y: outPage.bounds(for: .cropBox).maxY)
                    kept.destination = PDFDestination(page: outPage, at: point)
                    parent.insertChild(kept, at: parent.numberOfChildren)
                    appendRemapped(of: child, into: kept)
                } else if child.destination == nil {
                    // No destination of its own. Two cases worth keeping: a page-independent action
                    // (a web-link bookmark — dropping it would leave dead label text), and a
                    // structural folder whose descendants survived. A folder with nothing left under
                    // it and no action of its own is dropped rather than kept as an empty row.
                    let folder = PDFOutline()
                    folder.label = child.label
                    let action = child.action.flatMap { $0 is PDFActionGoTo ? nil : $0 }
                    appendRemapped(of: child, into: folder)
                    if folder.numberOfChildren > 0 || action != nil {
                        folder.action = action
                        parent.insertChild(folder, at: parent.numberOfChildren)
                    }
                } else {
                    // Bookmark whose target page wasn't retained: drop it, but keep walking so
                    // retained descendants are promoted rather than lost with it.
                    appendRemapped(of: child, into: parent)
                }
            }
        }

        let newRoot = PDFOutline()
        appendRemapped(of: sourceRoot, into: newRoot)
        if newRoot.numberOfChildren > 0 {
            output.outlineRoot = newRoot
        }
    }

    /// Writes a new PDF whose pages follow `order` (a permutation of the source's zero-based
    /// indices). This is `extract` with the full page set reshuffled — a page appears exactly
    /// where the new order places it.
    static func reorder(inputURL: URL, outputURL: URL, order: [Int]) throws {
        try extract(inputURL: inputURL, outputURL: outputURL, pageIndices: order)
    }

    /// In-memory core of ``reorder(inputURL:outputURL:order:)`` — `extract`'s core reshuffled.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func reorderData(inputURL: URL, order: [Int]) throws -> Data {
        try extractData(inputURL: inputURL, pageIndices: order)
    }

    /// Removes pages (zero-based). Duplicates are ignored.
    static func deletePages(inputURL: URL, outputURL: URL, pageIndices: [Int]) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try deletePagesData(inputURL: inputURL, pageIndices: pageIndices), to: outputURL)
    }

    /// In-memory core of ``deletePages(inputURL:outputURL:pageIndices:)``. Removed from highest
    /// index first.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func deletePagesData(inputURL: URL, pageIndices: [Int]) throws -> Data {
        guard !pageIndices.isEmpty else { throw PDFOperationError.noPagesSelected }
        // Mutates the loaded document in place, so a permission-restricted file must be refused
        // rather than silently no-op'd into an unchanged "deleted" file — see openEditableDocument.
        let doc = try openEditableDocument(at: inputURL)

        let unique = Set(pageIndices)
        // Bounds-check FIRST: otherwise an out-of-range index inflates `unique.count` and trips the
        // every-page guard, reporting `cannotRemoveEveryPage` for a request whose real problem is a
        // bad page number (e.g. [0,1,5] on a 3-page doc). Validate each index, then compare counts.
        // Iterate in SORTED order rather than raw `Set` order (which is non-deterministic across runs):
        // when several indices are out of range this reports the smallest offending page every time, so
        // the thrown `pageOutOfBounds(n)` is stable instead of a coin-flip among the bad indices.
        for index in unique.sorted() {
            guard index >= 0, index < doc.pageCount else {
                throw PDFOperationError.pageOutOfBounds(index + 1)
            }
        }
        guard unique.count < doc.pageCount else {
            throw PDFOperationError.cannotRemoveEveryPage
        }

        // Prune the outline BEFORE the pages go, while `doc.index(for:)` still returns the original
        // indices `unique` is expressed in. Delete used to leave the source outline untouched, but a
        // bookmark whose target page is removed does NOT vanish — PDFKit silently retargets it to
        // page 0 (verified), misdirecting the reader to the wrong content. Extract/reorder avoid this
        // by remapping (see `remapOutline`); delete now drops the orphaned bookmarks the same way,
        // in place so the catalog (and any `/AcroForm`) survives the removal.
        pruneOutlineForDeletion(in: doc, deleting: unique)

        let expectedCount = doc.pageCount - unique.count
        let survivors = (0..<doc.pageCount).filter { !unique.contains($0) }
        for index in unique.sorted(by: >) {
            doc.removePage(at: index)
        }
        // Belt and braces behind the permission guard: `removePage` reports nothing when PDFKit
        // declines it, so confirm the pages actually went. Shipping a file that still contains a
        // page the user deleted is the one outcome this tool must never produce.
        guard doc.pageCount == expectedCount else {
            throw PDFOperationError.permissionsForbidEditing(inputURL)
        }

        guard let data = doc.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        // A write that changes the page tree comes back with a bare catalog, in place or not. The
        // catalog is read from a second, untouched parse: `doc` has lost the deleted pages.
        guard let source = PDFDocument(url: inputURL), !source.isLocked, source.pageCount == survivors.count + unique.count else {
            return data
        }
        return carryingCatalogParts(data, from: source, outputToSource: survivors)
    }

    /// Rewrites `doc`'s outline in place for a page deletion: every bookmark whose destination page
    /// is in `deleted` is dropped, and its still-retained descendants are promoted to its parent, so
    /// a kept child under a deleted-page folder survives (the same rule ``remapOutline`` applies for
    /// a subset/reorder). Bookmarks to retained pages — and structural nodes with no destination —
    /// are kept, pointing at the same page objects; once the pages are removed, PDFKit re-resolves
    /// each destination's index on write, so a survivor lands on its page's new slot.
    ///
    /// Must run BEFORE the pages are removed, while `doc.index(for:)` still returns the original
    /// indices `deleted` is expressed in. Destination points are copied through unchanged (not
    /// clamped), matching ``remapOutline``.
    private static func pruneOutlineForDeletion(in doc: PDFDocument, deleting deleted: Set<Int>) {
        guard let sourceRoot = doc.outlineRoot else { return }

        func rebuild(_ node: PDFOutline, into parent: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                // A bookmark's jump arrives either as an explicit destination or as a GoTo action;
                // both point at a page, so both have to be tested against the deletion.
                let jump = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                var targetsDeletedPage = false
                if let destPage = jump?.page {
                    let index = doc.index(for: destPage)
                    targetsDeletedPage = index != NSNotFound && deleted.contains(index)
                }
                if targetsDeletedPage {
                    // Drop this node, but keep walking so descendants pointing at retained pages are
                    // promoted rather than lost with it.
                    rebuild(child, into: parent)
                } else {
                    let kept = PDFOutline()
                    kept.label = child.label
                    if let dest = child.destination, let destPage = dest.page {
                        kept.destination = PDFDestination(page: destPage, at: dest.point)
                    } else if let action = child.action {
                        // No destination of its own: whatever makes this node do something lives in
                        // its action (a web-link bookmark, a named or remote GoTo, or a GoTo to a
                        // retained page — the deleted-target case was dropped above). Copying only
                        // the destination left the label behind as dead text. A GoTo is safe to
                        // carry here — unlike `reattachOutline`, this rebuild stays inside the same
                        // document, so the action's page object is still one of ours.
                        kept.action = action
                    }
                    parent.insertChild(kept, at: parent.numberOfChildren)
                    rebuild(child, into: kept)
                }
            }
        }

        let newRoot = PDFOutline()
        rebuild(sourceRoot, into: newRoot)
        // Replace the original outline unconditionally — leaving it in place would keep the very
        // misdirecting bookmarks this prune exists to remove. An empty result clears the outline.
        doc.outlineRoot = newRoot.numberOfChildren > 0 ? newRoot : nil
    }

    /// Rotates selected pages by `quarterTurns` × 90° clockwise.
    public static func rotate(inputURL: URL, outputURL: URL, pageIndices: [Int], quarterTurns: Int) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(
            try rotateData(inputURL: inputURL, pageIndices: pageIndices, quarterTurns: quarterTurns),
            to: outputURL
        )
    }

    /// In-memory core of ``rotate(inputURL:outputURL:pageIndices:quarterTurns:)``.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func rotateData(inputURL: URL, pageIndices: [Int], quarterTurns: Int) throws -> Data {
        // Mutates `page.rotation` in place, so a permission-restricted file must be refused rather
        // than silently no-op'd into an unrotated "rotated" file — see openEditableDocument.
        let doc = try openEditableDocument(at: inputURL)
        // Validate the selection up front, like delete/extract/split: a page index past the end used
        // to be silently ignored (the rotate loop just never matched it), so a typo'd range rotated
        // nothing on that page with no error. Reject it with `pageOutOfBounds` instead.
        for i in pageIndices {
            guard i >= 0, i < doc.pageCount else {
                throw PDFOperationError.pageOutOfBounds(i + 1)
            }
        }
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns != 0 {
            let unique = Set(pageIndices)
            for i in 0..<doc.pageCount {
                guard unique.contains(i), let page = doc.page(at: i) else { continue }
                var r = page.rotation
                r = normalizedRotation(r)
                r += turns * 90
                r = normalizedRotation(r)
                page.rotation = r
                // Belt and braces behind the permission guard: PDFKit reports a declined rotation
                // only to the console, so confirm it landed rather than saving an unrotated file
                // under a "-rotated" name.
                guard normalizedRotation(page.rotation) == r else {
                    throw PDFOperationError.permissionsForbidEditing(inputURL)
                }
            }
        }

        guard let data = doc.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
    }

    /// Writes an encrypted copy that requires `password` to open.
    public static func encrypt(inputURL: URL, outputURL: URL, password: String) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try encryptData(inputURL: inputURL, password: password), to: outputURL)
    }

    /// In-memory core of ``encrypt(inputURL:outputURL:password:)``. The same string is set as both
    /// the user password (needed to open) and the owner password (needed to change permissions), so
    /// the document is fully locked behind one password. The input must be an openable, unencrypted
    /// PDF.
    internal static func encryptData(inputURL: URL, password: String) throws -> Data {
        guard !password.isEmpty else { throw PDFOperationError.passwordRequired }
        // A single password locks the whole file: user == owner, no permission bits written (once
        // opened, the reader has full owner access) — byte-for-byte the original single-password lock.
        return try encryptData(
            inputURL: inputURL,
            options: ProtectionOptions(userPassword: password, ownerPassword: password, permissionBits: nil)
        )
    }

    /// In-memory core shared by both protection styles. Always encrypts (an owner password is
    /// required); the user password gates *opening* and is omitted for the restrict-only style so the
    /// file opens freely, while `permissionBits` — when set — records what a reader may still do
    /// without the owner password. The input must be an openable, unencrypted PDF; a locked input
    /// throws `encryptedInput` (via `openUnlockedDocument`), not `incorrectPassword`, since no
    /// password was typed on this path.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func encryptData(inputURL: URL, options: ProtectionOptions) throws -> Data {
        guard !options.ownerPassword.isEmpty else { throw PDFOperationError.passwordRequired }
        let doc = try openUnlockedDocument(at: inputURL)
        guard doc.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        var writeOptions: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: options.ownerPassword,
        ]
        // Only set a user (open) password when there is one: an empty string here would demand an
        // empty password to open rather than opening freely.
        if !options.userPassword.isEmpty {
            writeOptions[.userPasswordOption] = options.userPassword
        }
        // Access permissions only bite when the file opens without the owner password, which is the
        // restrict-only style. `PDFAccessPermissions` is declared `NS_ENUM`, so the raw bits are
        // combined by the caller and passed as an NSNumber — the shape the write option expects.
        if let bits = options.permissionBits {
            writeOptions[.accessPermissionsOption] = NSNumber(value: bits)
        }
        guard let data = doc.dataRepresentation(options: writeOptions) else {
            throw PDFOperationError.protectionFailed
        }
        return data
    }

    /// Writes a decrypted copy with no password.
    public static func removePassword(inputURL: URL, outputURL: URL, password: String) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try removePasswordData(inputURL: inputURL, password: password), to: outputURL)
    }

    /// The protection state of the file at `inputURL`, or ``PDFEncryptionState/none`` if it can't be
    /// opened at all (callers surface the real failure when they go to do the work).
    public static func encryptionState(of inputURL: URL) -> PDFEncryptionState {
        guard let doc = PDFDocument(url: inputURL) else { return .none }
        if doc.isLocked { return .lockedToOpen }
        return doc.isEncrypted ? .restrictedOnly : .none
    }

    /// In-memory core of ``removePassword(inputURL:outputURL:password:)``. A source that isn't
    /// encrypted at all throws `notEncrypted` so the tool can say there's nothing to remove.
    ///
    /// `password` is only consulted for a ``PDFEncryptionState/lockedToOpen`` source, where it has to
    /// decrypt the content (wrong password → `incorrectPassword`). For a ``PDFEncryptionState/restrictedOnly``
    /// source it is **ignored, by necessity**: the document already opened without it, and PDFKit has
    /// no API to verify an owner password on an unlocked document. Nothing is being circumvented —
    /// owner restrictions are advisory and any reader can already do this — but the caller must not
    /// present the field as if it were checked. See ``PDFEncryptionState``.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func removePasswordData(inputURL: URL, password: String) throws -> Data {
        guard let doc = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        if doc.isLocked {
            guard doc.unlock(withPassword: password) else {
                throw PDFOperationError.incorrectPassword
            }
        } else if !doc.isEncrypted {
            throw PDFOperationError.notEncrypted
        }
        guard doc.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        // Serializing the unlocked document directly is NOT enough: PDFKit carries the original
        // encryption into the output, so a just-unlocked doc re-serializes to a file that is
        // still locked with the same password. Rebuild the pages into a fresh document, which
        // has no encryption dictionary, so the saved copy genuinely opens with no password.
        // The rebuild keeps pages and the info dictionary, and page labels, viewer settings, the
        // language and attached files are carried after it; an interactive form dictionary still
        // doesn't survive it (the tool's UI discloses this).
        let output = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else {
                throw PDFOperationError.protectionFailed
            }
            output.insert(page, at: output.pageCount)
        }
        output.documentAttributes = doc.documentAttributes
        // Bookmarks live on the catalog, not the pages, so the rebuild would drop them. Every page
        // is copied here in the SAME order, so reattaching the source outline is safe: PDFKit remaps
        // each destination onto the matching copy on write (the proven metadata-clean pattern). No
        // subset or reorder is involved, so the destinations can't dangle or misdirect.
        if let outline = doc.outlineRoot {
            output.outlineRoot = outline
        }
        remapInternalLinksOfFullCopy(from: doc, to: output)
        guard output.pageCount > 0, let data = output.dataRepresentation() else {
            throw PDFOperationError.protectionFailed
        }
        return carryingCatalogParts(data, from: doc, outputToSource: Array(0..<doc.pageCount))
    }

    /// Stamps text or a logo image onto the chosen pages and writes a new PDF.
    ///
    /// Each page is copied into a fresh CoreGraphics PDF context with `drawPDFPage`, which keeps the
    /// original page **as vector content** (text stays selectable, graphics stay sharp) rather than
    /// rasterizing it the way compression does. The watermark is then drawn on top — text with
    /// CoreText via an `NSGraphicsContext` bridge, a logo with `CGContext.draw` — so it is baked
    /// into the page content stream, not a strippable annotation. Intrinsic page rotation is
    /// honored: the output page's media box uses the page's *displayed* size and `getDrawingTransform`
    /// maps the source upright before the stamp is added. Visible annotation appearances (form
    /// values, signatures, notes) are drawn after the content so they survive the rebuild —
    /// flattened into the page rather than silently dropped. Pages outside `options.pageScope` are
    /// still emitted unchanged (page count is always preserved); they just receive no mark.
    static func watermark(inputURL: URL, outputURL: URL, options: WatermarkOptions) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try watermarkData(inputURL: inputURL, options: options), to: outputURL)
    }

    /// In-memory core of ``watermark(inputURL:outputURL:options:)`` — the CGPDFContext already
    /// builds the whole result in an `NSMutableData`, so the core simply hands those bytes back.
    public static func watermarkData(inputURL: URL, options: WatermarkOptions) throws -> Data {
        let trimmed = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate the payload for the chosen mode before touching the document.
        switch options.content {
        case .text:
            guard !trimmed.isEmpty else { throw PDFOperationError.watermarkTextRequired }
        case .image:
            guard options.image != nil else { throw PDFOperationError.watermarkImageRequired }
        }

        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        // Which pages get the mark, resolved against this document's real length (a custom range
        // that overshoots throws `pageOutOfBounds`, exactly like the other range-taking tools).
        let stampPages = try applicableWatermarkPages(options.pageScope, pageCount: source.pageCount)

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.watermarkFailed
        }

        for i in 0..<source.pageCount {
            let dp = try displayedPage(source.page(at: i), inputURL: inputURL)
            emitDisplayedPage(dp, into: ctx) { ctx, dp in
                // Every page is emitted; only the in-scope ones are stamped.
                guard stampPages.contains(i) else { return }
                drawWatermark(in: ctx, box: dp.box, trimmedText: trimmed, options: options)
            }
        }
        ctx.closePDF()

        guard pdfData.length > 0 else { throw PDFOperationError.watermarkFailed }
        // The CGPDFContext emits pages only; bookmarks, the info dictionary, and links live on the
        // catalog and would otherwise be lost (see ``restoringCatalog(_:from:restoreLinks:)``).
        return restoringCatalog(pdfData as Data, from: source, restoreLinks: true)
    }

    /// Bakes placed text, drawn signatures and patches onto their pages and writes a new PDF.
    ///
    /// Built exactly like ``watermark``: each page is redrawn as **vector** content with
    /// `drawPDFPage` (so the underlying text stays selectable) and its visible annotations are
    /// flattened in (in displayed-page space — PDFKit's annotation draw maps there itself). The
    /// placed items are then drawn *inside the crop-box drawing transform* like the content — so an
    /// item's page-space rectangle (captured from the placement canvas) lands on exactly the pixels
    /// the user saw, honoring page rotation and crop just like redaction fills.
    /// Typed runs are drawn with CoreText (they remain selectable, searchable vector text); drawn
    /// signatures are stroked as vector paths from their normalized polylines — never rasterized.
    /// Patches are filled rectangles, drawn first on their page so the text placed over them shows;
    /// they cover what is under them without removing it.
    static func fillAndSign(inputURL: URL, outputURL: URL, items: [FillSignItem]) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try fillAndSignData(inputURL: inputURL, items: items), to: outputURL)
    }

    /// In-memory core of ``fillAndSign(inputURL:outputURL:items:)`` — like ``watermarkData``, the
    /// CGPDFContext builds the result in memory and the core hands the bytes back.
    public static func fillAndSignData(inputURL: URL, items: [FillSignItem]) throws -> Data {
        let inked = items.filter(\.hasInk)
        guard !inked.isEmpty else { throw PDFOperationError.noFillSignItems }
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let byPage = Dictionary(grouping: inked, by: \.pageIndex)
        for key in byPage.keys where key < 0 || key >= source.pageCount {
            throw PDFOperationError.pageOutOfBounds(key + 1)
        }

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.fillSignFailed
        }

        for i in 0..<source.pageCount {
            let dp = try displayedPage(source.page(at: i), inputURL: inputURL)
            emitDisplayedPage(dp, into: ctx) { ctx, dp in
                // Placed items draw on top of the annotations, each in the space that renders it
                // the way the editor previewed it. Signatures are polylines: every point maps
                // through the page transform, so rotation is handled exactly. Typed text is laid
                // out by NSStringDrawing along the current CTM's axes — under the rotated page
                // transform it baked sideways (and wrapped to the unswapped width) on /Rotate
                // pages while the editor showed it upright, so text draws in display space with
                // the display-mapped rect. Patches go first, so a correction's words land on its
                // patch whichever order the items came in.
                let onPage = byPage[i] ?? []
                for item in onPage.filter(\.isPatch) + onPage.filter({ !$0.isPatch }) {
                    switch item.content {
                    case .text(let text):
                        drawFillText(text, in: displayRect(item.rect, cropBox: dp.cropBox, rotation: dp.rotation), ctx: ctx)
                    case .signature(let signature):
                        ctx.saveGState()
                        ctx.concatenate(dp.transform)
                        drawFillSignature(signature, in: item.rect, ctx: ctx)
                        ctx.restoreGState()
                    case .patch(let patch):
                        // A plain fill, in page space under the page transform as a signature is:
                        // a rectangle maps exactly under every rotation.
                        ctx.saveGState()
                        ctx.concatenate(dp.transform)
                        // sRGB, as text's ink is: a colour sampled off the page comes back as it was.
                        ctx.setFillColor(CGColor(srgbRed: patch.red, green: patch.green, blue: patch.blue, alpha: 1))
                        ctx.fill(item.rect)
                        ctx.restoreGState()
                    }
                }
            }
        }
        ctx.closePDF()

        guard pdfData.length > 0 else { throw PDFOperationError.fillSignFailed }
        return restoringCatalog(pdfData as Data, from: source, restoreLinks: true)
    }

    /// Maps a PDF-user-space rect into displayed-page coordinates (origin at the displayed crop
    /// box's corner, /Rotate applied, width/height swapped for 90°/270°) — the space the on-screen
    /// editor and `PDFAnnotation.draw` work in. Internal so geometry tests can pin the mapping.
    /// ``displayRect(_:cropBox:rotation:)`` for a bare point (a bookmark or GoTo destination). A
    /// zero-size rect maps corner-to-corner under every rotation, so the mapping stays in one place.
    static func displayPoint(_ point: CGPoint, cropBox: CGRect, rotation: Int) -> CGPoint {
        displayRect(CGRect(origin: point, size: .zero), cropBox: cropBox, rotation: rotation).origin
    }

    static func displayRect(_ rect: CGRect, cropBox: CGRect, rotation: Int) -> CGRect {
        let r = normalizedRotation(rotation)
        switch r {
        case 90:
            return CGRect(
                x: rect.minY - cropBox.minY,
                y: cropBox.maxX - rect.maxX,
                width: rect.height, height: rect.width
            )
        case 180:
            return CGRect(
                x: cropBox.maxX - rect.maxX,
                y: cropBox.maxY - rect.maxY,
                width: rect.width, height: rect.height
            )
        case 270:
            return CGRect(
                x: cropBox.maxY - rect.maxY,
                y: rect.minX - cropBox.minX,
                width: rect.height, height: rect.width
            )
        default:
            return CGRect(
                x: rect.minX - cropBox.minX,
                y: rect.minY - cropBox.minY,
                width: rect.width, height: rect.height
            )
        }
    }

    private static func drawFillText(_ text: FillSignText, in rect: CGRect, ctx: CGContext) {
        let trimmed = text.string
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        let color = NSColor(srgbRed: text.red, green: text.green, blue: text.blue, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(size: max(4, text.fontSize), script: text.isScript, font: text.font),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        // `flipped: false` matches the placement overlay: the first line sits at the top of the box.
        NSAttributedString(string: trimmed, attributes: attributes).draw(in: rect)

        NSGraphicsContext.restoreGraphicsState()
    }

    /// A handwriting face for typed signatures, falling back down a chain and finally to an italic
    /// system font so a machine missing the script fonts still renders something signature-like.
    public static func scriptOrSystemFont(size: CGFloat, script: Bool) -> NSFont {
        font(size: size, script: script, font: nil)
    }

    /// **The face a ``FillSignText`` draws in**: `font` when this Mac has it, else
    /// ``scriptOrSystemFont(size:script:)``'s.
    public static func font(size: CGFloat, script: Bool, font: FillSignFont?) -> NSFont {
        switch font {
        case .named(let name)?:
            if let found = NSFont(name: name, size: size) { return found }
        case .systemRounded?:
            if let rounded = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded) {
                return NSFont(descriptor: rounded, size: size) ?? NSFont.systemFont(ofSize: size)
            }
        case .systemMonospaced?:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case nil:
            break
        }
        guard script else { return NSFont.systemFont(ofSize: size) }
        for name in ["SnellRoundhand", "SavoyeLetPlain", "Zapfino", "BradleyHandITCTT-Bold"] {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }

    private static func drawFillSignature(_ signature: FillSignSignature, in rect: CGRect, ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let strokes = signature.strokes.filter { !$0.isEmpty }
        guard !strokes.isEmpty else { return }

        ctx.saveGState()
        ctx.setStrokeColor(red: signature.red, green: signature.green, blue: signature.blue, alpha: 1)
        ctx.setFillColor(red: signature.red, green: signature.green, blue: signature.blue, alpha: 1)
        let lineWidth = max(0.4, signature.penWidthFraction * min(rect.width, rect.height))
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for stroke in strokes {
            let points = stroke.map { FillSignGeometry.pagePoint(normalized: $0, in: rect) }
            if points.count == 1 {
                // A single tap (a dot on an "i", a period) has no length to stroke — fill a nib blob.
                let p = points[0]
                let r = lineWidth / 2
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: lineWidth, height: lineWidth))
                continue
            }
            ctx.beginPath()
            ctx.addLines(between: points)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    /// Permanently removes visual content inside the given rectangles by rasterizing affected pages and painting solid black over those regions—
    /// underlying text and vectors in those areas cannot be copied out afterward (same model as professional “burn-in” redaction). Unmarked pages are copied as PDF unless `options.stripAnnotationsFromUnredactedPages` is true.
    static func redact(
        inputURL: URL,
        outputURL: URL,
        marks: [RedactionMark],
        options: PDFRedactionExportOptions = .default
    ) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try redactData(inputURL: inputURL, marks: marks, options: options), to: outputURL)
    }

    /// In-memory core of ``redact(inputURL:outputURL:marks:options:)``.
    public static func redactData(
        inputURL: URL,
        marks: [RedactionMark],
        options: PDFRedactionExportOptions = .default
    ) throws -> Data {
        // Marks are the usual reason to run, but not the only one: a page named in
        // `forceRasterizePages` is being exported precisely BECAUSE its text has to go and no box
        // could be placed over it. Refusing that combination made the one case the option exists for
        // — every match unlocatable, nothing else marked — impossible to export.
        guard !marks.isEmpty || !options.forceRasterizePages.isEmpty else {
            throw PDFOperationError.noRedactions
        }
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let grouped = Dictionary(grouping: marks, by: \.pageIndex)
        for key in grouped.keys {
            guard key >= 0, key < source.pageCount else {
                throw PDFOperationError.pageOutOfBounds(key + 1)
            }
        }
        // Validated exactly like a mark's page. Silently ignoring a bad index here would be the
        // worst possible failure for this option: the caller asked for a page's text to be destroyed
        // and would be told it was, while the page shipped untouched.
        for index in options.forceRasterizePages {
            guard index >= 0, index < source.pageCount else {
                throw PDFOperationError.pageOutOfBounds(index + 1)
            }
        }

        let output = PDFDocument()
        for pageIndex in 0..<source.pageCount {
            // Per-page pool: redaction renders at up to `maxPixelDimension` (4000 px default,
            // ~150 MB of transient bitmap per US Letter page) — that scratch must drain per page,
            // not accumulate for the whole document. The inserted page survives; output owns it.
            try autoreleasepool {
                // A nil page on an already-opened, valid document should never happen — but returning
                // here would silently emit a redacted file with FEWER pages than the input, breaking
                // the page-preservation invariant every other tool upholds (PageReplay's
                // `displayedPage` throws in exactly this case). Fail loudly instead of dropping a page.
                guard let page = source.page(at: pageIndex) else {
                    throw PDFOperationError.redactionFailed
                }
                let rectsForPage = (grouped[pageIndex] ?? []).map(\.rect)

                // A force-rasterized page has no fills — nothing is painted black, and visually it
                // comes out identical. The point is the side effect the fills usually bring along:
                // the page is re-emitted as an image, so the text a mark could not be placed over
                // stops being extractable.
                if rectsForPage.isEmpty && !options.forceRasterizePages.contains(pageIndex) {
                    try Self.insertUnredactedPage(
                        into: output,
                        from: page,
                        stripAnnotations: options.stripAnnotationsFromUnredactedPages
                    )
                } else {
                    guard
                        let cgPage = page.pageRef,
                        let geometry = rasterGeometry(
                            for: page,
                            maxPixelDimension: options.maxPixelDimension,
                            allowUpscale: true
                        )
                    else {
                        throw PDFOperationError.redactionFailed
                    }
                    // A marked page is rasterized even when every fill clips away against the crop box
                    // (a mark dragged wholly into a cropped-out margin): rasterization destroys the
                    // out-of-crop content the mark covered, which is the safe direction — the old
                    // "empty fills → fail the whole export" behavior aborted with no hint which mark
                    // was the problem, and copying the page as vector would keep recoverable content.
                    let fills = mergeOverlappingRedactions(rectsForPage, pageBox: geometry.pageBox)
                    guard
                        let cgImage = renderBitmap(page, cgPage: cgPage, geometry: geometry, redactionFills: fills),
                        let pdfData = Self.singlePagePDFData(cgImage: cgImage, pageSize: geometry.displaySize),
                        let tempDoc = PDFDocument(data: pdfData),
                        let newPage = tempDoc.page(at: 0)
                    else {
                        throw PDFOperationError.redactionFailed
                    }
                    // Move the page into `output` so we never rely on `PDFPage.copy()` for image-heavy pages
                    // (copy has dropped resolution / MediaBox issues). `insert` removes the page from `tempDoc`.
                    newPage.rotation = 0
                    output.insert(newPage, at: output.pageCount)
                }
            }
        }

        guard output.pageCount > 0 else { throw PDFOperationError.redactionFailed }
        // The untouched pages are copies, and their internal links need re-pointing like any other
        // copy's (see ``remapInternalLinks(from:to:copiedPages:sourceToOutput:mappingPoint:)``). A
        // link INTO a rasterized page must follow that page into display space, as bookmarks do.
        let rasterized = Set(grouped.keys).union(options.forceRasterizePages)
        remapInternalLinks(
            from: source,
            to: output,
            copiedPages: (0..<source.pageCount).filter { !rasterized.contains($0) }.map { ($0, $0) },
            sourceToOutput: Dictionary(uniqueKeysWithValues: (0..<source.pageCount).map { ($0, $0) })
        ) { pageIndex, point in
            guard rasterized.contains(pageIndex), let page = source.page(at: pageIndex) else { return point }
            return displayPoint(point, cropBox: page.bounds(for: .cropBox), rotation: normalizedRotation(page.rotation))
        }
        // Do not pass `saveTextFromOCROption`: PDFKit’s OCR-on-save pass re-encodes image-based pages and
        // reliably produced thumbnail-sized redacted pages in testing (even with screen-optimize off).
        guard let data = output.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        // Bookmarks and the info dictionary are restored; the rasterized pages' links deliberately
        // are NOT — see
        // ``restoringCatalog(_:from:restoreLinks:)``. A link's URL can disclose the very value the
        // user painted over, and a live hotspot over a burned-in black box is recoverable content.
        //
        // Only the RASTERIZED pages were emitted in display space; the rest are untouched copies
        // that keep the source's box and `/Rotate`. Passing that set keeps each bookmark's
        // destination in the space its own page actually uses — a blanket mapping moved bookmarks
        // into unmarked, rotated or offset pages to the wrong spot. The set is the same test the
        // page loop above makes: marked OR force-rasterized. Deriving it from the marks alone
        // missed the force-rasterized pages, which carry no marks yet are rasterized all the same.
        //
        // Attached files go too when anything is marked: a file can hold what was painted over.
        return restoringCatalog(
            data,
            from: source,
            restoreLinks: false,
            displayMappedPages: rasterized,
            carriesAttachments: marks.isEmpty
        )
    }

    /// One-page PDF with explicit Core Graphics MediaBox and bitmap drawn into the full page rect.
    /// The page is emitted at origin zero with the given (displayed) size, so odd source origins and
    /// intrinsic rotation never confuse viewers.
    private static func singlePagePDFData(cgImage: CGImage, pageSize: CGSize) -> Data? {
        let pageRect = CGRect(x: 0, y: 0, width: abs(pageSize.width), height: abs(pageSize.height))
        guard pageRect.width > 0.5, pageRect.height > 0.5 else { return nil }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = pageRect
        guard let pdfContext = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        pdfContext.beginPDFPage(nil)
        pdfContext.interpolationQuality = .high
        pdfContext.draw(cgImage, in: pageRect)
        pdfContext.endPDFPage()
        pdfContext.closePDF()

        return data as Data
    }

    /// How a page maps onto a raster: the crop box drawn (what viewers actually display), its
    /// rotation-aware displayed size in points, and the exact pixels-per-point scale.
    // Internal (not private): the shared raster helpers that return/consume it are used by the
    // Compress core in a sibling file, which reads `displaySize` off the geometry.
    struct PageRasterGeometry {
        let pageBox: CGRect
        let displaySize: CGSize
        let scale: CGFloat
        var pixelWidth: Int { max(1, Int(ceil(displaySize.width * scale))) }
        var pixelHeight: Int { max(1, Int(ceil(displaySize.height * scale))) }
    }

    // Internal (not private): the raster pipeline is shared by redaction and the Compress core in a
    // sibling file (PDFToolkit+Compress.swift), which rebuilds pages through the same rasterizer.
    static func rasterGeometry(
        for page: PDFPage,
        maxPixelDimension: CGFloat,
        allowUpscale: Bool
    ) -> PageRasterGeometry? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0, page.pageRef != nil else { return nil }
        let displaySize = displayedSize(of: box, rotation: page.rotation)
        let longest = max(displaySize.width, displaySize.height)
        let raw = maxPixelDimension / max(longest, 1)
        // Redaction supersamples past 1 PDF point per pixel (otherwise pages look ~72 dpi and text
        // is fuzzy); compression only ever downsamples.
        let scale = allowUpscale ? min(max(raw, 0.5), 12) : min(1, raw)
        return PageRasterGeometry(pageBox: box, displaySize: displaySize, scale: scale)
    }

    /// Draws the page — content stream, then visible annotation appearances, then any redaction
    /// fills — upright into a fresh bitmap of `geometry`'s pixel size.
    ///
    /// The supersample scale is applied to the context *before* the page transform, and the
    /// transform maps into a 1x, display-sized rect. Both halves matter: `getDrawingTransform`
    /// refuses to scale a page up, so asking it to map straight into a supersampled pixel rect
    /// silently drew the page 1:1 and centered — a redacted US Letter page came out at ~1/5 size in
    /// a field of white. And the rect must use the rotation-swapped *displayed* size, or a
    /// /Rotate 90 page gets letterboxed into its unrotated aspect. Redaction rects arrive in PDF
    /// user space and are filled under the same transform, so they track the content exactly.
    // Internal (not private): shared with the Compress core in PDFToolkit+Compress.swift (same raster path).
    static func renderBitmap(
        _ page: PDFPage,
        cgPage: CGPDFPage,
        geometry: PageRasterGeometry,
        redactionFills: [CGRect]
    ) -> CGImage? {
        let pixelW = geometry.pixelWidth
        let pixelH = geometry.pixelHeight
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH)))

        ctx.saveGState()
        ctx.scaleBy(x: geometry.scale, y: geometry.scale)
        let displayRect = CGRect(origin: .zero, size: geometry.displaySize)
        let transform = cgPage.getDrawingTransform(.cropBox, rect: displayRect, rotate: 0, preserveAspectRatio: true)

        ctx.saveGState()
        ctx.concatenate(transform)
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()

        // Scale-only state: `PDFAnnotation.draw(with:in:)` maps into *displayed-page* coordinates
        // itself — it applies the page's rotation and subtracts the crop origin — so it must not
        // run under the page transform above. Composing both shifted annotations by the crop
        // origin on cropped pages and rotated them twice on rotated pages.
        drawAnnotations(of: page, in: ctx)

        // Redaction rects are in PDF user space, so the fills do need the page transform. Painting
        // after the annotations keeps a marked annotation buried under black.
        ctx.concatenate(transform)
        ctx.setBlendMode(.normal)
        ctx.setFillColor(gray: 0, alpha: 1)
        for r in redactionFills {
            ctx.fill(r)
        }
        ctx.restoreGState()

        return ctx.makeImage()
    }

    /// Annotation appearances (typed form values, ink signatures, notes, highlights, stamps) live in
    /// `/Annots`, outside the content stream `drawPDFPage` replays — a rebuilt page silently loses
    /// them unless they are drawn here. The context must be in *displayed-page* space (origin at the
    /// displayed crop box's corner, rotation already upright): PDFKit's draw performs the page's
    /// display mapping internally.
    // Internal (not private): the OCR extension re-draws pages the same way watermark does.
    //
    // A file attachment's icon is not drawn: the annotation itself, file and all, is put back on
    // the rebuilt page (``carryingCatalogParts(_:from:outputToSource:displayMappedPages:attachments:)``).
    static func drawAnnotations(of page: PDFPage, in ctx: CGContext) {
        let visible = page.annotations.filter { $0.shouldDisplay && $0.type != "FileAttachment" }
        guard !visible.isEmpty else { return }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for annotation in visible {
            annotation.draw(with: .cropBox, in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Keep redaction passes from leaving thin gaps between adjacent user rectangles.
    private static func mergeOverlappingRedactions(_ rects: [CGRect], pageBox: CGRect) -> [CGRect] {
        var list: [CGRect] = rects.compactMap { RedactionMarkGeometry.clip($0, to: pageBox) }
        guard !list.isEmpty else { return [] }

        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<list.count {
                for j in (i + 1)..<list.count {
                    if list[i].intersects(list[j]) || list[i].insetBy(dx: -1, dy: -1).intersects(list[j]) {
                        list[i] = list[i].union(list[j])
                        list.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return list
    }

    private static func insertUnredactedPage(
        into output: PDFDocument,
        from page: PDFPage,
        stripAnnotations: Bool
    ) throws {
        guard let copy = page.copy() as? PDFPage else {
            throw PDFOperationError.redactionFailed
        }
        if stripAnnotations {
            let stale = copy.annotations
            for ann in stale {
                copy.removeAnnotation(ann)
            }
        }
        output.insert(copy, at: output.pageCount)
    }

    /// Renders the page — content plus visible annotations — upright at its displayed size via the
    /// shared raster pipeline (rotation-swapped crop box, exact scale). Compression never upscales.
    /// Internal for the OCR extension: the page as displayed (rotation and crop applied), upscaled
    /// when the page is small so Vision has pixels to read. Compression's raster path deliberately
    /// never upscales; recognition wants the opposite.
    static func renderPageBitmap(_ page: PDFPage, maxPixelDimension: CGFloat) -> CGImage? {
        guard
            let cgPage = page.pageRef,
            let geometry = rasterGeometry(for: page, maxPixelDimension: maxPixelDimension, allowUpscale: true)
        else { return nil }
        return renderBitmap(page, cgPage: cgPage, geometry: geometry, redactionFills: [])
    }
}
