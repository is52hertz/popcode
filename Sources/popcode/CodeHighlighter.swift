import AppKit

/// Rule-based highlighting for scripts and config files. Each language's token patterns are joined
/// into one alternation and scanned left to right, so a token can't start inside an earlier one:
/// a `#` inside a string is not a comment, and quotes inside a comment don't open a string.
@MainActor
final class CodeHighlighter: Highlighter {
    enum Role: String, CaseIterable {
        case comment, string, keyword, constant, number, variable, key, function, section

        var color: NSColor {
            switch self {
            case .comment: .secondaryLabelColor
            case .string: .systemRed
            case .keyword, .constant: .systemPink
            case .number, .section: .systemPurple
            case .variable: .systemTeal
            case .key, .function: .systemBlue
            }
        }
    }

    struct Language {
        /// Token patterns in priority order; earlier wins when two match at the same position.
        /// Patterns must not contain capturing groups — use `(?:…)`.
        var tokens: [(Role, String)]
        /// Variables expanded inside double-quoted strings (shell `"$HOME"`).
        var interpolation: String?
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .semibold)

    let bodyAttributes: [NSAttributedString.Key: Any] = [
        .font: CodeHighlighter.font,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: MarkdownHighlighter.paragraphStyle,
    ]
    private let scanner: NSRegularExpression
    private let interpolation: NSRegularExpression?
    private let roles: [Role]

    init(_ language: Language) {
        roles = language.tokens.map(\.0)
        let pattern = language.tokens.enumerated()
            .map { index, token in "(?<t\(index)>\(token.1))" }
            .joined(separator: "|")
        scanner = try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        interpolation = language.interpolation.map { try! NSRegularExpression(pattern: $0) }
    }

    func style(_ text: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: text.length)
        text.setAttributes(bodyAttributes, range: full)
        let string = text.string as NSString
        for match in scanner.matches(in: text.string, range: full) {
            guard let index = roles.indices.first(where: { match.range(withName: "t\($0)").location != NSNotFound })
            else { continue }
            let role = roles[index]
            text.addAttribute(.foregroundColor, value: role.color, range: match.range)
            if role == .section {
                text.addAttribute(.font, value: Self.boldFont, range: match.range)
            }
            if role == .string, let interpolation, string.character(at: match.range.location) == 0x22 {
                for inner in interpolation.matches(in: text.string, range: match.range) {
                    text.addAttribute(.foregroundColor, value: Role.variable.color, range: inner.range)
                }
            }
        }
    }
}

extension CodeHighlighter.Language {
    private static let doubleQuoted = #""(?:[^"\\]|\\.)*""#
    private static let singleQuoted = #"'[^']*'"#
    private static let number = #"(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?![\w.])"#

    /// zsh / bash / sh.
    static let shell = Self(
        tokens: [
            // `#` starts a comment only at a word boundary: `$#` and `a#b` are not comments.
            (.comment, #"(?:^|(?<=[\s;|&(]))#[^\n]*"#),
            (.string, #"\$'(?:[^'\\]|\\.)*'"#),
            (.string, singleQuoted),
            (.string, doubleQuoted),
            (.variable, #"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#?$!@*-]"#),
            (.function, #"(?<=^|\s)(?:function\s+)?[A-Za-z_][\w.:-]*(?=\s*\(\)\s*\{?)"#),
            (.keyword, #"(?<![\w-])(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|select|return|local|export|typeset|declare|readonly|unset|source|alias|unalias|setopt|unsetopt|autoload|bindkey|zstyle|eval|exec|trap|break|continue|shift)(?![\w-])"#),
            (.key, #"(?<![\w$-])[A-Za-z_][A-Za-z0-9_]*(?=\+?=)"#),
        ],
        interpolation: #"\$\{[^}\n]*\}|\$\([^)\n]*\)|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#?$!@*-]"#
    )

    /// JSON, including the `//` and `/* */` comments of JSONC files.
    static let json = Self(
        tokens: [
            (.comment, #"//[^\n]*|/\*[\s\S]*?\*/"#),
            (.key, doubleQuoted + #"(?=\s*:)"#),
            (.string, doubleQuoted),
            (.constant, #"\b(?:true|false|null)\b"#),
            (.number, number),
        ]
    )

    static let yaml = Self(
        tokens: [
            (.comment, #"(?:^|(?<=\s))#[^\n]*"#),
            (.section, #"^(?:---|\.\.\.)[ \t]*$"#),
            // A key at the start of a line, after indentation or a list dash. ICU has no `\K`, so
            // the prefix is a bounded lookbehind.
            (.key, #"(?:(?<=^)|(?<=^[ \t]{1,64})|(?<=^[ \t]{0,64}-[ \t]))(?:"(?:[^"\\]|\\.)*"|'[^']*'|[^\s#:'"\[\]{},-][^:#\n]*?)(?=[ \t]*:(?:[ \t]|$))"#),
            (.string, doubleQuoted),
            (.string, singleQuoted),
            (.variable, #"[&*][A-Za-z0-9_-]+"#),
            (.constant, #"(?<![\w-])(?:true|false|yes|no|on|off|null|~)(?![\w-])"#),
            (.number, number),
        ]
    )

    static let toml = Self(
        tokens: [
            (.comment, #"#[^\n]*"#),
            (.section, #"^[ \t]*\[\[?[^\]\n]+\]\]?"#),
            (.string, #""""[\s\S]*?"""|'''[\s\S]*?'''"#),
            (.key, #"^[ \t]*(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|'[^']*')(?:[ \t]*\.[ \t]*(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"))*(?=[ \t]*=)"#),
            (.string, doubleQuoted),
            (.string, singleQuoted),
            (.constant, #"\b(?:true|false)\b"#),
            (.number, number),
        ]
    )

    /// INI and git-style config: `[section]`, `key = value`, `;` or `#` comments.
    static let ini = Self(
        tokens: [
            (.comment, #"^[ \t]*[#;][^\n]*"#),
            (.section, #"^[ \t]*\[[^\]\n]+\]"#),
            (.key, #"^[ \t]*[A-Za-z0-9_.-]+(?=[ \t]*=)"#),
            (.string, doubleQuoted),
            (.constant, #"(?<![\w-])(?:true|false|yes|no|on|off)(?![\w-])"#),
            (.number, number),
        ]
    )
}
