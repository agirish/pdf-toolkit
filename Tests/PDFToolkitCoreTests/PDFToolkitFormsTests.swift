import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

// Form filling in place: `formFields(at:)` and `fillFormData(inputURL:values:items:)`.
//
// Two ways of reading a result, and they answer different questions:
// - `RawForm` reads the bytes through CoreGraphics: each widget's `/AS`, its field's `/V`, and the
//   text inside the appearance stream a viewer actually paints. That is what Acrobat, Chrome and
//   every other non-PDFKit reader shows, so it is the guard on "the new value is visible".
// - Flattening through a page-replay tool and reading the page text is what the plan asked for,
//   and it is kept — but it is NOT a test of the appearance streams. PDFKit draws a widget from its
//   `/V`, not its `/AP` (measured: a file whose `/V` says one name and whose appearance says another
//   flattens to the `/V`), so a flattened page shows the new value even when every appearance in
//   the file is stale.
//
// None of these tests mounts a PDFView: a heavy form in one starts a thread per field (see README).
// Every test runs on ``FormLane``, which says why.

/// Runs a form test on one dedicated thread, one test at a time, instead of on Swift Testing's
/// cooperative pool — the forms counterpart of ``VisionLane``, for the same kind of deadlock.
///
/// Parsing a widget makes PDFKit resolve the font named in its `/DA` (`Helv`, `ZaDb`), and on
/// macOS 27.0.1 a first-time lookup blocks its thread on a synchronous reply from the font registry
/// that cannot arrive while every cooperative-pool thread is blocked the same way. These suites run
/// dozens of form parses in parallel, so on a 10-core Mac 3 runs in 25 hung with all ten pool
/// threads parked in `XTCopyFontWithName` and `fontd` idle. A host that follows the README's
/// threading contract — every PDFKit call on one serial queue — cannot reach it.
///
/// A task-executor preference rather than ``VisionLane``'s continuation hop: the body stays inside
/// the test's own task, so its `#expect`s are still attributed to the test, while the waiting test
/// is suspended and holds no pool thread.
enum FormLane {
    final class Executor: TaskExecutor, @unchecked Sendable {
        private let queue = DispatchQueue(label: "PDFToolkitCoreTests.FormLane")

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        }
    }

    static let executor = Executor()

    static func run<T>(_ body: () throws -> T) async throws -> T {
        try await withTaskExecutorPreference(executor) { try body() }
    }
}

/// What a non-PDFKit reader sees of a form: per widget, read straight off the CoreGraphics objects.
struct RawForm {
    struct Widget {
        var name: String
        var page: Int
        /// The `/AS` name, or nil.
        var appearanceState: String?
        /// The field's `/V` when it is a NAME (buttons); nil when it is a string or absent.
        var valueName: String?
        /// The state names of a `/AP /N` dictionary; empty when `/N` is a single stream.
        var states: [String]
        /// The text shown by the appearance stream `/AS` selects (or the only one).
        var shownText: String
    }

    var widgets: [Widget]

