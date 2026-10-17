import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

// End-to-end runs of the real tools over the committed corpus (see ``RealCorpus``).
//
// These are not a second copy of the unit suite. Each one asserts something that
// only a real file can put at risk: a form the app didn't write, a producer whose
// bytes Apple's parser has to work at, an encryption dictionary with real
// permission bits, a page whose crop box does not start at the origin. Where a
// synthetic fixture already pins the mechanism, the corpus test pins the
// *outcome* — that the mechanism still holds on input from the wild.

/// Fails loudly and once if a corpus file was regenerated into a different shape,
/// truncated in transit, or dropped from the bundle — rather than letting every
/// downstream suite fail in a confusing scatter.
struct RealCorpusIntegrityTests {
    @Test(arguments: RealCorpus.allCases)
    func fileHasTheTraitsTheSuiteReliesOn(_ file: RealCorpus) throws {
        let expected = file.traits
        let doc = try #require(PDFDocument(url: file.url), "\(file.rawValue) did not open")

        #expect(doc.isLocked == expected.isLocked)
        #expect(doc.isEncrypted == expected.isEncrypted)
        #expect(PDFToolkit.hasInteractiveForm(at: file.url) == expected.hasForm)
        #expect(PDFToolkit.bookmarkCount(at: file.url) == expected.bookmarkCount)

        if doc.isLocked { #expect(doc.unlock(withPassword: RealCorpus.userPassword)) }
        #expect(doc.pageCount == expected.pageCount)
        #expect(doc.allowsDocumentAssembly == expected.allowsAssembly)

        let firstPageText = doc.page(at: 0)?.string ?? ""
        if let token = expected.firstPageToken {
            #expect(firstPageText.contains(token))
        } else {
            // The scan must stay text-free, or the OCR test silently stops testing OCR.
            #expect(firstPageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The corpus is committed to git; a runaway fixture would bloat every clone.
    @Test func corpusStaysSmall() throws {
        let total = try RealCorpus.allCases.reduce(0) { $0 + (try $1.data.count) }
        #expect(total < 512 * 1024, "corpus grew to \(total / 1024) KB")
    }
}

// MARK: - The fidelity warnings, on files that genuinely carry what's at risk

/// ``OutputFidelityWarning`` exists to disclose three unavoidable losses. Its unit
/// tests drive the detector with hand-built inputs; these run it against real files
/// and, crucially, also assert that the losses it predicts are the losses that
/// actually happen when the tool runs.
struct RealCorpusFidelityWarningTests {
    @Test func aRealFormRaisesTheFlattenWarningForRebuildTools() throws {
        let warning = try #require(OutputFidelityWarning.detect(
            in: [RealCorpus.acroFormXrefStream.url], formLoss: .formFlattened, checksBookmarks: false
        ))
        #expect(warning.losses == [.formFlattened])
        #expect(warning.headline == "This PDF has fillable form fields")
        #expect(warning.confirmButtonTitle == "Flatten and continue")
    }

    @Test func aRealFormRaisesTheOrphanWarningForCopyTools() throws {
        let warning = try #require(OutputFidelityWarning.detect(
            in: [RealCorpus.acroFormXrefStream.url], formLoss: .formOrphaned, checksBookmarks: false
        ))
        #expect(warning.losses == [.formOrphaned])
        #expect(warning.confirmationTitle == "Form fields will stop working")
    }

    @Test func aNestedOutlineIsCountedThroughTheWholeTree() throws {
        let warning = try #require(OutputFidelityWarning.detect(
            in: [RealCorpus.outlineNested.url], formLoss: nil, checksBookmarks: true
        ))
        // 3 top-level entries, one with 3 children: a count of 3 would mean only
        // the top level was walked.
        #expect(warning.losses == [.bookmarks(total: 6, fileCount: 1)])
    }

    /// Merge warns about both at once when the selection mixes a form and an outline.
    @Test func mergingAFormWithAnOutlineWarnsAboutBoth() throws {
        let warning = try #require(OutputFidelityWarning.detect(
            in: [RealCorpus.acroFormXrefStream.url, RealCorpus.outlineNested.url,
                 RealCorpus.chromeArticle.url],
            formLoss: .formOrphaned,
            checksBookmarks: true
        ))
        #expect(warning.losses == [.formOrphaned, .bookmarks(total: 6, fileCount: 1)])
        #expect(warning.headline == "Some things won’t carry over")
        #expect(warning.keptLine.contains("Page content"))
    }

    /// The warning must stay off for an ordinary document, or it becomes wallpaper.
    /// A browser-printed article is the most ordinary input the corpus has.
    @Test func anOrdinaryFileRaisesNoWarningAtAll() {
        for loss in [OutputFidelityWarning.Loss.formFlattened, .formOrphaned] {
            #expect(OutputFidelityWarning.detect(
                in: [RealCorpus.chromeArticle.url], formLoss: loss, checksBookmarks: true
            ) == nil)
        }
    }

    /// A locked file can't be inspected, and the warning must not guess. Silence
    /// here is correct: the tool refuses the file long before any save.
    @Test func aLockedFileRaisesNoWarning() {
        #expect(OutputFidelityWarning.detect(
            in: [RealCorpus.encryptedUser.url], formLoss: .formFlattened, checksBookmarks: true
        ) == nil)
    }
}

