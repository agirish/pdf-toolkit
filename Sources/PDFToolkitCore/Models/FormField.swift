import CoreGraphics
import Foundation

/// One interactive form field, as ``PDFToolkit/formFields(at:)`` reads it: the field's fully
/// qualified name, what kind of control it is, its current value, and every widget that shows it.
public struct FormField: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A text box. `multiline` fields accept line breaks.
        case text(multiline: Bool)
        case checkbox
        case radio
        /// A combo box (`isCombo`, one line with a pop-up) or a list box. `allowsCustom` is the
        /// editable-combo flag: the field accepts a value that is not one of its ``FormField/options``.
        case choice(isCombo: Bool, allowsCustom: Bool)
        /// Listed but never filled here — signing is a separate act.
        case signature
        /// Listed but never filled here — a push button has no value.
        case pushButton
    }

    /// One place the field appears. A field can have several: the same name on two pages, or one
    /// widget per radio choice.
    public struct Widget: Hashable, Sendable {
        /// Zero-based page index.
        public var pageIndex: Int
        /// The widget's rectangle in its page's PDF user space (y-up) — the same space as
        /// ``FillSignItem/rect``.
        public var rect: CGRect
        /// For a checkbox or radio widget, the value that turns THIS widget on (its "on" appearance
        /// state, such as `Yes` or `plus`); nil for every other kind.
        public var exportValue: String?

        public init(pageIndex: Int, rect: CGRect, exportValue: String? = nil) {
            self.pageIndex = pageIndex
            self.rect = rect
            self.exportValue = exportValue
        }
    }

    /// The fully qualified field name — the partial names of the field and its ancestors joined by
    /// periods, e.g. `topmostSubform[0].Page1[0].f1_1[0]`. This is the key ``FormFieldValue``s are
    /// addressed by.
    public var name: String
    public var kind: Kind
    /// The current value: the text, the selected choice, or for a checkbox or radio group the
    /// export value that is on (`Off` when none is). Nil for signature and push-button fields.
    public var value: String?
    /// A choice field's items, or the export values of a radio group's widgets in document order,
    /// or a checkbox's single on value. Empty for text, signature and push-button fields.
    public var options: [String]
    public var isReadOnly: Bool
    /// Whether ``PDFToolkit/fillFormData(inputURL:values:items:)`` will fill this field. False for
    /// signature and push-button fields, read-only fields, and choice fields whose items are
    /// `[export display]` pairs: PDFKit lists those by their display text and would write the
    /// display text where the export value belongs, so they are refused rather than changed wrongly.
    public var isFillable: Bool
    /// The text field's `/MaxLen`, or nil when it has none.
    public var maxLength: Int?
    public var widgets: [Widget]

    public init(
        name: String,
        kind: Kind,
        value: String?,
        options: [String] = [],
        isReadOnly: Bool = false,
        isFillable: Bool = true,
        maxLength: Int? = nil,
        widgets: [Widget]
    ) {
        self.name = name
        self.kind = kind
        self.value = value
        self.options = options
        self.isReadOnly = isReadOnly
        self.isFillable = isFillable
        self.maxLength = maxLength
        self.widgets = widgets
    }
}

/// A value to put in one field with ``PDFToolkit/fillFormData(inputURL:values:items:)``. The case
/// must match the field's ``FormField/Kind``; a mismatch is refused, never coerced.
public enum FormFieldValue: Hashable, Sendable {
    /// For a text field.
    case text(String)
    /// For a checkbox: on (its export value) or `Off`.
    case checked(Bool)
    /// For a radio group: the export value of the widget to turn on (one of ``FormField/options``).
    case radio(String)
    /// For a combo or list box: one of ``FormField/options``, or any string when the field
    /// ``FormField/Kind/choice(isCombo:allowsCustom:)`` allows custom values.
    case choice(String)
}
