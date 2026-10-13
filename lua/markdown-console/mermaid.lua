-- markdown-console.nvim - pure-Lua mermaid renderer
--
-- Renders mermaid flowcharts (graph / flowchart) to Unicode text, with no
-- external tools. Only flowcharts are supported for now; anything else returns
-- nil so the caller can fall back to showing the source.
--
-- M.render(src) -> list of lines, or nil + reason.

local M = {}

local function tw(s)
  if vim and vim.fn then return vim.fn.strdisplaywidth(s) end
  return #s
end

-- Split a UTF-8 string into a list of characters.
local function chars(s)
  local t = {}
  for _, c in ipairs(vim.fn.split(s, '\\zs')) do t[#t + 1] = c end
  return t
end

----------------------------------------------------------------------
-- parsing
----------------------------------------------------------------------

-- Lua patterns have no alternation, so the arrow is a single class:
-- a run of - . = followed by an optional arrow head (> x o).
local ARROW = '^[%-%.=]+[>ox]?'

-- Read "id" plus an optional shape group: A, A[text], A(text), A{text}, A((x)).
local function read_node(line, i)
  local id = line:match('^[%w_]+', i)
  if not id then return nil, i end
  i = i + #id
  local label, shape
  if line:sub(i, i + 1) == '[[' then
    local inner, e = line:match('^%[%[(.-)%]%]()', i)
    if inner then label, shape, i = inner, 'rect', e end
  elseif line:sub(i, i) == '[' then
    local inner, e = line:match('^%[(.-)%]()', i)
    if inner then label, shape, i = inner, 'rect', e end
  elseif line:sub(i, i + 1) == '((' then
    local inner, e = line:match('^%((.-)%)%)()', i)
    if inner then label, shape, i = inner, 'round', e end
  elseif line:sub(i, i) == '(' then
    local inner, e = line:match('^%((.-)%)()', i)
    if inner then label, shape, i = inner, 'round', e end
  elseif line:sub(i, i) == '{' then
    local inner, e = line:match('^%{(.-)%}()', i)
    if inner then label, shape, i = inner, 'round', e end
  elseif line:sub(i, i) == '>' then
    local inner, e = line:match('^>(.-)%]()', i)
    if inner then label, shape, i = inner, 'rect', e end
  end
  if label then
    label = label:gsub('^%s*"', ''):gsub('"%s*$', ''):gsub('^%s+', ''):gsub('%s+$', '')
  end
  return { id = id, label = label, shape = shape }, i
end

-- Turn one line into tokens: nodes, arrows and "and" separators.
local function tokenize(line)
  -- rewrite "-- label -->" into "-->|label|" first
  line = line:gsub('%-%-%s+([^>]+?)%s+%-%-+%s*>', '-->|%1|')
  local toks, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == ' ' or c == '\t' then
      i = i + 1
    elseif c == '&' then
      toks[#toks + 1] = { t = 'and' }
      i = i + 1
    else
      local a = line:match(ARROW, i)
      if a then
        local directed = a:find('[>ox]') ~= nil
        i = i + #a
        local j = i
        while line:sub(j, j) == ' ' do j = j + 1 end
        local label
        if line:sub(j, j) == '|' then
          local k = line:find('|', j + 1)
          if k then label = line:sub(j + 1, k - 1); i = k + 1 end
        end
        toks[#toks + 1] = { t = 'arrow', directed = directed, label = label }
      else
        local nd, ni = read_node(line, i)
        if nd then
          toks[#toks + 1] = { t = 'node', node = nd }
          i = ni
        else
          i = i + 1
        end
      end
    end
  end
  return toks
end

local function parse(src)
  local lines = {}
  for l in (src .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = l end
  local head = lines[1] or ''
  local dir = head:match('^%s*[gG]raph%s+(%a+)') or head:match('^%s*flo[wW]chart%s+(%a+)')
  if not dir and head:match('^%s*flo[wW]chart') then dir = 'TD' end
  if not dir then return nil, 'not a flowchart' end
  dir = dir:upper()

  local nodes, order, edges = {}, {}, {}
  local function node(id)
    if not nodes[id] then
      nodes[id] = { id = id, label = id, shape = 'rect' }
      order[#order + 1] = id
    end
    return nodes[id]
  end

  for li = 2, #lines do
    local line = lines[li]:gsub('%%%%[^\n]*', '')
    if not (line:match('^%s*$') or line:match('^%s*[Ss]ubgraph') or line:match('^%s*end%s*$')
        or line:match('^%s*classDef') or line:match('^%s*class%s') or line:match('^%s*style')
        or line:match('^%s*linkStyle') or line:match('^%s*click') or line:match('^%s*direction')) then
      local toks = tokenize(line)
      local ti = 1
      local prev
      while ti <= #toks do
        local tk = toks[ti]
        if tk.t == 'node' then
          local def = node(tk.node.id)
          if tk.node.label then def.label = tk.node.label end
          if tk.node.shape then def.shape = tk.node.shape end
          prev = def
          ti = ti + 1
        elseif tk.t == 'arrow' and prev then
          local targets = {}
          local tj = ti + 1
          while tj <= #toks and (toks[tj].t == 'node' or toks[tj].t == 'and') do
            if toks[tj].t == 'node' then
              local def = node(toks[tj].node.id)
              if toks[tj].node.label then def.label = toks[tj].node.label end
              if toks[tj].node.shape then def.shape = toks[tj].node.shape end
              targets[#targets + 1] = def
            end
            tj = tj + 1
          end
          for _, tg in ipairs(targets) do
            edges[#edges + 1] = { from = prev, to = tg, label = tk.label, directed = tk.directed }
          end
          if targets[1] then prev = targets[#targets] end
          ti = tj
        else
          ti = ti + 1
        end
      end
    end
  end
  return { dir = dir, nodes = nodes, order = order, edges = edges }
end

----------------------------------------------------------------------
-- canvas
----------------------------------------------------------------------

local function new_canvas()
  return { g = {}, maxx = 0, maxy = 0 }
end

local function cell(cv, x, y)
  if x < 1 then x = 1 end
  if y < 1 then y = 1 end
  if x > cv.maxx then cv.maxx = x end
  if y > cv.maxy then cv.maxy = y end
  local row = cv.g[y]
  if not row then row = {}; cv.g[y] = row end
  local c = row[x]
  if not c then c = {}; row[x] = c end
  return c
end

local function vline(cv, x, y0, y1)
  if y0 > y1 then y0, y1 = y1, y0 end
  for y = y0, y1 do
    local c = cell(cv, x, y)
    if y > y0 then c.n = true end
    if y < y1 then c.s = true end
  end
end

local function hline(cv, x0, x1, y)
  if x0 > x1 then x0, x1 = x1, x0 end
  for x = x0, x1 do
    local c = cell(cv, x, y)
    if x > x0 then c.w = true end
    if x < x1 then c.e = true end
  end
end

local function put(cv, x, y, s)
  for k, ch in ipairs(chars(s)) do cell(cv, x + k - 1, y).ch = ch end
end

local CORNERS = {
  rect = { '┌', '┐', '└', '┘', '─', '│' },
  round = { '╭', '╮', '╰', '╯', '─', '│' },
}

local function draw_box(cv, x, y, w, label, shape)
  local c = CORNERS[shape] or CORNERS.rect
  local tl, tr, bl, br, hz, vt = c[1], c[2], c[3], c[4], c[5], c[6]
  cell(cv, x, y).ch = tl
  cell(cv, x + w - 1, y).ch = tr
  cell(cv, x, y + 2).ch = bl
  cell(cv, x + w - 1, y + 2).ch = br
  for i = 1, w - 2 do
    cell(cv, x + i, y).ch = hz
    cell(cv, x + i, y + 2).ch = hz
  end
  cell(cv, x, y + 1).ch = vt
  cell(cv, x + w - 1, y + 1).ch = vt
  -- label, one space of padding on each side of the inner width
  local ci = x + 1
  cell(cv, ci, y + 1).ch = ' '
  ci = ci + 1
  local used = 0
  for _, ch in ipairs(chars(label)) do
    if ci > x + w - 2 then break end
    cell(cv, ci, y + 1).ch = ch
    ci = ci + 1
    used = used + 1
  end
  while ci <= x + w - 2 do
    cell(cv, ci, y + 1).ch = ' '
    ci = ci + 1
  end
end

local function to_grid(cv, map)
  local grid = {}
  for y = 1, cv.maxy do
    local row = cv.g[y] or {}
    local arr = {}
    for x = 1, cv.maxx do
      local c = row[x]
      local ch = ' '
      if c then
        if c.ch then
          ch = c.ch
        else
          local n, s, e, w = c.n, c.s, c.e, c.w
          if n and s and e and w then ch = '┼'
          elseif n and s and e then ch = '├'
          elseif n and s and w then ch = '┤'
          elseif n and e and w then ch = '┴'
          elseif s and e and w then ch = '┬'
          elseif n and s then ch = '│'
          elseif e and w then ch = '─'
          elseif s and e then ch = '┌'
          elseif s and w then ch = '┐'
          elseif n and e then ch = '└'
          elseif n and w then ch = '┘'
          elseif n or s then ch = '│'
          elseif e or w then ch = '─'
          end
        end
      end
      arr[x] = map and (map[ch] or ch) or ch
    end
    grid[y] = arr
  end
  return grid
end

local function grid_to_lines(grid)
  local out = {}
  for _, row in ipairs(grid) do
    out[#out + 1] = (table.concat(row):gsub('%s+$', ''))
  end
  return out
end

local function grid_to_string(grid)
  return table.concat(grid_to_lines(grid), '\n')
end

----------------------------------------------------------------------
-- layout + edge routing (vertical: TD/TB, horizontal: LR/RL)
----------------------------------------------------------------------

local NODE_H = 3
local GAP_X = 4
local GAP_Y = 2
local LAYER_GAP = 3

local function compute_layout(g, vertical, forward)
  local nodes, edges = g.nodes, g.edges
  local w = {}
  for id, nd in pairs(nodes) do w[id] = tw(nd.label) + 4 end

  -- longest-path layering (back edges in cycles are collapsed)
  local layer, visiting = {}, {}
  local function visit(id)
    if layer[id] then return layer[id] end
    if visiting[id] then return 0 end
    visiting[id] = true
    local best = 0
    for _, e in ipairs(edges) do
      if e.to.id == id then
        local l = visit(e.from.id) + 1
        if l > best then best = l end
      end
    end
    visiting[id] = nil
    layer[id] = best
    return best
  end
  local maxl = 0
  for _, id in ipairs(g.order) do maxl = math.max(maxl, visit(id)) end

  local slots = {}
  for l = 0, maxl do slots[l] = {} end
  for _, id in ipairs(g.order) do slots[layer[id]][#slots[layer[id]] + 1] = id end

  -- secondary axis: x when vertical, y otherwise
  local function sec_size(id) return vertical and w[id] or NODE_H end
  local sec_gap = vertical and GAP_X or GAP_Y

  local sec = {}
  local function bary(id)
    local sum, cnt = 0, 0
    for _, e in ipairs(edges) do
      if e.to.id == id and sec[e.from.id] then
        sum = sum + (sec[e.from.id] + sec_size(e.from.id) / 2)
        cnt = cnt + 1
      end
    end
    return cnt > 0 and (sum / cnt) or 1e9
  end
  for l = 0, maxl do
    local ids = slots[l]
    if l > 0 then
      table.sort(ids, function(a, b)
        local ba, bb = bary(a), bary(b)
        if ba == bb then return a < b end
        return ba < bb
      end)
    end
    local cursor = 1
    for _, id in ipairs(ids) do
      local want
      if l > 0 then
        local sum, cnt = 0, 0
        for _, e in ipairs(edges) do
          if e.to.id == id and sec[e.from.id] then
            sum = sum + (sec[e.from.id] + sec_size(e.from.id) / 2)
            cnt = cnt + 1
          end
        end
        if cnt > 0 then want = math.floor(sum / cnt - sec_size(id) / 2) end
      end
      local p = math.max(cursor, want or 1)
      sec[id] = p
      cursor = p + sec_size(id) + sec_gap
    end
  end

  -- coordinate along the layer axis
  local lc = {}
  if vertical then
    for l = 0, maxl do
      local ll = forward and l or (maxl - l)
      lc[l] = ll * (NODE_H + LAYER_GAP) + 1
    end
  else
    local cw = {}
    for l = 0, maxl do
      local mx = 0
      for _, id in ipairs(slots[l]) do mx = math.max(mx, w[id]) end
      cw[l] = mx
    end
    local cum, acc = {}, 0
    for l = 0, maxl do cum[l] = acc; acc = acc + cw[l] + LAYER_GAP end
    local total = acc - LAYER_GAP
    for l = 0, maxl do
      if forward then lc[l] = cum[l] + 1
      else lc[l] = total - (cum[l] + cw[l]) + 1 end
    end
  end

  local pos = {}
  for _, id in ipairs(g.order) do
    local l = layer[id]
    if vertical then pos[id] = { x = sec[id], y = lc[l] }
    else pos[id] = { x = lc[l], y = sec[id] } end
  end
  return { w = w, layer = layer, pos = pos }
end

local function draw(cv, g, L, vertical, forward)
  for _, e in ipairs(g.edges) do
    local p, c = e.from, e.to
    if p.id ~= c.id then
      local pp, cp = L.pos[p.id], L.pos[c.id]
      if vertical then
        local pcx = pp.x + math.floor(L.w[p.id] / 2)
        local ccx = cp.x + math.floor(L.w[c.id] / 2)
        if forward then
          local pb = pp.y + NODE_H - 1
          local ct = cp.y
          local chan = math.min(pb + 1, ct - 1)
          vline(cv, pcx, pb + 1, chan)
          if ccx ~= pcx then hline(cv, pcx, ccx, chan) end
          vline(cv, ccx, chan, ct - 1)
          cell(cv, ccx, ct - 1).ch = e.directed and '\u{25BC}' or '\u{2534}'
          if e.label and #e.label > 0 then put(cv, ccx + 2, ct - 1, e.label) end
        else
          local pt = pp.y
          local cb = cp.y + NODE_H - 1
          local chan = math.max(pt - 1, cb + 1)
          vline(cv, pcx, pt - 1, chan)
          if ccx ~= pcx then hline(cv, pcx, ccx, chan) end
          vline(cv, ccx, chan, cb + 1)
          cell(cv, ccx, cb + 1).ch = e.directed and '\u{25B2}' or '\u{252C}'
          if e.label and #e.label > 0 then put(cv, ccx + 2, cb + 1, e.label) end
        end
      else
        local pcy = pp.y + math.floor(NODE_H / 2)
        local ccy = cp.y + math.floor(NODE_H / 2)
        if forward then
          local pr = pp.x + L.w[p.id] - 1
          local cl = cp.x
          local chan = math.min(pr + 1, cl - 1)
          hline(cv, pr + 1, chan, pcy)
          if ccy ~= pcy then vline(cv, chan, pcy, ccy) end
          hline(cv, chan, cl - 1, ccy)
          cell(cv, cl - 1, ccy).ch = e.directed and '\u{25B6}' or '\u{2524}'
          if e.label and #e.label > 0 then put(cv, chan, ccy + 1, e.label) end
        else
          local pl = pp.x
          local cr = cp.x + L.w[c.id] - 1
          local chan = math.max(pl - 1, cr + 1)
          hline(cv, pl - 1, chan, pcy)
          if ccy ~= pcy then vline(cv, chan, pcy, ccy) end
          hline(cv, chan, cr + 1, ccy)
          cell(cv, cr + 1, ccy).ch = e.directed and '\u{25C0}' or '\u{251C}'
          if e.label and #e.label > 0 then put(cv, chan, ccy + 1, e.label) end
        end
      end
    end
  end
  for _, id in ipairs(g.order) do
    local p = L.pos[id]
    draw_box(cv, p.x, p.y, L.w[id], g.nodes[id].label, g.nodes[id].shape)
  end
end

----------------------------------------------------------------------
-- render
----------------------------------------------------------------------

local cache = {}

function M.render(src)
  local hit = cache[src]
  if hit then return hit end
  local ok, res = pcall(function()
    local g, err = parse(src)
    if not g then return nil, err end
    if #g.order == 0 then return nil, 'no nodes' end
    local vertical = g.dir ~= 'LR' and g.dir ~= 'RL'
    local forward = g.dir ~= 'BT' and g.dir ~= 'RL'
    local L = compute_layout(g, vertical, forward)
    local cv = new_canvas()
    draw(cv, g, L, vertical, forward)
    return grid_to_lines(to_grid(cv))
  end)
  if not ok then return nil, tostring(res) end
  cache[src] = res
  return res
end

return M