/// The three fates a real `/AcroForm` can meet, asserted on the file the warnings
/// were raised for. This is the half the detector can't check: that the disclosure
/// tells the truth about what the tool then does.
struct RealCorpusFormFateTests {
    private func hasCatalogForm(_ data: Data, in dir: FixtureDir, named name: String) throws -> Bool {
        let url = dir.url(name)
        try data.write(to: url)
        return PDFToolkit.hasInteractiveForm(at: url)
    }

    private func widgetCount(_ data: Data) throws -> Int {
        let doc = try #require(PDFDocument(data: data))
        return (0..<doc.pageCount).reduce(0) { total, i in
            total + (doc.page(at: i)?.annotations.filter { $0.type == "Widget" }.count ?? 0)
        }
    }

    /// KEPT: the in-place mutators leave the form entirely intact, so no warning is
    /// shown for them — and that silence has to be earned.
    @Test func deleteAndRotateKeepTheFormIntact() throws {
        let dir = FixtureDir()
        let source = RealCorpus.acroFormXrefStream.url

        let rotated = try PDFToolkit.rotateData(inputURL: source, pageIndices: [0], quarterTurns: 1)
        #expect(try hasCatalogForm(rotated, in: dir, named: "rotated.pdf"))
        #expect(try widgetCount(rotated) == 2)

        let deleted = try PDFToolkit.deletePagesData(inputURL: source, pageIndices: [1])
        #expect(try hasCatalogForm(deleted, in: dir, named: "deleted.pdf"))
        #expect(try widgetCount(deleted) == 2)
    }

    /// ORPHANED: the widgets ride along on the copied pages — still visible, still
    /// holding their values — but the catalog `/AcroForm` that binds them is gone.
    /// Both halves matter: losing the widgets too would be a different (worse) bug
    /// than the one disclosed.
    @Test func copyRebuildsOrphanTheFormWithoutLosingTheWidgets() throws {
        let dir = FixtureDir()
        let source = RealCorpus.acroFormXrefStream.url

        let extracted = try PDFToolkit.extractData(inputURL: source, pageIndices: [0])
        #expect(try hasCatalogForm(extracted, in: dir, named: "extracted.pdf") == false)
        #expect(try widgetCount(extracted) == 2)

        let reordered = try PDFToolkit.reorderData(inputURL: source, order: [1, 0])
        #expect(try hasCatalogForm(reordered, in: dir, named: "reordered.pdf") == false)
        #expect(try widgetCount(reordered) == 2)

        let merged = try PDFToolkit.mergeData(inputURLs: [source, RealCorpus.chromeArticle.url])
        #expect(try hasCatalogForm(merged, in: dir, named: "merged.pdf") == false)
        #expect(try widgetCount(merged) == 2)
    }

