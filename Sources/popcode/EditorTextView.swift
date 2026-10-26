import AppKit

/// The editing surface: a VS Code-style smooth caret and rounded, animated selection, plus the
/// ⌘-shortcuts popcode routes by hand because it has no main menu.
final class EditorTextView: NSTextView {
    var onSave: () -> Void = {}

    /// Matches VS Code's `transition: all 80ms` on its smooth caret.
    private static let glide: TimeInterval = 0.08
    /// VS Code's `editor.roundedSelection` uses 3px; a touch more suits the larger text here.
    private static let selectionRadius: CGFloat = 4

    // The system caret and selection highlight are hidden and redrawn here: a system
    // NSTextInsertionIndicator that glides (keeps blink and dictation effects), and a shape layer
    // that outlines the selection as one rounded shape like VS Code.
    private let caret = NSTextInsertionIndicator()
    /// The indicator resets its own frame animations whenever it is moved, so it rides inside a
    /// plain view and the glide is applied to that view instead.
    private let caretHost = NSView()
    /// Flipped to match the text view; an unflipped host mirrored the outline vertically.
    private let selectionView = FlippedView()
    private let selectionShape = CAShapeLayer()
    private var isDecorated = false
    /// The fixed end of the selection. NSTextView keeps its anchor private, and neither its
    /// selectionAffinity nor TextKit 2's selection affinity reliably reports direction.
    private var selectionAnchor = 0
    /// Time constant of the selection's per-line ease-out; ~95% settled after 3τ ≈ the caret glide.
    private static let selectionTimeConstant: CFTimeInterval = 0.027
    /// Neighbouring line edges closer than this are evened out; proportional glyph widths otherwise
    /// leave a row of tiny rounded notches down the side of the selection.
    private static let edgeSnap: CGFloat = 6

    // The selection animates per line rather than by interpolating outlines (which morphs through
    // distorted shapes when the lines differ): each visual line's horizontal extent eases toward its
    // target, lines enter and leave by growing from and collapsing to zero width, and the rounded
    // outline is rebuilt from the current lines every frame, so it is always square and rounded.
    private var shownLines: [CGFloat: CGRect] = [:]
    private var targetLines: [CGFloat: CGRect] = [:]
    private var selectionLink: CADisplayLink?
    private var lastSelectionFrame: CFTimeInterval?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !isDecorated else { return }
        isDecorated = true
        insertionPointColor = .clear
        selectedTextAttributes = [.backgroundColor: NSColor.clear]

