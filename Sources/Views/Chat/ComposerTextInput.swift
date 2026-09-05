import SwiftUI
import AppKit

/// Native paste routing keeps screenshots out of the text storage and preserves normal text editing.
struct ComposerTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder = ""
    var fontSize: CGFloat = 13
    var spellCheck = true
    var expanded = false
    var minimumLines: CGFloat = 1
    var onSubmit: (() -> Void)? = nil
    var onCommandReturn: () -> Void = {}
    var onKey: (KeyEquivalent) -> KeyPress.Result = { _ in .ignored }
    var onPaste: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = AttachmentTextView()
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = view
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? AttachmentTextView else { return }
        view.onPaste = onPaste
        view.onKey = onKey
        view.onReturn = expanded ? nil : onSubmit
        view.onCommandReturn = onCommandReturn
        view.placeholder = placeholder
        view.setAccessibilityLabel(placeholder.isEmpty ? "Message" : placeholder)
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = NSColor(Color.kilnText)
        view.insertionPointColor = NSColor(Color.kilnAccent)
        view.isContinuousSpellCheckingEnabled = spellCheck
        view.isAutomaticSpellingCorrectionEnabled = spellCheck
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        view.needsDisplay = true
        if isFocused, view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak view] in
                guard let view, context.coordinator.parent.isFocused else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let view = nsView.documentView as? NSTextView, let container = view.textContainer,
              let manager = view.layoutManager else { return nil }
        let width = proposal.width ?? 300
        container.containerSize = NSSize(width: max(1, width - 2), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let line = ceil(manager.defaultLineHeight(for: .systemFont(ofSize: fontSize)))
        let height = expanded ? (proposal.height ?? 420) : min(line * 8, max(line * minimumLines, ceil(manager.usedRect(for: container).height)))
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextInput
        init(_ parent: ComposerTextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
            view.needsDisplay = true
        }
        func textDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func textDidEndEditing(_ notification: Notification) { parent.isFocused = false }
    }
}

final class AttachmentTextView: NSTextView {
    var onPaste: ([NSItemProvider]) -> Void = { _ in }
    var onKey: (KeyEquivalent) -> KeyPress.Result = { _ in .ignored }
    var onReturn: (() -> Void)?
    var onCommandReturn: () -> Void = {}
    var placeholder = ""
    var clipboard: () -> NSPasteboard = { .general }

    override func paste(_ sender: Any?) {
        let providers = AttachmentImporter.providers(from: clipboard())
        if !providers.isEmpty { onPaste(providers) }
        else { super.paste(sender) }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), NSPasteboard.general.canReadItem(withDataConformingToTypes: ["public.file-url", "public.image"]) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadItem(withDataConformingToTypes: ["public.file-url", "public.image"]) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let providers = AttachmentImporter.providers(from: sender.draggingPasteboard)
        if !providers.isEmpty { onPaste(providers); return true }
        return super.performDragOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            if modifiers.contains(.command) { onCommandReturn(); return }
            if !modifiers.contains(.shift), !modifiers.contains(.option), !modifiers.contains(.control), let onReturn { onReturn(); return }
        }
        let key: KeyEquivalent? = [126: .upArrow, 125: .downArrow, 53: .escape, 48: .tab][Int(event.keyCode)]
        if !modifiers.contains(.command), !modifiers.contains(.shift), !modifiers.contains(.option), !modifiers.contains(.control),
           let key, onKey(key) == .handled { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: .zero, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }
}