    init(_ data: Data) throws {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cg = try #require(CGPDFDocument(provider))
        if cg.isEncrypted, !cg.isUnlocked { _ = cg.unlockWithPassword("") }
        widgets = []
        for pageNumber in 1...max(1, cg.numberOfPages) {
            guard let page = cg.page(at: pageNumber)?.dictionary else { continue }
            var annots: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annots), let annots else { continue }
            for i in 0..<CGPDFArrayGetCount(annots) {
                var a: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annots, i, &a), let a, Self.name(a, "Subtype") == "Widget",
                      let fqn = PDFToolkit.fullyQualifiedName(of: a) else { continue }
                var valueName: String?
                var node: CGPDFDictionaryRef? = a
                while let current = node, valueName == nil {
                    valueName = Self.name(current, "V")
                    var parent: CGPDFDictionaryRef?
                    node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
                }
                let state = Self.name(a, "AS")
                widgets.append(Widget(
                    name: fqn, page: pageNumber - 1, appearanceState: state, valueName: valueName,
                    states: PDFToolkit.appearanceStates(of: a),
                    shownText: Self.shownText(Self.normalAppearance(a, state: state))
                ))
            }
        }
    }

    func widgets(named name: String) -> [Widget] { widgets.filter { $0.name == name } }

    private static func name(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var n: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(d, key, &n), let n else { return nil }
        return String(cString: n)
    }

    private static func normalAppearance(_ widget: CGPDFDictionaryRef, state: String?) -> Data {
        var ap: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(widget, "AP", &ap), let ap else { return Data() }
        var stream: CGPDFStreamRef?
        if !CGPDFDictionaryGetStream(ap, "N", &stream) {
            var states: CGPDFDictionaryRef?
            guard let state, CGPDFDictionaryGetDictionary(ap, "N", &states), let states,
                  CGPDFDictionaryGetStream(states, state, &stream) else { return Data() }
        }
        guard let stream else { return Data() }
        var format = CGPDFDataFormat.raw
        return (CGPDFStreamCopyData(stream, &format) as Data?) ?? Data()
    }

    /// The text an appearance stream shows: the string operands of its text-showing operators,
    /// each operator's strings joined (a kerned `TJ` array splits a word into pieces), operators
    /// separated by newlines. Literal strings only — what PDFKit and these fixtures write.
    static func shownText(_ stream: Data) -> String {
        let bytes = [UInt8](stream)
        var lines: [String] = []
        var current = ""
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "(") {
                var depth = 1
                i += 1
                var s: [UInt8] = []
                while i < bytes.count, depth > 0 {
                    let d = bytes[i]
                    if d == UInt8(ascii: "\\"), i + 1 < bytes.count {
                        s.append(bytes[i + 1]); i += 2; continue
                    }
                    if d == UInt8(ascii: "(") { depth += 1 }
                    if d == UInt8(ascii: ")") { depth -= 1; if depth == 0 { break } }
                    s.append(d); i += 1
                }
                current += String(decoding: s, as: UTF8.self)
            } else if c == UInt8(ascii: "T"), i + 1 < bytes.count,
                      bytes[i + 1] == UInt8(ascii: "j") || bytes[i + 1] == UInt8(ascii: "J") {
                lines.append(current)
                current = ""
            }
            i += 1
        }
        return lines.joined(separator: "\n")
    }
}

/// The corpus form, values for every fillable kind, and helpers shared by the suites below.
enum FormFixture {
    static let values: [String: FormFieldValue] = [
        "applicant.name": .text("Grace Hopper"),
        "initials": .text("GH"),
        "notes": .text("Line one\nLine two"),
        "subscribe": .checked(true),
        "plan": .radio("pro"),
        "country": .choice("Japan"),
        "colour": .choice("Blue"),
        "title": .choice("Prof"),     // editable combo: not one of its options
    ]

    /// `acroform-fieldkinds.pdf` re-encrypted with an owner password whose permissions allow
    /// filling forms but forbid page assembly and annotating — the restricted-but-fillable shape.
    /// PDFKit's writer can produce it; it keeps the `/AcroForm` on an in-place write.
    static func writeFillableRestricted(to url: URL) throws {
        let doc = try RealCorpus.acroFormFieldKinds.document()
        let bits = PDFAccessPermissions.allowsFormFieldEntry.rawValue
            | PDFAccessPermissions.allowsHighQualityPrinting.rawValue
            | PDFAccessPermissions.allowsLowQualityPrinting.rawValue
            | PDFAccessPermissions.allowsContentAccessibility.rawValue
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: "owner-secret",
            .accessPermissionsOption: NSNumber(value: bits),
        ]
        try #require(doc.dataRepresentation(options: options)).write(to: url, options: .atomic)
    }

    /// Flattens `data` through Watermark's page replay and returns each page's text.
    static func flattenedText(_ data: Data, in dir: FixtureDir) throws -> [String] {
        let url = dir.url("filled-\(UUID().uuidString).pdf")
        try data.write(to: url)
        let flat = try PDFToolkit.watermarkData(
            inputURL: url,
            options: WatermarkOptions(text: "FLAT", fontSize: 8, opacity: 0.1, rotationDegrees: 0,
                                      red: 0, green: 0, blue: 0, tiled: false)
        )
        return try PDFFixtures.pageTexts(data: flat)
    }

    static func fields(_ data: Data, in dir: FixtureDir) throws -> [String: FormField] {
        let url = dir.url("read-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return Dictionary(uniqueKeysWithValues: try PDFToolkit.formFields(at: url).map { ($0.name, $0) })
    }

    static func widgetCount(_ data: Data) throws -> Int {
        let doc = try #require(PDFDocument(data: data))
        return (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.annotations.filter { $0.type == "Widget" }.count ?? 0) }
    }

    /// A page's decoded `/Contents` stream (a single stream, as every fixture here writes).
    static func pageContents(_ data: Data, page: Int) throws -> Data {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cg = try #require(CGPDFDocument(provider))
        let dict = try #require(cg.page(at: page + 1)?.dictionary)
        var stream: CGPDFStreamRef?
        #expect(CGPDFDictionaryGetStream(dict, "Contents", &stream))
        let contents = try #require(stream)
        var format = CGPDFDataFormat.raw
        return try #require(CGPDFStreamCopyData(contents, &format) as Data?)
    }

    static func hasForm(_ data: Data, in dir: FixtureDir) throws -> Bool {
        let url = dir.url("form-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return try PDFFixtures.catalogHasEntry("AcroForm", at: url)
    }
}

