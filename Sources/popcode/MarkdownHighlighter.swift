import AppKit

/// Obsidian-style source-mode styling: the Markdown stays as typed, but headings
/// grow, emphasis is applied, and syntax markers fade back.
@MainActor
final class MarkdownHighlighter: Highlighter {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return style
    }()
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
    }

    private static let headingFonts: [NSFont] = [
        .systemFont(ofSize: 24, weight: .bold),
        .systemFont(ofSize: 20, weight: .bold),
        .systemFont(ofSize: 17.5, weight: .semibold),
        .systemFont(ofSize: 16, weight: .semibold),
        .systemFont(ofSize: 15, weight: .semibold),
        .systemFont(ofSize: 15, weight: .semibold),
    ]
    private static let markerColor = NSColor.tertiaryLabelColor
    private static let accentColor = NSColor.controlAccentColor

    private let heading = regex(#"^(#{1,6}[ \t]+)\S.*$"#)
    private let quote = regex(#"^[ \t]*(>+)[ \t]?.*$"#)
    private let listMarker = regex(#"^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private let rule = regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private let inlineCode = regex(#"(`+)[^`\n]+?\1"#)
    private let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    // The marker must not sit next to another copy of itself, or `**bold**` would also match as italic.
    private let italic = regex(#"(?<![*\w])\*(?![\s*])(.+?)(?<![\s*])\*(?![*\w])|(?<![_\w])_(?![\s_])(.+?)(?<![\s_])_(?![_\w])"#)
    private let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)~~"#)
    private let link = regex(#"\[([^\]\n]+)\](\([^)\n]+\))"#)

    var bodyAttributes: [NSAttributedString.Key: Any] { Self.bodyAttributes }

    func style(_ storage: NSMutableAttributedString) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.setAttributes(Self.bodyAttributes, range: full)

        let blocks = fencedBlocks(in: text)
        for block in blocks {
            storage.addAttribute(.font, value: Self.codeFont, range: block.whole)
            for fence in block.fences {
                storage.addAttribute(.foregroundColor, value: Self.markerColor, range: fence)
            }
        }
        var skipRanges = blocks.map(\.whole)

        func matches(_ re: NSRegularExpression) -> [NSTextCheckingResult] {
            re.matches(in: storage.string, range: full).filter { m in
                !skipRanges.contains { NSIntersectionRange($0, m.range).length > 0 }
            }
        }

        for m in matches(heading) {
            let markerLength = m.range(at: 1).length
            let level = text.substring(with: m.range(at: 1)).filter { $0 == "#" }.count
            storage.addAttribute(.font, value: Self.headingFonts[level - 1], range: m.range)
            storage.addAttribute(.foregroundColor, value: Self.markerColor,
                                 range: NSRange(location: m.range.location, length: markerLength))
        }
        for m in matches(quote) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            storage.addAttribute(.foregroundColor, value: Self.accentColor, range: m.range(at: 1))
        }
        for m in matches(listMarker) {
            storage.addAttribute(.foregroundColor, value: Self.accentColor, range: m.range(at: 1))
            if m.range(at: 2).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: Self.accentColor, range: m.range(at: 2))
            }
        }
        for m in matches(rule) {
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: m.range)
        }

        for m in matches(inlineCode) {
            let ticks = m.range(at: 1).length
            storage.addAttribute(.font, value: Self.codeFont, range: m.range)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: m.range)
            dimEnds(of: m.range, length: ticks, in: storage)
            skipRanges.append(m.range)
        }
        for m in matches(bold) {
            addTrait(.boldFontMask, to: m.range, in: storage)
            dimEnds(of: m.range, length: 2, in: storage)
        }
        for m in matches(italic) {
            addTrait(.italicFontMask, to: m.range, in: storage)
            dimEnds(of: m.range, length: 1, in: storage)
        }
        for m in matches(strike) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            dimEnds(of: m.range, length: 2, in: storage)
        }
        for m in matches(link) {
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range(at: 1))
        }
    }

    private struct FencedBlock {
        var whole: NSRange
        var fences: [NSRange]
    }

    private func fencedBlocks(in text: NSString) -> [FencedBlock] {
        var blocks: [FencedBlock] = []
        var open: NSRange?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) {
            line, lineRange, enclosingRange, _ in
            let trimmed = (line ?? "").trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return }
            if let start = open {
                let whole = NSRange(location: start.location, length: NSMaxRange(enclosingRange) - start.location)
                blocks.append(FencedBlock(whole: whole, fences: [start, lineRange]))
                open = nil
            } else {
                open = lineRange
            }
        }
        // An unclosed fence runs to the end, matching how renderers treat it while typing.
        if let start = open {
            let whole = NSRange(location: start.location, length: text.length - start.location)
            blocks.append(FencedBlock(whole: whole, fences: [start]))
        }
        return blocks
    }

    private func addTrait(_ trait: NSFontTraitMask, to range: NSRange, in storage: NSMutableAttributedString) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? Self.bodyFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
        }
    }

    private func dimEnds(of range: NSRange, length: Int, in storage: NSMutableAttributedString) {
        storage.addAttribute(.foregroundColor, value: Self.markerColor,
                             range: NSRange(location: range.location, length: length))
        storage.addAttribute(.foregroundColor, value: Self.markerColor,
                             range: NSRange(location: NSMaxRange(range) - length, length: length))
    }

}

private func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
}