    /// FLATTENED: the page-replay tools lose the catalog form AND the widgets, but
    /// the field's *appearance* must survive as page content — that is the whole
    /// claim the "looks identical, can no longer be filled in" wording makes.
    @Test func pageReplayToolsFlattenTheFormButKeepItsAppearance() throws {
        let dir = FixtureDir()
        let source = RealCorpus.acroFormXrefStream.url

        let watermarked = try PDFToolkit.watermarkData(
            inputURL: source,
            options: WatermarkOptions(
                text: "DRAFT", fontSize: 48, opacity: 0.2, rotationDegrees: 45,
                red: 1, green: 0, blue: 0, tiled: false
            )
        )
        #expect(try hasCatalogForm(watermarked, in: dir, named: "watermarked.pdf") == false)
        #expect(try widgetCount(watermarked) == 0)

        // The typed value came from the widget's appearance stream. If flattening
        // dropped it, the saved copy would NOT look identical — it would be blank
        // where the user's answer was.
        let doc = try #require(PDFDocument(data: watermarked))
        #expect(doc.page(at: 0)?.string?.contains("Dana Reyes") == true)
        #expect(doc.page(at: 0)?.string?.contains("CORPUSTOKEN-FORM") == true)
    }
}

// MARK: - Outline, links and titles through the rebuild operations

/// Bookmarks live on the catalog, so every rebuild-by-copy had to be taught to
/// carry them and re-point them. A flat one-per-page outline can't tell "kept the
/// tree" from "kept a list", which is why the corpus outline is nested.
struct RealCorpusOutlineTests {
    /// Every outline entry as `(label, resolved page index)`, walked depth-first
    /// through the whole tree. An entry whose destination no longer resolves
    /// reports -1 rather than being silently skipped.
    private func outline(of doc: PDFDocument) -> [(String, Int)] {
        var found: [(String, Int)] = []
        func walk(_ node: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let page = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
                found.append((child.label ?? "", page.map { doc.index(for: $0) } ?? -1))
                walk(child)
            }
        }
        doc.outlineRoot.map(walk)
        return found
    }

    @Test func deletingAPageKeepsTheTreeAndRepointsWhatFollows() throws {
        // Drop "Power" (page 3). Its own bookmark must go; "Uplink" and "Index"
        // must slide down a page and keep pointing at their own content.
        let data = try PDFToolkit.deletePagesData(inputURL: RealCorpus.outlineNested.url, pageIndices: [3])
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 5)

        let entries = outline(of: doc)
        #expect(entries.map(\.0) == ["Front Matter", "Contents", "Siting", "Uplink", "Index"])
        #expect(entries.allSatisfy { $0.1 >= 0 }, "a bookmark stopped resolving: \(entries)")

        // The real check: each surviving bookmark still lands on ITS OWN text.
        for (label, index) in entries where ["Siting", "Uplink", "Index"].contains(label) {
            #expect(doc.page(at: index)?.string?.contains(label) == true,
                    "\(label) points at page \(index), which doesn't contain it")
        }
    }

    @Test func extractingASubsetKeepsOnlyTheBookmarksItStillHas() throws {
        // Pages 3 and 5 (Siting, Uplink), in that order.
        let data = try PDFToolkit.extractData(inputURL: RealCorpus.outlineNested.url, pageIndices: [2, 4])
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 2)

        let entries = outline(of: doc)
        #expect(entries.map(\.0) == ["Siting", "Uplink"])
        for (label, index) in entries {
            #expect(doc.page(at: index)?.string?.contains(label) == true)
        }
    }

    @Test func reorderingFollowsBookmarksToTheirNewPositions() throws {
        // Reverse the document outright — the case where every bookmark moves.
        let data = try PDFToolkit.reorderData(inputURL: RealCorpus.outlineNested.url, order: [5, 4, 3, 2, 1, 0])
        let doc = try #require(PDFDocument(data: data))
        for (label, index) in outline(of: doc) {
            #expect(index >= 0, "\(label) stopped resolving after reorder")
            #expect(doc.page(at: index)?.string?.contains(label) == true,
                    "\(label) followed to page \(index), which doesn't contain it")
        }
    }

    /// The document title lives on the catalog too, and rebuilds used to drop it.
    @Test func theDocumentTitleSurvivesEveryRebuild() throws {
        let title = "Northbridge Field Handbook"
        let source = RealCorpus.outlineNested.url
        let outputs: [(String, Data)] = [
            ("extract", try PDFToolkit.extractData(inputURL: source, pageIndices: [0, 1])),
            ("reorder", try PDFToolkit.reorderData(inputURL: source, order: [1, 0, 2, 3, 4, 5])),
            ("delete", try PDFToolkit.deletePagesData(inputURL: source, pageIndices: [5])),
            ("crop", try PDFToolkit.cropData(inputURL: source, insets: CropInsets(top: 10, left: 10, bottom: 10, right: 10))),
        ]
        for (name, data) in outputs {
            let doc = try #require(PDFDocument(data: data))
            #expect(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == title,
                    "\(name) dropped the document title")
        }
    }

    /// Link annotations are the third catalog-adjacent thing rebuilds used to lose.
    @Test func linkAnnotationsSurviveARebuild() throws {
        let data = try PDFToolkit.cropData(
            inputURL: RealCorpus.outlineNested.url,
            insets: CropInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
        let doc = try #require(PDFDocument(data: data))
        let links = doc.page(at: 0)?.annotations.filter { $0.type == "Link" } ?? []
        #expect(links.count == 1)
        #expect(links.first?.action is PDFActionGoTo)
    }

    /// Chrome writes real external links; they must survive too, URL intact.
    @Test func externalLinksFromARealProducerSurvive() throws {
        let data = try PDFToolkit.extractData(inputURL: RealCorpus.chromeArticle.url, pageIndices: [0])
        let doc = try #require(PDFDocument(data: data))
        let urls = (doc.page(at: 0)?.annotations ?? [])
            .compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString }
        #expect(urls.contains { $0.contains("example.org") },
                "external link lost; found \(urls)")
    }
}

