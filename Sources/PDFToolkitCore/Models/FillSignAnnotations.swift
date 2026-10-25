import Foundation

/// What Fill & Sign's redraw does with the review comments already on a page: highlights, sticky
/// notes, drawings, stamps and the rest of PDF's markup annotations.
public enum FillSignAnnotations: String, Hashable, Sendable {
    /// Drawn into the page, where they can no longer be edited, moved or deleted — and a sticky
    /// note keeps only its icon. What ``PDFToolkit/fillAndSignData(inputURL:items:)`` always does.
    case flatten
    /// Kept as annotations on the redrawn page, each with its own appearance, text, colour, author,
    /// popup and reply links — not drawn into the page.
    case keep

    /// The annotation subtypes ``keep`` keeps: PDF's markup annotations and their popups, as
    /// `/Subtype` and `PDFAnnotation.type` name them. Links and form widgets are not among them:
    /// they are handled as before under either choice.
    public static let keptSubtypes: Set<String> = [
        "Text", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight", "Underline",
        "Squiggly", "StrikeOut", "Stamp", "Caret", "Ink", "FileAttachment", "Sound", "Redact", "Popup",
    ]
}

/// A Fill & Sign copy, and what became of the source's comments in it.
public struct FillSignOutput: Sendable {
    /// The copy's bytes.
    public let data: Data
    /// What the copy did with the source's comments. ``FillSignAnnotations/keep`` asked for can come
    /// back ``FillSignAnnotations/flatten``: when they could not be written as annotations — an
    /// encrypted copy, which an appended update cannot add to, or anything unexpected in the copy —
    /// they are drawn into the pages instead, as before, so nothing is lost. Say so to the reader.
    public let annotations: FillSignAnnotations
}
