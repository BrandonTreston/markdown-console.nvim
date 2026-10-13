-- markdown-console.nvim
--
-- Shows a rendered view of a markdown buffer while you are in normal mode and
-- the raw source while you are editing (insert / replace / visual).
--
-- The buffer text is NEVER changed. The rendered view is drawn as a per-line
-- overlay (virt_text_pos = "overlay"): for each source line an extmark draws the
-- rendered form on top of the raw text and, where the rendered form is shorter,
-- pads it so the raw text underneath is fully hidden. Entering an editing mode
-- simply clears the overlay, so the raw source reappears.
--
-- Because the buffer is left alone, Neovim's own undo/redo works for every edit
-- (insert and normal alike), the buffer only becomes 'modified' when you
-- actually edit it, and saving writes the buffer directly - no BufWriteCmd.

local M = {}

local ns = vim.api.nvim_create_namespace('markdown_console')

-- bufnr -> true while the rendered overlay is shown
local rendered = {}
-- reentrancy guard
local busy = false

local function tw(s)
  return vim.fn.strdisplaywidth(s)
end

----------------------------------------------------------------------
-- buffer helpers
----------------------------------------------------------------------

local function ts_off(buf)
  if vim.treesitter and vim.treesitter.highlighter then
    pcall(vim.treesitter.stop, buf)
  end
end

local function shown(buf)
  return vim.fn.bufwinid(buf) ~= -1
end

-- Usable text width of the window a buffer is shown in, for full-width bars.
local function text_width(win)
  local w = vim.api.nvim_win_get_width(win)
  local wo = vim.wo[win]
  local num = (wo.number or wo.relativenumber) and wo.numberwidth or 0
  local sign = wo.signcolumn == 'no' and 0 or 1
  local fold = tonumber(wo.foldcolumn) or 0
  return math.max(10, w - num - sign - fold)
end

-- Files the plugin manages. Keying on the file name (not just 'filetype') keeps
-- the render source and the mode switch in agreement even when markdown file
-- type detection is off or overridden.
local MD_PATTERN = '*.md,*.markdown,*.mdx'
local function md(buf)
  if vim.bo[buf].buftype ~= '' then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  return name:match('%.md$') ~= nil
    or name:match('%.markdown$') ~= nil
    or name:match('%.mdx$') ~= nil
end

local function is_raw_mode(mode)
  local c = mode:sub(1, 1)
  return c == 'i' or c == 'R' or c == 'v' or c == 'V' or c == 's' or c == 'S'
    or mode:byte(1) == 22 -- Ctrl-V (blockwise visual)
end

----------------------------------------------------------------------
-- inline markdown
----------------------------------------------------------------------

-- group 1 is the text shown in place of the markup
local INLINE = {
  { '`([^`]+)`', 'MarkdownConsoleCode' },
  { '!%[([^%]]*)%]%(([^%)]*)%)', 'MarkdownConsoleImage' },
  { '%[([^%]]*)%]%(([^%)]*)%)', 'MarkdownConsoleLink' },
  { '%*%*([^%*]+)%*%*', 'MarkdownConsoleBold' },
  { '__([^_]+)__', 'MarkdownConsoleBold' },
  { '%*([^%*]+)%*', 'MarkdownConsoleItalic' },
  { '_([^_]+)_', 'MarkdownConsoleItalic' },
}

