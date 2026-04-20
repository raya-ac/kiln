import SwiftUI
import AppKit

// MARK: - Code Editor (NSTextView wrapper)

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: String
    let isEditable: Bool
    var onSave: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // Explicit RGB colors, not SwiftUI Color conversions.
    private static let editorFg = NSColor(red: 0xE4/255.0, green: 0xE4/255.0, blue: 0xE7/255.0, alpha: 1)
    private static let editorBg = NSColor(red: 0x0A/255.0, green: 0x0A/255.0, blue: 0x0B/255.0, alpha: 1)
    private static let editorAccent = NSColor(red: 0xF9/255.0, green: 0x73/255.0, blue: 0x16/255.0, alpha: 1)

    func makeNSView(context: Context) -> NSScrollView {
        // Use AppKit's own factory — this gives us a fully correct NSTextView
        // (layoutManager, textStorage, textContainer, resizing masks) inside an
        // NSScrollView. This is the same setup Xcode / TextEdit use.
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.editorBg
        scrollView.appearance = NSAppearance(named: .darkAqua)

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.appearance = NSAppearance(named: .darkAqua)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = Self.editorBg
        textView.textColor = Self.editorFg
        textView.insertionPointColor = Self.editorAccent
        textView.selectedTextAttributes = [
            .backgroundColor: Self.editorAccent.withAlphaComponent(0.25),
            .foregroundColor: Self.editorFg,
        ]

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.font = font
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: Self.editorFg,
        ]

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = []
        paragraphStyle.defaultTabInterval = 28.0
        textView.defaultParagraphStyle = paragraphStyle
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        // Line number gutter
        let rulerView = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.rulerView = rulerView

        // ⌘S monitor — scoped to when this textView is first responder
        context.coordinator.installSaveMonitor()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            applySyntaxHighlighting(to: storage)
            textView.selectedRanges = selectedRanges
            textView.needsDisplay = true
        }

        context.coordinator.rulerView?.needsDisplay = true
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeSaveMonitor()
    }

    fileprivate func applySyntaxHighlighting(to storage: NSTextStorage) {
        let code = storage.string
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: Self.editorFg,
        ], range: fullRange)

        let rules = SyntaxRules.rules(for: language)
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                let range = rule.captureGroup < match.numberOfRanges ? match.range(at: rule.captureGroup) : match.range
                if range.location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: rule.color, range: range)
                    if rule.bold {
                        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: range)
                    }
                }
            }
        }
        storage.endEditing()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var rulerView: LineNumberRulerView?
        private var saveMonitor: Any?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            rulerView?.needsDisplay = true

            DispatchQueue.main.async { [weak self] in
                guard let self, let tv = self.textView, let storage = tv.textStorage else { return }
                self.parent.applySyntaxHighlighting(to: storage)
            }
        }

        func installSaveMonitor() {
            // ⌘S is handled at the SwiftUI scene level via keyboard shortcut;
            // a local event monitor here conflicts with Swift 6 strict concurrency.
            // Placeholder — see SceneCommands for the actual wiring.
        }

        func removeSaveMonitor() {
            if let m = saveMonitor {
                NSEvent.removeMonitor(m)
                saveMonitor = nil
            }
        }

        deinit { removeSaveMonitor() }
    }
}

// MARK: - Line Number Ruler

class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 40

        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange),
            name: NSText.didChangeNotification, object: textView
        )
        if let scrollView = textView.enclosingScrollView {
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    @objc private func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        // Fill only within the ruler's own bounds — `rect` in some AppKit states can
        // exceed the ruler bounds and paint over the document area, hiding text.
        let fillRect = rect.intersection(self.bounds)
        let bgColor = NSColor(Color.kilnSurface)
        bgColor.setFill()
        fillRect.fill()

        let borderColor = NSColor(Color.kilnBorder)
        borderColor.setStroke()
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: self.bounds.maxX - 0.5, y: self.bounds.minY))
        borderPath.line(to: NSPoint(x: self.bounds.maxX - 0.5, y: self.bounds.maxY))
        borderPath.lineWidth = 1
        borderPath.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(Color.kilnTextTertiary),
        ]

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let string = textView.string as NSString
        var lineNumber = 1

        string.enumerateSubstrings(in: NSRange(location: 0, length: charRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        string.enumerateSubstrings(in: charRange, options: [.byLines, .substringNotRequired]) { _, substringRange, _, _ in
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: substringRange.location)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect.origin.y -= visibleRect.origin.y

            let numStr = "\(lineNumber)" as NSString
            let size = numStr.size(withAttributes: attrs)
            let x = self.ruleThickness - size.width - 8
            let y = lineRect.origin.y + (lineRect.height - size.height) / 2

            numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            lineNumber += 1
        }
    }
}

