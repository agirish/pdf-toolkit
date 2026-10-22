import Foundation

/// Rewrites a handful of values in a PDF that PDFKit has just written, by appending an
/// incremental update — the standard way to change a PDF without re-serializing it.
///
/// It exists for two jobs. The first is checkbox and radio states. PDFKit's writer cannot set a button widget
/// (measured on macOS 27.0.1): any change through `buttonWidgetState` or `widgetStringValue`
/// replaces the widget's on/off appearance dictionary with one regenerated stream, writes `/V` as a
/// string instead of a name, and leaves `/AS` naming the old state — so on reopen PDFKit itself
/// reads a radio group as all-off with every export value gone. Untouched buttons, though, come
/// through PDFKit's write byte-faithful. So form filling leaves buttons alone in PDFKit and sets
/// their `/AS` and `/V` here instead, keeping the producer's own appearance streams.
///
/// Only names change, and names are never encrypted, so this works unchanged on an encrypted file:
/// each rewritten object keeps its object and generation number, which is what its encrypted
/// strings are keyed by, so they are copied through verbatim and still decrypt.
///
/// The second is the catalog entries PDFKit's writer cannot set at all — page labels, viewer
/// settings, the language and attached files (see ``PDFToolkit/carryingCatalogParts``). Those
/// edits take raw values and new objects, and are refused on an encrypted file
/// (``isEncrypted``): their strings would have to be encrypted, and nothing here does that.
///
/// Deliberately narrow. It reads what PDFKit writes — classic cross-reference tables, every object
/// at top level — and throws ``Failure`` on anything else rather than guessing.
struct PDFAppendedUpdate {
    enum Failure: Error {
        case unreadable(String)
    }

    /// A parsed value, with the byte range it occupied so it can be replaced in place.
    indirect enum Value {
        /// Each entry with the byte range of its value, and where its key starts.
        case dict([(key: String, value: Value, range: Range<Int>, keyStart: Int)])
        case array([Value])
        case ref(Int, Int)
        case name(String)
        case other

        subscript(key: String) -> Value? {
            guard case .dict(let entries) = self else { return nil }
            return entries.first { $0.key == key }?.value
        }

        var ref: (Int, Int)? {
            if case .ref(let n, let g) = self { return (n, g) }
            return nil
        }
    }

    private let bytes: [UInt8]
    /// Object number → (byte offset, generation), newest section winning.
    private var xref: [Int: (offset: Int, gen: Int)] = [:]
    private var trailer: Value = .other
    private var trailerRanges: [String: Range<Int>] = [:]
    private var lastXref = 0
    /// Pending edits: object number → (key → what it becomes).
    private var edits: [Int: [String: Edit]] = [:]
    /// Objects whose whole value is replaced: object number → its new bytes.
    private var replaced: [Int: [UInt8]] = [:]
    /// New objects, in the order they were added: (number, bytes).
    private var added: [(number: Int, body: [UInt8])] = []

