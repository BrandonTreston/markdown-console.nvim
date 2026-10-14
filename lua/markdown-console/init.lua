-- markdown-console.nvim
--
-- Shows a rendered view of a markdown buffer while you are in normal mode and
-- the raw source while you are editing (insert / replace / visual).
--
-- The buffer text is NEVER changed. The rendered view is drawn with extmarks:
--
--   * Text lines (headings, paragraphs, lists, quotes) conceal the markdown
--     syntax and keep the text itself real, so the cursor moves naturally over
--     the rendered line and it wraps with 'wrap' like any other line.
--   * Blocks whose rendered shape differs from the source (code boxes, tables,
--     mermaid diagrams) fall back to a whole-line overlay (virt_text_pos =
--     "overlay"): the raw text is concealed and the rendered form is drawn on
--     top.
--
-- Conceal hides the syntax but does not shrink the width Neovim wraps at - the
-- hidden cells still count - so on a line that wraps a concealed run leaves a
-- gap as wide as the run it hid (worst for long URLs). Text is concealed only
-- when the line fits (so it cannot wrap) or its hidden runs are short; a line
-- that wraps and hides a long run is left as raw source, which wraps cleanly.
-- Entering an editing mode clears everything, so the raw source reappears.
--
-- Because the buffer is left alone, Neovim's own undo/redo works for every edit
-- (insert and normal alike), the buffer only becomes 'modified' when you
-- actually edit it, and saving writes the buffer directly - no BufWriteCmd.

local M = {}

-- Pure-Lua mermaid renderer, optional: if it fails to load, mermaid blocks
-- simply stay as raw source.
local mermaid = select(2, pcall(require, 'markdown-console.mermaid'))
local mermaid_dirs = { mermaid = true, mmd = true }

local ns = vim.api.nvim_create_namespace('markdown_console')

