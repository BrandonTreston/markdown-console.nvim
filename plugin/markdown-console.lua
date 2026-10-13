if vim.g.loaded_markdown_console then return end
vim.g.loaded_markdown_console = 1

require('markdown-console').setup()