// MARK: - Syntax Highlighting Rules

struct SyntaxRule {
    let pattern: String
    let color: NSColor
    let options: NSRegularExpression.Options
    let captureGroup: Int
    let bold: Bool

    init(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = [], captureGroup: Int = 0, bold: Bool = false) {
        self.pattern = pattern
        self.color = color
        self.options = options
        self.captureGroup = captureGroup
        self.bold = bold
    }
}

enum SyntaxRules {
    static let keyword = NSColor(Color(hex: 0xC084FC))
    static let string = NSColor(Color(hex: 0x86EFAC))
    static let comment = NSColor(Color(hex: 0x6B7280))
    static let number = NSColor(Color(hex: 0xFBBF24))
    static let type = NSColor(Color(hex: 0x67E8F9))
    static let function = NSColor(Color(hex: 0x93C5FD))
    static let property = NSColor(Color(hex: 0xFCA5A5))

    static func rules(for language: String) -> [SyntaxRule] {
        switch language {
        case "swift":
            return swiftRules
        case "js", "javascript", "ts", "typescript", "jsx", "tsx":
            return jsRules
        case "py", "python":
            return pythonRules
        case "json":
            return jsonRules
        case "css":
            return cssRules
        case "html":
            return htmlRules
        default:
            return genericRules
        }
    }