// MARK: - Geometry, on pages that are rotated and cropped off the origin

/// Crop insets are given in DISPLAYED orientation and must be mapped through each
/// page's intrinsic rotation onto the stored box — and applied relative to a crop
/// origin that isn't zero. Both halves are easy to get subtly wrong and impossible
/// to catch on an upright, origin-zero fixture.
struct RealCorpusGeometryTests {
    @Test func croppingTrimsTheDisplayedEdgesOfEveryRotation() throws {
        let source = RealCorpus.rotatedCropped.url
        let before = try #require(PDFDocument(url: source))
        let insets = CropInsets(top: 30, left: 10, bottom: 20, right: 5)

        let doc = try #require(PDFDocument(data: try PDFToolkit.cropData(inputURL: source, insets: insets)))
        #expect(doc.pageCount == 4)

        for i in 0..<doc.pageCount {
            let old = try #require(before.page(at: i)).bounds(for: .cropBox)
            let new = try #require(doc.page(at: i)).bounds(for: .cropBox)
            let rotation = try #require(doc.page(at: i)).rotation

            // Whatever the rotation, the DISPLAYED box shrinks by the displayed
            // insets: total horizontal loss = left+right, vertical = top+bottom.
            let displayedOld = PDFToolkit.displayedSize(of: old, rotation: rotation)
            let displayedNew = PDFToolkit.displayedSize(of: new, rotation: rotation)
            #expect(abs(displayedOld.width - displayedNew.width - 15) < 0.01,
                    "page \(i) rot \(rotation): width \(displayedOld.width) -> \(displayedNew.width)")
            #expect(abs(displayedOld.height - displayedNew.height - 50) < 0.01,
                    "page \(i) rot \(rotation): height \(displayedOld.height) -> \(displayedNew.height)")

