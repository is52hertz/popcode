# popcode

A floating, Dictionary-style editor for `$VISUAL` on macOS. Press Ctrl+G in Claude Code (or run
`git commit`) and a glass panel pops up over the bottom of your terminal window.

| Key | Action |
| --- | --- |
| ⌘↩ / ⌘S | Save and close |
| Esc | Close without saving (press twice if there are changes) |
| ⌘F | Find |

`.md` files get Obsidian-style source highlighting: larger headings, bold/italic applied, markers dimmed.

## Install

```sh
swift build -c release
ln -sf "$PWD/.build/release/popcode" ~/.local/bin/popcode
```

Then in `~/.zshrc` (skipped over SSH, where there is no GUI):

```sh
[[ -z $SSH_CONNECTION ]] && export VISUAL=popcode
```

Keep `code` in the binary name: Claude Code uses it to keep the TUI visible while the editor is open.
