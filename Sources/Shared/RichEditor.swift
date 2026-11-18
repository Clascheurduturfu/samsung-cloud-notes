import SwiftUI
#if os(macOS)
import AppKit
typealias RichFont = NSFont
typealias RichColor = NSColor
typealias RichImage = NSImage
#else
import UIKit
typealias RichFont = UIFont
typealias RichColor = UIColor
typealias RichImage = UIImage
#endif

/// One editor for Samsung rich text: the text is edited as plain text and every
/// keystroke re-applies the note's formatting through `RichText.withText`, so what
/// is shown is what will be saved. Bullets, numbers and checkboxes are drawn in the
/// paragraph indent (they are not part of the text); checkboxes can be clicked.
enum RichStyler {
    static let indentStep: CGFloat = 22
    static let markerWidth: CGFloat = 24

    struct Marker { var location: Int; var marker: RichMarker; var indent: CGFloat; var paragraph: Int }

    static var textColor: RichColor {
        #if os(macOS)
        .textColor
        #else
        .label
        #endif
    }
    static var secondaryColor: RichColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    static func baseAttributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: RichFont.systemFont(ofSize: size), .foregroundColor: textColor]
    }

    static func font(size: CGFloat, bold: Bool, italic: Bool) -> RichFont {
        let base = RichFont.systemFont(ofSize: size)
        #if os(macOS)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return traits.isEmpty ? base : NSFontManager.shared.convert(base, toHaveTrait: traits)
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return RichFont(descriptor: descriptor, size: size)
        #endif
    }

    static func color(_ argb: UInt32) -> RichColor {
        RichColor(red: CGFloat((argb >> 16) & 0xff) / 255, green: CGFloat((argb >> 8) & 0xff) / 255,
                  blue: CGFloat(argb & 0xff) / 255, alpha: CGFloat(argb >> 24) / 255)
    }

    /// Restyles `storage` in place (characters untouched, so selection and undo survive).
    /// `rich` must describe exactly `storage.string`; otherwise the text is shown plain.
    @discardableResult
    static func apply(_ rich: RichText?, to storage: NSTextStorage, baseSize: CGFloat) -> [Marker] {
        let length = storage.length
        storage.beginEditing(); defer { storage.endEditing() }
        storage.setAttributes(baseAttributes(baseSize), range: NSRange(location: 0, length: length))
        guard let rich, rich.text.utf16.count == length, rich.text == storage.string else { return [] }
        var markers: [Marker] = []
        var position = 0
        for (index, paragraph) in rich.previewParagraphs().enumerated() {
            if index > 0 { position += 1 } // the paragraph's leading line break
            let contentStart = position
            for segment in paragraph.segments {
                let count = segment.text.utf16.count
                guard position + count <= length else { return markers }
                storage.addAttributes(attributes(segment, checked: paragraph.checked, baseSize: baseSize), range: NSRange(location: position, length: count))
                position += count
            }
            let indent = CGFloat(paragraph.indent) * indentStep
            let lead = indent + (paragraph.marker == .plain ? 0 : markerWidth)
            let style = NSMutableParagraphStyle()
            style.alignment = paragraph.alignment == 2 ? .center : paragraph.alignment == 1 ? .right : paragraph.alignment == 3 ? .justified : .natural
            style.firstLineHeadIndent = lead; style.headIndent = lead
            style.paragraphSpacing = 2
            let end = min(position + 1, length) // Cocoa paragraphs own their trailing line break
            if end > contentStart { storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: contentStart, length: end - contentStart)) }
            if paragraph.marker != .plain { markers.append(Marker(location: contentStart, marker: paragraph.marker, indent: indent, paragraph: index)) }
        }
        return markers
    }

    static func attributes(_ segment: RichSegment, checked: Bool, baseSize: CGFloat) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: font(size: segment.size.map { CGFloat($0) * baseSize / 15 } ?? baseSize, bold: segment.bold, italic: segment.italic),
            .foregroundColor: checked ? secondaryColor : segment.color.map(color) ?? textColor,
        ]
        if let highlight = segment.highlight { result[.backgroundColor] = color(highlight) }
        if segment.underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        // Samsung strikes through and greys out completed checklist items.
        if segment.strikethrough || checked { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return result
    }
}

/// Samsung pictures and tables shown in place of their U+FFFC anchors. Only display
/// attributes change; the text, and so what is saved, stays the same.
enum RichObjects {
    static let maxWidth: CGFloat = 420, maxHeight: CGFloat = 520

