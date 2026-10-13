# markdown-console.nvim

I learned Neovim a bit over a year ago. Then AI got good (enough).

Now I need markdown in my terminal because I need to read and curate all the slop. So I made AI make me this slop plugin to read and edit markdown in neovim. Then I proceeded to __not__ read and edit it. Enjoy.

## Features

- **Normal mode**: rendered markdown with highlight groups
  - Headings: level 1 with a full-width background bar, level 2 underlined,
    levels 3-6 bold, each in its own colour
  - Bullet / numbered lists
  - Code blocks with box-drawing borders, a language label, and optional
    treesitter syntax highlighting (lua, python, js/ts, rust, go, bash, ...)
  - Blockquotes with a `▏` prefix
  - Tables with aligned columns
  - Mermaid flowcharts (```mermaid) drawn as Unicode boxes and arrows, with no
    external tools
  - Horizontal rules
  - Inline **bold**, *italic*, `code`, [links](url), ![images](url)
- **Editing** (insert / replace / visual): raw markdown source
- **Automatic switching**: any way you enter or leave an editing mode
  (`i`, `a`, `o`, `cc`, `s`, `R`, `v`, `<Esc>`, ...) switches the view
- **`:MarkdownConsoleToggle`** to switch the view by hand
- **Saving** writes the raw markdown source, never the rendered view
- **Native undo**: because the buffer text is never changed, `u`/`<C-r>` work
  for every edit, in normal *and* insert mode
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
  manages, because it draws its own highlights and full-line conceal over the raw
  text.
- Mermaid support covers `graph` / `flowchart` diagrams (TD/TB/BT/LR/RL). It is a
  best-effort layout: unrecognised directives are ignored and an unrenderable
  diagram is left as raw source.

## How It Works

1. The buffer always holds the raw source. In normal mode text lines (headings,
   paragraphs, lists, quotes) conceal their markdown syntax with extmarks and
   keep the text itself real, so the cursor moves over the rendered line and it
   wraps with `wrap` like any other line.
2. Blocks whose rendered shape differs from the source (code boxes, tables,
   mermaid diagrams) get an extmark that fully conceals the block and draws the
   rendered form as an overlay (`virt_text_pos = "overlay"`).
3. Conceal does not shrink the width Neovim wraps at, so a text line that would
   wrap *and* hide a long run (a URL) is left as raw source instead, which wraps
   cleanly without a gap.
4. Entering an editing mode clears the view and turns conceal off, so the raw
   source reappears; leaving it renders again. This is driven entirely by
   `ModeChanged`, so every editing entry point is covered.
5. The buffer text is never touched, so `u`/`<C-r>` behave natively, the
   `modified` flag reflects only your own edits, and saving writes the buffer
   directly (no `BufWriteCmd`).

## Commands

- `:MarkdownConsoleToggle` - toggle between the rendered and raw view

## Requirements

- Neovim 0.9+
- A 24-bit colour terminal for the default colours

## License

MIT
