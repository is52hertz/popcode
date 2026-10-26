import AppKit

/// Handles ⌘-shortcuts itself: popcode has no main menu to route them.
final class EditorTextView: NSTextView {
    var onSave: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = flags.contains(.shift)

        if event.keyCode == 36 || event.keyCode == 76 || (key == "s" && !shift) {
            onSave()
            return true
        }
        switch (key, shift) {
        case ("x", false): cut(nil)
        case ("c", false): copy(nil)
        case ("v", false): paste(nil)
        case ("a", false): selectAll(nil)
        case ("z", false): undoManager?.undo()
        case ("z", true): undoManager?.redo()
        case ("f", false):
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            performTextFinderAction(item)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// Holds the text at the top while it fits, so the scroll view never scrolls (or flashes a
/// scroller) in the frames between the text growing and the popover catching up.
final class PinnedClipView: NSClipView {
    var isPinned = true

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if isPinned { rect.origin.y = 0 }
        return rect
    }
}

/// Fades the scroll view's content out (opacity + blur) at whichever edge has more content beyond it.
/// AppKit has no public scroll edge effect for a free-standing scroll view, so this is hand-rolled.
final class EditorContainerView: NSView {
    static let fadeLength: CGFloat = 28

    let scrollView: NSScrollView
    /// Fades only appear once the text is taller than the editor can grow.
    var isOverflowing = false {
        didSet { if isOverflowing != oldValue { updateEdges() } }
    }
    private let opacityMask = CAGradientLayer()
    private let topBlur = EdgeBlurView(fadesDown: true)
    private let bottomBlur = EdgeBlurView(fadesDown: false)

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        scrollView.wantsLayer = true
        scrollView.layer?.mask = opacityMask
        for view in [topBlur, bottomBlur] {
            addSubview(view, positioned: .above, relativeTo: nil)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateEdges),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let frame = scrollView.frame
        let fade = Self.fadeLength
        topBlur.frame = NSRect(x: frame.minX, y: frame.maxY - fade, width: frame.width, height: fade)
        bottomBlur.frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: fade)
        updateEdges()
    }

    @objc func updateEdges() {
        let clip = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let hiddenAbove = isOverflowing && clip.bounds.minY > 0.5
        let hiddenBelow = isOverflowing && clip.bounds.maxY < documentHeight - 0.5
        let height = max(scrollView.bounds.height, 1)
        let fade = min(Self.fadeLength / height, 0.5)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The scroll view's layer is not flipped: location 0 is the bottom edge.
        opacityMask.frame = scrollView.bounds
        opacityMask.colors = [hiddenBelow ? NSColor.clear : NSColor.black, .black, .black,
                              hiddenAbove ? NSColor.clear : NSColor.black].map(\.cgColor)
        opacityMask.locations = [0, fade, 1 - fade, 1].map { NSNumber(value: Double($0)) }
        opacityMask.startPoint = CGPoint(x: 0.5, y: 0)
        opacityMask.endPoint = CGPoint(x: 0.5, y: 1)
        CATransaction.commit()
        topBlur.isHidden = !hiddenAbove
        bottomBlur.isHidden = !hiddenBelow
    }
}

/// Blurs what is behind it, strongest at the outer edge and fading to none inward.
final class EdgeBlurView: NSView {
    private let fadesDown: Bool
    private let gradient = CAGradientLayer()

    init(fadesDown: Bool) {
        self.fadesDown = fadesDown
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(3, forKey: kCIInputRadiusKey)
            layer?.backgroundFilters = [blur]
        }
        gradient.colors = [NSColor.black.cgColor, NSColor.clear.cgColor]
        layer?.mask = gradient
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        gradient.startPoint = CGPoint(x: 0.5, y: fadesDown ? 1 : 0)
        gradient.endPoint = CGPoint(x: 0.5, y: fadesDown ? 0 : 1)
    }
}

@MainActor
final class EditorController: NSObject, NSTextViewDelegate, NSPopoverDelegate {
    private static let hintText = "⌘↩ 保存    esc 放弃"
    private static let escapeWindow: TimeInterval = 1.5
    private static let textTop: CGFloat = 10
    private static let hintArea: CGFloat = 30
    private static let minTextHeight: CGFloat = 72
    private static let horizontalPadding: CGFloat = 8
    /// Time constant of the ease-out height animation; ~95% settled after 3τ.
    private static let resizeTimeConstant: CFTimeInterval = 0.07

    private let url: URL
    private let original: String
    private let cursorLine: Int?
    private let popover = NSPopover()
    private let anchorWindow: NSPanel
    private let textView = EditorTextView(usingTextLayoutManager: true)
    private let clipView = PinnedClipView()
    private let container: EditorContainerView
    private let hint = NSTextField(labelWithString: EditorController.hintText)
    private let highlighter: MarkdownHighlighter?
    private var escapeArmedAt: Date?
    private var width: CGFloat = 640
    private var maxTextHeight: CGFloat = 560
    private var targetHeight: CGFloat = 0
    private var resizeLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?