-- bufnr -> true while the rendered overlay is shown
local rendered = {}
-- bufnr -> the buffer's 'syntax' name, saved while the overlay is shown
local saved_syntax = {}
-- bufnr -> list of {first, last} 0-based row ranges of tables drawn as wide
-- blocks (their source rows are concealed, so the cursor cannot sit on them).
local wide_ranges = {}
-- bufnr -> {first, last} of the wide table currently rendered inline so the
-- cursor can move through it, or nil.
local revealed = {}
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
-- when there is no parser / query for the language. Ranges are 0-based bytes,
-- line_index is 1-based (matching the block's own line list).
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
            out[sr + 1] = out[sr + 1] or {}
            out[sr + 1][#out[sr + 1] + 1] = { sc, ec, '@' .. cap }
          end
        end
      end
    end
    return out
  end)
  return ok and res or nil
end

-- Turn a code line plus its treesitter ranges into highlight chunks.
-- Treesitter capture groups carry no background, which would leave gaps in the
-- code block's background, so each is wrapped in a MarkdownConsole group that
-- copies its colours and adds the block background.
local ts_hl_cache = {}
local function code_token_hl(group)
  local cached = ts_hl_cache[group]
  if cached then return cached end
  local name = 'MarkdownConsoleTs_' .. group:gsub('[@%.]', '_')
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok or type(hl) ~= 'table' then hl = {} end
  hl.bg = '#2d2d2d'
  hl.link = nil
  hl.default = nil
  if not hl.fg then hl.fg = '#c8a060' end
  pcall(vim.api.nvim_set_hl, 0, name, hl)
  ts_hl_cache[group] = name
  return name
end

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
    if g:sub(1, 1) == '@' then g = code_token_hl(g) end
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
      blocks[#blocks + 1] = { kind = 'blank', n = 1 }
    elseif hashes and #hashes <= 6 then
      blocks[#blocks + 1] = { kind = 'heading', level = #hashes, segs = inline(line:sub(#hashes + 2)), n = 1 }
    elseif line:match('^```') then
      local lang = vim.trim(line:sub(4))
      local body = {}
      next_()
      while i <= #lines and not lines[i]:match('^```') do
        body[#body + 1] = lines[i]
        next_()
      end
      local llang = lang:lower()
      local kind = mermaid_dirs[llang] and 'mermaid' or 'code'
      blocks[#blocks + 1] = { kind = kind, lang = lang, lines = body, n = #body + 2 }
    elseif line:match('^%s*>') then
      local quote = {}
      while i <= #lines and lines[i]:match('^%s*>') do
        quote[#quote + 1] = inline((lines[i]:gsub('^%s*>%s?', '')))
        next_()
      end
      i = i - 1
      blocks[#blocks + 1] = { kind = 'quote', lines = quote, n = #quote }
    elseif line:match('^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_%s]*$') and #line >= 3 then
      blocks[#blocks + 1] = { kind = 'hr', n = 1 }
    elseif line:match('^%s*[%-%*+]%s+') then
      blocks[#blocks + 1] = { kind = 'list', marker = '-', segs = inline((line:gsub('^%s*[%-%*+]%s+', ''))), n = 1 }
    elseif line:match('^%s*%d+%.%s+') then
      blocks[#blocks + 1] = { kind = 'list', marker = line:match('^%s*(%d+)'), segs = inline((line:gsub('^%s*%d+%.%s+', ''))), n = 1 }
    elseif line:match('^|.*|%s*$') then
      local rows, start = {}, i
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
      blocks[#blocks + 1] = { kind = 'table', rows = rows, n = i - start + 1 }
    else
      blocks[#blocks + 1] = { kind = 'paragraph', segs = inline(line), n = 1 }
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

-- Word-wrap plain text to `width` cells, hard-breaking any word longer than the
-- width. Used to wrap table cells in the block render.
local function wrap_text(text, width)
  if width < 1 then width = 1 end
  local out, cur = {}, ''
  for word in text:gmatch('%S+') do
    while #word > width do
      if #cur > 0 then out[#out + 1] = cur; cur = '' end
      out[#out + 1] = word:sub(1, width)
      word = word:sub(width + 1)
    end
    if #cur == 0 then
      cur = word
    elseif #cur + 1 + #word <= width then
      cur = cur .. ' ' .. word
    else
      out[#out + 1] = cur
      cur = word
    end
  end
  if #cur > 0 or #out == 0 then out[#out + 1] = cur end
  return out
end

-- Split `budget` cells across `ncol` columns. Each column first gets its longest
-- word (and its header cell, capped by its natural width) so neither is broken
-- mid-way, filled smallest-demand-first (max-min fair) so one very long word
-- cannot starve the others. Left-over budget then grows columns towards their
-- natural width in proportion to what they still need. Never exceeds `budget`.
local function alloc_widths(natural, wordmin, budget, ncol)
  local out = {}
  if ncol <= 0 then return out end
  if budget < 1 then budget = 1 end
  local want = {}
  for c = 1, ncol do
    want[c] = math.min(natural[c] or 0, math.max(1, wordmin[c] or 1))
  end
  -- Give every column its longest word where the budget allows, satisfying the
  -- smallest demands first; the rest split what remains in proportion to need.
  local rem, nrem = budget, ncol
  local pending = {}
  for c = 1, ncol do pending[c] = true end
  while nrem > 0 do
    local share = math.floor(rem / nrem)
    local progressed = false
    for c = 1, ncol do
      if pending[c] and want[c] <= share then
        out[c] = want[c]
        rem = rem - want[c]
        pending[c] = false
        nrem = nrem - 1
        progressed = true
      end
    end
    if not progressed then break end
  end
  if nrem > 0 then
    local wsum = 0
    for c = 1, ncol do if pending[c] then wsum = wsum + want[c] end end
    for c = 1, ncol do
      if pending[c] then out[c] = math.max(1, math.floor(rem * want[c] / wsum)) end
    end
  end
  -- Spend whatever is left growing columns towards their natural width, in
  -- proportion to how much each column still needs, then hand out the rounding
  -- crumbs one cell at a time so a column that just misses a word still gets it.
  local sum = 0
  for c = 1, ncol do sum = sum + (out[c] or 0) end
  local left = budget - sum
  if left > 0 then
    local need = 0
    for c = 1, ncol do need = need + math.max(0, (natural[c] or 0) - (out[c] or 0)) end
    if need > 0 then
      local acc = 0
      for c = 1, ncol do
        local extra = math.floor(left * math.max(0, (natural[c] or 0) - (out[c] or 0)) / need)
        out[c] = (out[c] or 0) + extra
        acc = acc + extra
      end
      local crumbs = left - acc
      while crumbs > 0 do
        local best, bestgap
        for c = 1, ncol do
          local gap = math.max(0, (natural[c] or 0) - (out[c] or 0))
          if gap > 0 and (not bestgap or gap < bestgap) then best, bestgap = c, gap end
        end
        if not best then break end
        out[best] = out[best] + 1
        crumbs = crumbs - 1
      end
    end
  end
  -- Guarantee the total never exceeds the budget.
  sum = 0
  for c = 1, ncol do sum = sum + out[c] end
  while sum > budget do
    local widest = 1
    for c = 1, ncol do if out[c] > out[widest] then widest = c end end
    if out[widest] <= 1 then break end
    out[widest] = out[widest] - 1
    sum = sum - 1
  end
  return out
end

-- Build one row (list of {text, hl} chunks) for each source line, so the rows
-- line up 1:1 with the buffer. Each row may carry:
--   fill  - highlight group used for the padding that hides the raw text
--   min   - minimum display width (full-width level-1 heading bar)
-- Tables and mermaid diagrams are drawn separately (they need the buffer rows).
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

    elseif b.kind == 'mermaid' then
      -- The diagram is not built here: it needs the buffer rows to overlay onto.
      -- Emit one placeholder per source line so later rows stay aligned.
      for _ = 1, b.n do put({}) end

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
      -- Drawn by render_table, which may collapse the source rows into a block.
      -- Emit placeholders so later source lines keep their row index.
      for _ = 1, b.n do put({}) end
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

----------------------------------------------------------------------
-- inline markup: conceal the syntax, keep the text real so the cursor
-- can move over the rendered line
----------------------------------------------------------------------

-- pat must capture the visible text as group 1; plen is the byte length of
-- the opening markup so the concealed range can be located.
local INLINE_SPECS = {
  { pat = '`([^`]+)`', plen = 1, group = 'MarkdownConsoleCode' },
  { pat = '!%[([^%]]*)%]%(([^%)]*)%)', plen = 2, group = 'MarkdownConsoleImage' },
  { pat = '%[([^%]]*)%]%(([^%)]*)%)', plen = 1, group = 'MarkdownConsoleLink' },
  { pat = '%*%*([^%*]+)%*%*', plen = 2, group = 'MarkdownConsoleBold' },
  { pat = '__([^_]+)__', plen = 2, group = 'MarkdownConsoleBold' },
  { pat = '%*([^%*]+)%*', plen = 1, group = 'MarkdownConsoleItalic' },
  { pat = '_([^_]+)_', plen = 1, group = 'MarkdownConsoleItalic' },
}

local function conceal(buf, row, c0, c1)
  if c1 > c0 then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, c0, { end_col = c1, conceal = '' })
  end
end

local function paint(buf, row, c0, c1, group)
  if group and c1 > c0 then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, c0, { end_col = c1, hl_group = group })
  end
end

-- Conceal the syntax of one inline region of `text` (which starts at byte
-- offset `off` in the row) and highlight the text that remains. `base` styles
-- plain runs.
local function inline_row(buf, row, text, off, base)
  local pos = 1
  while pos <= #text do
    local best
    for _, sp in ipairs(INLINE_SPECS) do
      local s, e, cap = text:find(sp.pat, pos)
      if s and (not best or s < best.s) then
        best = { s = s, e = e, cap = cap, plen = sp.plen, group = sp.group }
      end
    end
    if not best then
      paint(buf, row, off + pos - 1, off + #text, base)
      return
    end
    local s, e, plen = best.s, best.e, best.plen
    local ks = s + plen
    local ke = ks + #best.cap - 1
    if s > pos then paint(buf, row, off + pos - 1, off + s - 1, base) end
    conceal(buf, row, off + s - 1, off + ks - 1)
    paint(buf, row, off + ks - 1, off + ke, best.group)
    conceal(buf, row, off + ke, off + e)
    pos = e + 1
  end
end

-- Conceal does not shrink the width Neovim wraps at, so hiding a long run (a
-- URL) on a line that wraps leaves a gap as wide as the run on the wrapped row.
-- Return the widest single run inline_row would conceal on this text, so a
-- wrapping line whose run is wide enough to blank a whole row can be left as raw
-- source. `text` must be the same slice inline_row is given.
local function conceal_max(text)
  local worst, pos = 0, 1
  while pos <= #text do
    local best
    for _, sp in ipairs(INLINE_SPECS) do
      local s, e, cap = text:find(sp.pat, pos)
      if s and (not best or s < best.s) then
        best = { s = s, e = e, cap = cap, plen = sp.plen }
      end
    end
    if not best then break end
    local closing = best.e - best.s + 1 - best.plen - #best.cap
    worst = math.max(worst, best.plen, closing)
    pos = best.e + 1
  end
  return worst
end

-- Conceal a block marker and draw a replacement with inline virtual text.
local function marker(buf, row, len, text, group)
  conceal(buf, row, 0, len)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
    virt_text = { { text, group } },
    virt_text_pos = 'inline',
  })
end

-- Structural blocks (code boxes, tables) keep the whole-line overlay: their
-- rendered form has a different shape from the source.
local function overlay_row(buf, row, line, row_data)
  if not row_data or #row_data.chunks == 0 then
    conceal(buf, row, 0, #line)
    return
  end
  local width = 0
  for _, c in ipairs(row_data.chunks) do width = width + tw(c[1]) end
  local target = math.max(width, row_data.min or 0)
  if target > width then
    local space = string.rep(' ', target - width)
    row_data.chunks[#row_data.chunks + 1] = row_data.fill and { space, row_data.fill } or { space }
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
    end_col = #line,
    conceal = '',
    virt_text = row_data.chunks,
    virt_text_pos = 'overlay',
    hl_mode = 'replace',
    priority = 100,
  })
end

-- Overlay one styled run on a row, hiding the row's own text. Used for rendered
-- blocks whose shape differs from the source (mermaid diagrams).
local function overlay_text(buf, row, line_len, text, group)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
    end_col = line_len,
    conceal = '',
    virt_text = { { text, group } },
    virt_text_pos = 'overlay',
    hl_mode = 'replace',
    priority = 100,
  })
end

-- Render a wide table inline, keeping every source row a real buffer line so the
-- cursor can move through the table with h/j/k/l (mapping directly onto the raw
-- source underneath). The `|` separators are concealed and the `|---|` delimiter
-- row is collapsed, so the rows read as rendered cells rather than raw markdown.
local function render_table_inline(buf, first, last, lines)
  local HDR = 'MarkdownConsoleTableHeader'
  local data_group = 'MarkdownConsoleTableRow'
  for r = first, last do
    local line = lines[r + 1] or ''
    local body = vim.trim(line):gsub('^|', ''):gsub('|$', '')
    local n, is_sep = 0, true
    for cell in (body .. '|'):gmatch('([^|]*)|') do
      n = n + 1
      if not vim.trim(cell):match('^:?-+:?$') then is_sep = false end
    end
    if is_sep and n > 0 then
      -- Drop the `|---|` row entirely (it has no content of its own).
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, r, 0, { end_row = r, conceal_lines = '' })
    else
      local c = 1
      while true do
        local s, e = line:find('|', c, true)
        if not s then break end
        conceal(buf, r, s - 1, e)
        c = e + 1
      end
      inline_row(buf, r, line, 0, r == first and HDR or data_group)
    end
  end
end

-- Render a table block. `first` is the 0-based row of the table's first source
-- line. When the table fits the window each source row is overlaid 1:1 (the
-- cursor can move over the rendered rows). When it does not fit, the source rows
-- are collapsed with `conceal_lines` and the whole re-flowed table is drawn as
-- `virt_lines` on the neighbouring row, so nothing is clipped and no blank rows
-- are left behind. `conceal_lines` needs Neovim 0.11+; older versions keep the
-- raw source for wide tables.
local can_conceal_lines = vim.fn.has('nvim-0.11') == 1
local function render_table(buf, blk, first, lines, avail)
  local ncol = 0
  for _, r in ipairs(blk.rows) do ncol = math.max(ncol, #r) end
  if ncol == 0 then return end
  local natural, wordmin = {}, {}
  for c = 1, ncol do
    natural[c], wordmin[c] = 0, 1
    for _, r in ipairs(blk.rows) do
      local t = seg_text(inline(r[c] or ''))
      natural[c] = math.max(natural[c], tw(t))
      for w in t:gmatch('%S+') do wordmin[c] = math.max(wordmin[c], tw(w)) end
    end
  end
  -- Keep the header cell on one line where the column can fit it.
  for c = 1, ncol do
    local hw = tw(seg_text(inline((blk.rows[1] or {})[c] or '')))
    if hw > wordmin[c] then wordmin[c] = hw end
  end
  local HDR, ROW, SEP = 'MarkdownConsoleTableHeader', 'MarkdownConsoleTableRow', 'MarkdownConsoleTableSep'
  -- A boxed table: `cw[c]` is the content width of column c. Each cell is drawn
  -- with a space on either side, so a rule segment under it is `cw[c] + 2` wide
  -- and the whole box costs `3*ncol + 1` cells of framing.
  local overhead = 3 * ncol + 1
  local function mkrow(cw, cells, group)
    local parts = {}
    for c = 1, ncol do parts[c] = ' ' .. pad(cells[c] or '', cw[c]) .. ' ' end
    return { { '│' .. table.concat(parts, '│') .. '│', group } }
  end
  local function mkrule(l, m, r, cw)
    local parts = {}
    for c = 1, ncol do parts[c] = string.rep('─', cw[c] + 2) end
    return { { l .. table.concat(parts, m) .. r, SEP } }
  end

  local total = overhead
  for c = 1, ncol do total = total + natural[c] end

  if total <= avail then
    -- Fits: overlay one source row at a time (the cursor can move over the
    -- rendered rows). `blk.rows` omits the |---| line, so the header is on the
    -- first row, the rule on the second, data after that. The top and bottom of
    -- the box are drawn as virtual lines on the first and last source rows.
    for ri, r in ipairs(blk.rows) do
      local cells = {}
      for c = 1, ncol do cells[c] = seg_text(inline(r[c] or '')) end
      local src = ri == 1 and first or first + ri
      overlay_row(buf, src, lines[src + 1], { chunks = mkrow(natural, cells, ri == 1 and HDR or ROW) })
    end
    overlay_row(buf, first + 1, lines[first + 2], { chunks = mkrule('├', '┼', '┤', natural) })
    local last = first + blk.n - 1
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, first, 0, {
      virt_lines_above = true, virt_lines = { mkrule('┌', '┬', '┐', natural) }, priority = 90,
    })
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, last, 0, {
      virt_lines = { mkrule('└', '┴', '┘', natural) }, priority = 90,
    })
    return
  end

  -- Does not fit: re-flow into a block. Shrink columns to the window and
  -- word-wrap each cell, giving each row as many display rows as it needs.
  if not can_conceal_lines then return end

  -- Anchor the block on a neighbouring line (the block itself has no row of its
  -- own once its source lines are concealed).
  local last = first + blk.n - 1
  local anchor, above
  if last + 1 <= #lines - 1 then
    anchor, above = last + 1, true
  elseif first - 1 >= 0 then
    anchor, above = first - 1, false
  else
    return -- the table is the whole buffer; nothing to anchor to, leave raw
  end
  wide_ranges[buf] = wide_ranges[buf] or {}
  wide_ranges[buf][#wide_ranges[buf] + 1] = { first, last }
  -- The cursor cannot sit on concealed rows, so while it is inside this table we
  -- render it inline instead: the rows stay real, so h/j/k/l move through them.
  local rev = revealed[buf]
  if rev and rev[1] == first and rev[2] == last then
    render_table_inline(buf, first, last, lines)
    return
  end

  local cw = alloc_widths(natural, wordmin, avail - overhead, ncol)
  local display = { mkrule('┌', '┬', '┐', cw) }
  for ri, r in ipairs(blk.rows) do
    local celllines, height = {}, 1
    for c = 1, ncol do
      celllines[c] = wrap_text(seg_text(inline(r[c] or '')), cw[c])
      height = math.max(height, #celllines[c])
    end
    local group = ri == 1 and HDR or ROW
    for k = 1, height do
      local cells = {}
      for c = 1, ncol do cells[c] = celllines[c][k] or '' end
      display[#display + 1] = mkrow(cw, cells, group)
    end
    if ri == 1 then display[#display + 1] = mkrule('├', '┼', '┤', cw) end
  end
  display[#display + 1] = mkrule('└', '┴', '┘', cw)

  pcall(vim.api.nvim_buf_set_extmark, buf, ns, first, 0, { end_row = last, conceal_lines = '' })
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, anchor, 0, {
    virt_lines_above = above, virt_lines = display, priority = 90,
  })
end

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
    -- conceal_line decoration provider errors on a live tree. The legacy markdown
    -- syntax is cleared too, because it conceals emphasis markers by itself and
    -- would half-render any line we leave as raw source.
    ts_off(buf)
    if vim.bo[buf].syntax ~= '' then
      saved_syntax[buf] = vim.bo[buf].syntax
      vim.bo[buf].syntax = ''
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local win = vim.fn.bufwinid(buf)
    local bar = text_width(win) - 2
    local avail = text_width(win) - 1
    local rows = build_rows(lines, bar)
    clear(buf)
    wide_ranges[buf] = {}
    -- Text lines keep the conceal path so they wrap normally with 'wrap' on:
    -- conceal hides the markup and the real text flows across the wrapped rows.
    -- Conceal does not shrink the width Neovim wraps at (the hidden cells still
    -- count), so on a line that wraps a concealed run leaves a gap as wide as
    -- the run it hid. A line is therefore concealed only when it fits the window
    -- (so it cannot wrap) or when its hidden runs are short; a line that wraps
    -- and hides a long run (a URL) is left as raw source, which wraps cleanly.
    -- Blocks whose rendered shape differs from the source (code, tables,
    -- mermaid) still use the whole-line overlay.
    local function fits(line)
      return tw(line) <= avail
    end
    -- Conceal a line when it fits (so it cannot wrap), or when its widest
    -- concealed run is narrower than the window: a hidden run that can span a
    -- whole wrapped row would leave a blank row, so those lines stay raw.
    local function text_ok(line, seg)
      return fits(line) or conceal_max(seg) < avail
    end
    local li = 0
    for _, b in ipairs(parse(lines)) do
      if b.kind == 'mermaid' then
        local art = mermaid and mermaid.render(table.concat(b.lines, '\n')) or nil
        if art and #art > 0 then
          local last = li + b.n
          for k = 1, b.n do
            local ln = lines[li + k]
            if ln then conceal(buf, li + k - 1, 0, #ln) end
          end
          local below = {}
          for k = 1, #art do
            local target = li + k
            if target <= last then
              overlay_text(buf, target - 1, #(lines[target] or ''), art[k], 'MarkdownConsoleMermaid')
            else
              below[#below + 1] = { { art[k], 'MarkdownConsoleMermaid' } }
            end
          end
          if #below > 0 then
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, last - 1, 0, { virt_lines = below })
          end
          li = last
        else
          li = li + b.n
        end
      elseif b.kind == 'code' then
        for _ = 1, b.n do
          li = li + 1
          if li > #lines then break end
          overlay_row(buf, li - 1, lines[li], rows[li])
        end
      elseif b.kind == 'table' then
        render_table(buf, b, li, lines, avail)
        li = li + b.n
      elseif b.kind == 'heading' then
        li = li + 1
        local line = lines[li] or ''
        local hashes = line:match('^(#+)%s')
        if hashes then
          local prefix = #hashes + 1
          local group = 'MarkdownConsoleH' .. b.level
          local pgroup = b.level == 1 and 'MarkdownConsoleH1Prefix' or 'MarkdownConsoleHPrefix'
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, li - 1, 0, {
            end_col = #line, hl_group = group, hl_eol = b.level == 1,
          })
          if text_ok(line, line:sub(prefix + 1)) then
            paint(buf, li - 1, 0, prefix, pgroup)
            if #line > prefix then inline_row(buf, li - 1, line:sub(prefix + 1), prefix, group) end
          end
        end
      elseif b.kind == 'paragraph' then
        li = li + 1
        if text_ok(lines[li], lines[li]) then
          inline_row(buf, li - 1, lines[li], 0, nil)
        end
      elseif b.kind == 'list' then
        li = li + 1
        local line = lines[li]
        local m = line:match('^(%s*[%-%*+]%s+)') or line:match('^(%s*%d+%.%s+)') or ''
        if text_ok(line, line:sub(#m + 1)) then
          local lead = line:match('^(%s*)') or ''
          local depth = math.floor(#lead / 2)
          local glyph
          if b.marker == '-' then
            glyph = ({ '•', '◦', '▪' })[depth % 3 + 1]
          else
            glyph = b.marker .. '.'
          end
          marker(buf, li - 1, #m, '  ' .. lead .. glyph .. ' ', 'MarkdownConsoleList')
          inline_row(buf, li - 1, line:sub(#m + 1), #m, nil)
        end
      elseif b.kind == 'quote' then
        for _ = 1, b.n do
          li = li + 1
          local line = lines[li]
          local m = line:match('^(%s*>%s?)') or ''
          if text_ok(line, line:sub(#m + 1)) then
            marker(buf, li - 1, #m, '▏ ', 'MarkdownConsoleQuote')
            inline_row(buf, li - 1, line:sub(#m + 1), #m, 'MarkdownConsoleQuote')
          end
        end
      elseif b.kind == 'hr' then
        li = li + 1
        marker(buf, li - 1, #lines[li], string.rep('─', 40), 'MarkdownConsoleHr')
      else
        li = li + b.n
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
  if saved_syntax[buf] then
    vim.bo[buf].syntax = saved_syntax[buf]
    saved_syntax[buf] = nil
  end
  rendered[buf] = nil
  revealed[buf] = nil
  busy = false
end

-- A wide table collapses its source rows into a virtual block, but then the
-- cursor has no real row to sit on. While the cursor is inside such a table we
-- render it inline instead (see render_table_inline) so h/j/k/l move through it,
-- and restore the block as soon as the cursor leaves. Cheap when nothing changed:
-- it only re-renders on the transitions in and out of a table.
local function sync_reveal(buf)
  if busy or not md(buf) or not rendered[buf] then return end
  if is_raw_mode(vim.fn.mode(1)) then return end
  if vim.api.nvim_get_current_buf() ~= buf then return end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local hit
  for _, r in ipairs(wide_ranges[buf] or {}) do
    if row >= r[1] and row <= r[2] then hit = r; break end
  end
  local cur = revealed[buf]
  if hit then
    if not (cur and cur[1] == hit[1] and cur[2] == hit[2]) then
      revealed[buf] = hit
      render(buf, true)
    end
  elseif cur then
    revealed[buf] = nil
    render(buf, true)
  end
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
    MarkdownConsoleCode = { fg = '#c8a060', bg = '#2d2d2d' },
    MarkdownConsoleFence = { fg = '#6c6c6c', bg = '#2d2d2d' },
    MarkdownConsoleCodeLang = { fg = '#ffd93d', bold = true, italic = true, bg = '#2d2d2d' },
    MarkdownConsoleQuote = { fg = '#6c6c6c', italic = true },
    MarkdownConsoleHr = { fg = '#6c6c6c' },
    MarkdownConsoleBold = { bold = true },
    MarkdownConsoleItalic = { italic = true },
    MarkdownConsoleLink = { fg = '#4d96ff', underline = true },
    MarkdownConsoleImage = { fg = '#6c6c6c' },
    MarkdownConsoleTableHeader = { bold = true },
    MarkdownConsoleTableRow = {},
    MarkdownConsoleTableSep = { fg = '#6c6c6c' },
    MarkdownConsoleMermaid = { fg = '#8be9fd' },
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
      if vim.fn.mode() == 'n' then
        render(args.buf)
        sync_reveal(args.buf)
      end
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
        sync_reveal(args.buf)
      end
    end,
  })

  -- Render a wide table inline while the cursor is inside it (see sync_reveal),
  -- and draw the boxed block again once the cursor moves away.
  vim.api.nvim_create_autocmd('CursorMoved', {
    callback = function(args)
      sync_reveal(args.buf)
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
          sync_reveal(args.buf)
        end
      end)
    end,
  })

  -- Keep the level-1 background bar spanning the window.
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    callback = function()
      for buf in pairs(rendered) do
        if vim.api.nvim_buf_is_valid(buf) then
          render(buf, true)
          sync_reveal(buf)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    callback = function(args)
      rendered[args.buf] = nil
      wide_ranges[args.buf] = nil
      revealed[args.buf] = nil
    end,
  })

  vim.api.nvim_create_user_command('MarkdownConsoleToggle', toggle, {})
end

return M