            // And the result stays inside the original box — a crop that wandered
            // outside it would expose content the source deliberately hid.
            #expect(old.insetBy(dx: -0.01, dy: -0.01).contains(new),
                    "page \(i): cropped box \(new) escaped the original \(old)")
        }
    }

    /// Rotation is recorded, not baked, and must not disturb the boxes.
    @Test func rotatingLeavesEveryBoxWhereItWas() throws {
        let source = RealCorpus.rotatedCropped.url
        let before = try #require(PDFDocument(url: source))
        let doc = try #require(PDFDocument(data: try PDFToolkit.rotateData(
            inputURL: source, pageIndices: Array(0..<4), quarterTurns: 1
        )))
        for i in 0..<4 {
            let old = try #require(before.page(at: i))
            let new = try #require(doc.page(at: i))
            #expect(new.rotation == PDFToolkit.normalizedRotation(old.rotation + 90))
            #expect(new.bounds(for: .cropBox) == old.bounds(for: .cropBox))
            #expect(new.bounds(for: .mediaBox) == old.bounds(for: .mediaBox))
        }
    }

    /// Watermarking replays each page upright, so the OUTPUT page box is the
    /// displayed size of the input — and the mark must land on every page,
    /// whatever that page's size and rotation were.
    @Test func watermarkingHandlesMixedSizesAndRotations() throws {
        let source = RealCorpus.rotatedCropped.url
        let before = try #require(PDFDocument(url: source))
        let data = try PDFToolkit.watermarkData(
            inputURL: source,
            options: WatermarkOptions(
                text: "CONFIDENTIAL", fontSize: 36, opacity: 0.35, rotationDegrees: 45,
                red: 0.8, green: 0, blue: 0, tiled: false
            )
        )
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 4)

        for i in 0..<4 {
            let old = try #require(before.page(at: i))
            let expected = PDFToolkit.displayedSize(of: old.bounds(for: .cropBox), rotation: old.rotation)
            let actual = try #require(doc.page(at: i)).bounds(for: .mediaBox).size
            #expect(abs(actual.width - expected.width) < 0.5 && abs(actual.height - expected.height) < 0.5,
                    "page \(i): got \(actual), expected displayed \(expected)")
            // The page's own content must still be there under the mark.
            #expect(doc.page(at: i)?.string?.contains("CORPUSTOKEN-GEOM page \(i + 1)") == true)
        }
    }

    /// A crop can't be allowed to reduce a page below the usable minimum, however
    /// odd the source geometry. The narrowest corpus page is 340pt wide displayed.
    @Test func anOverlargeCropIsRefusedRatherThanProducingASliver() {
        #expect(throws: PDFOperationError.self) {
            try PDFToolkit.cropData(
                inputURL: RealCorpus.rotatedCropped.url,
                insets: CropInsets(top: 200, left: 170, bottom: 200, right: 170)
            )
        }
    }
}

// MARK: - Encryption, with permission bits the app didn't write

struct RealCorpusEncryptionTests {
    @Test func aLockedFileIsRefusedByEveryOperationRatherThanSilentlyMangled() {
        let locked = RealCorpus.encryptedUser.url
        #expect(throws: PDFOperationError.self) {
            try PDFToolkit.extractData(inputURL: locked, pageIndices: [0])
        }
        #expect(throws: PDFOperationError.self) {
            try PDFToolkit.rotateData(inputURL: locked, pageIndices: [0], quarterTurns: 1)
        }
        #expect(throws: PDFOperationError.self) {
            try PDFToolkit.readMetadata(inputURL: locked)
        }
        #expect(PDFToolkit.encryptionState(of: locked) == .lockedToOpen)
    }

    @Test func removingTheUserPasswordYieldsAReadableDocument() throws {
        let dir = FixtureDir()
        let out = dir.url("unlocked.pdf")
        try PDFToolkit.removePassword(
            inputURL: RealCorpus.encryptedUser.url, outputURL: out, password: RealCorpus.userPassword
        )
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.isLocked == false)
        #expect(doc.isEncrypted == false)
        #expect(doc.pageCount == 3)
        #expect(doc.page(at: 0)?.string?.contains("CORPUSTOKEN-SECURE page 1") == true)
    }

    @Test func theWrongPasswordIsRejected() {
        #expect(throws: PDFOperationError.self) {
            try PDFToolkit.removePasswordData(inputURL: RealCorpus.encryptedUser.url, password: "wrong")
        }
    }

    /// The regression that shipped: a restrictions-only file opens freely, PDFKit
    /// then refuses the mutation in silence, and the tool wrote out an unchanged
    /// file under a `-rotated` / `-deleted` name. It must refuse instead.
    @Test func restrictedPermissionsMakeRotateAndDeleteRefuse() throws {
        let restricted = RealCorpus.ownerRestricted.url
        #expect(PDFToolkit.encryptionState(of: restricted) == .restrictedOnly)

        for kind in ["rotate", "delete"] {
            let error = #expect(throws: PDFOperationError.self) {
                kind == "rotate"
                    ? try PDFToolkit.rotateData(inputURL: restricted, pageIndices: [0], quarterTurns: 1)
                    : try PDFToolkit.deletePagesData(inputURL: restricted, pageIndices: [1])
            }
            #expect(error?.kind == "permissionsForbidEditing", "\(kind) did not refuse")
        }
    }

    /// The guard must stay surgical: the rebuild-by-copy tools worked correctly on
    /// a restricted input before it existed and must keep working.
    @Test func rebuildToolsStillWorkOnARestrictedFile() throws {
        let restricted = RealCorpus.ownerRestricted.url

        let extracted = try #require(PDFDocument(data: try PDFToolkit.extractData(
            inputURL: restricted, pageIndices: [2, 0]
        )))
        #expect(extracted.pageCount == 2)
        #expect(extracted.page(at: 0)?.string?.contains("CORPUSTOKEN-SECURE page 3") == true)

        let cropped = try #require(PDFDocument(data: try PDFToolkit.cropData(
            inputURL: restricted, insets: CropInsets(top: 20, left: 20, bottom: 20, right: 20)
        )))
        #expect(cropped.pageCount == 3)
    }
}