    static func attachment(_ object: NoteObject, baseSize: CGFloat) -> NSTextAttachment? {
        let attachment = NSTextAttachment()
        switch object {
        case .image(let data):
            guard let image = RichImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
            attachment.image = image
            let scale = min(1, maxWidth / image.size.width, maxHeight / image.size.height)
            attachment.bounds = CGRect(x: 0, y: 0, width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        case .table(let rows):
            guard let image = table(rows, size: baseSize) else { return nil }
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: image.size)
        }
        return attachment
    }

    /// Attaches the objects to each anchored U+FFFC of `rich` (which must describe `storage`).
    static func apply(_ rich: RichText?, to storage: NSTextStorage, attachments: [String: NSTextAttachment]) {
        guard let rich, !attachments.isEmpty, rich.text == storage.string else { return }
        let units = Array(rich.text.utf16)
        let positions = units.indices.filter { units[$0] == 0xFFFC }
        storage.beginEditing(); defer { storage.endEditing() }
        for (position, id) in zip(positions, SamsungAttachments.anchors(rich)) {
            guard let id, let attachment = attachments[id] else { continue }
            storage.addAttribute(.attachment, value: attachment, range: NSRange(location: position, length: 1))
        }
    }

    /// A grid with each cell's text, sized to its content (wide tables wrap).
    static func table(_ rows: [[String]], size: CGFloat) -> RichImage? {
        let width = rows.map(\.count).max() ?? 0
        guard !rows.isEmpty, width > 0 else { return nil }
        let font = RichFont.systemFont(ofSize: size)
        let padH: CGFloat = 8, padV: CGFloat = 5
        func measure(_ text: String, _ limit: CGFloat) -> CGSize {
            let rect = ((text.isEmpty ? " " : text) as NSString).boundingRect(with: CGSize(width: limit, height: .greatestFiniteMagnitude),
                                                                              options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil)
            return CGSize(width: ceil(rect.width), height: ceil(rect.height))
        }
        var columns = (0..<width).map { c in (rows.map { c < $0.count ? measure($0[c], 10_000).width : 0 }.max() ?? 0) + 2 * padH }
        columns = columns.map { min(max($0, 44), 260) }
        let total = columns.reduce(0, +)
        if total > maxWidth { columns = columns.map { max(44, ($0 * maxWidth / total).rounded(.down)) } }
        let heights = rows.map { row in ((0..<width).map { c in measure(c < row.count ? row[c] : "", columns[c] - 2 * padH).height }.max() ?? 0) + 2 * padV }
        let size = CGSize(width: columns.reduce(0, +) + 1, height: heights.reduce(0, +) + 1)
        func draw(_ context: CGContext, line: RichColor, text: RichColor) {
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            context.setStrokeColor(line.cgColor); context.setLineWidth(1)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil)); context.strokePath()
            var x: CGFloat = 0.5
            for column in columns.dropLast() { x += column; context.move(to: CGPoint(x: x, y: 0.5)); context.addLine(to: CGPoint(x: x, y: size.height - 0.5)) }
            var y: CGFloat = 0.5
            for height in heights.dropLast() { y += height; context.move(to: CGPoint(x: 0.5, y: y)); context.addLine(to: CGPoint(x: size.width - 0.5, y: y)) }
            context.strokePath()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
            y = 0
            for (r, row) in rows.enumerated() {
                x = 0
                for c in 0..<width {
                    let cell = CGRect(x: x + padH, y: y + padV, width: columns[c] - 2 * padH, height: heights[r] - 2 * padV)
                    NSAttributedString(string: c < row.count ? row[c] : "", attributes: attributes).draw(with: cell, options: [.usesLineFragmentOrigin], context: nil)
                    x += columns[c]
                }
                y += heights[r]
            }
        }
        #if os(macOS)
        // Drawn on demand, so the colours follow light and dark mode.
        return NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(context, line: .separatorColor, text: .textColor)
            return true
        }
        #else
        return UIGraphicsImageRenderer(size: size).image { draw($0.cgContext, line: .separator, text: .label) }
        #endif
    }
}

/// Draws list markers in the paragraph indent and hit-tests checkboxes.
final class RichLayoutManager: NSLayoutManager {
    var markers: [RichStyler.Marker] = []
    var baseSize: CGFloat = 15

    private func lineRect(_ marker: RichStyler.Marker) -> (CGRect, CGFloat)? {
        guard let storage = textStorage else { return nil }
        let font = RichFont.systemFont(ofSize: baseSize)
        if marker.location >= storage.length {
            let rect = extraLineFragmentRect
            return rect.height > 0 ? (rect, font.ascender) : nil
        }
        let glyph = glyphIndexForCharacter(at: marker.location)
        let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (rect, location(forGlyphAt: glyph).y)
    }

