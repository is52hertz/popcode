# notice

## What this is
`popcode`: a blocking `$VISUAL` editor for macOS. It shows a system `NSPopover` (Liquid Glass and
arrow come from AppKit) pointing at the bottom of the frontmost (terminal) window, sized to the text
up to a cap, saves on ⌘↩ / ⌘S, discards on Esc (twice if modified),
then exits 0. Built with SwiftPM + AppKit, macOS 26+.

## Claude Code Ctrl+G contract (read from the v2.1.310 bundle; internal, may change)
- Editor = `$VISUAL` → `$EDITOR` → first of `code`/`vi`/`nano` on PATH.
- Prompt is written to `$TMPDIR/claude-prompt-<id>.md` with `[Pasted text #N]` expanded;
  unchanged pastes are re-collapsed after save. One trailing newline is stripped.
- Spawned synchronously; a non-zero exit code or signal discards the edit with a warning.
- If the editor basename contains `code`/`cursor`/`windsurf`/`codium`/`subl`/`atom`/`gedit`/`notepad`,
  Claude Code treats it as a GUI editor: the TUI stays on screen and, for the `code` family,
  passes `-g <file>:<line>`. Otherwise it switches to the alternate screen (TUI hidden) and passes
  `+<line>` only to vi/emacs/nano-like names. **The binary name must keep `code` in it.**

## Gotchas
- Caret and selection are custom (`EditorTextView`): the system insertion point and selection highlight are
  made clear, a system `NSTextInsertionIndicator` (inside a host view, since it cancels its own frame
  animations) glides, and a `CAShapeLayer` draws the selection as rounded outlines. The selection view
  must stay the bottom-most subview: TextKit 2 draws text in `_NSTextContentView` subviews above it.
  VS Code itself animates only the caret (80ms); the selection animation here is an extra. Its top/bottom
  edges slide vertically to reveal or hide lines (the user preferred this over lines growing sideways
  from zero width), lines that stay ease horizontally, and the outline is rebuilt every frame. Don't go back to interpolating the outline path: across different lines it morphs through
  distorted shapes.
- TextKit 2 quirks the selection code works around: `.selection` segments run to the container edge when
  a line break is selected and report empty lines as a zero rect at the origin; `firstRect(forCharacterRange:)`
  only estimates positions outside the viewport. Geometry comes from text line fragments instead.
- There is no main menu: ⌘-shortcuts are routed by hand in `EditorTextView.performKeyEquivalent`.
  New ⌘ shortcuts go there.
- Line numbers (⌘L) are drawn by `LineNumberView` in the text view's left margin and must never change
  the text layout. That is why the side padding lives in `textContainerInset` (the scroll view spans the
  container, `scrollerInsets` keeps the scroller in place). A number's baseline is its paragraph's first
  line box bottom plus the font's descender: TextKit 2 keeps an empty line's spacing below it, so the glyph
  origin would lift it. The line after a final newline has no fragment and is placed via `caretRect`.
  Not on Option: right Option is the user's WeType voice toggle.
- Don't add custom glass/visual-effect backgrounds inside the popover; Apple's Liquid Glass guidance
  says to let the system draw popover backgrounds (a custom borderless glass panel showed a stray frame).
- AppKit has no public scroll edge effect for a free-standing scroll view (`NSScrollEdgeEffectStyle`
  is only for titlebar/split-view accessories), so the overflow fade + blur in `EditorContainerView`
  is hand-rolled.
- `MarkdownHighlighter.apply` must only write back attribute runs that changed: resetting the whole
  storage per keystroke makes TextKit 2 drop all layout and use estimated heights off-screen, so text
  jumps while typing mid-document in a long file.
- Highlighters conform to `Highlighter` (Highlighter.swift); `makeHighlighter(for:text:)` picks one from the
  file name, extension, or shebang. `CodeHighlighter` joins a language's token patterns into one named-group
  alternation scanned left to right, so token patterns must use non-capturing groups, and ICU has no `\K`
  (use a bounded lookbehind). Adding a language = adding a `Language` table plus a detection rule.
- Markdown styling runs only for `.md`/`.markdown` files (so git's `COMMIT_EDITMSG` `#` comments
  are not turned into headings) and is skipped while the IME has marked text.
- osascript keystrokes and `screencapture` are not permitted from the agent shell here, so focus/IME
  behavior must be checked by hand.
- Marked text (pinyin composition, dictation) changes the text without `didChangeText`/`textDidChange`.
  `EditorTextView.setMarkedText` forwards it (`onMarkedTextChange` → `contentChanged`) so the popover grows
  and the clip view unpins; before that, a long dictation kept the old height with scrolling pinned to the
  top and the caret out of view.
- popcode must run as `popcode.app` (built by `scripts/bundle.sh`). LaunchServices only records a bundle
  identifier for a process exec'd from inside a bundle: a bare binary (even with an Info.plist embedded via
  `-sectcreate`) or a symlink into the bundle shows `bundleID=[ NULL ]` in `lsappinfo info <pid>`, so
  `main.swift` re-execs from the symlink-resolved path. Without the identity, WeType (微信输入法) never
  commits long dictation (30s+): it asks for `validAttributesForMarkedText` and `markedRange`, then
  stops, leaving the underlined marked text stuck; short dictation (plain `insertText`) worked either way.
  Fixed and confirmed by a 31s test on 2026-11-09. Apps on WeType's lists (`voice_terminal_bundles`:
  Ghostty, Terminal, iTerm…; Chrome) get long text via clipboard + ⌘V instead.
- While WeType's text was stuck like that, Return wiped it with no undo, through a path that never reached
  `doCommandBy` (an `unmarkText` guard there did nothing in the real case). Not understood; moot once commits work.
- Debugging WeType: its IMK calls are in `/usr/bin/log show --predicate 'process == "WeType"'` (zsh's `log`
  builtin shadows the tool). Its own `~/Library/Caches/WeType/Logs/*.xlog` are encrypted, but `strings` on
  its binary shows its log messages and config keys. Dictation started within ~1s of popcode opening can
  miss the input session (WeType then delivers the text to the clipboard).