// MARK: - Compress and OCR, where a real scan is the only honest input

struct RealCorpusCompressTests {
    /// A genuine scan is the case Compress exists for.
    @Test func compressingARealScanActuallyShrinksIt() throws {
        let dir = FixtureDir()
        let out = dir.url("smaller.pdf")
        let source = RealCorpus.scannedReceipt.url
        let before = try RealCorpus.scannedReceipt.data.count

        try PDFToolkit.compress(inputURL: source, outputURL: out, quality: 0.3)
        let after = try Data(contentsOf: out).count

        #expect(after < before, "\(before) -> \(after) bytes: compression gained nothing")
        // Still a valid, complete document — not a shrunken wreck.
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
    }

    /// The save path is bounded by the input's size: rasterizing lean text INFLATES
    /// it, so Compress must pass the original bytes through rather than hand the
    /// user a bigger file — and the text layer must therefore still be there.
    @Test func compressingLeanTextPassesTheOriginalThroughInstead() throws {
        let dir = FixtureDir()
        let out = dir.url("unchanged.pdf")
        let source = RealCorpus.chromeArticle.url

        try PDFToolkit.compress(inputURL: source, outputURL: out, quality: 0.3)
        let after = try Data(contentsOf: out).count
        #expect(after <= (try RealCorpus.chromeArticle.data.count))

        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 3)
        #expect(doc.page(at: 0)?.string?.contains("CORPUSTOKEN-ALPHA") == true,
                "the text layer was rasterized away despite the output being no smaller")
    }
}

struct RealCorpusOCRTests {
    /// The only test in the suite where Vision has to read something that was
    /// genuinely rendered to pixels and re-encoded as JPEG.
    @Test func ocrGivesARealScanASearchableTextLayer() throws {
        let dir = FixtureDir()
        let out = dir.url("ocr.pdf")
        let summary = try PDFToolkit.ocr(
            inputURL: RealCorpus.scannedReceipt.url, outputURL: out, options: OCROptions()
        )
        #expect(summary.recognizedPages == 2)
        #expect(summary.skippedPages == 0)

        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)
        let text = (doc.page(at: 0)?.string ?? "").uppercased()
        // Recognition is a model, not a parser: assert on a distinctive token
        // rather than the exact transcript, so a minor OCR wobble isn't a failure.
        #expect(text.contains("NORTHBRIDGE"), "no recognized text on page 1; got: \(text.prefix(120))")
        #expect(doc.string?.uppercased().contains("88214") == true,
                "page 2 was not recognized")
    }

    /// Pages that already have text are copied through: stacking a second,
    /// slightly-offset text layer under a live one wrecks selection.
    @Test func ocrSkipsPagesThatAlreadyHaveText() throws {
        let dir = FixtureDir()
        let out = dir.url("skipped.pdf")
        let summary = try PDFToolkit.ocr(
            inputURL: RealCorpus.chromeArticle.url, outputURL: out, options: OCROptions()
        )
        #expect(summary.recognizedPages == 0)
        #expect(summary.skippedPages == 3)
        #expect(try #require(PDFDocument(url: out)).page(at: 0)?.string?.contains("CORPUSTOKEN-ALPHA") == true)
    }
}