// MARK: - Listing

struct FormFieldListingTests {
    @Test func listsEveryKindInDocumentOrder() async throws {
        try await FormLane.run {
            let fields = try PDFToolkit.formFields(at: RealCorpus.acroFormFieldKinds.url)
            #expect(fields.map(\.name) == [
                "applicant.name", "initials", "notes", "account", "subscribe", "plan",
                "country", "colour", "title", "size", "signature", "reset",
            ])
            let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })

            let name = try #require(byName["applicant.name"])
            #expect(name.kind == .text(multiline: false))
            #expect(name.value == "Ada Quill")
            #expect(name.maxLength == nil)
            #expect(name.widgets == [FormField.Widget(pageIndex: 0, rect: CGRect(x: 200, y: 692, width: 220, height: 20))])

            let notes = try #require(byName["notes"])
            #expect(notes.kind == .text(multiline: true))
            #expect(notes.maxLength == 200)

            let account = try #require(byName["account"])
            #expect(account.isReadOnly)
            #expect(account.value == "ACCT-0042")
            #expect(fields.filter(\.isReadOnly).map(\.name) == ["account"])

            let subscribe = try #require(byName["subscribe"])
            #expect(subscribe.kind == .checkbox)
            #expect(subscribe.value == "Off")
            #expect(subscribe.options == ["Yes"])
            #expect(subscribe.widgets.map(\.exportValue) == ["Yes"])

            let plan = try #require(byName["plan"])
            #expect(plan.kind == .radio)
            #expect(plan.value == "plus")
            #expect(plan.options == ["basic", "plus", "pro"])
            #expect(plan.widgets.map(\.exportValue) == ["basic", "plus", "pro"])
            #expect(plan.widgets.map(\.rect.minX) == [200, 260, 320])

            #expect(byName["country"]?.kind == .choice(isCombo: true, allowsCustom: false))
            #expect(byName["country"]?.options == ["Canada", "France", "Japan"])
            #expect(byName["country"]?.value == "France")
            #expect(byName["colour"]?.kind == .choice(isCombo: false, allowsCustom: false))
            #expect(byName["colour"]?.value == "Green")
            #expect(byName["title"]?.kind == .choice(isCombo: true, allowsCustom: true))

            // Export/display pairs: PDFKit lists and reads the DISPLAY strings. Listed, not fillable.
            let size = try #require(byName["size"])
            #expect(size.kind == .choice(isCombo: true, allowsCustom: false))
            #expect(size.options == ["Small", "Medium", "Large"])
            #expect(size.value == "Medium")
            #expect(!size.isFillable)
            #expect(fields.filter { !$0.isFillable }.map(\.name) == ["account", "size", "signature", "reset"])

            #expect(byName["signature"]?.kind == .signature)
            #expect(byName["signature"]?.value == nil)
            #expect(byName["reset"]?.kind == .pushButton)
            #expect(byName["reset"]?.value == nil)
        }
    }

    @Test func groupsAFieldsWidgetsAcrossPages() async throws {
        try await FormLane.run {
            let initials = try #require(try PDFToolkit.formFields(at: RealCorpus.acroFormFieldKinds.url).first { $0.name == "initials" })
            #expect(initials.value == "AQ")
            #expect(initials.widgets.map(\.pageIndex) == [0, 1])
            #expect(initials.widgets.map(\.rect) == [
                CGRect(x: 200, y: 652, width: 60, height: 20),
                CGRect(x: 200, y: 700, width: 60, height: 20),
            ])
        }
    }

    @Test func readsAFormInsideAnObjectStream() async throws {
        try await FormLane.run {
            let fields = try PDFToolkit.formFields(at: RealCorpus.acroFormXrefStream.url)
            #expect(fields.map(\.name) == ["FullName", "Agree"])
            #expect(fields.map(\.value) == ["Dana Reyes", "Yes"])
            #expect(fields.map(\.kind) == [.text(multiline: false), .checkbox])
        }
    }

    @Test func aFileWithNoFormListsNothing() async throws {
        try await FormLane.run {
            let fields = try PDFToolkit.formFields(at: RealCorpus.chromeArticle.url)
            #expect(fields.isEmpty)
        }
    }

    @Test func aLockedFileIsRefused() async throws {
        try await FormLane.run {
            let error = #expect(throws: PDFOperationError.self) {
                try PDFToolkit.formFields(at: RealCorpus.encryptedUser.url)
            }
            #expect(error?.kind == "encryptedInput")
        }
    }
}

