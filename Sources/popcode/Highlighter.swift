import AppKit

/// Restyles a document's source in place; the text itself is never changed.
@MainActor
protocol Highlighter: AnyObject {
    /// Attributes for unstyled text, also used as the typing attributes.
    var bodyAttributes: [NSAttributedString.Key: Any] { get }
    /// Styles `text` from scratch.
    func style(_ text: NSMutableAttributedString)
}

extension Highlighter {
    /// Styles into a scratch copy, then writes back only the runs whose attributes changed.
    /// Resetting the whole storage on every keystroke made TextKit 2 drop all layout and fall back
    /// to estimated heights for off-screen text, so the document height (and the text under the
    /// viewport) jumped while typing in the middle of a long document.
    func apply(to storage: NSTextStorage) {
        let styled = NSMutableAttributedString(string: storage.string)
        style(styled)
        storage.beginEditing()
        defer { storage.endEditing() }
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { wanted, range, _ in
            var location = range.location
            while location < NSMaxRange(range) {
                var current = NSRange()
                let existing = storage.attributes(at: location, longestEffectiveRange: &current,
                                                  in: NSRange(location: location, length: NSMaxRange(range) - location))
                if !(existing as NSDictionary).isEqual(to: wanted) {
                    storage.setAttributes(wanted, range: current)
                }
                location = NSMaxRange(current)
            }
        }
    }
}

/// Picks a highlighter from the file name, extension, or shebang; nil means plain text.
@MainActor
func makeHighlighter(for url: URL, text: String) -> Highlighter? {
    let name = url.lastPathComponent.lowercased()
    let ext = url.pathExtension.lowercased()

    if ["md", "markdown"].contains(ext) { return MarkdownHighlighter() }

    let shellNames: Set = [".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout",
                           ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile",
                           ".bash_aliases", ".aliases"]
    if shellNames.contains(name) || ["sh", "zsh", "bash", "command"].contains(ext) {
        return CodeHighlighter(.shell)
    }
    if ["json", "jsonc"].contains(ext) { return CodeHighlighter(.json) }
    if ["yml", "yaml"].contains(ext) { return CodeHighlighter(.yaml) }
    if ext == "toml" { return CodeHighlighter(.toml) }
    if [".gitconfig", ".gitmodules", ".editorconfig"].contains(name) || ["ini", "cfg", "gitconfig"].contains(ext) {
        return CodeHighlighter(.ini)
    }

    // Extensionless scripts: trust the interpreter named on the shebang line.
    if text.hasPrefix("#!"), let firstLine = text.split(separator: "\n", maxSplits: 1).first,
       ["sh", "zsh", "bash", "dash", "ksh"].contains(where: { firstLine.hasSuffix("/" + $0) || firstLine.hasSuffix(" " + $0) }) {
        return CodeHighlighter(.shell)
    }
    return nil
}