    private enum Edit {
        case name(String)
        case raw([UInt8])
        case remove
    }

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard let start = Self.lastStartXref(in: bytes) else { throw Failure.unreadable("no startxref") }
        lastXref = start
        var next: Int? = start
        var seen = Set<Int>()
        var newest = true
        while let at = next, seen.insert(at).inserted {
            var p = at
            guard readKeyword("xref", at: &p) else {
                throw Failure.unreadable("cross-reference stream at \(at); only tables are supported")
            }
            while true {
                skipSpace(&p)
                if readKeyword("trailer", at: &p) { break }
                guard let first = readInt(&p), let count = readInt(&p) else { throw Failure.unreadable("xref subsection") }
                for i in 0..<count {
                    guard let offset = readInt(&p), let gen = readInt(&p) else { throw Failure.unreadable("xref entry") }
                    skipSpace(&p)
                    let used = p < bytes.count && bytes[p] == UInt8(ascii: "n")
                    p += 1
                    if used, xref[first + i] == nil { xref[first + i] = (offset, gen) }
                }
            }
            let (dict, _) = try parseValue(&p)
            if newest {
                trailer = dict
                if case .dict(let entries) = dict {
                    for e in entries { trailerRanges[e.key] = e.range }
                }
                newest = false
            }
            next = nil
            if case .dict(let entries) = dict, let prev = entries.first(where: { $0.key == "Prev" }) {
                next = Int(String(decoding: bytes[prev.range], as: UTF8.self).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: Reading

    /// The object `number`'s value and the byte range of that value.
    func object(_ number: Int) throws -> (value: Value, range: Range<Int>) {
        guard let entry = xref[number] else { throw Failure.unreadable("object \(number) not in xref") }
        var p = entry.offset
        guard readInt(&p) == number, readInt(&p) == entry.gen, readKeyword("obj", at: &p) else {
            throw Failure.unreadable("object \(number) header")
        }
        skipSpace(&p)
        let start = p
        let (value, end) = try parseValue(&p)
        return (value, start..<end)
    }

    /// Follows an indirect reference; a direct value is returned as is.
    func resolve(_ value: Value?) throws -> Value? {
        guard let value else { return nil }
        if let (n, _) = value.ref { return try object(n).value }
        return value
    }

    /// The catalog's object number.
    func rootObject() throws -> Int {
        guard let root = trailer["Root"]?.ref else { throw Failure.unreadable("no /Root") }
        return root.0
    }

    /// Whether the file is encrypted — where a raw edit's strings would need encrypting.
    var isEncrypted: Bool { trailerRanges["Encrypt"] != nil }

    /// The bytes of `key`'s value in object `number`, as written, or nil when it has no such key.
    func rawValue(_ key: String, inObject number: Int) throws -> [UInt8]? {
        guard case .dict(let entries) = try object(number).value,
              let entry = entries.first(where: { $0.key == key }) else { return nil }
        return Array(bytes[entry.range])
    }

    /// The bytes of object `number`'s whole value, as written.
    func rawObject(_ number: Int) throws -> [UInt8] {
        Array(bytes[try object(number).range])
    }

    /// The object number of every page, in page order.
    func pageObjects() throws -> [Int] {
        guard let root = trailer["Root"]?.ref, let pages = try object(root.0).value["Pages"]?.ref else {
            throw Failure.unreadable("no /Root /Pages")
        }
        var result: [Int] = []
        var visited = Set<Int>()
        func walk(_ number: Int) throws {
            guard visited.insert(number).inserted else { throw Failure.unreadable("page tree cycle") }
            let node = try object(number).value
            if case .array(let kids)? = try resolve(node["Kids"]) {
                for kid in kids {
                    guard let (n, _) = kid.ref else { throw Failure.unreadable("direct page object") }
                    try walk(n)
                }
            } else {
                result.append(number)
            }
        }
        try walk(pages.0)
        return result
    }

    /// The object number of each entry in a page's `/Annots`, in array order.
    func annotationObjects(ofPage page: Int) throws -> [Int] {
        guard case .array(let annots)? = try resolve(try object(page).value["Annots"]) else { return [] }
        return try annots.map {
            guard let (n, _) = $0.ref else { throw Failure.unreadable("direct annotation on page object \(page)") }
            return n
        }
    }

    /// The object number of each top-level field in the catalog's `/AcroForm /Fields`, in order.
    func formFieldObjects() throws -> [Int] {
        guard let root = trailer["Root"]?.ref else { throw Failure.unreadable("no /Root") }
        guard let acroForm = try resolve(try object(root.0).value["AcroForm"]),
              case .array(let fields)? = try resolve(acroForm["Fields"]) else { return [] }
        return try fields.map {
            guard let (n, _) = $0.ref else { throw Failure.unreadable("direct field in /Fields") }
            return n
        }
    }

    /// The object number of each entry in an object's `/Kids`, in order.
    func kids(of number: Int) throws -> [Int] {
        guard case .array(let kids)? = try resolve(try object(number).value["Kids"]) else { return [] }
        return try kids.map {
            guard let (n, _) = $0.ref else { throw Failure.unreadable("direct kid of object \(number)") }
            return n
        }
    }

    /// The `/Parent` reference of an object, if any.
    func parent(of number: Int) throws -> Int? {
        try object(number).value["Parent"]?.ref?.0
    }

    func hasKey(_ key: String, inObject number: Int) throws -> Bool {
        try object(number).value[key] != nil
    }

    // MARK: Writing

    /// Records that `key` in object `number` becomes the name `/value`.
    mutating func setName(_ key: String, to value: String, inObject number: Int) {
        edits[number, default: [:]][key] = .name(value)
    }

    /// Records that `key` in object `number` becomes `raw`, a value already in PDF syntax.
    mutating func setRaw(_ key: String, to raw: String, inObject number: Int) {
        setRaw(key, to: Array(raw.utf8), inObject: number)
    }

    /// ``setRaw(_:to:inObject:)`` for a value's raw bytes.
    mutating func setRaw(_ key: String, to raw: [UInt8], inObject number: Int) {
        edits[number, default: [:]][key] = .raw(raw)
    }

    /// Records that object `number` loses `key`.
    mutating func removeKey(_ key: String, inObject number: Int) {
        edits[number, default: [:]][key] = .remove
    }

    /// Records that object `number`'s whole value becomes `raw`.
    mutating func replaceObject(_ number: Int, with raw: [UInt8]) {
        replaced[number] = raw
    }

    /// Adds an object whose value is `body` (a stream object's body ends with its `endstream`), and
    /// returns its number.
    mutating func addObject(_ body: [UInt8]) -> Int {
        let number = (added.last?.number ?? max(previousSize, (xref.keys.max() ?? 0) + 1) - 1) + 1
        added.append((number, body))
        return number
    }

    /// Sets the bytes of an object ``addObject(_:)`` added — for one whose number had to be known
    /// before its body was written.
    mutating func replaceAdded(_ number: Int, with body: [UInt8]) {
        guard let i = added.firstIndex(where: { $0.number == number }) else { return }
        added[i].body = body
    }

    /// `/Size` from the newest trailer: free entries count too, so new numbers start past it.
    private var previousSize: Int {
        trailerRanges["Size"].flatMap {
            Int(String(decoding: bytes[$0], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } ?? 0
    }

    /// The original bytes plus one incremental update carrying every recorded edit. Returns the
    /// input unchanged when nothing was recorded.
    func appended() throws -> Data {
        guard !edits.isEmpty || !replaced.isEmpty || !added.isEmpty else { return Data(bytes) }
        var out = bytes
        if out.last != UInt8(ascii: "\n") { out.append(UInt8(ascii: "\n")) }
        var offsets: [(Int, Int, Int)] = []   // (number, gen, offset)
        for number in Set(edits.keys).union(replaced.keys).sorted() {
            guard let gen = xref[number]?.gen else { throw Failure.unreadable("object \(number) not in xref") }
            var body: [UInt8]
            if let whole = replaced[number] {
                body = whole
            } else {
                let (value, range) = try object(number)
                guard case .dict(let entries) = value else { throw Failure.unreadable("object \(number) is not a dictionary") }
                body = Array(bytes[range])
                var additions: [UInt8] = []
                // Replace from the back so earlier ranges stay valid.
                var replacements: [(Range<Int>, [UInt8])] = []
                for (key, edit) in edits[number] ?? [:] {
                    let encoded: [UInt8]
                    switch edit {
                    case .name(let name): encoded = Array(("/" + Self.escapedName(name)).utf8)
                    case .raw(let raw): encoded = raw
                    case .remove: encoded = []
                    }
                    if let entry = entries.first(where: { $0.key == key }) {
                        if case .remove = edit {
                            replacements.append((entry.keyStart..<entry.range.upperBound, []))
                        } else {
                            replacements.append((entry.range, [UInt8(ascii: " ")] + encoded))
                        }
                    } else if !encoded.isEmpty {
                        additions += Array(" /\(Self.escapedName(key)) ".utf8) + encoded
                    }
                }
                for (r, new) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
                    body.replaceSubrange((r.lowerBound - range.lowerBound)..<(r.upperBound - range.lowerBound), with: new)
                }
                // The dictionary's closing `>>` is the last two bytes of its range.
                body.insert(contentsOf: additions, at: body.count - 2)
            }
            offsets.append((number, gen, out.count))
            out += Array("\(number) \(gen) obj\n".utf8) + body + Array("\nendobj\n".utf8)
        }
        for (number, body) in added {
            offsets.append((number, 0, out.count))
            out += Array("\(number) 0 obj\n".utf8) + body + Array("\nendobj\n".utf8)
        }
        let xrefOffset = out.count
        var section = "xref\n"
        for (number, gen, offset) in offsets {
            section += "\(number) 1\n" + String(format: "%010d %05d n \n", offset, gen)
        }
        // Never smaller than the previous section's: `/Size` counts free entries too.
        let size = max(previousSize, (xref.keys.max() ?? 0) + 1, offsets.map { $0.0 + 1 }.max() ?? 0)
        section += "trailer\n<< /Size \(size)"
        for key in ["Root", "Info", "Encrypt", "ID"] {
            guard let r = trailerRanges[key] else { continue }
            section += " /\(key) " + String(decoding: bytes[r], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        section += " /Prev \(lastXref) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out += Array(section.utf8)
        return Data(out)
    }

    /// A name's bytes as they must appear after `/`: delimiters, `#`, whitespace and anything
    /// outside printable ASCII written as `#xx`.
    static func escapedName(_ name: String) -> String {
        escapedName(bytes: Array(name.utf8))
    }

    /// ``escapedName(_:)`` for a name's raw bytes, which need not be UTF-8.
    static func escapedName<S: Sequence>(bytes name: S) -> String where S.Element == UInt8 {
        var out = ""
        for byte in name {
            if byte > 0x20, byte < 0x7F, !"()<>[]{}/%#".utf8.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "#%02X", byte)
            }
        }
        return out
    }

    // MARK: Lexing

    private static func lastStartXref(in bytes: [UInt8]) -> Int? {
        let needle = Array("startxref".utf8)
        let window = max(0, bytes.count - 2048)
        var i = bytes.count - needle.count
        while i >= window {
            if Array(bytes[i..<(i + needle.count)]) == needle {
                var p = i + needle.count
                var digits = ""
                while p < bytes.count, bytes[p] == 0x20 || bytes[p] == 0x0A || bytes[p] == 0x0D { p += 1 }
                while p < bytes.count, (0x30...0x39).contains(bytes[p]) { digits.append(Character(UnicodeScalar(bytes[p]))); p += 1 }
                return Int(digits)
            }
            i -= 1
        }
        return nil
    }

    private static func isWhite(_ b: UInt8) -> Bool { b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }
    private static func isDelimiter(_ b: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(b) }

    private func skipSpace(_ p: inout Int) {
        while p < bytes.count {
            if Self.isWhite(bytes[p]) { p += 1 } else if bytes[p] == UInt8(ascii: "%") {
                while p < bytes.count, bytes[p] != 10, bytes[p] != 13 { p += 1 }
            } else { return }
        }
    }

    private func readKeyword(_ word: String, at p: inout Int) -> Bool {
        var q = p
        skipSpace(&q)
        let w = Array(word.utf8)
        guard q + w.count <= bytes.count, Array(bytes[q..<(q + w.count)]) == w else { return false }
        let end = q + w.count
        if end < bytes.count, !Self.isWhite(bytes[end]), !Self.isDelimiter(bytes[end]) { return false }
        p = end
        return true
    }

    private func readInt(_ p: inout Int) -> Int? {
        skipSpace(&p)
        var q = p
        if q < bytes.count, bytes[q] == UInt8(ascii: "-") || bytes[q] == UInt8(ascii: "+") { q += 1 }
        let digitsStart = q
        while q < bytes.count, (0x30...0x39).contains(bytes[q]) { q += 1 }
        guard q > digitsStart, q == bytes.count || !(bytes[q] == UInt8(ascii: ".")) else { return nil }
        let value = Int(String(decoding: bytes[p..<q], as: UTF8.self))
        p = q
        return value
    }

    /// Parses one value starting at `p` (leading whitespace allowed) and returns it with the
    /// offset just past it.
    private func parseValue(_ p: inout Int) throws -> (Value, Int) {
        skipSpace(&p)
        guard p < bytes.count else { throw Failure.unreadable("unexpected end") }
        let b = bytes[p]
        if b == UInt8(ascii: "<"), p + 1 < bytes.count, bytes[p + 1] == UInt8(ascii: "<") {
            p += 2
            var entries: [(key: String, value: Value, range: Range<Int>, keyStart: Int)] = []
            while true {
                skipSpace(&p)
                guard p < bytes.count else { throw Failure.unreadable("unterminated dictionary") }
                if bytes[p] == UInt8(ascii: ">") {
                    guard p + 1 < bytes.count, bytes[p + 1] == UInt8(ascii: ">") else { throw Failure.unreadable("bad >") }
                    p += 2
                    return (.dict(entries), p)
                }
                let keyStart = p
                guard case (.name(let key), _) = try parseValue(&p) else { throw Failure.unreadable("dictionary key") }
                let valueStart = p
                let (value, end) = try parseValue(&p)
                entries.append((key, value, valueStart..<end, keyStart))
            }
        }
        switch b {
        case UInt8(ascii: "["):
            p += 1
            var items: [Value] = []
            while true {
                skipSpace(&p)
                guard p < bytes.count else { throw Failure.unreadable("unterminated array") }
                if bytes[p] == UInt8(ascii: "]") { p += 1; return (.array(items), p) }
                items.append(try parseValue(&p).0)
            }
        case UInt8(ascii: "/"):
            p += 1
            let start = p
            while p < bytes.count, !Self.isWhite(bytes[p]), !Self.isDelimiter(bytes[p]) { p += 1 }
            return (.name(Self.unescapedName(bytes[start..<p])), p)
        case UInt8(ascii: "("):
            var depth = 0
            while p < bytes.count {
                let c = bytes[p]
                if c == UInt8(ascii: "\\") { p += 2; continue }
                if c == UInt8(ascii: "(") { depth += 1 }
                if c == UInt8(ascii: ")") { depth -= 1; if depth == 0 { p += 1; return (.other, p) } }
                p += 1
            }
            throw Failure.unreadable("unterminated string")
        case UInt8(ascii: "<"):
            while p < bytes.count, bytes[p] != UInt8(ascii: ">") { p += 1 }
            p += 1
            return (.other, p)
        default:
            // A number, `true`/`false`/`null`, or the first number of `n g R`.
            var q = p
            if let n = readInt(&q) {
                var r = q
                if let g = readInt(&r), readKeyword("R", at: &r) {
                    p = r
                    return (.ref(n, g), p)
                }
            }
            let start = p
            while p < bytes.count, !Self.isWhite(bytes[p]), !Self.isDelimiter(bytes[p]) { p += 1 }
            guard p > start else { throw Failure.unreadable("unexpected byte \(b) at \(p)") }
            return (.other, p)
        }
    }

    private static func unescapedName(_ raw: ArraySlice<UInt8>) -> String {
        var out: [UInt8] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == UInt8(ascii: "#"), i + 2 < raw.endIndex,
               let v = UInt8(String(decoding: raw[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(raw[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
