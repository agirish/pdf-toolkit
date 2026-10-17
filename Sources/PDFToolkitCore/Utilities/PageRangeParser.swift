import Foundation

public enum PageRangeParser {
    /// Parses "1, 3-5, 8" into zero-based indices.
    /// When `emptyMeansAllPages` is true, blank input selects every page (Extract's blank-means-all semantics).
    /// When false, blank input throws `pageRangeRequired` (used by Delete so an empty field cannot mean “delete everything”).
    /// When `preserveOrder` is true (Extract), comma-separated groups stay in order, ranges expand in direction (3-5 vs 5-3), and duplicate pages are allowed.
    public static func parse(
        _ text: String,
        pageCount: Int,
        emptyMeansAllPages: Bool = true,
        preserveOrder: Bool = false
    ) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            guard emptyMeansAllPages else {
                throw PDFOperationError.pageRangeRequired
            }
            return Array(0..<pageCount)
        }

        if preserveOrder {
            return try parsePreservingOrder(trimmed, pageCount: pageCount)
        }
        return try parseUniqueSorted(trimmed, pageCount: pageCount)
    }

    // MARK: - Fixed chunks (Split — "Every N pages")

    /// Splits `pageCount` pages into consecutive chunks of `chunkSize`, the last chunk taking
    /// whatever remains. `chunkSize` is floored at 1 so a zero/negative stepper value can't produce
    /// an empty stride; a zero-page document yields no segments. Each inner array is zero-based page
    /// indices — the same shape `parseSegments` returns, so both split modes feed `PDFToolkit.split`
    /// identically, and the live "N files" hint counts exactly what the export will write.
    public static func everyNPagesSegments(pageCount: Int, chunkSize: Int) -> [[Int]] {
        let n = max(1, chunkSize)
        guard pageCount > 0 else { return [] }
        return stride(from: 0, to: pageCount, by: n).map { start in
            Array(start..<min(start + n, pageCount))
        }
    }

    // MARK: - Segments (Split — each comma group becomes its own output file)

    /// Parses "1-3, 4-6, 7" into one zero-based index array **per comma group**: [[0,1,2],[3,4,5],[6]].
    /// A group is a single page ("7") or an inclusive range ("1-3"); ranges expand ascending.
    /// Empty input throws `pageRangeRequired`. Each group must land inside the document.
    public static func parseSegments(_ text: String, pageCount: Int) throws -> [[Int]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PDFOperationError.pageRangeRequired }

        var segments: [[Int]] = []
        for part in trimmed.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }

            if p.contains("-") {
                let bounds = p.split(separator: "-", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]) else {
                    throw PDFOperationError.invalidPageRange(String(p))
                }
                let lo = min(a, b), hi = max(a, b)
                var segment: [Int] = []
                for oneBased in lo...hi {
                    let zero = oneBased - 1
                    guard (0..<pageCount).contains(zero) else {
                        throw PDFOperationError.pageOutOfBounds(oneBased)
                    }
                    segment.append(zero)
                }
                segments.append(segment)
            } else if let oneBased = Int(p) {
                let zero = oneBased - 1
                guard (0..<pageCount).contains(zero) else {
                    throw PDFOperationError.pageOutOfBounds(oneBased)
                }
                segments.append([zero])
            } else {
                throw PDFOperationError.invalidPageRange(String(p))
            }
        }

        guard !segments.isEmpty else { throw PDFOperationError.invalidPageRange(trimmed) }
        return segments
    }

    // MARK: - Unique, sorted (Rotate range, Delete)

    private static func parseUniqueSorted(_ trimmed: String, pageCount: Int) throws -> [Int] {
        var indices = Set<Int>()
        let parts = trimmed.split(separator: ",")

        for part in parts {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }

            if p.contains("-") {
                let rangeParts = p.split(separator: "-", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard rangeParts.count == 2,
                    let startOneBased = Int(rangeParts[0]),
                    let endOneBased = Int(rangeParts[1])
                else {
                    throw PDFOperationError.invalidPageRange(String(p))
                }
                let lo = min(startOneBased, endOneBased)
                let hi = max(startOneBased, endOneBased)
                for oneBased in lo...hi {
                    let zero = oneBased - 1
                    guard (0..<pageCount).contains(zero) else {
                        throw PDFOperationError.pageOutOfBounds(oneBased)
                    }
                    indices.insert(zero)
                }
            } else if let oneBased = Int(p) {
                let zero = oneBased - 1
                guard (0..<pageCount).contains(zero) else {
                    throw PDFOperationError.pageOutOfBounds(oneBased)
                }
                indices.insert(zero)
            } else {
                throw PDFOperationError.invalidPageRange(String(p))
            }
        }

        guard !indices.isEmpty else {
            throw PDFOperationError.invalidPageRange(trimmed)
        }

        return indices.sorted()
    }

    // MARK: - Order preserved (Extract)

    private static func parsePreservingOrder(_ trimmed: String, pageCount: Int) throws -> [Int] {
        var result: [Int] = []
        let parts = trimmed.split(separator: ",")

        for part in parts {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }

            if p.contains("-") {
                let rangeParts = p.split(separator: "-", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard rangeParts.count == 2,
                    let startOneBased = Int(rangeParts[0]),
                    let endOneBased = Int(rangeParts[1])
                else {
                    throw PDFOperationError.invalidPageRange(String(p))
                }

                // Lazy sequences, never materialized arrays: a typo like "1-999999999" must throw
                // pageOutOfBounds at the first bad page, not allocate gigabytes first. The sibling
                // parsers already iterate their ranges lazily.
                let oneBasedSequence: AnySequence<Int>
                if startOneBased <= endOneBased {
                    oneBasedSequence = AnySequence(startOneBased...endOneBased)
                } else {
                    oneBasedSequence = AnySequence(stride(from: startOneBased, through: endOneBased, by: -1))
                }

                for oneBased in oneBasedSequence {
                    let zero = oneBased - 1
                    guard (0..<pageCount).contains(zero) else {
                        throw PDFOperationError.pageOutOfBounds(oneBased)
                    }
                    result.append(zero)
                }
            } else if let oneBased = Int(p) {
                let zero = oneBased - 1
                guard (0..<pageCount).contains(zero) else {
                    throw PDFOperationError.pageOutOfBounds(oneBased)
                }
                result.append(zero)
            } else {
                throw PDFOperationError.invalidPageRange(String(p))
            }
        }

        guard !result.isEmpty else {
            throw PDFOperationError.invalidPageRange(trimmed)
        }

        return result
    }
}