    init(url: URL, text: String, cursorLine: Int?) {
        self.url = url
        self.original = text
        self.cursorLine = cursorLine
        let ext = url.pathExtension.lowercased()
        highlighter = (ext == "md" || ext == "markdown") ? MarkdownHighlighter() : nil

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = textView
        container = EditorContainerView(scrollView: scrollView)

        // An invisible window that only gives the popover something to point at.
        anchorWindow = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        super.init()

        anchorWindow.isOpaque = false
        anchorWindow.backgroundColor = .clear
        anchorWindow.ignoresMouseEvents = true
        anchorWindow.level = .floating
        anchorWindow.hidesOnDeactivate = false

        textView.delegate = self
        textView.onSave = { [weak self] in self?.save() }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = MarkdownHighlighter.bodyFont
        textView.typingAttributes = MarkdownHighlighter.bodyAttributes
        textView.string = text

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        for view in [scrollView, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view, positioned: .below, relativeTo: nil)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.textTop),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.horizontalPadding),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.horizontalPadding),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.hintArea),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        let viewController = NSViewController()
        viewController.view = container
        popover.contentViewController = viewController
        // Clicking elsewhere must not throw away the draft; only ⌘↩ / Esc end the session.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

        highlight()
    }

    func show() {
        let anchor = anchorPoint()
        anchorWindow.setFrame(NSRect(x: anchor.x - 1, y: anchor.y - 1, width: 2, height: 2), display: false)
        anchorWindow.orderFrontRegardless()

        container.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 200))
        updateLayoutState()
        popover.contentSize = NSSize(width: width, height: targetHeight)
        placeCursor()
        NSApp.activate()
        popover.show(relativeTo: anchorWindow.contentView!.bounds, of: anchorWindow.contentView!, preferredEdge: .maxY)
        textView.window?.makeKey()
        textView.window?.makeFirstResponder(textView)
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

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        // Resizes are animated by hand from here on (see animateResize).
        popover.animates = false
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // NSPopover closes itself on Esc via cancelOperation:; route that through our discard logic.
        handleEscape()
        return false
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
        let wasOverflowing = container.isOverflowing
        updateLayoutState()
        if container.isOverflowing && !wasOverflowing {
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        if abs(targetHeight - popover.contentSize.height) > 0.5 {
            animateResize()
        }
        container.updateEdges()
    }

    // MARK: - Helpers

    private func highlight() {
        // Restyling the storage mid-composition would wipe the IME's marked-text styling;
        // the commit triggers another textDidChange.
        guard let highlighter, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        highlighter.apply(to: storage)
    }

    /// Measures the text and derives the popover height it wants (growing with the text up to
    /// `maxTextHeight`) and whether it overflows, i.e. needs scrolling, scroller and edge fades.
    private func updateLayoutState() {
        container.layoutSubtreeIfNeeded()
        var textHeight = Self.minTextHeight
        if let layout = textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            textHeight = layout.usageBoundsForTextContainer.height + textView.textContainerInset.height * 2
        }
        let overflowing = textHeight > maxTextHeight
        clipView.isPinned = !overflowing
        container.scrollView.hasVerticalScroller = overflowing
        container.isOverflowing = overflowing
        let clamped = min(max(textHeight, Self.minTextHeight), maxTextHeight)
        targetHeight = ceil(clamped + Self.textTop + Self.hintArea)
    }

    /// Eases the popover toward `targetHeight` frame by frame. NSPopover's own `animates` is only a
    /// hint for content size changes and visibly snaps, so the curve is driven here. Exponential
    /// approach: retargeting mid-flight (fast typing) stays smooth with no restart.
    private func animateResize() {
        guard resizeLink == nil else { return }
        lastFrameTime = nil
        // Tied to the screen, not a view: a view's link was observed to pause mid-animation once the
        // popover window started resizing.
        let screen = textView.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let link = screen.displayLink(target: self, selector: #selector(stepResize(_:)))
        link.add(to: .main, forMode: .common)
        resizeLink = link
    }

    @objc private func stepResize(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrameTime.map { now - $0 } ?? link.duration
        lastFrameTime = now
        let current = popover.contentSize.height
        let progress = 1 - exp(-dt / Self.resizeTimeConstant)
        var next = current + (targetHeight - current) * progress
        if abs(targetHeight - next) < 0.5 {
            next = targetHeight
            link.invalidate()
            resizeLink = nil
        }
        popover.contentSize = NSSize(width: width, height: next)
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

    /// Just above the bottom edge of the frontmost window (the terminal that launched us), where the
    /// prompt input lives; falls back to the lower third of the main screen. Also sizes the editor.
    private func anchorPoint() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        guard let terminal = frontmostWindowFrame() else {
            let visible = screen.visibleFrame
            width = min(720, visible.width - 80)
            maxTextHeight = min(560, visible.height * 0.55)
            return NSPoint(x: visible.midX, y: visible.minY + visible.height / 3)
        }
        let visible = (NSScreen.screens.first { $0.frame.intersects(terminal) } ?? screen).visibleFrame
        let anchor = NSPoint(x: terminal.midX, y: max(terminal.minY + 36, visible.minY + 8))
        width = min(max(terminal.width - 80, 420), 760)
        let chrome = Self.textTop + Self.hintArea + 40  // popover arrow and screen margin
        maxTextHeight = max(Self.minTextHeight, min(terminal.height * 0.7, visible.maxY - anchor.y - chrome, 640))
        return anchor
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