    /// Marker box in text-container coordinates.
    func markerRect(_ marker: RichStyler.Marker) -> CGRect? {
        guard let (line, _) = lineRect(marker), let container = textContainers.first else { return nil }
        return CGRect(x: line.minX + container.lineFragmentPadding + marker.indent, y: line.minY, width: RichStyler.markerWidth, height: line.height)
    }

    func checkbox(at point: CGPoint) -> Int? {
        for marker in markers {
            guard case .checkbox = marker.marker, let rect = markerRect(marker), rect.insetBy(dx: -4, dy: -2).contains(point) else { continue }
            return marker.paragraph
        }
        return nil
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        let font = RichFont.systemFont(ofSize: baseSize)
        for marker in markers {
            guard let (line, baseline) = lineRect(marker), let box = markerRect(marker) else { continue }
            let rect = box.offsetBy(dx: origin.x, dy: origin.y)
            let top = line.minY + origin.y + baseline - font.ascender
            switch marker.marker {
            case .plain: break
            case .bullet, .number:
                let label: String
                if case .number(let value) = marker.marker { label = "\(value)." } else { label = "•" }
                let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: RichStyler.secondaryColor])
                let width = text.size().width
                text.draw(at: CGPoint(x: rect.maxX - 6 - width, y: top))
            case .checkbox(let checked):
                let side = (baseSize * 0.95).rounded()
                let centreY = line.minY + origin.y + baseline - font.capHeight / 2
                let square = CGRect(x: rect.minX, y: centreY - side / 2, width: side, height: side)
                drawCheckbox(square, checked: checked)
            }
        }
    }

    private func drawCheckbox(_ rect: CGRect, checked: Bool) {
        #if os(macOS)
        let accent = NSColor.controlAccentColor
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.3
        if checked { accent.setFill(); path.fill() } else { NSColor.tertiaryLabelColor.setStroke(); path.stroke() }
        guard checked else { return }
        let tick = NSBezierPath()
        tick.lineWidth = 1.6; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
        // Flipped view: y grows downwards.
        tick.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.52))
        tick.line(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
        tick.line(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.34))
        NSColor.white.setStroke(); tick.stroke()
        #else
        let accent = UIColor.tintColor
        let path = UIBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.3
        if checked { accent.setFill(); path.fill() } else { UIColor.tertiaryLabel.setStroke(); path.stroke() }
        guard checked else { return }
        let tick = UIBezierPath()
        tick.lineWidth = 1.6; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
        tick.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.52))
        tick.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
        tick.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.34))
        UIColor.white.setStroke(); tick.stroke()
        #endif
    }
}

/// Shared editing state between the platform text view and SwiftUI.
class RichEditorCoordinator: NSObject {
    var text: Binding<String>
    var rich: RichText?
    var baseSize: CGFloat
    var onToggle: (Int) -> Void
    /// Pictures and tables by Samsung object id.
    var objects: [String: NoteObject] = [:] {
        didSet { if objects != oldValue { attachments = [:]; objectsChanged = true } }
    }
    private var attachments: [String: NSTextAttachment] = [:]
    private var objectsChanged = false
    let storage = NSTextStorage()
    let layout = RichLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private var styled: (text: String, rich: RichText?)?

    init(text: Binding<String>, rich: RichText?, baseSize: CGFloat, onToggle: @escaping (Int) -> Void) {
        self.text = text; self.rich = rich; self.baseSize = baseSize; self.onToggle = onToggle
        super.init()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.baseSize = baseSize
    }

    /// Re-applies formatting when the text or its formatting changed.
    func restyle(force: Bool = false) {
        let current = storage.string
        if !force, !objectsChanged, let styled, styled.text == current, styled.rich == rich { return }
        let display = rich.map { $0.withText(current) }
        layout.markers = RichStyler.apply(display, to: storage, baseSize: baseSize)
        if attachments.isEmpty {
            for (id, object) in objects { attachments[id] = RichObjects.attachment(object, baseSize: baseSize) }
        }
        RichObjects.apply(display, to: storage, attachments: attachments)
        layout.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        styled = (current, rich); objectsChanged = false
    }

    /// Replaces the whole text when it changed outside the editor (another note, a reload).
    func sync(text newText: String) -> Bool {
        guard storage.string != newText else { return false }
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        return true
    }
}

