-- markdown-console.nvim
--
-- Shows a rendered view of a markdown buffer while you are in normal mode and
-- the raw source while you are editing (insert / replace / visual). The buffer
-- itself always holds the source; only the view is swapped in and out.
--
-- The plugin does its own highlighting, so it keeps the native treesitter
-- highlighter switched off for the buffers it manages. Replacing a whole buffer
-- while a highlighter is parsing leaves the language tree holding nodes that no
-- longer exist, which raises "attempt to call method 'range' (a nil value)" on
-- the next redraw and breaks the switch back to raw.

local M = {}

local ns = vim.api.nvim_create_namespace('markdown_console')

-- bufnr -> raw source lines, present only while the rendered view is shown
local managed = {}
-- reentrancy guard for the whole render/restore cycle
local busy = false

----------------------------------------------------------------------
-- buffer helpers
----------------------------------------------------------------------

-- Replace the whole buffer for a view swap. Undo is disabled for the change so
-- the swap itself never becomes an undo step, and the 'modified' flag is
-- restored so viewing never makes the buffer look edited. The cursor is kept in
-- place (clamped to the new text) so editing continues where it was.
local function set_lines(buf, lines)
  local win = vim.fn.bufwinid(buf)
  local cur = win ~= -1 and vim.api.nvim_win_get_cursor(win) or nil
  local bo = vim.bo[buf]
  local old_undolevels, old_modified = bo.undolevels, bo.modified
  bo.undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  bo.undolevels = old_undolevels
  bo.modified = old_modified
  if cur and vim.api.nvim_win_is_valid(win) then
    local line = math.min(cur[1], vim.api.nvim_buf_line_count(buf))
    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
    pcall(vim.api.nvim_win_set_cursor, win, { line, math.min(cur[2], #text) })
  end
end

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
-- when there is no parser / query for the language. Errors are swallowed: a
-- missing parser must never stop the block from rendering.
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
-- rendering
----------------------------------------------------------------------

local function box_width(cells)
  return math.max(40, math.min(100, cells + 3))
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function pad(text, cells)
  return text .. string.rep(' ', math.max(0, cells - display_width(text)))
end

-- Build the displayed lines and the per-line highlight marks.
-- bar = width to pad level-1 headings to (for a full-width background bar).
-- Returns { lines = { string }, marks = { [line_idx] = { {start,end,group}, ... } } }
local function build(lines, bar)
  local out, marks = {}, {}
  local idx = 0

  local function push(text, line_marks)
    out[#out + 1] = text
    if line_marks then marks[idx] = line_marks end
    idx = idx + 1
  end

  local function push_segs(prefix, prefix_group, segs, base_group)
    local text, lm, col = prefix, {}, #prefix
    if prefix_group and #prefix > 0 then lm[#lm + 1] = { 0, #prefix, prefix_group } end
    for _, s in ipairs(segs) do
      if base_group and #s.text > 0 then lm[#lm + 1] = { col, col + #s.text, base_group } end
      if s.hl and #s.text > 0 then lm[#lm + 1] = { col, col + #s.text, s.hl } end
      text = text .. s.text
      col = col + #s.text
    end
    push(text, lm)
  end

  for _, b in ipairs(parse(lines)) do
    if b.kind == 'blank' then
      push('')

    elseif b.kind == 'heading' then
      local prefix = string.rep('#', b.level) .. ' '
      local base = 'MarkdownConsoleH' .. b.level
      local pgroup = b.level == 1 and 'MarkdownConsoleH1Prefix' or 'MarkdownConsoleHPrefix'
      local text = prefix
      for _, s in ipairs(b.segs) do text = text .. s.text end
      -- level 1 gets a full-width background bar
      if b.level == 1 and bar and #text < bar then text = pad(text, bar) end
      local lm = { { 0, #text, base }, { 0, #prefix, pgroup } }
      local col = #prefix
      for _, s in ipairs(b.segs) do
        if s.hl and #s.text > 0 then lm[#lm + 1] = { col, col + #s.text, s.hl } end
        col = col + #s.text
      end
      push(text, lm)

    elseif b.kind == 'paragraph' then
      push_segs('', nil, b.segs, nil)

    elseif b.kind == 'list' then
      local prefix = b.marker == '-' and '  • ' or ('  ' .. b.marker .. '. ')
      push_segs(prefix, 'MarkdownConsoleList', b.segs, nil)

    elseif b.kind == 'hr' then
      push(string.rep('─', 40), { { 0, 40 * #'─', 'MarkdownConsoleHr' } })

    elseif b.kind == 'quote' then
      for _, q in ipairs(b.lines) do
        push_segs('▏ ', 'MarkdownConsoleQuote', q, 'MarkdownConsoleQuote')
      end

    elseif b.kind == 'code' then
      local widest = 0
      for _, l in ipairs(b.lines) do widest = math.max(widest, display_width(l)) end
      local width = box_width(math.max(widest, b.lang ~= '' and (display_width(b.lang) + 1) or 0))
      local inner = width - 2
      local fence = 'MarkdownConsoleFence'
      local function boxline(content)
        local line = '│' .. pad(content, inner) .. '│'
        push(line, { { 0, #line, fence } })
      end
      local top = '┌' .. string.rep('─', inner) .. '┐'
      local bot = '└' .. string.rep('─', inner) .. '┘'
      push(top, { { 0, #top, fence } })
      local langline = ' ' .. b.lang
      local lm = { { 0, #('│' .. pad(langline, inner) .. '│'), fence } }
      if b.lang ~= '' then
        lm[#lm + 1] = { #'│' + 1, #'│' + 1 + #b.lang, 'MarkdownConsoleCodeLang' }
      end
      push('│' .. pad(langline, inner) .. '│', lm)
      local start = idx
      for _, l in ipairs(b.lines) do
        boxline(' ' .. l)
      end
      -- base colour for the code body, then optional treesitter highlights on
      -- top (later extmarks win); the body starts four bytes in, after "│ ".
      for k = start, idx - 1 do
        marks[k] = { { 0, #out[k + 1], 'MarkdownConsoleCode' } }
      end
      for line, list in pairs(code_marks(b.lines, b.lang) or {}) do
        for _, m in ipairs(list) do
          local target = marks[start + line]
          if target then
            target[#target + 1] = { 4 + m[1], math.min(4 + m[2], #out[start + line + 1]), m[3] }
          end
        end
      end
      push(bot, { { 0, #bot, fence } })

    elseif b.kind == 'table' then
      local ncol = 0
      for _, r in ipairs(b.rows) do ncol = math.max(ncol, #r) end
      local widths = {}
      for c = 1, ncol do
        for _, r in ipairs(b.rows) do
          local cell = r[c] or ''
          widths[c] = math.max(widths[c] or 0, display_width(seg_text(inline(cell))))
        end
      end
      for ri, r in ipairs(b.rows) do
        local cells = {}
        for c = 1, ncol do
          cells[c] = pad(seg_text(inline(r[c] or '')), widths[c])
        end
        local line = ' ' .. table.concat(cells, ' │ ') .. ' '
        push(line, { { 0, #line, ri == 1 and 'MarkdownConsoleTableHeader' or 'MarkdownConsoleTableRow' } })
        if ri == 1 then
          local sep = string.rep('─', display_width(line))
          push(sep, { { 0, #sep, 'MarkdownConsoleTableSep' } })
        end
      end
    end
  end

  return { lines = out, marks = marks }
end

----------------------------------------------------------------------
-- view switching
----------------------------------------------------------------------

local function render(buf, force)
  if busy or not md(buf) or not shown(buf) then return end
  if managed[buf] and not force then return end
  busy = true
  local ok, err = pcall(function()
    local raw = managed[buf] or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local built = build(raw, text_width(vim.fn.bufwinid(buf)) - 2)
    ts_off(buf)
    set_lines(buf, built.lines)
    managed[buf] = raw
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for line, line_marks in pairs(built.marks) do
      for _, m in ipairs(line_marks) do
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, m[1], {
          end_col = m[2],
          hl_group = m[3],
        })
      end
    end
  end)
  busy = false
  if not ok then
    vim.notify('markdown-console: render failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function restore(buf)
  if busy then return end
  local raw = managed[buf]
  if not raw or not shown(buf) then return end
  busy = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  ts_off(buf)
  set_lines(buf, raw)
  managed[buf] = nil
  busy = false
end

local function toggle()
  local buf = vim.api.nvim_get_current_buf()
  if managed[buf] then restore(buf) else render(buf) end
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

  -- nvim-treesitter (and others) start the native highlighter on FileType; let
  -- them run, then switch it back off for markdown buffers.
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'markdown',
    callback = function(args)
      local buf = args.buf
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then ts_off(buf) end
      end)
    end,
  })

  -- Render when a managed markdown buffer is shown while in normal mode.
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufEnter' }, {
    pattern = MD_PATTERN,
    callback = function(args)
      if vim.fn.mode() == 'n' then render(args.buf) end
    end,
  })

  -- Raw source while editing, rendered view otherwise. ModeChanged covers every
  -- transition into and out of an editing mode (insert, replace, visual). Only
  -- react to entering/leaving an editing mode, so a manual toggle back to raw is
  -- not undone when the command line is left.
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

  -- Write the source to disk. While the rendered view is shown the buffer holds
  -- the rendered text, so write raw straight from the saved copy; doing this
  -- through BufWriteCmd keeps the buffer (and its undo history) untouched.
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    pattern = MD_PATTERN,
    callback = function(args)
      local buf = args.buf
      local raw = managed[buf] or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local name = args.file ~= '' and args.file or vim.api.nvim_buf_get_name(buf)
      local sep = vim.bo[buf].fileformat == 'dos' and '\r\n' or '\n'
      local text = table.concat(raw, sep)
      if vim.bo[buf].endofline then text = text .. sep end
      local fd, err = io.open(name, 'wb')
      if not fd then
        vim.notify('markdown-console: write failed: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end
      fd:write(text)
      fd:close()
      vim.bo[buf].modified = false
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    callback = function(args)
      managed[args.buf] = nil
    end,
  })

  -- Keep the level-1 background bar spanning the window.
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    callback = function()
      for buf in pairs(managed) do
        if vim.api.nvim_buf_is_valid(buf) then render(buf, true) end
      end
    end,
  })

  vim.api.nvim_create_user_command('MarkdownConsoleToggle', toggle, {})
end

return M
