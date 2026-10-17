import Testing
import CoreGraphics
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// Extract, Reorder, and Delete all rebuild a document from copied pages. They share a page-copy
/// path, so the tests focus on each one's distinct contract: extract preserves the requested order
/// and duplicates, reorder is a full permutation, and delete removes from the highest index down
/// while refusing to empty the document.
@Suite struct PDFToolkitExtractReorderDeleteTests {

    // MARK: - Extract

    @Test func extractCopiesPagesInTheRequestedOrder() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [2, 0])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 2)
        #expect(texts[0].contains("P3"))
        #expect(texts[1].contains("P1"))
    }

    @Test func extractCanRepeatAPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2"], to: src)

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [0, 0])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 2)
        #expect(texts.allSatisfy { $0.contains("P1") })
    }

    @Test func extractRejectsEmptySelection() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.extract(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [])
        }?.kind == "noPagesSelected")
    }

    @Test func extractRejectsOutOfBoundsPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.extract(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [5])
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }

    // MARK: - Reorder

    @Test func reorderAppliesAFullPermutation() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [2, 1, 0])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 3)
        #expect(texts[0].contains("P3"))
        #expect(texts[1].contains("P2"))
        #expect(texts[2].contains("P1"))
    }

    @Test func reorderWithIdentityOrderCopiesUnchanged() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2"], to: src)

        try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [0, 1])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains("P1"))
        #expect(texts[1].contains("P2"))
    }

    @Test func reorderCanDropPagesWhileReordering() throws {
        // The Reorder tool's "remove page" affordance drops an index from the working order, so the
        // order it hands the engine is a *reordered subset*: fewer pages than the source, in a new
        // arrangement. Prove the output holds exactly the kept pages, in that order — the shape a
        // user gets from dragging P4 to the top and trashing P2 and P3.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3", "P4"], to: src)

        try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [3, 0])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 2)
        #expect(texts[0].contains("P4"))
        #expect(texts[1].contains("P1"))
    }

    @Test func reorderPreservesEachKeptPagesRotation() throws {
        // Page geometry has bitten this app before, so pin it: when a rotated page survives a
        // drop-and-reorder, its /Rotate must travel with the correct page — not get reassigned to
        // whatever now sits at that output position. Page 1 is turned 90°, page 3 turned 180°;
        // keeping [page3, page1] must yield rotations [180, 90] with matching text identity.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], rotations: [0: 90, 2: 180], to: src)

        try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [2, 0])

        let texts = try PDFFixtures.pageTexts(at: out)
        let rotations = try PDFFixtures.pageRotations(at: out)
        #expect(texts.count == 2)
        #expect(texts[0].contains("P3"))
        #expect(texts[1].contains("P1"))
        #expect(rotations == [180, 90])
    }

    // MARK: - Delete

    @Test func deleteRemovesTheNamedPages() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [1])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 2)
        #expect(texts[0].contains("P1"))
        #expect(texts[1].contains("P3"))
    }

    @Test func deleteFromHighestIndexDownKeepsTheRightPages() throws {
        // Removing [0,1] must delete the first two pages, not shift and delete the wrong ones —
        // the engine sorts descending so earlier removals don't renumber later ones.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [0, 1])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 1)
        #expect(texts[0].contains("P3"))
    }

    @Test func deleteDeduplicatesRepeatedIndices() throws {
        // Naming a page twice removes it once — the count reflects a single deletion.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [1, 1])

        #expect(try PDFFixtures.pageCount(at: out) == 2)
    }

    @Test func deleteRefusesToRemoveEveryPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.deletePages(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [0, 1, 2])
        }?.kind == "cannotRemoveEveryPage")
    }

    @Test func deleteRejectsEmptySelection() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.deletePages(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [])
        }?.kind == "noPagesSelected")
    }

    @Test func deleteRejectsOutOfBoundsPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.deletePages(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [5])
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }

    @Test func deleteReportsTheBadIndexNotCannotRemoveEveryPage() throws {
        // A request naming as many indices as there are pages, but with one OUT OF RANGE, must report
        // the bad page — not `cannotRemoveEveryPage`. The every-page count check used to run before
        // the per-index bounds check, so [0,1,5] on a 3-page doc mis-reported as "removing every page".
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.deletePages(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [0, 1, 5])
        }
        #expect(error?.kind == "pageOutOfBounds")
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }

    @Test func deleteReportsAStableSmallestBadPageForMultipleOutOfRangeIndices() throws {
        // With SEVERAL out-of-range indices the reported page must be the SAME every run. The engine
        // de-duplicates the indices into a Set (whose iteration order is non-deterministic) and then
        // walks them in SORTED order, so the smallest offending page — here 5, reported 1-based as 6 —
        // is thrown deterministically rather than whichever index the Set happened to yield first.
        // Repeated to make a non-deterministic reversion (iterating the raw Set) conspicuous.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        for _ in 0..<16 {
            let error = #expect(throws: PDFOperationError.self) {
                try PDFToolkit.deletePages(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [9, 7, 5])
            }
            if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
                Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
            }
        }
    }
}

