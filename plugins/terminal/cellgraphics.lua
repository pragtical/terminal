-- Pixel rectangles for terminal graphics whose strokes meet at cell boundaries.
local graphics = {}
local sizes = setmetatable({}, { __mode = "v" })

-- Entries in each group share the same connections, in light, heavy and double.
local boxes = {
  { "─", "━", "═", "lr" }, { "│", "┃", "║", "ud" },
  { "┌", "┏", "╔", "rd" }, { "┐", "┓", "╗", "ld" },
  { "└", "┗", "╚", "ru" }, { "┘", "┛", "╝", "lu" },
  { "├", "┣", "╠", "urd" }, { "┤", "┫", "╣", "uld" },
  { "┬", "┳", "╦", "lrd" }, { "┴", "┻", "╩", "lru" },
  { "┼", "╋", "╬", "lrud" }
}

local function rect(shape, x1, y1, x2, y2)
  if x2 > x1 and y2 > y1 then
    shape[#shape+1] = { x1, y1, x2 - x1, y2 - y1 }
  end
end

local function box(w, h, stroke, double, arms)
  local shape = {}
  local l, r = arms:find("l", 1, true), arms:find("r", 1, true)
  local u, d = arms:find("u", 1, true), arms:find("d", 1, true)
  local gap = double and math.min(stroke, w - 2*stroke, h - 2*stroke) or 0
  local band = gap > 0 and 2*stroke + gap or stroke
  local x, y = math.floor((w-band)/2), math.floor((h-band)/2)
  local left, right = l and 0 or x, r and w or x+band
  local top, bottom = u and 0 or y, d and h or y+band
  if gap <= 0 then
    if not (l or r) then
      rect(shape, x, top, x+stroke, bottom)
    else
      rect(shape, left, y, right, y+stroke)
      rect(shape, x, top, x+stroke, y)
      rect(shape, x, y+stroke, x+stroke, bottom)
    end
  elseif not (l or r) then
    rect(shape, x, top, x+stroke, bottom)
    rect(shape, x+band-stroke, top, x+band, bottom)
  else
    -- An incoming vertical arm splits the horizontal rail at the junction.
    local function rail(rail_y, arm, y1, y2)
      if arm then
        rect(shape, x, y1, x+stroke, y2)
        rect(shape, x+band-stroke, y1, x+band, y2)
        rect(shape, left, rail_y, x, rail_y+stroke)
        rect(shape, x+band, rail_y, right, rail_y+stroke)
      else
        rect(shape, left, rail_y, right, rail_y+stroke)
      end
    end
    rail(y, u, top, y+stroke)
    rail(y+band-stroke, d, y+band-stroke, bottom)
    if not l then rect(shape, x, y+stroke, x+stroke, y+band-stroke) end
    if not r then rect(shape, x+band-stroke, y+stroke, x+band, y+band-stroke) end
  end
  return shape
end

-- Turn a light stroke through a quarter circle; its ends meet the straight rails.
local function rounded_corner(w, h, stroke, right, down)
  local shape = {}
  local x, y = math.floor((w-stroke)/2), math.floor((h-stroke)/2)
  local width, height = right and w-x or x+stroke, down and h-y or y+stroke
  local outer = math.min(width, height, math.floor(w/3) + stroke)
  local inner = outer-stroke
  local function segment(x1, y1, x2, y2)
    if not right then x1, x2 = stroke-x2, stroke-x1 end
    if not down then y1, y2 = stroke-y2, stroke-y1 end
    rect(shape, x+x1, y+y1, x+x2, y+y2)
  end
  segment(outer, 0, width, stroke)
  segment(0, outer, stroke, height)
  for row = 0, outer-1 do
    local dy = outer-row-0.5
    local function edge(radius)
      return outer - math.floor(math.sqrt(math.max(0, radius*radius-dy*dy)) + 0.5)
    end
    segment(edge(outer), row, edge(inner), row+1)
  end
  return shape
end

---Get shared glyph shapes for a cell size. Coordinates are relative to the cell.
---@param w integer Cell width in pixels
---@param h integer Cell height in pixels
---@return table<string, table[]> shapes
function graphics.build(w, h)
  local key = w .. "x" .. h
  if sizes[key] then return sizes[key] end
  local shapes = {}
  local function block(glyph, x1, y1, x2, y2)
    shapes[glyph] = {}
    rect(shapes[glyph], x1, y1, x2, y2)
  end
  local function eighth(size, n) return math.floor((size*n + 4)/8) end
  for n = 1, 8 do
    block(utf8.char(0x2580+n), 0, eighth(h, 8-n), w, h)
  end
  for n = 1, 7 do
    block(utf8.char(0x2590-n), 0, 0, eighth(w, n), h)
  end
  block("▀", 0, 0, w, eighth(h, 4))
  block("▔", 0, 0, w, eighth(h, 1))
  block("▐", eighth(w, 4), 0, w, h)
  block("▕", eighth(w, 7), 0, w, h)
  local mid_x, mid_y = eighth(w, 4), eighth(h, 4)
  local function quadrant(glyphs, x1, y1, x2, y2)
    for glyph in glyphs:gmatch(utf8.charpattern) do
      shapes[glyph] = shapes[glyph] or {}
      rect(shapes[glyph], x1, y1, x2, y2)
    end
  end
  quadrant("▘▙▚▛▜", 0, 0, mid_x, mid_y)
  quadrant("▛▜▝▞▟", mid_x, 0, w, mid_y)
  quadrant("▖▙▛▞▟", 0, mid_y, mid_x, h)
  quadrant("▗▙▚▜▟", mid_x, mid_y, w, h)
  local side = math.min(w, h)
  local sx, sy = math.floor((w-side)/2), math.floor((h-side)/2)
  block("■", sx, sy, sx+side, sy+side)

  local stroke = math.min(side, math.max(1, math.floor(w/12 + 0.5)))
  for _, group in ipairs(boxes) do
    shapes[group[1]] = box(w, h, stroke, false, group[4])
    shapes[group[2]] = box(w, h, math.min(2*stroke, side), false, group[4])
    shapes[group[3]] = box(w, h, stroke, true, group[4])
  end
  shapes["╭"] = rounded_corner(w, h, stroke, true, true)
  shapes["╮"] = rounded_corner(w, h, stroke, false, true)
  shapes["╰"] = rounded_corner(w, h, stroke, true, false)
  shapes["╯"] = rounded_corner(w, h, stroke, false, false)
  sizes[key] = shapes
  return shapes
end

return graphics
