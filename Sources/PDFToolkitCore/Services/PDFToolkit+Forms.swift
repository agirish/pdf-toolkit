import AppKit
import CoreGraphics
import Foundation
import PDFKit

// Interactive form fields: list them, and fill them IN PLACE so the result is still a fillable
// form. This is the opposite of ``PDFToolkit/fillAndSignData(inputURL:items:)``, which redraws
// every page and flattens the form into page content — right for a form nobody will touch again,
// wrong for one that is going back to whoever sent it.
//
// How each kind reaches other readers (measured on macOS 27.0.1, see README "Forms"):
// - Text and choice fields go through PDFKit, which rewrites `/V` AND regenerates each widget's
//   appearance stream with the new value — but only for widgets it was handed, so the value is set
//   on every widget of the field. A field with a widget on two pages otherwise shows the new value
//   on one page and the old one on the other.
// - Checkboxes and radio buttons do NOT go through PDFKit: its writer collapses their on/off
//   appearances and leaves `/AS` stale. They are set afterwards by ``PDFAppendedUpdate``.
// - Placed `items` become FreeText and Ink annotations, so they never flatten the page.
extension PDFToolkit {
    // MARK: - Listing

    /// Every interactive form field in the PDF at `url`, in document order (page by page, in each
    /// page's annotation order), one entry per fully qualified name with its widgets grouped under
    /// it. Read-only. Signature and push-button fields are listed but cannot be filled.
    ///
    /// Locked files throw ``PDFOperationError/encryptedInput(_:)``. A file with no form returns `[]`.
    public static func formFields(at url: URL) throws -> [FormField] {
        collectFormFields(in: try openUnlockedDocument(at: url)).map(\.field)
    }

    /// A listed field plus the PDFKit widgets that show it, for the fill path.
    struct CollectedFormField {
        var field: FormField
        var annotations: [PDFAnnotation]
    }