/// Bookmarks live on the document catalog, so every operation that rebuilds a document from copied
/// pages must deliberately carry them across — and, for a subset or reorder, REMAP each destination
/// onto the page's new position rather than reattach the source outline verbatim (which would leave
/// bookmarks pointing at the wrong page, or off the end). These open the output and assert each
/// surviving bookmark resolves to the CORRECT page index. Remove-password is grouped here — it too
/// rebuilds from copied pages, and it has no dedicated owned test file — alongside the extract and
/// reorder cases whose remap logic is the subtle part.
@Suite struct PDFToolkitOutlinePreservationTests {

    @Test func extractRemapsSurvivingBookmarksAndDropsThoseForOmittedPages() throws {
        // Source bookmarks: A→p0, B→p1, C→p3. Extract [3, 1] keeps p3 (now output 0) and p1 (output 1)
        // and drops p0. So A vanishes, B moves to index 1, C moves to index 0 — proving both the remap
        // and the drop of a bookmark whose target page isn't in the output.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 4, bookmarks: [("A", 0), ("B", 1), ("C", 3)], to: src)

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [3, 1])

        // Sanity: the pages themselves landed where extract promises.
        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains(PDFFixtures.marker(4)))
        #expect(texts[1].contains(PDFFixtures.marker(2)))

        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["B", "C"])
        #expect(bookmarks.map(\.pageIndex) == [1, 0])
    }

    @Test func reorderRemapsBookmarksToTheNewPositions() throws {
        // First→p0, Last→p2. Reversing the order ([2,1,0]) sends p0 to output index 2 and p2 to
        // output index 0, so the bookmarks must follow their pages, not stay at their old indices.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, bookmarks: [("First", 0), ("Last", 2)], to: src)

        try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [2, 1, 0])

        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["First", "Last"])
        #expect(bookmarks.map(\.pageIndex) == [2, 0])
    }

    @Test func reorderFollowsEveryBookmarkThroughAFullPermutation() throws {
        // A three-page, three-bookmark source under the permutation [1, 2, 0]: output p0 = source p1,
        // p1 = source p2, p2 = source p0. So One→out2, Two→out0, Three→out1 — every bookmark travels
        // with its OWN page, none left at its old index. (The two-bookmark reversal above pins the
        // pair case; this pins a full 3-cycle where each page moves.) The outline keeps its source
        // order (One, Two, Three); only each destination's page index changes.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, bookmarks: [("One", 0), ("Two", 1), ("Three", 2)], to: src)

        try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [1, 2, 0])

        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["One", "Two", "Three"])
        #expect(bookmarks.map(\.pageIndex) == [2, 0, 1])
    }

    @Test func extractMapsABookmarkToTheFirstOccurrenceOfADuplicatedPage() throws {
        // Extract [0, 0, 1] copies source page 0 twice, then page 1, so the output is [p0, p0, p1].
        // A bookmark targeting source page 0 must resolve to the FIRST copy (output index 0), and the
        // page-1 bookmark to output index 2 — the "first occurrence wins" rule the remap map encodes.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, bookmarks: [("A", 0), ("B", 1)], to: src)

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [0, 0, 1])

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 3)
        #expect(texts[0].contains(PDFFixtures.marker(1)))
        #expect(texts[1].contains(PDFFixtures.marker(1)))
        #expect(texts[2].contains(PDFFixtures.marker(2)))

        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["A", "B"])
        #expect(bookmarks.map(\.pageIndex) == [0, 2])
    }

    @Test func extractPromotesAKeptChildWhenItsParentPageIsDropped() throws {
        // A NESTED outline: Parent → p0 with a nested Child → p2. Extract [2] keeps p2 (output index 0)
        // and drops p0, so the Parent node — whose target page is gone — must be dropped while its
        // still-retained Child is PROMOTED to the top level, pointing at the kept page's new slot.
        // `writePDF(pageCount:bookmarks:)` only builds a flat outline, so construct the nesting here
        // (writing the pages to a distinct base first, to avoid the self-overwrite hazard the flat
        // helper documents).
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        let parent = PDFOutline()
        parent.label = "Parent"
        parent.destination = PDFDestination(page: try #require(doc.page(at: 0)), at: CGPoint(x: 0, y: PDFFixtures.letter.height))
        let child = PDFOutline()
        child.label = "Child"
        child.destination = PDFDestination(page: try #require(doc.page(at: 2)), at: CGPoint(x: 0, y: PDFFixtures.letter.height))
        parent.insertChild(child, at: 0)
        root.insertChild(parent, at: 0)
        doc.outlineRoot = root
        #expect(doc.write(to: src))

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [2])

        // Only marker page 3 survives, at output index 0.
        #expect(try PDFFixtures.pageTexts(at: out) == [PDFFixtures.marker(3)])
        // Parent dropped; Child promoted to the top level, resolving to the kept page (output 0).
        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["Child"])
        #expect(bookmarks.map(\.pageIndex) == [0])
    }

    /// A grouping FOLDER — a node with children and no destination of its own — is how most
    /// well-organized PDFs structure their outline. It used to be treated as an orphan and dropped,
    /// flattening every surviving bookmark up a level; the hierarchy must survive instead.
    @Test func extractKeepsStructuralFoldersWhoseChildrenSurvive() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        let folder = PDFOutline()          // no destination — a pure grouping node
        folder.label = "Part One"
        let child = PDFOutline()
        child.label = "Child"
        child.destination = PDFDestination(page: try #require(doc.page(at: 2)), at: CGPoint(x: 0, y: PDFFixtures.letter.height))
        folder.insertChild(child, at: 0)
        root.insertChild(folder, at: 0)
        doc.outlineRoot = root
        #expect(doc.write(to: src))

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [2])

        let outDoc = try #require(PDFDocument(url: out))
        let keptFolder = try #require(outDoc.outlineRoot?.child(at: 0))
        #expect(keptFolder.label == "Part One")
        #expect(keptFolder.destination == nil)
        let keptChild = try #require(keptFolder.child(at: 0))
        #expect(keptChild.label == "Child")
        #expect(outDoc.index(for: try #require(keptChild.destination?.page)) == 0)
    }

    /// The other half of the folder rule: a folder with nothing left under it is dropped, not kept
    /// as an empty row the reader can't do anything with.
    @Test func extractDropsAStructuralFolderWithNoSurvivingChildren() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        let folder = PDFOutline()
        folder.label = "Part One"
        let child = PDFOutline()
        child.label = "Child"
        child.destination = PDFDestination(page: try #require(doc.page(at: 0)), at: CGPoint(x: 0, y: PDFFixtures.letter.height))
        folder.insertChild(child, at: 0)
        root.insertChild(folder, at: 0)
        doc.outlineRoot = root
        #expect(doc.write(to: src))

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [2])

        // Page 0 is gone, so nothing under the folder survived — no outline at all.
        #expect(try PDFFixtures.outlineBookmarks(at: out).isEmpty)
    }

    /// A web-link bookmark has an action and no destination; extract used to drop it silently.
    @Test func extractKeepsURLOnlyBookmarks() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        let web = PDFOutline()
        web.label = "Our site"
        web.action = PDFActionURL(url: try #require(URL(string: "https://example.com/docs")))
        root.insertChild(web, at: 0)
        doc.outlineRoot = root
        #expect(doc.write(to: src))

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [1])

        // The document must stay alive in a local: a PDFOutline read off a temporary document
        // loses its action the moment that document deallocates.
        let outDoc = try #require(PDFDocument(url: out))
        let kept = try #require(outDoc.outlineRoot?.child(at: 0))
        #expect(kept.label == "Our site")
        #expect((kept.action as? PDFActionURL)?.url?.absoluteString == "https://example.com/docs")
    }

    /// Delete rebuilds the outline too, and it used to copy only each survivor's destination — so a
    /// web-link bookmark (action, no destination) came through as dead label text. A GoTo action into
    /// a page that WAS deleted still has to go, the same as an explicit destination would.
    @Test func deleteKeepsURLOnlyBookmarksAndDropsGoToActionsIntoDeletedPages() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        let web = PDFOutline()
        web.label = "Our site"
        web.action = PDFActionURL(url: try #require(URL(string: "https://example.com/docs")))
        root.insertChild(web, at: 0)
        let goneJump = PDFOutline()
        goneJump.label = "To page 2"
        goneJump.action = PDFActionGoTo(
            destination: PDFDestination(page: try #require(doc.page(at: 1)), at: .zero)
        )
        root.insertChild(goneJump, at: 1)
        let keptJump = PDFOutline()
        keptJump.label = "To page 3"
        keptJump.action = PDFActionGoTo(
            destination: PDFDestination(page: try #require(doc.page(at: 2)), at: .zero)
        )
        root.insertChild(keptJump, at: 2)
        doc.outlineRoot = root
        #expect(doc.write(to: src))

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [1])

        // The document must stay alive in a local: a PDFOutline read off a temporary document
        // loses its action the moment that document deallocates.
        let outDoc = try #require(PDFDocument(url: out))
        let outRoot = try #require(outDoc.outlineRoot)
        #expect(outRoot.numberOfChildren == 2, "the bookmark into the deleted page should be gone")
        let kept = try #require(outRoot.child(at: 0))
        #expect(kept.label == "Our site")
        #expect((kept.action as? PDFActionURL)?.url?.absoluteString == "https://example.com/docs")
        let jump = try #require(outRoot.child(at: 1))
        #expect(jump.label == "To page 3")
        let target = try #require(jump.destination ?? (jump.action as? PDFActionGoTo)?.destination)
        let targetPage = try #require(target.page)
        #expect(outDoc.index(for: targetPage) == 1)
    }

    @Test func removePasswordKeepsBookmarksPointingAtTheRightPages() throws {
        // Remove-password rebuilds the pages into a fresh, unencrypted document (the only way to shed
        // the encryption); all pages are copied in order, so reattaching the source outline keeps each
        // bookmark on its original page. Build an ENCRYPTED source that carries an outline, strip the
        // password, then open the result and check the destinations still resolve correctly.
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), locked = dir.url("locked.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, bookmarks: [("Intro", 0), ("End", 2)], to: base)
        try PDFToolkit.encrypt(inputURL: base, outputURL: locked, password: "secret")
        #expect(try #require(PDFDocument(url: locked)).isLocked)   // sanity: really encrypted

        try PDFToolkit.removePassword(inputURL: locked, outputURL: out, password: "secret")

        #expect(try #require(PDFDocument(url: out)).isLocked == false)
        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["Intro", "End"])
        #expect(bookmarks.map(\.pageIndex) == [0, 2])
    }

    @Test func deleteDropsBookmarksForRemovedPagesAndFollowsTheSurvivors() throws {
        // Source bookmarks A→p0, B→p1, C→p2. Deleting page 1 (B's page) must DROP B rather than
        // silently retarget it to page 0 (the misdirection an untouched source outline produced),
        // while A stays on page 0 and C follows its page to the new index 1.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, bookmarks: [("A", 0), ("B", 1), ("C", 2)], to: src)

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [1])

        // Sanity: the two survivors, in order.
        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains(PDFFixtures.marker(1)))
        #expect(texts[1].contains(PDFFixtures.marker(3)))

        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["A", "C"])
        #expect(bookmarks.map(\.pageIndex) == [0, 1])
    }

    @Test func deletePromotesAKeptChildWhenItsFolderPageIsDeleted() throws {
        // A NESTED outline: Parent → p0 with a nested Child → p2. Deleting page 0 removes the Parent's
        // target page, so the Parent node is dropped while its still-retained Child is PROMOTED to the
        // top level, resolving to the kept page's new slot (p2 → output index 1). Mirrors the extract
        // promotion test; `writePDF` only builds a flat outline, so construct the nesting here.
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: base)
        let doc = try PDFFixtures.authoringCopy(of: base)
        let root = PDFOutline()
        let parent = PDFOutline()
        parent.label = "Parent"
        parent.destination = PDFDestination(page: try #require(doc.page(at: 0)), at: CGPoint(x: 0, y: PDFFixtures.letter.height))
        let child = PDFOutline()
        child.label = "Child"
        child.destination = PDFDestination(page: try #require(doc.page(at: 2)), at: CGPoint(x: 0, y: PDFFixtures.letter.height))
        parent.insertChild(child, at: 0)
        root.insertChild(parent, at: 0)
        doc.outlineRoot = root
        #expect(doc.write(to: src))

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [0])

        // Pages 2 and 3 (markers) survive; page 1 gone.
        #expect(try PDFFixtures.pageTexts(at: out) == [PDFFixtures.marker(2), PDFFixtures.marker(3)])
        // Parent dropped; Child promoted to the top level, resolving to the kept page (output index 1).
        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["Child"])
        #expect(bookmarks.map(\.pageIndex) == [1])
    }
}