    static let genericRules: [SyntaxRule] = [
        SyntaxRule(#""(?:[^"\\]|\\.)*""#, color: string),
        SyntaxRule(#"'(?:[^'\\]|\\.)*'"#, color: string),
        SyntaxRule(#"//.*$"#, color: comment, options: .anchorsMatchLines),
        SyntaxRule(#"/\*[\s\S]*?\*/"#, color: comment, options: .dotMatchesLineSeparators),
        SyntaxRule(#"#.*$"#, color: comment, options: .anchorsMatchLines),
        SyntaxRule(#"\b\d+\.?\d*\b"#, color: number),
    ]

    static let swiftRules: [SyntaxRule] = [
        SyntaxRule(#"//.*$"#, color: comment, options: .anchorsMatchLines),
        SyntaxRule(#"/\*[\s\S]*?\*/"#, color: comment, options: .dotMatchesLineSeparators),
        SyntaxRule(#""""[\s\S]*?""""#, color: string, options: .dotMatchesLineSeparators),
        SyntaxRule(#""(?:[^"\\]|\\.)*""#, color: string),
        SyntaxRule(#"\b(func|var|let|class|struct|enum|protocol|extension|import|return|if|else|guard|switch|case|default|for|while|repeat|break|continue|throw|throws|try|catch|do|in|as|is|self|Self|super|init|deinit|typealias|associatedtype|where|true|false|nil|static|private|public|internal|fileprivate|open|final|override|mutating|nonmutating|lazy|weak|unowned|async|await|actor|nonisolated|some|any|@MainActor|@Published|@State|@Binding|@ObservedObject|@StateObject|@EnvironmentObject|@Environment)\b"#, color: keyword, bold: true),
        SyntaxRule(#"\b[A-Z][a-zA-Z0-9]*\b"#, color: type),
        SyntaxRule(#"\b([a-z][a-zA-Z0-9]*)\s*\("#, color: function, captureGroup: 1),
        SyntaxRule(#"\b\d+\.?\d*\b"#, color: number),
        SyntaxRule(#"\.([a-z][a-zA-Z0-9]*)"#, color: property, captureGroup: 1),
    ]

    static let jsRules: [SyntaxRule] = [
        SyntaxRule(#"//.*$"#, color: comment, options: .anchorsMatchLines),
        SyntaxRule(#"/\*[\s\S]*?\*/"#, color: comment, options: .dotMatchesLineSeparators),
        SyntaxRule(#"`(?:[^`\\]|\\.)*`"#, color: string),
        SyntaxRule(#""(?:[^"\\]|\\.)*""#, color: string),
        SyntaxRule(#"'(?:[^'\\]|\\.)*'"#, color: string),
        SyntaxRule(#"\b(const|let|var|function|return|if|else|for|while|do|switch|case|default|break|continue|throw|try|catch|finally|new|delete|typeof|instanceof|in|of|class|extends|super|this|import|export|from|default|async|await|yield|true|false|null|undefined|void|interface|type|enum|implements|public|private|protected|readonly|static|abstract|as|is)\b"#, color: keyword, bold: true),
        SyntaxRule(#"\b[A-Z][a-zA-Z0-9]*\b"#, color: type),
        SyntaxRule(#"\b([a-z][a-zA-Z0-9]*)\s*\("#, color: function, captureGroup: 1),
        SyntaxRule(#"\b\d+\.?\d*\b"#, color: number),
        SyntaxRule(#"(=>)"#, color: keyword),
    ]

    static let pythonRules: [SyntaxRule] = [
        SyntaxRule(#"#.*$"#, color: comment, options: .anchorsMatchLines),
        SyntaxRule(#"\"\"\"[\s\S]*?\"\"\""#, color: string, options: .dotMatchesLineSeparators),
        SyntaxRule(#"'''[\s\S]*?'''"#, color: string, options: .dotMatchesLineSeparators),
        SyntaxRule(#""(?:[^"\\]|\\.)*""#, color: string),
        SyntaxRule(#"'(?:[^'\\]|\\.)*'"#, color: string),
        SyntaxRule(#"\b(def|class|return|if|elif|else|for|while|break|continue|pass|import|from|as|try|except|finally|raise|with|yield|lambda|and|or|not|is|in|True|False|None|self|global|nonlocal|async|await)\b"#, color: keyword, bold: true),
        SyntaxRule(#"\b[A-Z][a-zA-Z0-9_]*\b"#, color: type),
        SyntaxRule(#"\b([a-z_][a-zA-Z0-9_]*)\s*\("#, color: function, captureGroup: 1),
        SyntaxRule(#"\b\d+\.?\d*\b"#, color: number),
        SyntaxRule(#"@[a-zA-Z_][a-zA-Z0-9_]*"#, color: keyword),
    ]

    static let jsonRules: [SyntaxRule] = [
        SyntaxRule(#""(?:[^"\\]|\\.)*"\s*:"#, color: property),
        SyntaxRule(#""(?:[^"\\]|\\.)*""#, color: string),
        SyntaxRule(#"\b(true|false|null)\b"#, color: keyword),
        SyntaxRule(#"-?\b\d+\.?\d*([eE][+-]?\d+)?\b"#, color: number),
    ]

    static let cssRules: [SyntaxRule] = [
        SyntaxRule(#"/\*[\s\S]*?\*/"#, color: comment, options: .dotMatchesLineSeparators),
        SyntaxRule(#""(?:[^"\\]|\\.)*""#, color: string),
        SyntaxRule(#"'(?:[^'\\]|\\.)*'"#, color: string),
        SyntaxRule(#"[.#][a-zA-Z_-][a-zA-Z0-9_-]*"#, color: type),
        SyntaxRule(#"[a-zA-Z-]+(?=\s*:)"#, color: property),
        SyntaxRule(#"\b\d+\.?\d*(px|em|rem|%|vh|vw|s|ms)?\b"#, color: number),
        SyntaxRule(#"@(media|keyframes|import|font-face|supports)\b"#, color: keyword),
    ]

    static let htmlRules: [SyntaxRule] = [
        SyntaxRule(#"<!--[\s\S]*?-->"#, color: comment, options: .dotMatchesLineSeparators),
        SyntaxRule(#""(?:[^"\\]|\\.)*""#, color: string),
        SyntaxRule(#"'(?:[^'\\]|\\.)*'"#, color: string),
        SyntaxRule(#"</?[a-zA-Z][a-zA-Z0-9-]*"#, color: keyword),
        SyntaxRule(#"\b[a-zA-Z-]+(?==)"#, color: property),
        SyntaxRule(#"/?\s*>"#, color: keyword),
    ]
}
