# markdown-console.nvim

Shows a rendered view of a markdown buffer in normal mode and the raw source
while you are editing. The buffer always holds the source; only the view is
swapped in and out.

## Features

- **Normal mode**: rendered markdown with highlight groups
  - Headings: level 1 with a full-width background bar, level 2 underlined,
    levels 3-6 bold, each in its own colour
  - Bullet / numbered lists
  - Code blocks with box-drawing borders, a language label, and optional
    treesitter syntax highlighting (lua, python, js/ts, rust, go, bash, ...)
  - Blockquotes with a `▏` prefix
  - Tables with aligned columns
  - Horizontal rules
  - Inline **bold**, *italic*, `code`, [links](url), ![images](url)
- **Editing** (insert / replace / visual): raw markdown source
- **Automatic switching**: any way you enter or leave an editing mode
  (`i`, `a`, `o`, `cc`, `s`, `R`, `v`, `<Esc>`, ...) switches the view
- **`:MarkdownConsoleToggle`** to switch the view by hand
- **Saving** writes the raw markdown source, never the rendered view
- **Non-intrusive**: viewing a file never marks the buffer modified and never
  becomes an undo step

## Installation

### lazy.nvim

```lua
{
  'BrandonTreston/markdown-console.nvim',
  ft = 'markdown',
  config = function()
    require('markdown-console').setup()
  end,
}
```

### packer.nvim

```lua
use {
  'BrandonTreston/markdown-console.nvim',
  ft = 'markdown',
  config = function()
    require('markdown-console').setup()
  end,
}
```

## Usage

Open a `.md` file: it renders. Press `i` (or `a`, `o`, `cc`, `s`, `R`, ...) to
get the raw source back, edit, and press `<Esc>` to render again. Visual mode
also shows the raw source. `:MarkdownConsoleToggle` flips the view manually.

## Notes

- Code block syntax highlighting uses Neovim's treesitter string parser and
  silently falls back to plain coloring when the parser or query for a language
  is not installed.
- Highlight groups are set with `default = true`, so you can override any of
  them (`MarkdownConsoleH1` ... `MarkdownConsoleH6`, `MarkdownConsoleCode`,
  `MarkdownConsoleLink`, ...) from your own colorscheme or config.
- The plugin turns Neovim's native markdown highlighter off for the buffers it
  manages, because it replaces the whole buffer and draws its own highlights.

## How It Works

1. When a markdown buffer is shown in normal mode it is parsed and the rendered
   lines are written into the buffer, with highlights applied as extmarks.
2. Entering an editing mode restores the saved source lines; leaving it renders
   again. This is driven entirely by `ModeChanged`, so every editing entry point
   is covered.
3. Saving goes through `BufWriteCmd`, which writes the saved source lines to
   disk without touching the buffer.

## Commands

- `:MarkdownConsoleToggle` - toggle between the rendered and raw view

## Requirements

- Neovim 0.9+
- A 24-bit colour terminal for the default colours

## License

MIT
