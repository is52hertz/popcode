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
- Don't add custom glass/visual-effect backgrounds inside the popover; Apple's Liquid Glass guidance
  says to let the system draw popover backgrounds (a custom borderless glass panel showed a stray frame).
- AppKit has no public scroll edge effect for a free-standing scroll view (`NSScrollEdgeEffectStyle`
  is only for titlebar/split-view accessories), so the overflow fade + blur in `EditorContainerView`
  is hand-rolled.
- Markdown styling runs only for `.md`/`.markdown` files (so git's `COMMIT_EDITMSG` `#` comments
  are not turned into headings) and is skipped while the IME has marked text.
- osascript keystrokes and `screencapture` are not permitted from the agent shell here, so focus/IME
  behavior must be checked by hand.