    static func collectFormFields(in doc: PDFDocument) -> [CollectedFormField] {
        let traits = formFieldTraits(in: doc)
        var order: [String] = []
        var byName: [String: CollectedFormField] = [:]

        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                guard let name = annotation.fieldName, !name.isEmpty else { continue }
                let isButton: Bool
                if var entry = byName[name] {
                    isButton = entry.field.kind == .checkbox || entry.field.kind == .radio
                    entry.annotations.append(annotation)
                    entry.field.widgets.append(widget(annotation, page: pageIndex, isButton: isButton))
                    if isButton, !entry.field.options.contains(annotation.buttonWidgetStateString) {
                        entry.field.options.append(annotation.buttonWidgetStateString)
                    }
                    byName[name] = entry
                    continue
                }
                let trait = traits[name] ?? FieldTraits()
                guard let kind = formFieldKind(annotation, flags: trait.flags) else { continue }
                isButton = kind == .checkbox || kind == .radio
                let isReadOnly = annotation.isReadOnly || trait.flags & readOnlyFlag != 0
                let isFillable: Bool
                switch kind {
                case .signature, .pushButton: isFillable = false
                default: isFillable = !isReadOnly && !trait.hasExportPairs
                }
                let field = FormField(
                    name: name,
                    kind: kind,
                    value: formFieldValue(annotation, kind: kind),
                    options: formFieldOptions(annotation, kind: kind),
                    isReadOnly: isReadOnly,
                    isFillable: isFillable,
                    maxLength: isText(kind) && annotation.maximumLength > 0 ? annotation.maximumLength : nil,
                    widgets: [widget(annotation, page: pageIndex, isButton: isButton)]
                )
                order.append(name)
                byName[name] = CollectedFormField(field: field, annotations: [annotation])
            }
        }
        return order.compactMap { byName[$0] }
    }

    private static func isText(_ kind: FormField.Kind) -> Bool {
        if case .text = kind { return true }
        return false
    }

    private static let readOnlyFlag = 1 << 0
    private static let comboEditFlag = 1 << 18

    private static func widget(_ annotation: PDFAnnotation, page: Int, isButton: Bool) -> FormField.Widget {
        FormField.Widget(
            pageIndex: page,
            rect: annotation.bounds,
            exportValue: isButton ? annotation.buttonWidgetStateString : nil
        )
    }

    private static func formFieldKind(_ annotation: PDFAnnotation, flags: Int) -> FormField.Kind? {
        switch annotation.widgetFieldType {
        case .text:
            return .text(multiline: annotation.isMultiline)
        case .button:
            switch annotation.widgetControlType {
            case .radioButtonControl: return .radio
            case .checkBoxControl: return .checkbox
            default: return .pushButton
            }
        case .choice:
            // PDFKit has no accessor for the editable-combo flag, so it comes from the field
            // dictionary itself (see ``formFieldTraits(in:)``). A list box cannot be editable.
            let isCombo = !annotation.isListChoice
            return .choice(isCombo: isCombo, allowsCustom: isCombo && flags & comboEditFlag != 0)
        case .signature:
            return .signature
        default:
            return nil
        }
    }

    private static func formFieldValue(_ annotation: PDFAnnotation, kind: FormField.Kind) -> String? {
        switch kind {
        case .text, .choice:
            return annotation.widgetStringValue
        case .checkbox, .radio:
            let value = annotation.widgetStringValue ?? ""
            return value.isEmpty ? "Off" : value
        case .signature, .pushButton:
            return nil
        }
    }

    private static func formFieldOptions(_ annotation: PDFAnnotation, kind: FormField.Kind) -> [String] {
        switch kind {
        case .choice: return annotation.choices ?? []
        case .checkbox, .radio: return [annotation.buttonWidgetStateString]
        case .text, .signature, .pushButton: return []
        }
    }

    /// What the field dictionaries say that PDFKit does not expose.
    struct FieldTraits {
        /// `/Ff`, inherited down the field tree.
        var flags = 0
        /// A choice field whose `/Opt` items are `[export display]` pairs. PDFKit reads and lists
        /// the DISPLAY strings and writes the display string into `/V` (measured), where the
        /// export value belongs — a silent change to the data a form submits. Such fields are
        /// listed but refused.
        var hasExportPairs = false
    }

    /// Each field's ``FieldTraits`` by fully qualified name, read from the CoreGraphics catalog.
    static func formFieldTraits(in doc: PDFDocument) -> [String: FieldTraits] {
        guard let catalog = doc.documentRef?.catalog else { return [:] }
        var acroForm: CGPDFDictionaryRef?
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm,
              CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields
        else { return [:] }

        var result: [String: FieldTraits] = [:]
        var visited = Set<Int>()
        func walk(_ array: CGPDFArrayRef, prefix: String?, inherited: Int) {
            for i in 0..<CGPDFArrayGetCount(array) {
                var node: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, i, &node), let node,
                      visited.insert(unsafeBitCast(node, to: Int.self)).inserted   // a malformed tree can loop
                else { continue }
                let name = partialName(of: node).map { part in prefix.map { "\($0).\(part)" } ?? part } ?? prefix
                var ff: CGPDFInteger = 0
                let flags = CGPDFDictionaryGetInteger(node, "Ff", &ff) ? Int(ff) : inherited
                var opt: CGPDFArrayRef?
                var first: CGPDFArrayRef?
                let pairs = CGPDFDictionaryGetArray(node, "Opt", &opt) && opt.map { CGPDFArrayGetCount($0) > 0 && CGPDFArrayGetArray($0, 0, &first) } == true
                if let name {
                    result[name] = FieldTraits(flags: flags, hasExportPairs: pairs || (result[name]?.hasExportPairs ?? false))
                }
                var kids: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
                    walk(kids, prefix: name, inherited: flags)
                }
            }
        }
        walk(fields, prefix: nil, inherited: 0)
        return result
    }

    private static func partialName(of dict: CGPDFDictionaryRef) -> String? {
        var string: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dict, "T", &string), let string,
              let text = CGPDFStringCopyTextString(string) else { return nil }
        return text as String
    }

    /// A widget's fully qualified field name, from its own `/T` and its ancestors'.
    static func fullyQualifiedName(of widget: CGPDFDictionaryRef) -> String? {
        var parts: [String] = []
        var node: CGPDFDictionaryRef? = widget
        var depth = 0
        while let current = node, depth < 64 {
            if let part = partialName(of: current) { parts.append(part) }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
            depth += 1
        }
        return parts.isEmpty ? nil : parts.reversed().joined(separator: ".")
    }

    // MARK: - Filling

    /// Fills form fields in place and returns the new file's bytes, with the form still fillable.
    ///
    /// - `values` is keyed by fully qualified field name (``FormField/name``). Every value is
    ///   checked before anything is changed: an unknown name, a read-only field, a signature or
    ///   push-button field, a choice whose items have separate export values (see
    ///   ``FormField/isFillable``), a value of the wrong kind, a choice outside the field's
    ///   options (unless the field allows custom values), a radio value that is not one of its
    ///   export values, or text longer than the field's `/MaxLen` each throw — nothing is skipped
    ///   silently.
    /// - `items` are placed text and drawn signatures, added as FreeText and Ink annotations rather
    ///   than drawn into the page, so they too leave the form fillable. Typed text on a page with a
    ///   `/Rotate` throws ``PDFOperationError/textOnRotatedPage(pageNumber:)``: PDFKit would write
    ///   it sideways.
    ///
    /// The file is opened from `inputURL` and mutated in place, so everything else it carries — the
    /// catalog `/AcroForm`, its widgets, the outline, links, XMP and Info, and any encryption —
    /// survives. A file whose owner permissions forbid form entry throws
    /// ``PDFOperationError/permissionsForbidEditing(_:)``; so does one that forbids annotations when
    /// `items` is not empty. Many forms restrict editing but allow filling, so the check is
    /// `allowsFormFieldEntry`, not `allowsDocumentAssembly`.
    ///
    /// The result is reopened and read back before it is returned: every value must be there,
    /// every button in the right state, and the form, its widget count and the added items intact.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func fillFormData(
        inputURL: URL,
        values: [String: FormFieldValue],
        items: [FillSignItem] = []
    ) throws -> Data {
        let inked = items.filter(\.hasInk)
        guard !values.isEmpty || !inked.isEmpty else { throw PDFOperationError.noFormValues }

        let doc = try openUnlockedDocument(at: inputURL)
        guard doc.pageCount > 0 else { throw PDFOperationError.emptyPDF }
        // PDFKit silently ignores a field change or a new annotation the permissions forbid (it only
        // logs), so refuse up front, as ``openEditableDocument(at:)`` does for page edits. The
        // read-back below is the second line of defence.
        if !values.isEmpty {
            guard !doc.isEncrypted || doc.allowsFormFieldEntry else {
                throw PDFOperationError.permissionsForbidEditing(inputURL)
            }
        }
        if !inked.isEmpty {
            guard !doc.isEncrypted || doc.allowsCommenting else {
                throw PDFOperationError.permissionsForbidEditing(inputURL)
            }
            for item in inked {
                guard item.pageIndex >= 0, item.pageIndex < doc.pageCount, let page = doc.page(at: item.pageIndex) else {
                    throw PDFOperationError.pageOutOfBounds(item.pageIndex + 1)
                }
                // PDFKit writes a FreeText appearance in unrotated page space, with no `/Matrix` and
                // no `/Rotate`, so on a rotated page every reader shows the text turned with the
                // page — sideways, where Fill & Sign bakes it upright. Refused rather than written
                // wrong. Ink is unaffected: its strokes are page-space, as Fill & Sign draws them.
                if item.isText, normalizedRotation(page.rotation) != 0 {
                    throw PDFOperationError.textOnRotatedPage(pageNumber: item.pageIndex + 1)
                }
            }
        }

        let fields = collectFormFields(in: doc)
        let byName = Dictionary(fields.map { ($0.field.name, $0) }, uniquingKeysWith: { first, _ in first })
        let widgetCount = fields.reduce(0) { $0 + $1.annotations.count }
        let hadForm = hasInteractiveForm(doc)

        // Validate everything before changing anything, in a stable order so the same bad input
        // always reports the same field.
        var plan: [(field: FormField, value: FormFieldValue)] = []
        for name in values.keys.sorted() {
            guard let entry = byName[name] else { throw PDFOperationError.unknownFormField(name) }
            try validate(values[name]!, for: entry.field)
            plan.append((entry.field, values[name]!))
        }

        var buttonStates: [String: String] = [:]
        for (field, value) in plan {
            switch value {
            case .text(let string), .choice(let string):
                // EVERY widget: PDFKit regenerates the appearance only of the widgets it is handed.
                for annotation in byName[field.name]!.annotations {
                    annotation.widgetStringValue = string
                }
            case .checked(let on):
                buttonStates[field.name] = on ? (field.options.first ?? "Yes") : "Off"
            case .radio(let export):
                buttonStates[field.name] = export
            }
        }

        // Counted BEFORE adding: PDFKit drops an annotation it is not allowed to add without a word,
        // so the in-memory document cannot be asked afterwards.
        var expectedItems = itemAnnotationCounts(in: doc)
        for item in inked {
            doc.page(at: item.pageIndex)?.addAnnotation(formItemAnnotation(item))
            expectedItems[item.pageIndex, default: 0] += 1
        }

        guard var data = doc.dataRepresentation() else { throw PDFOperationError.couldNotEncodeOutput }
        if !buttonStates.isEmpty {
            data = try settingButtonStates(buttonStates, in: data)
        }

        try verifyFilledForm(
            data, plan: plan, buttonStates: buttonStates,
            hadForm: hadForm, widgetCount: widgetCount,
            expectedItems: inked.isEmpty ? [:] : expectedItems
        )
        return data
    }

    private static func validate(_ value: FormFieldValue, for field: FormField) throws {
        switch field.kind {
        case .signature, .pushButton: throw PDFOperationError.formFieldNotFillable(field.name)
        default: break
        }
        guard !field.isReadOnly else { throw PDFOperationError.formFieldReadOnly(field.name) }
        guard field.isFillable else { throw PDFOperationError.formFieldNotFillable(field.name) }

        switch (field.kind, value) {
        case (.text, .text(let string)):
            if let max = field.maxLength, string.count > max {
                throw PDFOperationError.formValueNotAccepted(field: field.name, value: string)
            }
        case (.checkbox, .checked):
            break
        case (.radio, .radio(let export)):
            guard field.options.contains(export) else {
                throw PDFOperationError.formValueNotAccepted(field: field.name, value: export)
            }
        case (.choice(_, let allowsCustom), .choice(let choice)):
            guard allowsCustom || field.options.contains(choice) else {
                throw PDFOperationError.formValueNotAccepted(field: field.name, value: choice)
            }
        default:
            throw PDFOperationError.formValueNotAccepted(field: field.name, value: describe(value))
        }
    }

    private static func describe(_ value: FormFieldValue) -> String {
        switch value {
        case .text(let s), .radio(let s), .choice(let s): return s
        case .checked(let on): return on ? "checked" : "unchecked"
        }
    }

    /// A placed item as an annotation: typed text as FreeText (PDFKit writes its appearance stream
    /// with the text in it), a drawn signature as Ink built from the same normalized strokes Fill &
    /// Sign strokes, with the same pen width and round caps.
    static func formItemAnnotation(_ item: FillSignItem) -> PDFAnnotation {
        let rect = item.rect
        switch item.content {
        case .text(let text):
            let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            annotation.contents = text.string
            annotation.font = scriptOrSystemFont(size: max(4, text.fontSize), script: text.isScript)
            annotation.fontColor = NSColor(srgbRed: text.red, green: text.green, blue: text.blue, alpha: 1)
            annotation.color = .clear
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            annotation.shouldPrint = true
            return annotation
        case .signature(let signature):
            let annotation = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
            let lineWidth = max(0.4, signature.penWidthFraction * min(rect.width, rect.height))
            for stroke in signature.strokes where !stroke.isEmpty {
                // Ink paths are in the annotation's own space: page points less the rect's origin.
                let points = stroke.map { normalized -> CGPoint in
                    let p = FillSignGeometry.pagePoint(normalized: normalized, in: rect)
                    return CGPoint(x: p.x - rect.minX, y: p.y - rect.minY)
                }
                let path = NSBezierPath()
                path.move(to: points[0])
                if points.count == 1 {
                    // A tap has no length; a hair-long segment with round caps draws the dot.
                    path.line(to: CGPoint(x: points[0].x + 0.01, y: points[0].y))
                } else {
                    for p in points.dropFirst() { path.line(to: p) }
                }
                annotation.add(path)
            }
            annotation.color = NSColor(srgbRed: signature.red, green: signature.green, blue: signature.blue, alpha: 1)
            let border = PDFBorder()
            border.lineWidth = lineWidth
            annotation.border = border
            annotation.shouldPrint = true
            return annotation
        }
    }

    /// How many FreeText and Ink annotations each page carries.
    private static func itemAnnotationCounts(in doc: PDFDocument) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for i in 0..<doc.pageCount {
            counts[i] = (doc.page(at: i)?.annotations ?? []).filter { $0.type == "FreeText" || $0.type == "Ink" }.count
        }
        return counts
    }

    /// Sets each named button field to `state` — an export value, or `Off` — by rewriting its
    /// widgets' `/AS` and its `/V` as names in an appended update (see ``PDFAppendedUpdate``).
    /// Every widget whose appearance dictionary has that state is turned on; every other widget
    /// of the field is turned off.
    static func settingButtonStates(_ states: [String: String], in data: Data) throws -> Data {
        do {
            var update = try PDFAppendedUpdate(data)
            guard let provider = CGDataProvider(data: data as CFData), let cg = CGPDFDocument(provider) else {
                throw PDFOperationError.couldNotEncodeOutput
            }
            if cg.isEncrypted, !cg.isUnlocked { _ = cg.unlockWithPassword("") }
            let pages = try update.pageObjects()
            guard pages.count == cg.numberOfPages else { throw PDFOperationError.couldNotEncodeOutput }

            var unset = Set(states.keys)
            for (index, pageObject) in pages.enumerated() {
                guard let pageDict = cg.page(at: index + 1)?.dictionary else { continue }
                var annots: CGPDFArrayRef?
                guard CGPDFDictionaryGetArray(pageDict, "Annots", &annots), let annots else { continue }
                let objects = try update.annotationObjects(ofPage: pageObject)
                // The raw `/Annots` and CoreGraphics' are the same array of the same bytes, so
                // position i names the same annotation in both.
                guard objects.count == CGPDFArrayGetCount(annots) else { throw PDFOperationError.couldNotEncodeOutput }

                for i in 0..<objects.count {
                    var widget: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(annots, i, &widget), let widget,
                          let name = fullyQualifiedName(of: widget), let state = states[name]
                    else { continue }
                    let onStates = appearanceStates(of: widget).filter { $0 != "Off" }
                    // A widget with no state dictionary has nothing to choose between; it follows
                    // the field.
                    let isOn = onStates.isEmpty ? state != "Off" : onStates.contains(state)
                    let object = objects[i]
                    update.setName("AS", to: isOn ? state : "Off", inObject: object)

                    // `/V` belongs to the field: the widget itself when it carries the name, else
                    // the nearest ancestor that does.
                    var field = object
                    var hops = 0
                    while try !update.hasKey("T", inObject: field), let parent = try update.parent(of: field), hops < 64 {
                        field = parent
                        hops += 1
                    }
                    update.setName("V", to: state, inObject: field)
                    if field != object, try update.hasKey("V", inObject: object) {
                        update.setName("V", to: state, inObject: object)
                    }
                    unset.remove(name)
                }
            }
            // PDFKit on macOS 26 writes each widget TWICE — once where the page's `/Annots` points,
            // once more under the `/AcroForm` field tree — and reads a field back from the tree
            // (measured on the hosted macos-26 runner, 26.6.2). macOS 27 writes one object, reached
            // both ways. So the field tree is walked too, and every copy is set the same way.
            if let catalog = cg.catalog {
                var acroForm: CGPDFDictionaryRef?
                var fields: CGPDFArrayRef?
                if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm,
                   CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields {
                    var visited = Set<Int>()
                    func walk(_ objects: [Int], _ nodes: CGPDFArrayRef, prefix: String?) throws {
                        // The raw array and CoreGraphics' are the same bytes, so position i
                        // names the same node in both.
                        guard objects.count == CGPDFArrayGetCount(nodes) else {
                            throw PDFOperationError.couldNotEncodeOutput
                        }
                        for (i, object) in objects.enumerated() where visited.insert(object).inserted {
                            var node: CGPDFDictionaryRef?
                            guard CGPDFArrayGetDictionary(nodes, i, &node), let node else { continue }
                            let partial = partialName(of: node)
                            let name = partial.map { p in prefix.map { "\($0).\(p)" } ?? p } ?? prefix
                            if let name, let state = states[name] {
                                if try partial != nil || update.hasKey("V", inObject: object) {
                                    update.setName("V", to: state, inObject: object)
                                }
                                var subtype: UnsafePointer<CChar>?
                                if CGPDFDictionaryGetName(node, "Subtype", &subtype), let subtype,
                                   String(cString: subtype) == "Widget" {
                                    let onStates = appearanceStates(of: node).filter { $0 != "Off" }
                                    let isOn = onStates.isEmpty ? state != "Off" : onStates.contains(state)
                                    update.setName("AS", to: isOn ? state : "Off", inObject: object)
                                }
                            }
                            var kids: CGPDFArrayRef?
                            if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
                                try walk(try update.kids(of: object), kids, prefix: name)
                            }
                        }
                    }
                    try walk(try update.formFieldObjects(), fields, prefix: nil)
                }
            }

            if let missing = unset.sorted().first { throw PDFOperationError.formFillFailed(missing) }
            return try update.appended()
        } catch is PDFAppendedUpdate.Failure {
            throw PDFOperationError.couldNotEncodeOutput
        }
    }

    /// The state names in a widget's normal appearance dictionary (`/AP /N`), e.g. `Yes`, `Off`.
    static func appearanceStates(of widget: CGPDFDictionaryRef) -> [String] {
        var ap: CGPDFDictionaryRef?
        var normal: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(widget, "AP", &ap), let ap,
              CGPDFDictionaryGetDictionary(ap, "N", &normal), let normal else { return [] }
        var names: [String] = []
        CGPDFDictionaryApplyBlock(normal, { key, _, _ in
            names.append(String(cString: key))
            return true
        }, nil)
        return names
    }

    /// Reopens the result and confirms the fill actually landed — the rotate/delete rule: PDFKit
    /// reports a declined change only to the console, so trust nothing until it is read back.
    private static func verifyFilledForm(
        _ data: Data,
        plan: [(field: FormField, value: FormFieldValue)],
        buttonStates: [String: String],
        hadForm: Bool,
        widgetCount: Int,
        expectedItems: [Int: Int]
    ) throws {
        guard let reopened = PDFDocument(data: data), !reopened.isLocked else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        let after = Dictionary(
            collectFormFields(in: reopened).map { ($0.field.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (field, value) in plan {
            guard let entry = after[field.name] else { throw PDFOperationError.formFillFailed(field.name) }
            switch value {
            case .text(let string), .choice(let string):
                guard entry.annotations.allSatisfy({ $0.widgetStringValue == string }) else {
                    throw PDFOperationError.formFillFailed(field.name)
                }
            case .checked, .radio:
                let state = buttonStates[field.name]!
                guard entry.field.value == state,
                      entry.annotations.allSatisfy({
                          ($0.buttonWidgetState == .onState) == ($0.buttonWidgetStateString == state)
                      })
                else { throw PDFOperationError.formFillFailed(field.name) }
            }
        }
        // Nothing else about the form may have changed: still a real form, same widgets.
        guard hasInteractiveForm(reopened) == hadForm,
              after.values.reduce(0, { $0 + $1.annotations.count }) == widgetCount
        else { throw PDFOperationError.couldNotEncodeOutput }
        // And every placed item is there as an annotation.
        if !expectedItems.isEmpty, itemAnnotationCounts(in: reopened) != expectedItems {
            throw PDFOperationError.fillSignFailed
        }
    }
}