// MARK: - Filling

struct FormFillTests {
    @Test func everyKindReadsBackAfterTheFill() async throws {
        try await FormLane.run {
            let dir = FixtureDir()
            let data = try PDFToolkit.fillFormData(inputURL: RealCorpus.acroFormFieldKinds.url, values: FormFixture.values)
            let fields = try FormFixture.fields(data, in: dir)

            #expect(fields["applicant.name"]?.value == "Grace Hopper")
            #expect(fields["initials"]?.value == "GH")
            #expect(fields["notes"]?.value == "Line one\nLine two")
            #expect(fields["subscribe"]?.value == "Yes")
            #expect(fields["plan"]?.value == "pro")
            #expect(fields["country"]?.value == "Japan")
            #expect(fields["colour"]?.value == "Blue")
            #expect(fields["title"]?.value == "Prof")
            // Untouched fields keep their values.
            #expect(fields["account"]?.value == "ACCT-0042")

            // Still a fillable form: the catalog form, and every widget.
            #expect(try FormFixture.hasForm(data, in: dir))
            #expect(try FormFixture.widgetCount(data) == FormFixture.widgetCount(RealCorpus.acroFormFieldKinds.data))
        }
    }

    /// THE appearance guard: what a non-PDFKit reader paints. Text and choice appearances are
    /// regenerated with the new value on EVERY widget; button widgets keep the producer's on/off
    /// appearances and have `/AS` and `/V` set as names.
    @Test func otherReadersSeeTheNewValues() async throws {
        try await FormLane.run {
            let data = try PDFToolkit.fillFormData(inputURL: RealCorpus.acroFormFieldKinds.url, values: FormFixture.values)
            let raw = try RawForm(data)

            for (name, text) in [("applicant.name", "Grace Hopper"), ("country", "Japan"), ("title", "Prof"), ("colour", "Blue")] {
                let widgets = raw.widgets(named: name)
                #expect(!widgets.isEmpty)
                for w in widgets { #expect(w.shownText.contains(text), "\(name) shows \(w.shownText)") }
            }
            let notes = try #require(raw.widgets(named: "notes").first)
            #expect(notes.shownText.contains("Line one") && notes.shownText.contains("Line two"))

            // The two-widget field shows the new value on BOTH pages.
            let initials = raw.widgets(named: "initials")
            #expect(initials.map(\.page) == [0, 1])
            for w in initials { #expect(w.shownText.contains("GH") && !w.shownText.contains("AQ"), "page \(w.page): \(w.shownText)") }

            let subscribe = try #require(raw.widgets(named: "subscribe").first)
            #expect(subscribe.appearanceState == "Yes")
            #expect(subscribe.valueName == "Yes")
            #expect(Set(subscribe.states) == ["Yes", "Off"], "the producer's on/off appearances survive")
        }
    }

    @Test func choosingARadioTurnsItsSiblingsOff() async throws {
        try await FormLane.run {
            let data = try PDFToolkit.fillFormData(inputURL: RealCorpus.acroFormFieldKinds.url, values: ["plan": .radio("pro")])
            let plan = try RawForm(data).widgets(named: "plan")
            #expect(plan.map(\.appearanceState) == ["Off", "Off", "pro"])
            #expect(plan.allSatisfy { $0.valueName == "pro" })
            #expect(plan.map { Set($0.states) } == [["basic", "Off"], ["plus", "Off"], ["pro", "Off"]])

            let doc = try #require(PDFDocument(data: data))
            let states = try #require(doc.page(at: 0)).annotations.filter { $0.fieldName == "plan" }.map(\.buttonWidgetState)
            #expect(states == [.offState, .offState, .onState])
        }
    }

    @Test func aCheckboxInAnObjectStreamCanBeUnchecked() async throws {
        try await FormLane.run {
            let data = try PDFToolkit.fillFormData(
                inputURL: RealCorpus.acroFormXrefStream.url,
                values: ["Agree": .checked(false), "FullName": .text("Jordan Lee")]
            )
            let raw = try RawForm(data)
            let agree = try #require(raw.widgets(named: "Agree").first)
            #expect(agree.appearanceState == "Off")
            #expect(agree.valueName == "Off")
            #expect(Set(agree.states) == ["Yes", "Off"])
            #expect(try #require(raw.widgets(named: "FullName").first).shownText.contains("Jordan Lee"))
        }
    }

    /// What the plan asked for: flatten the filled file and read the page text. Kept, but see the
    /// file comment — PDFKit flattens widgets from `/V`, so this alone would pass on stale
    /// appearances. `otherReadersSeeTheNewValues` is the guard.
    @Test func theFlattenedPagesCarryTheNewValues() async throws {
        try await FormLane.run {
            let dir = FixtureDir()
            let data = try PDFToolkit.fillFormData(inputURL: RealCorpus.acroFormFieldKinds.url, values: FormFixture.values)
            let pages = try FormFixture.flattenedText(data, in: dir)
            for value in ["Grace Hopper", "GH", "Line one", "Japan", "Prof"] {
                #expect(pages[0].contains(value), "page 1 lacks \(value)")
            }
            #expect(pages[1].contains("GH"))
            #expect(!pages[0].contains("Ada Quill"))
        }
    }

    @Test func theSourceFileIsNotTouched() async throws {
        try await FormLane.run {
            let dir = FixtureDir()
            let source = try RealCorpus.acroFormFieldKinds.copy(into: dir)
            let before = try Data(contentsOf: source)
            _ = try PDFToolkit.fillFormData(inputURL: source, values: FormFixture.values)
            #expect(try Data(contentsOf: source) == before)
        }
    }

    @Test func outlineLinksXMPAndInfoSurvive() async throws {
        try await FormLane.run {
            let dir = FixtureDir()
            let data = try PDFToolkit.fillFormData(inputURL: RealCorpus.acroFormFieldKinds.url, values: FormFixture.values)
            let url = dir.url("filled.pdf")
            try data.write(to: url)

            let bookmarks = try PDFFixtures.outlineBookmarks(at: url)
            #expect(bookmarks.map(\.label) == ["Form", "Page two"])
            #expect(bookmarks.map(\.pageIndex) == [0, 1])

            let doc = try #require(PDFDocument(url: url))
            let link = try #require(doc.page(at: 0)?.annotations.first { $0.type == "Link" })
            #expect(link.destination?.page.map { doc.index(for: $0) } == 1)

            #expect(try PDFFixtures.catalogHasEntry("Metadata", at: url))
            let attributes = doc.documentAttributes ?? [:]
            #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "Membership Form")
            #expect(attributes[PDFDocumentAttribute.authorAttribute] as? String == "CORPUS-INFO-AUTHOR")
        }
    }
}

// MARK: - Permissions

struct FormFillPermissionTests {
    @Test func aFileThatForbidsAssemblyButAllowsFillingIsFilled() async throws {
        try await FormLane.run {
            let dir = FixtureDir()
            let url = dir.url("fillable-restricted.pdf")
            try FormFixture.writeFillableRestricted(to: url)
            let source = try #require(PDFDocument(url: url))
            #expect(source.isEncrypted && !source.isLocked)
            #expect(source.allowsFormFieldEntry)
            #expect(!source.allowsDocumentAssembly)

            let data = try PDFToolkit.fillFormData(inputURL: url, values: FormFixture.values)

            // Still encrypted with the same restrictions — re-serializing in place keeps them.
            let result = try #require(PDFDocument(data: data))
            #expect(result.isEncrypted)
            #expect(!result.allowsDocumentAssembly)
            // The values landed, buttons included: the appended update copied each rewritten object's
            // encrypted strings verbatim, so the field names still decrypt.
            let fields = try FormFixture.fields(data, in: dir)
            #expect(fields["applicant.name"]?.value == "Grace Hopper")
            #expect(fields["plan"]?.value == "pro")
            #expect(fields["subscribe"]?.value == "Yes")
            let raw = try RawForm(data)
            #expect(raw.widgets(named: "plan").map(\.appearanceState) == ["Off", "Off", "pro"])
            #expect(try #require(raw.widgets(named: "applicant.name").first).shownText.contains("Grace Hopper"))
        }
    }

    @Test func aFileThatForbidsFormEntryIsRefused() async throws {
        try await FormLane.run {
            // owner-restricted.pdf carries permissions 0x23: no form entry.
            let error = #expect(throws: PDFOperationError.self) {
                try PDFToolkit.fillFormData(inputURL: RealCorpus.ownerRestricted.url, values: ["any": .text("x")])
            }
            #expect(error?.kind == "permissionsForbidEditing")
        }
    }

    @Test func placingItemsOnAFileThatForbidsAnnotatingIsRefused() async throws {
        try await FormLane.run {
            let dir = FixtureDir()
            let url = dir.url("fillable-restricted.pdf")
            try FormFixture.writeFillableRestricted(to: url)
            let error = #expect(throws: PDFOperationError.self) {
                try PDFToolkit.fillFormData(inputURL: url, values: [:], items: [FormItems.typed])
            }
            #expect(error?.kind == "permissionsForbidEditing")
        }
    }