        selectionView.wantsLayer = true
        selectionView.layer?.addSublayer(selectionShape)
        selectionShape.fillColor = NSColor.selectedTextBackgroundColor.cgColor
        addSubview(selectionView, positioned: .below, relativeTo: nil)
        // While the window is inactive TextKit 2 paints its own gray highlight and ignores
        // selectedTextAttributes, so stand aside instead of stacking two highlights.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                                   name: name, object: window)
        }
        windowKeyChanged()

        caret.displayMode = .automatic
        caret.autoresizingMask = [.height]
        caretHost.wantsLayer = true
        caretHost.addSubview(caret)
        addSubview(caretHost)
        updateDecorations(animated: false)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateDecorations(animated: true)
    }

    override func didChangeText() {
        // The delegate restyles the Markdown inside super, so geometry is final afterwards.
        super.didChangeText()
        updateDecorations(animated: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDecorations(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionShape.fillColor = NSColor.selectedTextBackgroundColor.cgColor
        }
    }

    @objc private func windowKeyChanged() {
        selectionView.isHidden = !(window?.isKeyWindow ?? false)
    }

    // MARK: - Caret

    private func updateDecorations(animated: Bool) {
        guard isDecorated else { return }
        let selection = selectedRange()
        let active = activeEnd(of: selection)
        updateSelection(selection, growsForward: active > selectionAnchor || selection.length == 0,
                        animated: animated)
        updateCaret(at: active, animated: animated)
    }

    /// The end of the selection that is moving, where VS Code keeps the caret while selecting.
    /// Extending keeps one end on the anchor; only a selection touching neither end of it (a click,
    /// double-click, select all) starts a new anchor. Re-running with an unchanged selection is stable.
    private func activeEnd(of selection: NSRange) -> Int {
        if selection.length == 0 {
            selectionAnchor = selection.location
            return selection.location
        }
        if selection.location == selectionAnchor { return NSMaxRange(selection) }
        if NSMaxRange(selection) == selectionAnchor { return selection.location }
        selectionAnchor = selection.location
        return NSMaxRange(selection)
    }

    private func updateCaret(at location: Int, animated: Bool) {
        guard let target = caretRect(at: location) else { return }
        caret.frame = NSRect(x: 0, y: 0, width: 0, height: target.height)
        guard animated, caretHost.frame != target, caretHost.frame != .zero else {
            caretHost.frame = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.glide
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            caretHost.animator().frame = target
        }
    }

    /// From TextKit 2 directly: `firstRect(forCharacterRange:)` only estimates positions outside the
    /// laid-out viewport, which put the caret on the wrong line.
    private func caretRect(at location: Int) -> NSRect? {
        guard let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              let position = content.location(content.documentRange.location, offsetBy: location),
              let range = NSTextRange(location: position, end: position)
        else { return nil }
        layoutManager.ensureLayout(for: range)
        var segment: CGRect?
        layoutManager.enumerateTextSegments(in: range, type: .selection, options: .rangeNotRequired) {
            _, frame, _, _ in
            segment = frame
            return false
        }
        let origin = textContainerOrigin
        var rect: NSRect
        if let segment, segment.height > 0 {
            rect = segment.offsetBy(dx: origin.x, dy: origin.y)
        } else {
            // TextKit 2 reports a zero rect for an empty line, so place the caret from the line's
            // layout fragment; past the final newline there is none, so go below the last line.
            let font = (typingAttributes[.font] as? NSFont) ?? MarkdownHighlighter.bodyFont
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            var top: CGFloat = 0
            var height = lineHeight
            if let fragment = layoutManager.textLayoutFragment(for: position),
               fragment.rangeInElement.location.compare(position) != .orderedDescending {
                top = fragment.layoutFragmentFrame.minY
                height = fragment.textLineFragments.first?.typographicBounds.height ?? lineHeight
            } else if location > 0 {
                top = layoutManager.usageBoundsForTextContainer.maxY - lineHeight
            }
            rect = NSRect(x: origin.x + (textContainer?.lineFragmentPadding ?? 0), y: origin.y + top,
                          width: 0, height: height)
        }
        rect.size.width = 2
        return rect.integral
    }

    // MARK: - Selection

    /// - Parameter growsForward: the moving end is after the anchor, so lines enter from and leave
    ///   toward their leading edge (and their trailing edge when selecting backward).
    private func updateSelection(_ selection: NSRange, growsForward: Bool, animated: Bool) {
        selectionView.frame = bounds
        selectionShape.frame = selectionView.bounds
        let lines = selection.length > 0 ? selectionLines(for: selection) : []
        targetLines = Dictionary(lines.map { (Self.lineKey($0), $0) }, uniquingKeysWith: { a, _ in a })

        guard animated, window != nil else {
            shownLines = targetLines
            stopSelectionAnimation()
            renderSelection()
            return
        }
        func collapsed(_ rect: CGRect) -> CGRect {
            CGRect(x: growsForward ? rect.minX : rect.maxX, y: rect.minY, width: 0, height: rect.height)
        }
        for (key, rect) in targetLines where shownLines[key] == nil {
            shownLines[key] = collapsed(rect)
        }
        for (key, rect) in shownLines where targetLines[key] == nil {
            targetLines[key] = collapsed(rect)
        }
        startSelectionAnimation()
    }

    private static func lineKey(_ rect: CGRect) -> CGFloat { (rect.minY * 2).rounded() / 2 }

    private func startSelectionAnimation() {
        guard selectionLink == nil else { return }
        lastSelectionFrame = nil
        // Screen-owned, like the popover resize: a view's display link pauses while the popover
        // window resizes.
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let link = screen.displayLink(target: self, selector: #selector(stepSelection(_:)))
        link.add(to: .main, forMode: .common)
        selectionLink = link
    }

    private func stopSelectionAnimation() {
        selectionLink?.invalidate()
        selectionLink = nil
    }

    @objc private func stepSelection(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastSelectionFrame.map { now - $0 } ?? link.duration
        lastSelectionFrame = now
        let progress = 1 - exp(-dt / Self.selectionTimeConstant)
        var settled = true
        for (key, target) in targetLines {
            let current = shownLines[key] ?? target
            var minX = current.minX + (target.minX - current.minX) * progress
            var maxX = current.maxX + (target.maxX - current.maxX) * progress
            if abs(target.minX - minX) < 0.25 && abs(target.maxX - maxX) < 0.25 {
                minX = target.minX
                maxX = target.maxX
            } else {
                settled = false
            }
            shownLines[key] = CGRect(x: minX, y: target.minY, width: maxX - minX, height: target.height)
        }
        if settled {
            // Lines that were only collapsing toward zero width are done.
            for (key, rect) in shownLines where rect.width <= 0 {
                shownLines[key] = nil
                targetLines[key] = nil
            }
            stopSelectionAnimation()
        }
        renderSelection()
    }

    private func renderSelection() {
        let lines = shownLines.values.filter { $0.width > 0.5 }.sorted { $0.minY < $1.minY }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionShape.path = Self.roundedPath(Self.polygons(from: lines), radius: Self.selectionRadius)
        CATransaction.commit()
    }

    /// One rect per visual line, stacked so neighbours touch.
    ///
    /// Built from line fragments rather than `.selection` segments: those run to the container's
    /// edge whenever a line break is selected, while VS Code stops each line at its text and adds
    /// only a sliver for the newline.
    private func selectionLines(for selection: NSRange) -> [CGRect] {
        guard let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: selection.location),
              let end = content.location(start, offsetBy: selection.length),
              let range = NSTextRange(location: start, end: end)
        else { return [] }
        layoutManager.ensureLayout(for: range)

        let origin = textContainerOrigin
        let documentStart = content.documentRange.location
        let selectionEnd = NSMaxRange(selection)
        let newlineWidth = ceil(MarkdownHighlighter.bodyFont.pointSize * 0.5)
        var lines: [CGRect] = []
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let paragraphStart = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard paragraphStart < selectionEnd else { return false }
            let frame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments {
                let lineRange = line.characterRange
                let lineStart = paragraphStart + lineRange.location
                let lineEnd = lineStart + lineRange.length
                let from = max(selection.location, lineStart)
                let to = min(selectionEnd, lineEnd)
                guard to > from else { continue }
                let text = line.attributedString.string as NSString
                let endsWithNewline = lineRange.length > 0
                    && text.character(at: NSMaxRange(lineRange) - 1) == 0x0A
                let textEnd = endsWithNewline ? lineEnd - 1 : lineEnd
                let x0 = line.locationForCharacter(at: from - paragraphStart).x
                let x1 = line.locationForCharacter(at: min(to, textEnd) - paragraphStart).x
                var width = x1 - x0
                if endsWithNewline && to > textEnd { width += newlineWidth }
                guard width > 0 else { continue }
                let bounds = line.typographicBounds
                lines.append(CGRect(x: origin.x + frame.minX + bounds.minX + x0,
                                    y: origin.y + frame.minY + bounds.minY,
                                    width: width, height: bounds.height))
            }
            return true
        }
        // Typographic bounds hug the glyphs; spread the line spacing evenly above and below each
        // line so the text sits centered, then split any remaining gap so stacked lines touch.
        let halfSpacing = MarkdownHighlighter.paragraphStyle.lineSpacing / 2
        lines = lines.map { $0.insetBy(dx: 0, dy: -halfSpacing) }
        // Align both gaps and overlaps; a mismatch leaves the outline with a slanted edge.
        for i in lines.indices.dropLast() where abs(lines[i + 1].minY - lines[i].maxY) > 0.01 {
            let middle = (lines[i].maxY + lines[i + 1].minY) / 2
            lines[i].size.height = middle - lines[i].minY
            lines[i + 1].size.height += lines[i + 1].minY - middle
            lines[i + 1].origin.y = middle
        }

        // Even out small differences between neighbouring edges. A run only extends while its whole
        // spread stays under the threshold, so a gradual drift is not dragged to one value.
        func runs(_ value: (CGRect) -> CGFloat) -> [ClosedRange<Int>] {
            var result: [ClosedRange<Int>] = []
            var index = 0
            while index < lines.count {
                var last = index
                var low = value(lines[index]), high = low
                while last + 1 < lines.count {
                    let next = value(lines[last + 1])
                    guard max(high, next) - min(low, next) < Self.edgeSnap else { break }
                    low = min(low, next)
                    high = max(high, next)
                    last += 1
                }
                result.append(index...last)
                index = last + 1
            }
            return result
        }
        for run in runs(\.maxX) {
            let maxX = lines[run].map(\.maxX).max()!
            for i in run { lines[i].size.width = maxX - lines[i].minX }
        }
        for run in runs(\.minX) {
            let minX = lines[run].map(\.minX).min()!
            for i in run {
                lines[i].size.width += lines[i].minX - minX
                lines[i].origin.x = minX
            }
        }
        return lines
    }

    /// Lines that overlap horizontally join into one outline (VS Code's connected shape); the
    /// rest stay separate.
    private static func polygons(from lines: [CGRect]) -> [[CGPoint]] {
        var groups: [[CGRect]] = []
        for line in lines {
            if let previous = groups.last?.last,
               abs(previous.maxY - line.minY) < 1,
               min(previous.maxX, line.maxX) - max(previous.minX, line.minX) > 0.5 {
                groups[groups.count - 1].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.map(Self.outline)
    }

    /// Clockwise outline (in flipped coordinates) of rects stacked top to bottom.
    private static func outline(of rects: [CGRect]) -> [CGPoint] {
        var right: [CGPoint] = []
        var left: [CGPoint] = []
        for rect in rects {
            right += [CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]
            left += [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
        let points = right + left.reversed()
        // Drop vertices that lie on a straight edge (equal widths on consecutive lines).
        return points.enumerated().filter { index, point in
            let previous = points[(index + points.count - 1) % points.count]
            let next = points[(index + 1) % points.count]
            return !(previous.x == point.x && point.x == next.x) && !(previous.y == point.y && point.y == next.y)
        }.map(\.element)
    }

    /// Rounds every corner, convex or concave, with `addArc(tangent1End:tangent2End:radius:)`.
    private static func roundedPath(_ polygons: [[CGPoint]], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for points in polygons where points.count >= 3 {
            let count = points.count
            func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
            let first = points[0], last = points[count - 1]
            path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
            for index in 0..<count {
                let point = points[index]
                let previous = points[(index + count - 1) % count]
                let next = points[(index + 1) % count]
                let r = min(radius, distance(point, previous) / 2, distance(point, next) / 2)
                path.addArc(tangent1End: point, tangent2End: next, radius: r)
            }
            path.closeSubpath()
        }
        return path
    }

    // MARK: - Shortcuts

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

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