#if os(macOS)
final class RichNSTextView: NSTextView {
    var onToggle: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        if isEditable, let layout = layoutManager as? RichLayoutManager, let paragraph = layout.checkbox(at: local) {
            onToggle?(paragraph); return
        }
        super.mouseDown(with: event)
    }
    // Pasting keeps only text; the note's formatting is applied by the editor.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    var rich: RichText?
    var editable: Bool
    var baseSize: CGFloat = 15
    var objects: [String: NoteObject] = [:]
    var onToggle: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, rich: rich, baseSize: baseSize, onToggle: onToggle) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.objects = objects
        coordinator.container.widthTracksTextView = true
        let view = RichNSTextView(frame: .zero, textContainer: coordinator.container)
        view.delegate = coordinator
        view.isRichText = true; view.importsGraphics = false; view.usesFontPanel = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 10, height: 12)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.onToggle = { paragraph in coordinator.onToggle(paragraph) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = view
        _ = coordinator.sync(text: text)
        coordinator.restyle(force: true)
        view.typingAttributes = RichStyler.baseAttributes(baseSize)
        view.isEditable = editable
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text; coordinator.onToggle = onToggle; coordinator.baseSize = baseSize
        coordinator.layout.baseSize = baseSize
        coordinator.objects = objects
        guard let view = scroll.documentView as? RichNSTextView else { return }
        view.isEditable = editable
        let replaced = coordinator.sync(text: text)
        coordinator.rich = rich
        if replaced { view.setSelectedRange(NSRange(location: 0, length: 0)); view.undoManager?.removeAllActions() }
        if !view.hasMarkedText() { coordinator.restyle(force: replaced) }
        view.needsDisplay = true
    }

    final class Coordinator: RichEditorCoordinator, NSTextViewDelegate {
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if text.wrappedValue != view.string { text.wrappedValue = view.string }
            if !view.hasMarkedText() { restyle(); view.needsDisplay = true }
            view.typingAttributes = RichStyler.baseAttributes(baseSize)
        }
    }
}
#else
final class RichUITextView: UITextView, UIGestureRecognizerDelegate {
    var onToggle: ((Int) -> Void)?
    lazy var checkboxTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        return tap
    }()
    private func paragraph(at recognizer: UIGestureRecognizer) -> Int? {
        guard isEditable, let layout = layoutManager as? RichLayoutManager else { return nil }
        let point = recognizer.location(in: self)
        return layout.checkbox(at: CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top))
    }
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === checkboxTap { return paragraph(at: recognizer) != nil }
        return super.gestureRecognizerShouldBegin(recognizer)
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if let paragraph = paragraph(at: recognizer) { onToggle?(paragraph) }
    }
}

struct RichTextEditor: UIViewRepresentable {
    @Binding var text: String
    var rich: RichText?
    var editable: Bool
    var baseSize: CGFloat = 17
    var objects: [String: NoteObject] = [:]
    var onToggle: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, rich: rich, baseSize: baseSize, onToggle: onToggle) }

    func makeUIView(context: Context) -> RichUITextView {
        let coordinator = context.coordinator
        coordinator.objects = objects
        coordinator.container.widthTracksTextView = true
        let view = RichUITextView(frame: .zero, textContainer: coordinator.container)
        view.delegate = coordinator
        view.backgroundColor = .clear
        view.smartQuotesType = .no; view.smartDashesType = .no
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.addGestureRecognizer(view.checkboxTap)
        view.onToggle = { paragraph in coordinator.onToggle(paragraph) }
        _ = coordinator.sync(text: text)
        coordinator.restyle(force: true)
        view.typingAttributes = RichStyler.baseAttributes(baseSize)
        view.isEditable = editable
        return view
    }

    func updateUIView(_ view: RichUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text; coordinator.onToggle = onToggle; coordinator.baseSize = baseSize
        coordinator.layout.baseSize = baseSize
        coordinator.objects = objects
        view.isEditable = editable
        let replaced = coordinator.sync(text: text)
        coordinator.rich = rich
        if replaced { view.selectedRange = NSRange(location: 0, length: 0); view.undoManager?.removeAllActions() }
        if view.markedTextRange == nil { coordinator.restyle(force: replaced) }
        view.setNeedsDisplay()
    }

    final class Coordinator: RichEditorCoordinator, UITextViewDelegate {
        func textViewDidChange(_ view: UITextView) {
            if text.wrappedValue != view.text { text.wrappedValue = view.text }
            if view.markedTextRange == nil { restyle(); view.setNeedsDisplay() }
            view.typingAttributes = RichStyler.baseAttributes(baseSize)
        }
    }
}
#endif
