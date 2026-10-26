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
    /// Vertex count of each polygon in the drawn selection; a path animates only between shapes
    /// with the same structure, otherwise Core Animation interpolates nonsense.
    private var selectionSignature: [Int] = []

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
        updateSelection(selection, animated: animated)
        updateCaret(at: activeEnd(of: selection), animated: animated)
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

    private func updateSelection(_ selection: NSRange, animated: Bool) {
        selectionView.frame = bounds
        let polygons = selection.length > 0 ? selectionPolygons(for: selection) : []
        let signature = polygons.map(\.count)
        let path = Self.roundedPath(polygons, radius: Self.selectionRadius)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionShape.frame = selectionView.bounds
        if animated, !polygons.isEmpty, signature == selectionSignature {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = selectionShape.presentation()?.path ?? selectionShape.path
            animation.duration = Self.glide
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            selectionShape.add(animation, forKey: "path")
        } else {
            selectionShape.removeAnimation(forKey: "path")
        }
        selectionShape.path = path
        CATransaction.commit()
        selectionSignature = signature
    }

    /// One rect per line of the selection, merged into outlines: lines that overlap horizontally
    /// join into a single polygon (VS Code's connected shape), otherwise they stay separate.
    private func selectionPolygons(for selection: NSRange) -> [[CGPoint]] {
        guard let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: selection.location),
              let end = content.location(start, offsetBy: selection.length),
              let range = NSTextRange(location: start, end: end)
        else { return [] }
        layoutManager.ensureLayout(for: range)

        let origin = textContainerOrigin
        var lines: [CGRect] = []
        layoutManager.enumerateTextSegments(in: range, type: .selection, options: .rangeNotRequired) {
            _, frame, _, _ in
            // TextKit 2 reports empty lines as a zero rect at the origin; skip them, the gap
            // closing below covers their height.
            guard frame.height > 0 else { return true }
            // An empty segment is a selected line break; give it a sliver of width as VS Code does.
            let rect = CGRect(x: frame.minX + origin.x, y: frame.minY + origin.y,
                              width: max(frame.width, 6), height: frame.height)
            // Segments of one line can differ in height and top (inline code uses a smaller font),
            // so merge by vertical overlap rather than equal tops.
            if let last = lines.last,
               min(last.maxY, rect.maxY) - max(last.minY, rect.minY) > min(last.height, rect.height) / 2 {
                lines[lines.count - 1] = last.union(rect)
            } else {
                lines.append(rect)
            }
            return true
        }
        // Close the line-spacing gaps so stacked lines read as one shape.
        for i in lines.indices.dropLast() where lines[i + 1].minY > lines[i].maxY {
            lines[i].size.height = lines[i + 1].minY - lines[i].minY
        }

        var groups: [[CGRect]] = []
        for line in lines {
            if let previous = groups.last?.last,
               min(previous.maxX, line.maxX) - max(previous.minX, line.minX) > Self.selectionRadius * 2 {
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
