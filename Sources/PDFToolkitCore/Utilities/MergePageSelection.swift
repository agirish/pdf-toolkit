import Foundation

/// Resolves one Merge row's page choice into the selection `PDFToolkit.merge(inputs:)` expects.
///
/// Lives apart from the view so the range-text → page-indices logic — the heart of the per-file
/// merge feature — is a pure function that can be unit tested directly, rather than buried in
/// SwiftUI `@State`.
public enum MergePageSelection {
    /// - Parameters:
    ///   - rangeText: an Extract-style range (`"1, 3-5"`); blank means all pages, and the typed order
    ///     is preserved (`"5,1,2"` → 5, 1, 2).
    ///   - dropped: zero-based pages removed via the combined preview's inline page-drop.
    ///   - pageCount: the file's real page count, used to bound-check the range.
    /// - Returns: `nil` when the whole file is taken (blank range and nothing dropped) so the engine
    ///   copies every page at write time; otherwise the parsed pages in typed order with the dropped
    ///   pages removed (possibly empty, meaning this file contributes nothing).
    /// - Throws: the same `PDFOperationError` cases Extract raises on a bad range
    ///   (`invalidPageRange`, `pageOutOfBounds`), so the run surfaces them identically.
    public static func resolve(rangeText: String, dropped: Set<Int>, pageCount: Int) throws -> [Int]? {
        let trimmed = rangeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && dropped.isEmpty {
            return nil
        }
        let parsed = try PageRangeParser.parse(
            trimmed, pageCount: pageCount, emptyMeansAllPages: true, preserveOrder: true
        )
        return parsed.filter { !dropped.contains($0) }
    }
}