// MARK: - Find & redact against real glyph runs

/// Selection geometry is the part of redaction that can't be reasoned about — it
/// comes back from PDFKit's text layout over whatever font the producer embedded.
/// Chrome's subset fonts are the only ones in the suite Apple didn't write.
struct RealCorpusRedactTests {
    @Test func findLocatesACardNumberInARealProducersText() throws {
        let result = try PDFToolkit.findRedactionMarks(
            inputURL: RealCorpus.chromeArticle.url, query: .pattern(.card)
        )
        #expect(result.matchCount == 1, "expected the one seeded card number")
        #expect(result.unlocatableMatches == 0, "the match was found but could not be boxed")
        #expect(result.pagesWithoutText.isEmpty)

        let rect = try #require(result.matches.first?.rects.first)
        #expect(rect.width > 0 && rect.height > 0)
        // On page 3, inside the page box — a box at the origin would mean the
        // geometry came back empty and was silently accepted.
        #expect(result.matches.first?.pageIndex == 2)
        #expect(CGRect(x: 0, y: 0, width: 612, height: 792).contains(rect))
    }

    @Test func redactingRemovesTheTextItCovered() throws {
        let dir = FixtureDir()
        let source = RealCorpus.chromeArticle.url
        let found = try PDFToolkit.findRedactionMarks(inputURL: source, query: .pattern(.card))
        let marks = found.matches.flatMap { match in
            match.rects.map { RedactionMark(pageIndex: match.pageIndex, rect: $0, origin: .autoMatch) }
        }
        #expect(!marks.isEmpty)

        let out = dir.url("redacted.pdf")
        try PDFToolkit.redact(inputURL: source, outputURL: out, marks: marks)

        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 3)
        // The redacted page is rasterized, so its whole text layer goes — the card
        // number can no longer be copied out of the file at all.
        #expect(doc.page(at: 2)?.string?.contains("4111") != true)
        #expect(try #require(doc.dataRepresentation()).range(of: Data("4111-1111-1111-1111".utf8)) == nil)
        // Untouched pages keep their vector text: redaction is surgical, not a
        // whole-document rasterize.
        #expect(doc.page(at: 0)?.string?.contains("CORPUSTOKEN-ALPHA") == true)
    }

    /// A scan has no text layer, so a search legitimately finds nothing — and must
    /// SAY so rather than reporting a clean "no matches", which would read as
    /// "there is nothing sensitive here".
    @Test func searchingAScanReportsThePagesItCouldNotRead() throws {
        let result = try PDFToolkit.findRedactionMarks(
            inputURL: RealCorpus.scannedReceipt.url, query: .literal("Northbridge")
        )
        #expect(result.matchCount == 0)
        #expect(result.pagesWithoutText == [0, 1])
    }
}

// MARK: - Metadata, including the XMP packet a plain attribute write leaves behind

struct RealCorpusMetadataTests {
    @Test func readingRecoversARealInfoDictionary() throws {
        let fields = try PDFToolkit.readMetadata(inputURL: RealCorpus.acroFormXrefStream.url)
        #expect(fields.title == "Northbridge Access Request")
        #expect(fields.author == "CORPUS-INFO-AUTHOR")
        #expect(fields.creator == "CORPUS-INFO-CREATOR")
        // Keywords come back as an array from this producer and are normalized to
        // the comma-joined editing form.
        #expect(fields.keywords.contains("acroform"))
    }

    /// The leak that shipped: clearing the Info dictionary left the XMP packet — a
    /// second, independent copy of the author and producer — sitting in the catalog.
    @Test func strippingRemovesTheXMPPacketAndNotJustTheInfoDictionary() throws {
        // A form-free file: a form-bearing one keeps the lighter Info-only clear by
        // design, since the rebuild that sheds XMP would orphan its fields.
        let dir = FixtureDir()
        let source = try RealCorpus.outlineNested.copy(into: dir)
        let out = dir.url("stripped.pdf")
        try PDFToolkit.writeMetadata(inputURL: source, outputURL: out, fields: .cleared)

        #expect(try PDFToolkit.readMetadata(inputURL: out).isCleared)
        #expect(try PDFFixtures.catalogHasEntry("Metadata", at: out) == false)
        let raw = try Data(contentsOf: out)
        #expect(raw.range(of: Data("CORPUS-INFO-AUTHOR".utf8)) == nil)
    }