    @Test func aLockedFileIsRefused() async throws {
        try await FormLane.run {
            let error = #expect(throws: PDFOperationError.self) {
                try PDFToolkit.fillFormData(inputURL: RealCorpus.encryptedUser.url, values: ["any": .text("x")])
            }
            #expect(error?.kind == "encryptedInput")
        }
    }
}

// MARK: - Refusals

struct FormFillRefusalTests {
    private func refusal(_ values: [String: FormFieldValue]) -> String? {
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.fillFormData(inputURL: RealCorpus.acroFormFieldKinds.url, values: values)
        }
        return error?.kind
    }

    @Test func anUnknownFieldIsRefused() async throws {
        try await FormLane.run {
            #expect(refusal(["applicant.nickname": .text("Amazing Grace")]) == "unknownFormField")
            // A partial name is not a field: only the fully qualified one is.
            #expect(refusal(["name": .text("Grace")]) == "unknownFormField")
        }
    }

    @Test func aReadOnlyFieldIsRefused() async throws {
        try await FormLane.run {
            #expect(refusal(["account": .text("ACCT-9999")]) == "formFieldReadOnly")
        }
    }

    @Test func signatureAndPushButtonFieldsAreRefused() async throws {
        try await FormLane.run {
            #expect(refusal(["signature": .text("G. Hopper")]) == "formFieldNotFillable")
            #expect(refusal(["reset": .checked(true)]) == "formFieldNotFillable")
        }
    }

    /// PDFKit would write the display string into `/V`, where the export value belongs.
    @Test func aChoiceWithExportValuesIsRefused() async throws {
        try await FormLane.run {
            #expect(refusal(["size": .choice("Large")]) == "formFieldNotFillable")
            #expect(refusal(["size": .choice("l")]) == "formFieldNotFillable")
        }
    }

    @Test func aChoiceOutsideTheOptionsIsRefused() async throws {
        try await FormLane.run {
            #expect(refusal(["country": .choice("Mars")]) == "formValueNotAccepted")
            #expect(refusal(["colour": .choice("Purple")]) == "formValueNotAccepted")
        }
    }

    @Test func aRadioValueThatIsNotAnExportValueIsRefused() async throws {
        try await FormLane.run {
            #expect(refusal(["plan": .radio("platinum")]) == "formValueNotAccepted")
        }
    }

    @Test func aValueOfTheWrongKindIsRefused() async throws {
        try await FormLane.run {
            #expect(refusal(["subscribe": .text("Yes")]) == "formValueNotAccepted")
            #expect(refusal(["applicant.name": .checked(true)]) == "formValueNotAccepted")
            #expect(refusal(["country": .text("Japan")]) == "formValueNotAccepted")
        }
    }

    @Test func textLongerThanMaxLenIsRefused() async throws {
        try await FormLane.run {
            #expect(refusal(["notes": .text(String(repeating: "x", count: 201))]) == "formValueNotAccepted")
        }
    }

    @Test func nothingToDoIsRefused() async throws {
        try await FormLane.run {
            #expect(refusal([:]) == "noFormValues")
        }
    }

    @Test func oneBadValueRefusesTheWholeFill() async throws {
        try await FormLane.run {
            // Validation runs before anything changes; there is no partial result to return.
            #expect(refusal(["applicant.name": .text("Grace Hopper"), "country": .choice("Mars")]) == "formValueNotAccepted")
        }
    }
}

