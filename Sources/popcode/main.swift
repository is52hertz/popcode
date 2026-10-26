import AppKit

// A blocking $VISUAL editor: shows a floating panel over the terminal and exits
// once the user saves (⌘↩ / ⌘S) or discards (Esc).
//
// Accepted invocations:
//   popcode <file>               (git, most tools)
//   popcode -g <file>:<line>     (Claude Code, because the name contains "code")

func parseArguments(_ args: [String]) -> (path: String, line: Int?)? {
    var path: String?
    var line: Int?
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        if arg == "-g", let target = iterator.next() {
            // "<file>:<line>[:<column>]" — peel numeric suffixes off the end.
            var parts = target.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            var numbers: [Int] = []
            while parts.count > 1, let n = Int(parts.last!) {
                numbers.insert(n, at: 0)
                parts.removeLast()
            }
            path = parts.joined(separator: ":")
            line = numbers.first
        } else if !arg.hasPrefix("-") {
            path = arg
        }
    }
    return path.map { ($0, line) }
}

guard let (path, line) = parseArguments(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: popcode [-g] <file>[:line]\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: path)
let original: String
if FileManager.default.fileExists(atPath: url.path) {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write(Data("popcode: cannot read \(path) as UTF-8\n".utf8))
        exit(1)
    }
    original = contents
} else {
    original = ""
}

// AppKit and the input-method frameworks NSLog to stderr, which is the caller's terminal: Claude Code
// hands us its TTY, and the noise lands inside its TUI (it stays visible when an unchanged prompt
// means no redraw). Our own errors are reported above, so silence stderr from here on.
let devNull = open("/dev/null", O_WRONLY)
if devNull >= 0 {
    dup2(devNull, STDERR_FILENO)
    close(devNull)
}

let app = NSApplication.shared
// Accessory + non-activating panel: the terminal stays the active app, so focus
// returns to it naturally when we exit.
app.setActivationPolicy(.accessory)
let controller = EditorController(url: url, text: original, cursorLine: line)
controller.show()
app.run()