    /// The documented tradeoff, asserted so it can't change by accident: a form
    /// keeps its XMP, because shedding it would cost the user their form.
    @Test func aFormBearingFileKeepsItsFormAndThereforeItsXMP() throws {
        let dir = FixtureDir()
        let source = try RealCorpus.acroFormXrefStream.copy(into: dir)
        let out = dir.url("form-stripped.pdf")
        try PDFToolkit.writeMetadata(inputURL: source, outputURL: out, fields: .cleared)

        #expect(try PDFToolkit.readMetadata(inputURL: out).isCleared)
        #expect(PDFToolkit.hasInteractiveForm(at: out), "the form was sacrificed to strip metadata")
    }

    /// Export-time stripping is a separate path (the Finder helper and batch runner
    /// use it), and it must reach the XMP too.
    @Test func exportTimeStrippingAlsoReachesTheXMP() throws {
        let cleaned = PDFToolkit.strippingAllMetadata(from: try RealCorpus.outlineNested.data)
        let doc = try #require(PDFDocument(data: cleaned))
        #expect((doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "").isEmpty)
        #expect(cleaned.range(of: Data("CORPUS-INFO-AUTHOR".utf8)) == nil)
        // Bookmarks live on the catalog and must survive the rebuild that sheds XMP.
        #expect(doc.outlineRoot?.numberOfChildren == 3)
    }
}

// MARK: - Merge and split across producers

struct RealCorpusMergeSplitTests {
    /// The realistic merge: files from three different producers, with different
    /// page sizes, rotations and fonts, in one output.
    @Test func mergingAcrossProducersKeepsEveryPageAndItsGeometry() throws {
        let sources = [RealCorpus.chromeArticle, .outlineNested, .rotatedCropped]
        let data = try PDFToolkit.mergeData(inputURLs: sources.map(\.url))
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == sources.reduce(0) { $0 + $1.traits.pageCount })

        // The rotated pages came last and must arrive with their rotation intact.
        #expect(doc.page(at: 9)?.rotation == 0)
        #expect(doc.page(at: 10)?.rotation == 90)
        #expect(doc.page(at: 11)?.rotation == 180)
        #expect(doc.page(at: 12)?.rotation == 270)
        #expect(doc.page(at: 11)?.bounds(for: .mediaBox).size == CGSize(width: 842, height: 595))

        // Text from each source survives the concatenation.
        #expect(doc.page(at: 0)?.string?.contains("CORPUSTOKEN-ALPHA") == true)
        #expect(doc.page(at: 3)?.string?.contains("CORPUSTOKEN-OUTLINE") == true)
        #expect(doc.page(at: 9)?.string?.contains("CORPUSTOKEN-GEOM") == true)
    }

    /// Merge takes its info dictionary from the first file, by documented policy.
    @Test func mergeTakesItsMetadataFromTheFirstFile() throws {
        let data = try PDFToolkit.mergeData(inputURLs: [RealCorpus.outlineNested.url, RealCorpus.chromeArticle.url])
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Northbridge Field Handbook")
    }

    @Test func splittingCutsARealOutlinedDocumentIntoCompleteParts() throws {
        let dir = FixtureDir()
        let outputs = try PDFToolkit.split(
            inputURL: RealCorpus.outlineNested.url,
            into: dir.url,
            baseName: "handbook",
            segments: [[0, 1], [2, 3], [4, 5]]
        )
        #expect(outputs.count == 3)

        for (segment, url) in outputs.enumerated() {
            let doc = try #require(PDFDocument(url: url))
            #expect(doc.pageCount == 2)
            #expect(doc.page(at: 0)?.string?.contains("CORPUSTOKEN-OUTLINE page \(segment * 2 + 1)") == true)
        }
        // Bookmarks are deliberately dropped rather than misdirected — the loss the
        // Split warning discloses. Asserted so the disclosure stays true.
        #expect(PDFToolkit.bookmarkCount(at: outputs[0]) == 0)
    }
}
