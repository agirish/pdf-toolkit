import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// **A popup nothing carries is drawn in, as ``FillSignAnnotations/flatten`` draws it** — under
/// ``FillSignAnnotations/keep`` a popup was left out of the drawing whatever it belonged to, while
/// only a popup whose `/Parent` is a kept comment comes along as an annotation. One whose parent is
/// a link, or that names none, was then neither drawn nor carried: gone from the copy.
///
/// Assembled by hand, as ``PDFToolkitKeepCommentsTests``' fixture is: each popup open, printable,
/// and drawing a dark box as its appearance, so a drawn one shows in the page's own content.
struct PDFToolkitOrphanPopupTests {
    static let noteRect = CGRect(x: 72, y: 700, width: 20, height: 20)
    static let linkRect = CGRect(x: 72, y: 600, width: 100, height: 20)
    /// The note's own popup: carried with it, so not drawn.
    static let keptPopup = CGRect(x: 300, y: 680, width: 150, height: 60)
    /// A popup whose `/Parent` is the link.
    static let linkPopup = CGRect(x: 300, y: 500, width: 150, height: 60)
    /// A popup with no `/Parent` at all.
    static let loosePopup = CGRect(x: 300, y: 300, width: 150, height: 60)

    static func write(to url: URL) throws {
        var bodies: [String] = []
        func add(_ body: String) -> Int { bodies.append(body); return bodies.count }
        func stream(_ dictionary: String, _ text: String) -> String {
            "<< \(dictionary) /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream"
        }
        func rect(_ r: CGRect) -> String { "[\(r.minX) \(r.minY) \(r.maxX) \(r.maxY)]" }
        func appearance(_ r: CGRect) -> Int {
            add(stream("/Type /XObject /Subtype /Form /BBox [0 0 \(Int(r.width)) \(Int(r.height))]",
                       "0.1 0.1 0.1 rg 0 0 \(Int(r.width)) \(Int(r.height)) re f"))
        }
        _ = add("catalog")                                   // 1
        _ = add("pages")                                     // 2
        let page = add("page")                               // 3
        let content = add(stream("", "BT /F1 18 Tf 72 740 Td (Hello page) Tj ET"))
        let font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let note = add("note"), noteNo = add("note popup"), link = add("link")
        let linkNo = add("link popup"), looseNo = add("loose popup")
        let noteAP = appearance(Self.noteRect)
        let aps = [noteNo: appearance(Self.keptPopup), linkNo: appearance(Self.linkPopup), looseNo: appearance(Self.loosePopup)]
        bodies[note - 1] = "<< /Type /Annot /Subtype /Text /NM (note) /Rect \(rect(Self.noteRect)) /P \(page) 0 R"
            + " /Contents (Note) /F 28 /Popup \(noteNo) 0 R /AP << /N \(noteAP) 0 R >> >>"
        bodies[link - 1] = "<< /Type /Annot /Subtype /Link /NM (link) /Rect \(rect(Self.linkRect)) /Border [0 0 0]"
            + " /A << /S /URI /URI (https://example.com/) >> >>"
        for (number, nm, r, parent) in [(noteNo, "note-popup", Self.keptPopup, " /Parent \(note) 0 R"),
                                        (linkNo, "link-popup", Self.linkPopup, " /Parent \(link) 0 R"),
                                        (looseNo, "loose-popup", Self.loosePopup, "")] {
            bodies[number - 1] = "<< /Type /Annot /Subtype /Popup /NM (\(nm)) /Rect \(rect(r)) /P \(page) 0 R"
                + parent + " /Open true /F 4 /AP << /N \(aps[number]!) 0 R >> >>"
        }
        let annots = [note, noteNo, link, linkNo, looseNo].map { "\($0) 0 R" }.joined(separator: " ")
        bodies[page - 1] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(content) 0 R"
            + " /Resources << /Font << /F1 \(font) 0 R >> >> /Annots [\(annots)] >>"
        bodies[0] = "<< /Type /Catalog /Pages 2 0 R >>"
        bodies[1] = "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>"

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

    /// Under `.keep` each popup is either carried as an annotation or drawn into the page, exactly
    /// as `.flatten` would have drawn it: the note's own popup is carried and not drawn; the link's
    /// and the loose one are not carried, so they are drawn as `.flatten` draws them.
    @Test func aPopupNothingCarriesIsDrawnIn() throws {
        let dir = FixtureDir()
        let url = dir.url("orphans.pdf")
        try Self.write(to: url)
        let rects = [Self.keptPopup, Self.linkPopup, Self.loosePopup]
        let flat = try PDFToolkit.fillAndSignData(inputURL: url, items: [PDFToolkitKeepCommentsTests.patch], annotations: .flatten)
        let flatDark = try PDFToolkitKeepCommentsTests.pageContentDarkness(flat.data, page: 0, rects: rects, dir: dir)
        // What flattening draws of each popup is PDFKit's to decide; the orphans must be among it,
        // or this tests nothing.
        try #require(flatDark[1] < 0.95 && flatDark[2] < 0.95, "flatten draws no orphan popup — this tests nothing: \(flatDark)")

        let kept = try PDFToolkit.fillAndSignData(inputURL: url, items: [PDFToolkitKeepCommentsTests.patch], annotations: .keep)
        #expect(kept.annotations == .keep)
        let copy = try PDFToolkitKeepCommentsTests.Comments(kept.data)
        #expect(copy.byName["note-popup"] != nil, "the note's popup was not carried")
        #expect(copy.byName["link-popup"] == nil && copy.byName["loose-popup"] == nil,
                "an orphan popup was carried — then drawing it too would show it twice")
        let keptDark = try PDFToolkitKeepCommentsTests.pageContentDarkness(kept.data, page: 0, rects: rects, dir: dir)
        #expect(keptDark[0] > 0.9, "the carried popup is drawn into the page too: \(keptDark)")
        #expect(keptDark[1] < 0.95, "the link's popup is neither carried nor drawn: \(keptDark)")
        #expect(keptDark[2] < 0.95, "the popup with no parent is neither carried nor drawn: \(keptDark)")
    }
}