// MARK: - Placed items

enum FormItems {
    static let typed = FillSignItem(
        pageIndex: 0, rect: CGRect(x: 300, y: 100, width: 220, height: 24),
        content: .text(FillSignText(string: "Signed in Lisbon", fontSize: 12, red: 0, green: 0, blue: 0.6))
    )
    static let drawn = FillSignItem(
        pageIndex: 0, rect: CGRect(x: 430, y: 200, width: 150, height: 40),
        content: .signature(FillSignSignature(
            strokes: [[CGPoint(x: 0.05, y: 0.8), CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.95, y: 0.7)], [CGPoint(x: 0.6, y: 0.5)]],
            red: 0, green: 0, blue: 0, penWidthFraction: FillSignSignature.defaultPenWidthFraction
        ))
    )
}

struct FormFillItemTests {
    @Test func itemsBecomeAnnotationsAndTheFormStaysFillable() async throws {
        try await FormLane.run {
            let dir = FixtureDir()
            let data = try PDFToolkit.fillFormData(
                inputURL: RealCorpus.acroFormFieldKinds.url,
                values: ["applicant.name": .text("Grace Hopper")],
                items: [FormItems.typed, FormItems.drawn]
            )
            let doc = try #require(PDFDocument(data: data))
            let annotations = try #require(doc.page(at: 0)).annotations
            let freeText = try #require(annotations.first { $0.type == "FreeText" })
            #expect(freeText.contents == "Signed in Lisbon")
            #expect(freeText.bounds == FormItems.typed.rect)
            let ink = try #require(annotations.first { $0.type == "Ink" })
            #expect(ink.bounds == FormItems.drawn.rect)
            #expect(ink.paths?.count == 2)

            #expect(try FormFixture.hasForm(data, in: dir))
            #expect(try FormFixture.widgetCount(data) == FormFixture.widgetCount(RealCorpus.acroFormFieldKinds.data))
            #expect(try FormFixture.fields(data, in: dir)["applicant.name"]?.value == "Grace Hopper")

            // The page itself was not redrawn: its content stream is the original's byte for byte; the
            // typed text lives in the annotation until something flattens it.
            #expect(try FormFixture.pageContents(data, page: 0) == FormFixture.pageContents(RealCorpus.acroFormFieldKinds.data, page: 0))
            #expect(try FormFixture.flattenedText(data, in: dir)[0].contains("Signed in Lisbon"))
        }
    }