-- Split a line into { text = string, hl = group|nil } segments, dropping markup.
local function inline(text)
  local out, pos = {}, 1
  while pos <= #text do
    local bs, be, bgrp, bhl
    for _, p in ipairs(INLINE) do
      local s, e, grp = text:find(p[1], pos)
      if s and (not bs or s < bs) then
        bs, be, bgrp, bhl = s, e, grp, p[2]
      end
    end
    if not bs then
      out[#out + 1] = { text = text:sub(pos) }
      break
    end
    if bs > pos then
      out[#out + 1] = { text = text:sub(pos, bs - 1) }
    end
    out[#out + 1] = { text = bgrp, hl = bhl }
    pos = be + 1
  end
  return out
end

local function seg_text(segs)
  local t = {}
  for _, s in ipairs(segs) do t[#t + 1] = s.text end
  return table.concat(t)
end

----------------------------------------------------------------------
-- code block syntax highlighting (optional, via the treesitter string parser)
----------------------------------------------------------------------

local TS_LANG = {
  lua = 'lua', python = 'python', javascript = 'javascript', js = 'javascript',
  typescript = 'typescript', ts = 'typescript', bash = 'bash', sh = 'bash',
  json = 'json', yaml = 'yaml', yml = 'yaml', toml = 'toml', rust = 'rust',
  go = 'go', c = 'c', cpp = 'cpp', java = 'java', html = 'html', css = 'css',
  scss = 'scss', sql = 'sql', markdown = 'markdown', md = 'markdown',
}

-- Returns { [line_index] = { {start, end, group}, ... } } for the block, or nil
-- when there is no parser / query for the language. Ranges are 0-based bytes.
-- Errors are swallowed: a missing parser must never stop the block rendering.
local function code_marks(body, lang)
  local ts_lang = TS_LANG[lang:lower()]
  if not ts_lang then return nil end
  local ok, res = pcall(function()
    local text = table.concat(body, '\n')
    local parser = vim.treesitter.get_string_parser(text, ts_lang)
    local tree = parser:parse()[1]
    local query = vim.treesitter.query.get(ts_lang, 'highlights')
    if not tree or not query then return nil end
    local out = {}
    for _, match in query:iter_matches(tree:root(), text, 0, -1) do
      for id, nodes in pairs(match) do
        local cap = query.captures[id]
        for _, node in ipairs(nodes) do
          local sr, sc, er, ec = node:range()
          if sr == er then
            out[sr] = out[sr] or {}
            out[sr][#out[sr] + 1] = { sc, ec, '@' .. cap }
          end
        end
      end
    end
    return out
  end)
  return ok and res or nil
end

-- Turn a code line plus its treesitter ranges into highlight chunks.
local function code_chunks(line, marks)
  local cs = {}
  if not marks or #marks == 0 then
    if #line > 0 then cs[#cs + 1] = { line, 'MarkdownConsoleCode' } end
    return cs
  end
  table.sort(marks, function(a, b) return a[1] < b[1] end)
  local pos = 0
  for _, m in ipairs(marks) do
    local s, e, g = m[1], m[2], m[3]
    if s >= pos then
      if s > pos then cs[#cs + 1] = { line:sub(pos + 1, s), 'MarkdownConsoleCode' } end
      if e > s then cs[#cs + 1] = { line:sub(s + 1, e), g } end
      if e > pos then pos = e end
    elseif e > pos then
      -- overlapping tail of a nested capture
      cs[#cs + 1] = { line:sub(pos + 1, e), g }
      pos = e
    end
  end
  if pos < #line then cs[#cs + 1] = { line:sub(pos + 1), 'MarkdownConsoleCode' } end
  return cs
end

----------------------------------------------------------------------
-- block parsing
----------------------------------------------------------------------

local function parse(lines)
  local blocks, i = {}, 1
  while i <= #lines do
    local line = lines[i]
    local hashes = line:match('^(#+)%s')
    local next_ = function() i = i + 1 end

    if line:match('^%s*$') then
      blocks[#blocks + 1] = { kind = 'blank' }
    elseif hashes and #hashes <= 6 then
      blocks[#blocks + 1] = { kind = 'heading', level = #hashes, segs = inline(line:sub(#hashes + 2)) }
    elseif line:match('^```') then
      local lang = vim.trim(line:sub(4))
      local body = {}
      next_()
      while i <= #lines and not lines[i]:match('^```') do
        body[#body + 1] = lines[i]
        next_()
      end
      blocks[#blocks + 1] = { kind = 'code', lang = lang, lines = body }
    elseif line:match('^%s*>') then
      local quote = {}
      while i <= #lines and lines[i]:match('^%s*>') do
        quote[#quote + 1] = inline((lines[i]:gsub('^%s*>%s?', '')))
        next_()
      end
      i = i - 1
      blocks[#blocks + 1] = { kind = 'quote', lines = quote }
    elseif line:match('^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_%s]*$') and #line >= 3 then
      blocks[#blocks + 1] = { kind = 'hr' }
    elseif line:match('^%s*[%-%*+]%s+') then
      blocks[#blocks + 1] = { kind = 'list', marker = '-', segs = inline((line:gsub('^%s*[%-%*+]%s+', ''))) }
    elseif line:match('^%s*%d+%.%s+') then
      blocks[#blocks + 1] = { kind = 'list', marker = line:match('^%s*(%d+)'), segs = inline((line:gsub('^%s*%d+%.%s+', ''))) }
    elseif line:match('^|.*|%s*$') then
      local rows = {}
      while i <= #lines and lines[i]:match('^|.*|%s*$') do
        local body = vim.trim(lines[i]):gsub('^|', ''):gsub('|$', '')
        local cells, is_sep = {}, true
        for cell in (body .. '|'):gmatch('([^|]*)|') do
          local trimmed = vim.trim(cell)
          cells[#cells + 1] = trimmed
          if not trimmed:match('^:?-+:?$') then is_sep = false end
        end
        if not is_sep then rows[#rows + 1] = cells end
        next_()
      end
      i = i - 1
      blocks[#blocks + 1] = { kind = 'table', rows = rows }
    else
      blocks[#blocks + 1] = { kind = 'paragraph', segs = inline(line) }
    end
    next_()
  end
  return blocks
end

----------------------------------------------------------------------
-- rendering: one row per source line, as highlight chunks
----------------------------------------------------------------------

local function box_width(cells)
  return math.max(40, math.min(100, cells + 3))
end

local function pad(text, cells)
  return text .. string.rep(' ', math.max(0, cells - tw(text)))
end

-- Build one row (list of {text, hl} chunks) for each source line, so the rows
-- line up 1:1 with the buffer and can be overlaid directly. Each row may carry:
--   fill  - highlight group used for the padding that hides the raw text
--   min   - minimum display width (full-width level-1 heading bar)
local function build_rows(lines, bar)
  local rows = {}

  local function put(chunks, fill, min)
    rows[#rows + 1] = { chunks = chunks or {}, fill = fill, min = min }
  end

  local function plain(segs, base)
    local cs = {}
    for _, s in ipairs(segs) do
      if #s.text > 0 then
        cs[#cs + 1] = (s.hl or base) and { s.text, s.hl or base } or { s.text }
      end
    end
    return cs
  end

  for _, b in ipairs(parse(lines)) do
    if b.kind == 'blank' then
      put({})

    elseif b.kind == 'heading' then
      local base = 'MarkdownConsoleH' .. b.level
      local pgroup = b.level == 1 and 'MarkdownConsoleH1Prefix' or 'MarkdownConsoleHPrefix'
      local cs = { { string.rep('#', b.level) .. ' ', pgroup } }
      for _, s in ipairs(b.segs) do
        cs[#cs + 1] = (s.hl and { s.text, s.hl }) or { s.text, base }
      end
      put(cs, base, b.level == 1 and bar or nil)

    elseif b.kind == 'paragraph' then
      put(plain(b.segs, nil))

    elseif b.kind == 'list' then
      local prefix = b.marker == '-' and '  • ' or ('  ' .. b.marker .. '. ')
      local cs = { { prefix, 'MarkdownConsoleList' } }
      for _, s in ipairs(plain(b.segs, nil)) do cs[#cs + 1] = s end
      put(cs)

    elseif b.kind == 'hr' then
      put({ { string.rep('─', 40), 'MarkdownConsoleHr' } })

    elseif b.kind == 'quote' then
      for _, q in ipairs(b.lines) do
        local cs = { { '▏ ', 'MarkdownConsoleQuote' } }
        for _, s in ipairs(plain(q, 'MarkdownConsoleQuote')) do cs[#cs + 1] = s end
        put(cs)
      end

    elseif b.kind == 'code' then
      local widest = 0
      for _, l in ipairs(b.lines) do widest = math.max(widest, tw(l)) end
      local extra = b.lang ~= '' and (tw(b.lang) + 4) or 0
      local width = box_width(math.max(widest, extra))
      local inner = width - 2
      local Fence = 'MarkdownConsoleFence'
      -- The language label rides on the top border so the block stays exactly
      -- as many rows as it has source lines.
      if b.lang ~= '' then
        local head = '─ ' .. b.lang .. ' '
        local dashes = string.rep('─', math.max(0, inner - tw(head)))
        put({ { '┌─ ', Fence }, { b.lang, 'MarkdownConsoleCodeLang' }, { ' ' .. dashes .. '┐', Fence } })
      else
        put({ { '┌' .. string.rep('─', inner) .. '┐', Fence } })
      end
      local cm = code_marks(b.lines, b.lang) or {}
      for k, l in ipairs(b.lines) do
        local cs = { { '│', Fence }, { ' ', 'MarkdownConsoleCode' } }
        for _, c in ipairs(code_chunks(l, cm[k])) do cs[#cs + 1] = c end
        local fillw = math.max(0, inner - 1 - tw(l))
        if fillw > 0 then cs[#cs + 1] = { string.rep(' ', fillw), Fence } end
        cs[#cs + 1] = { '│', Fence }
        put(cs)
      end
      put({ { '└' .. string.rep('─', inner) .. '┘', Fence } })

    elseif b.kind == 'table' then
      local ncol = 0
      for _, r in ipairs(b.rows) do ncol = math.max(ncol, #r) end
      local widths = {}
      for c = 1, ncol do
        for _, r in ipairs(b.rows) do
          local cell = r[c] or ''
          widths[c] = math.max(widths[c] or 0, tw(seg_text(inline(cell))))
        end
      end
      for ri, r in ipairs(b.rows) do
        local cells = {}
        for c = 1, ncol do cells[c] = pad(seg_text(inline(r[c] or '')), widths[c]) end
        local line = ' ' .. table.concat(cells, ' │ ') .. ' '
        put({ { line, ri == 1 and 'MarkdownConsoleTableHeader' or 'MarkdownConsoleTableRow' } })
        if ri == 1 then
          put({ { string.rep('─', tw(line)), 'MarkdownConsoleTableSep' } })
        end
      end
    end
  end

  return rows
end

----------------------------------------------------------------------
-- overlay
----------------------------------------------------------------------

-- Set a window option on every window showing the buffer.
local function set_win_opt(buf, name, val)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then vim.wo[win][name] = val end
  end
end

local function clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

-- The raw line is fully concealed so it takes no room (no wrapping, no bleed
-- through) and the rendered text is drawn over it. Neovim's undo is untouched
-- because the buffer text is never changed.
local function render(buf, force)
  if busy or not md(buf) or not shown(buf) then return end
  if rendered[buf] and not force then
    set_win_opt(buf, 'conceallevel', 2)
    set_win_opt(buf, 'concealcursor', 'n')
    return
  end
  busy = true
  local ok, err = pcall(function()
    -- Native highlighting must be off before conceal is enabled: the treesitter
    -- conceal_line decoration provider errors on a live tree.
    ts_off(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local bar = text_width(vim.fn.bufwinid(buf)) - 2
    local rows = build_rows(lines, bar)
    clear(buf)
    for i = 1, #lines do
      local row = rows[i]
      if row and #row.chunks > 0 then
        local width = 0
        for _, c in ipairs(row.chunks) do width = width + tw(c[1]) end
        local target = math.max(width, row.min or 0)
        if target > width then
          local space = string.rep(' ', target - width)
          row.chunks[#row.chunks + 1] = row.fill and { space, row.fill } or { space }
        end
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
          end_col = #lines[i],
          conceal = '',
          virt_text = row.chunks,
          virt_text_pos = 'overlay',
          hl_mode = 'replace',
          priority = 100,
        })
      else
        -- nothing to show (blank line): still conceal so nothing bleeds
        if #lines[i] > 0 then
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
            end_col = #lines[i], conceal = '',
          })
        end
      end
    end
    set_win_opt(buf, 'conceallevel', 2)
    set_win_opt(buf, 'concealcursor', 'n')
    rendered[buf] = true
  end)
  busy = false
  if not ok then
    vim.notify('markdown-console: render failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function restore(buf)
  if busy or not rendered[buf] then return end
  busy = true
  clear(buf)
  set_win_opt(buf, 'conceallevel', 0)
  rendered[buf] = nil
  busy = false
end

local function toggle()
  local buf = vim.api.nvim_get_current_buf()
  if rendered[buf] then restore(buf) else render(buf, true) end
end

----------------------------------------------------------------------
-- highlights
----------------------------------------------------------------------

local function base(groups)
  for group, opts in pairs(groups) do
    vim.api.nvim_set_hl(0, group, vim.tbl_extend('force', { default = true }, opts))
  end
end

-- Colours are only defaults: with default = true any highlight the user (or the
-- colorscheme) defines wins. Non-colour attributes are linked to built-ins so
-- they keep working on light and dark themes.
local function setup_highlights()
  base({
    MarkdownConsoleH1 = { fg = '#ffb3b3', bold = true, bg = '#59202a' },
    MarkdownConsoleH2 = { fg = '#ffd93d', bold = true, underline = true },
    MarkdownConsoleH3 = { fg = '#6bcb77', bold = true },
    MarkdownConsoleH4 = { fg = '#4d96ff', bold = true },
    MarkdownConsoleH5 = { fg = '#bb6bff', bold = true },
    MarkdownConsoleH6 = { fg = '#6bcaff', bold = true },
    MarkdownConsoleHPrefix = { fg = '#888888', bold = true },
    MarkdownConsoleH1Prefix = { fg = '#ffb3b3', bold = true, bg = '#59202a' },
    MarkdownConsoleList = { fg = '#ffd93d' },
    MarkdownConsoleCode = { fg = '#c8a060' },
    MarkdownConsoleFence = { fg = '#6c6c6c' },
    MarkdownConsoleCodeLang = { fg = '#ffd93d', bold = true, italic = true },
    MarkdownConsoleQuote = { fg = '#6c6c6c', italic = true },
    MarkdownConsoleHr = { fg = '#6c6c6c' },
    MarkdownConsoleBold = { bold = true },
    MarkdownConsoleItalic = { italic = true },
    MarkdownConsoleLink = { fg = '#4d96ff', underline = true },
    MarkdownConsoleImage = { fg = '#6c6c6c' },
    MarkdownConsoleTableHeader = { bold = true },
    MarkdownConsoleTableRow = {},
    MarkdownConsoleTableSep = { fg = '#6c6c6c' },
  })
end

----------------------------------------------------------------------
-- setup
----------------------------------------------------------------------

local did_setup = false

function M.setup()
  if did_setup then return end
  did_setup = true

  setup_highlights()

  -- nvim-treesitter (and others) start the native highlighter on FileType; the
  -- overlay draws its own highlights, so switch it back off for markdown.
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'markdown',
    callback = function(args)
      local buf = args.buf
      ts_off(buf)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then ts_off(buf) end
      end)
    end,
  })

  -- Draw the overlay when a managed markdown buffer is shown in normal mode.
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufEnter' }, {
    pattern = MD_PATTERN,
    callback = function(args)
      if vim.fn.mode() == 'n' then render(args.buf) end
    end,
  })

  -- Raw source while editing, rendered view otherwise. ModeChanged covers every
  -- transition into and out of an editing mode (insert, replace, visual).
  vim.api.nvim_create_autocmd('ModeChanged', {
    callback = function(args)
      if not md(args.buf) then return end
      local ev = vim.v.event
      local old_mode, new_mode = ev.old_mode, ev.new_mode
      if not new_mode and args.match then
        old_mode, new_mode = args.match:match('^(.-):(.*)$')
      end
      old_mode = old_mode or vim.fn.mode(1)
      new_mode = new_mode or vim.fn.mode(1)
      if is_raw_mode(new_mode) then
        restore(args.buf)
      elseif is_raw_mode(old_mode) then
        render(args.buf)
      end
    end,
  })

  -- A normal-mode edit (or an undo/redo) changes the text under the overlay, so
  -- redraw it to match. Only in normal mode; the overlay is cleared while editing.
  vim.api.nvim_create_autocmd('TextChanged', {
    callback = function(args)
      if not md(args.buf) or is_raw_mode(vim.fn.mode(1)) then return end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) and not is_raw_mode(vim.fn.mode(1)) then
          render(args.buf, true)
        end
      end)
    end,
  })

  -- Keep the level-1 background bar spanning the window.
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    callback = function()
      for buf in pairs(rendered) do
        if vim.api.nvim_buf_is_valid(buf) then render(buf, true) end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    callback = function(args)
      rendered[args.buf] = nil
    end,
  })

  vim.api.nvim_create_user_command('MarkdownConsoleToggle', toggle, {})
end

return M
