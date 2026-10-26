import AppKit

final class EditorPanel: NSPanel {
    var onSave: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // The app is never active, so there is no main menu to route ⌘-shortcuts;
    // handle the editing ones here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = flags.contains(.shift)

        if event.keyCode == 36 || event.keyCode == 76 || (key == "s" && !shift) {
            onSave()
            return true
        }
        if key == "f" && !shift {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            return NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
        }
        let action: Selector? = switch (key, shift) {
        case ("x", false): #selector(NSText.cut(_:))
        case ("c", false): #selector(NSText.copy(_:))
        case ("v", false): #selector(NSText.paste(_:))
        case ("a", false): #selector(NSText.selectAll(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class EditorController: NSObject, NSTextViewDelegate {
    private static let hintText = "⌘↩ 保存    esc 放弃"
    private static let escapeWindow: TimeInterval = 1.5

    private let url: URL
    private let original: String
    private let cursorLine: Int?
    private let panel: EditorPanel
    private let textView: NSTextView
    private let hint = NSTextField(labelWithString: EditorController.hintText)
    private let highlighter: MarkdownHighlighter?
    private var escapeArmedAt: Date?

    init(url: URL, text: String, cursorLine: Int?) {
        self.url = url
        self.original = text
        self.cursorLine = cursorLine
        let ext = url.pathExtension.lowercased()
        highlighter = (ext == "md" || ext == "markdown") ? MarkdownHighlighter() : nil

        panel = EditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        super.init()

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onSave = { [weak self] in self?.save() }

        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = MarkdownHighlighter.bodyFont
        textView.typingAttributes = MarkdownHighlighter.bodyAttributes
        textView.string = text
        scrollView.drawsBackground = false

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let container = NSView()
        for view in [scrollView, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55)
        glass.contentView = container
        panel.contentView = glass
        panel.minSize = NSSize(width: 360, height: 200)

        highlight()
    }

    func show() {
        panel.setFrame(initialFrame(), display: false)
        placeCursor()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    // MARK: - Actions

    private func save() {
        do {
            try textView.string.write(to: url, atomically: false, encoding: .utf8)
        } catch {
            NSSound.beep()
            showHint("保存失败：\(error.localizedDescription)", color: .systemRed)
            return
        }
        exit(0)
    }

    private func handleEscape() {
        if textView.string == original {
            exit(0)
        }
        if let armed = escapeArmedAt, Date().timeIntervalSince(armed) < Self.escapeWindow {
            exit(0)
        }
        escapeArmedAt = Date()
        showHint("有未保存的修改，再按一次 esc 放弃", color: .systemOrange)
    }

    private func showHint(_ text: String, color: NSColor) {
        hint.stringValue = text
        hint.textColor = color
        let shown = text
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.escapeWindow) { [weak self] in
            guard let self, self.hint.stringValue == shown else { return }
            self.hint.stringValue = Self.hintText
            self.hint.textColor = .tertiaryLabelColor
        }
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Esc maps to cancelOperation:, which NSTextView would turn into completion.
        // The input method sees Esc first, so this never cancels an IME composition.
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            handleEscape()
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        highlight()
    }

    // MARK: - Helpers

    private func highlight() {
        // Restyling the storage mid-composition would wipe the IME's marked-text styling;
        // the commit triggers another textDidChange.
        guard let highlighter, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        highlighter.apply(to: storage)
    }

    private func placeCursor() {
        let text = textView.string as NSString
        var location = 0
        if let cursorLine, cursorLine > 0 {
            var lineStart = 0
            for _ in 1..<cursorLine where lineStart < text.length {
                lineStart = NSMaxRange(text.lineRange(for: NSRange(location: lineStart, length: 0)))
            }
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                              for: NSRange(location: min(lineStart, text.length), length: 0))
            location = contentsEnd
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Bottom-centered over the frontmost window (the terminal that launched us),
    /// where the prompt input lives; falls back to the center of the main screen.
    private func initialFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        guard let anchor = frontmostWindowFrame() else {
            let visible = screen.visibleFrame
            let size = NSSize(width: min(720, visible.width - 80), height: min(480, visible.height - 80))
            return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? screen).visibleFrame
        let width = min(max(anchor.width - 80, 420), 760)
        let height = min(max(anchor.height * 0.55, 260), 620)
        var frame = NSRect(x: anchor.midX - width / 2, y: anchor.minY + 36, width: width, height: height)
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - width - 8)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - height - 8)
        return frame
    }

    private func frontmostWindowFrame() -> NSRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        // The list is ordered front to back, so the first normal-layer window wins.
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            // CoreGraphics uses a top-left origin; AppKit uses bottom-left.
            return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}