    /// Other readers paint the annotations' appearance streams, so those must carry the text and
    /// the strokes, in the right place.
    @Test func itemAppearancesCarryTheTextAndTheStrokes() async throws {
        try await FormLane.run {
            let data = try PDFToolkit.fillFormData(
                inputURL: RealCorpus.acroFormFieldKinds.url, values: [:], items: [FormItems.typed, FormItems.drawn]
            )
            let provider = try #require(CGDataProvider(data: data as CFData))
            let cg = try #require(CGPDFDocument(provider))
            let page = try #require(cg.page(at: 1)?.dictionary)
            var annots: CGPDFArrayRef?
            #expect(CGPDFDictionaryGetArray(page, "Annots", &annots))
            var found: [String: CGPDFDictionaryRef] = [:]
            for i in 0..<CGPDFArrayGetCount(try #require(annots)) {
                var a: CGPDFDictionaryRef?
                var subtype: UnsafePointer<CChar>?
                if CGPDFArrayGetDictionary(annots!, i, &a), let a, CGPDFDictionaryGetName(a, "Subtype", &subtype), let subtype {
                    found[String(cString: subtype)] = a
                }
            }
            func appearance(_ a: CGPDFDictionaryRef) throws -> Data {
                var ap: CGPDFDictionaryRef?
                var n: CGPDFStreamRef?
                #expect(CGPDFDictionaryGetDictionary(a, "AP", &ap))
                let dict = try #require(ap)
                #expect(CGPDFDictionaryGetStream(dict, "N", &n))
                let stream = try #require(n)
                var format = CGPDFDataFormat.raw
                return try #require(CGPDFStreamCopyData(stream, &format) as Data?)
            }
            func printable(_ a: CGPDFDictionaryRef) -> Bool {
                var flags: CGPDFInteger = 0
                return CGPDFDictionaryGetInteger(a, "F", &flags) && flags & 4 != 0
            }

            let freeText = try #require(found["FreeText"])
            #expect(RawForm.shownText(try appearance(freeText)).contains("Signed in Lisbon"))
            #expect(printable(freeText))

            let ink = try #require(found["Ink"])
            let strokes = String(decoding: try appearance(ink), as: UTF8.self)
            #expect(strokes.contains(" m ") && strokes.contains(" l ") && strokes.contains(" S"))
            #expect(printable(ink))
            // The /InkList is in page space, and every point lies inside the placed rectangle.
            var inkList: CGPDFArrayRef?
            #expect(CGPDFDictionaryGetArray(ink, "InkList", &inkList))
            let rect = FormItems.drawn.rect.insetBy(dx: -1, dy: -1)
            for s in 0..<CGPDFArrayGetCount(try #require(inkList)) {
                var stroke: CGPDFArrayRef?
                #expect(CGPDFArrayGetArray(inkList!, s, &stroke))
                let count = CGPDFArrayGetCount(try #require(stroke))
                for k in stride(from: 0, to: count - 1, by: 2) {
                    var x: CGPDFReal = 0, y: CGPDFReal = 0
                    #expect(CGPDFArrayGetNumber(stroke!, k, &x) && CGPDFArrayGetNumber(stroke!, k + 1, &y))
                    #expect(rect.contains(CGPoint(x: x, y: y)), "ink point \(x),\(y) outside \(rect)")
                }
            }
        }
    }

    /// PDFKit writes a FreeText appearance unrotated, so on a `/Rotate` page it would show sideways
    /// in every reader. Refused; a drawn signature on the same page is fine (its strokes are
    /// page-space, exactly as Fill & Sign draws them).
    @Test func typedTextOnARotatedPageIsRefusedButInkIsNot() async throws {
        try await FormLane.run {
            let rotated = try #require(try RealCorpus.rotatedCropped.document().page(at: 1))
            #expect(rotated.rotation == 90)
            let crop = rotated.bounds(for: .cropBox)
            var text = FormItems.typed
            text.pageIndex = 1
            text.rect = CGRect(x: crop.minX + 10, y: crop.minY + 10, width: 40, height: 120)
            let error = #expect(throws: PDFOperationError.self) {
                try PDFToolkit.fillFormData(inputURL: RealCorpus.rotatedCropped.url, values: [:], items: [text])
            }
            #expect(error?.kind == "textOnRotatedPage")

            var ink = FormItems.drawn
            ink.pageIndex = 1
            ink.rect = text.rect
            let data = try PDFToolkit.fillFormData(inputURL: RealCorpus.rotatedCropped.url, values: [:], items: [ink])
            let page = try #require(PDFDocument(data: data)?.page(at: 1))
            #expect(page.annotations.filter { $0.type == "Ink" }.count == 1)
            #expect(page.rotation == 90)
        }
    }

    @Test func anItemOffThePageIsRefused() async throws {
        try await FormLane.run {
            var item = FormItems.typed
            item.pageIndex = 5
            let error = #expect(throws: PDFOperationError.self) {
                try PDFToolkit.fillFormData(inputURL: RealCorpus.acroFormFieldKinds.url, values: [:], items: [item])
            }
            #expect(error?.kind == "pageOutOfBounds")
        }
    }
}
