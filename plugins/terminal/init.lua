-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local common = require "core.common"
local View = require "core.view"
local keymap = require "core.keymap"
local StatusView = require "core.statusview"

local palette = require "plugins.terminal.palette"
local terminal_native = require "plugins.terminal.libterminal"

local prev_scale = SCALE
local windows = PLATFORM == "Windows"
local default_shell = os.getenv(windows and "COMSPEC" or "SHELL")
if not default_shell or default_shell == "" then
  default_shell = windows and [[C:\Windows\System32\cmd.exe]] or "sh"
end

local default_config = {
  -- outputs a terminal.log file of all the output of your shell
  debug = false,
  -- the TERM to present as.
  term = "xterm-256color",
  -- pressing this key and ctrl will allow normal commands to be run that start with ctrl (ctrl+n, ctrl+w, etc..) while using the terminal
  -- set to nil to disable entirely
  inversion_key = "shift",
  -- lua pattern for escape sequences to ignore. nil to target all escapes to terminal. example value would be "ctrl%+[nwpf]"
  omit_escapes = nil,
  -- the default shell to boot up in
  shell = default_shell,
  -- Arguments passed to the shell on startup.
  arguments = { },
  -- the environmental variable to set on shell instantiation
  environment = { },
  -- the amount of time between line scrolling when we're dragging offscreen
  scrolling_speed = 0.01,
  -- the newline character to use
  -- We set ICRNL, so that this is translated to `\n` at input time... but this seems to be necessary. `micro`
  -- doesn't allow you to newline if you don't set it to `\r`.
  newline = ((config.plugins.terminal.shell or default_shell):find("cmd.exe") and "\r\n" or "\r"),
  -- the backspace character to use
  backspace = "\x7F",
  -- the delete character to use
  delete = "\x1B[3~",
  -- the amount of lines you can emit before we start cutting them off
  scrollback_limit = 10000,
  -- the default height of the console drawer
  drawer_height = 300,
  -- Use a different font from the code editor
  use_custom_font = false,
  -- the default console font. non-monospace is unsupported, fonts that
  -- work great and provide mostly everything you need to properly render
  -- things like btop:
  -- * JuliaMono Regular - https://github.com/cormullion/juliamono
  -- * MesloLGS NF Regular - https://github.com/romkatv/powerlevel10k-media
  -- You should use both, Julia as main and MesloLGS as fallback.
  font = style.code_font,
  bold_font = style.code_font:copy(style.code_font:get_size(), { smoothing = true }),
  -- padding around the edges of the terminal
  padding = { x = 0, y = 0 },
  -- show bold text in bright colors
  bold_text_in_bright_colors = true,
  -- set to 0 to disable color adjustments based on background
  minimum_contrast_ratio = 3,
}
local function set_config_default_values(spec)
  for _, option in ipairs(spec) do
    if option.path and option.default == nil then
      option.default = default_config[option.path]
    end
  end
  return spec
end
-- configuration for the settings GUI (do not modify)
default_config.config_spec = set_config_default_values {
  name = "Terminal",
  {
    label = "Use Custom Font",
    description = "Use the configured custom font for the terminal (requires restart).",
    path = "use_custom_font", type = "TOGGLE",
    default = false
  },
  {
    label = "Font",
    description = "Custom font to use for the terminal (non-monospace unsupported, great choices are JuliaMono and MesloLGS NF) (requires restart).",
    path = "font", type = "font",
    default = {
      fonts = {
        {
          name = "JetBrains Mono Regular",
          path = DATADIR .. "/fonts/JetBrainsMono-Regular.ttf"
        }
      },
      options = {
        size = 15,
        antialiasing = "subpixel",
        hinting = "slight"
      }
    },
    on_apply = function()
      prev_scale = SCALE
      if not config.plugins.terminal.use_custom_font then
        config.plugins.terminal.font = style.code_font
      end
      config.plugins.terminal.bold_font = config.plugins.terminal.font:copy(
        config.plugins.terminal.font:get_size(), { smoothing = true }
      )
    end
  },
  {
    label = "Show Bold Text In Bright Colors",
    description = "Display emboldened text with brighter colors.",
    path = "bold_text_in_bright_colors", type = "TOGGLE",
    default = true
  },
  {
    label = "Minimum Contrast Ratio",
    description = "Minimum contrast between the text and background color (set to 0 to disable auto color adjustment).",
    path = "minimum_contrast_ratio", type = "NUMBER",
    default = 3
  },
  {
    label = "Terminal Drawer Height",
    description = "Height of the terminal drawer (in pixels).",
    path = "drawer_height", type = "NUMBER",
    default = 300
  },
  {
    label = "Inversion Key",
    description = "The key to press in combination with CTRL to send the shortcut to Pragtical instead of the terminal.",
    path = "inversion_key", type = "STRING",
    default = "shift"
  },
  {
    label = "Omit Shortcuts",
    description = "A Lua pattern of shortcuts to pass to Pragtical instead of the terminal.",
    path = "omit_escapes", type = "STRING"
  },
  {
    label = "Scrolling speed",
    description = "The amount of time to scroll a line when selecting text offscreen.",
    path = "scrolling_speed", type = "NUMBER",
    default = 0.01
  },
  {
    label = "Shell",
    description = "Absolute path to the shell for the terminal.",
    path = "shell", type = "FILE", exists=true,
    default = default_shell,
    on_apply = function(shell)
      if shell:lower():find("cmd.exe") then
        config.plugins.terminal.newline = "\r\n"
      else
        config.plugins.terminal.newline = "\r"
      end
    end
  },
  {
    label = "Shell Arguments",
    description = "Extra arguments to pass to the shell; does not function on windows.",
    path = "arguments", type = "LIST_STRINGS"
  },
  {
    label = "Terminal Type",
    description = "The type to terminal to appear as (sets the $TERM environment variable).",
    path = "term", type = "STRING",
    default = "xterm-256color"
  },
  {
    label = "Scrollback Buffer Size",
    description = "Number of lines to store for scrolling in the terminal.",
    path = "scrollback_limit", type = "NUMBER",
    default = 10000
  },
  {
    label = "Change Other Options",
    description = "Edit additional terminal options in your user module.",
    icon = "P", type = "BUTTON", on_click = "core:open-user-module", path = ""
  }
}
config.plugins.terminal = common.merge(default_config, config.plugins.terminal)

core.add_thread(function()
  -- give time for ui settings (even on editor restart) and then apply font
  for _=1, 2 do coroutine.yield() end
  if not config.plugins.terminal.use_custom_font then
    config.plugins.terminal.font = style.code_font
    config.plugins.terminal.bold_font = config.plugins.terminal.font:copy(
      config.plugins.terminal.font:get_size(), { smoothing = true }
    )
  elseif prev_scale ~= SCALE then
    config.plugins.terminal.font:set_size(
      (config.plugins.terminal.font:get_size() / prev_scale) * SCALE
    )
    config.plugins.terminal.bold_font = config.plugins.terminal.font:copy(
      config.plugins.terminal.font:get_size(), { smoothing = true }
    )
  end
end)

-- contrast functions pulled from https://github.com/xtermjs/xterm.js/blob/99df13b085aecb051f1373c5b7f8e819c4f41442/src/common/Color.ts#L285.
local function contrastRatio(l1, l2)
  if l1 < l2 then return (l2 + 0.05) / (l1 + 0.05) end
  return (l1 + 0.05) / (l2 + 0.05)
end

local function relativeLuminance(color)
  local rs = color[1] / 255
  local gs = color[2] / 255
  local bs = color[3] / 255
  local rr = rs <= 0.03928 and rs / 12.92 or (((rs + 0.055) / 1.055) ^ 2.4)
  local rg = gs <= 0.03928 and gs / 12.92 or (((gs + 0.055) / 1.055) ^ 2.4)
  local rb = bs <= 0.03928 and bs / 12.92 or (((bs + 0.055) / 1.055) ^ 2.4)
  return rr * 0.2126 + rg * 0.7152 + rb * 0.0722
end

local function reduceLuminance(bg, fg, ratio)
  local bgL = relativeLuminance(bg)
  local cr = contrastRatio(relativeLuminance(fg), bgL)
  local nFg = { table.unpack(fg) }
  while cr < ratio and (nFg[1] > 0 or nFg[2] > 0 or nFg[3] > 0) do
    -- Reduce by 10% until the ratio is hit
    nFg[1] = nFg[1] - math.max(0, math.ceil(nFg[1] * 0.1))
    nFg[2] = nFg[2] - math.max(0, math.ceil(nFg[2] * 0.1))
    nFg[3] = nFg[3] - math.max(0, math.ceil(nFg[3] * 0.1))
    cr = contrastRatio(relativeLuminance(nFg), bgL)
  end
  return nFg
end

local function increaseLuminance(bg, fg, ratio)
  local bgL = relativeLuminance(bg)
  local cr = contrastRatio(relativeLuminance(fg), bgL)
  local nFg = { table.unpack(fg) }
  local cr = contrastRatio(relativeLuminance(nFg), bgL)
  while cr < ratio and (nFg[1] < 0xFF or nFg[2] < 0xFF or nFg[3] < 0xFF) do
    -- Increase by 10% until the ratio is hit
    nFg[1] = math.min(0xFF, nFg[1] + math.ceil((255 - nFg[1]) * 0.1))
    nFg[2] = math.min(0xFF, nFg[2] + math.ceil((255 - nFg[2]) * 0.1))
    nFg[3] = math.min(0xFF, nFg[3] + math.ceil((255 - nFg[3]) * 0.1))
    cr = contrastRatio(relativeLuminance(nFg), bgL)
  end
  return nFg
end

local function ensureContrastRatio(bg, fg, ratio)
  local bgL = relativeLuminance(bg)
  local fgL = relativeLuminance(fg)
  local cr = contrastRatio(bgL, fgL)
  if cr < ratio then
    if fgL < bgL then
      local resultA = reduceLuminance(bg, fg, ratio)
      local resultARatio = contrastRatio(bgL, relativeLuminance(resultA))
      if resultARatio < ratio then
        local resultB = increaseLuminance(bg, fg, ratio)
        local resultBRatio = contrastRatio(bgL, relativeLuminance(resultB))
        return resultARatio > resultBRatio and resultA or resultB
      end
      return resultA
    end
    local resultA = increaseLuminance(bg, fg, ratio)
    local resultARatio = contrastRatio(bgL, relativeLuminance(resultA))
    if resultARatio < ratio then
      local resultB = reduceLuminance(bg, fg, ratio)
      local resultBRatio = contrastRatio(bgL, relativeLuminance(resultB))
      return resultARatio > resultBRatio and resultA or resultB
    end
    return resultA
  end
  return fg
end



local TerminalView = View:extend()

---Refresh indexed colors and discard contrast adjustments from the previous palette.
function TerminalView:update_colors()
  local colors = palette.get(style)
  local ratio = config.plugins.terminal.minimum_contrast_ratio
  local bright = self.options.bold_text_in_bright_colors
  if self.colors ~= colors or self.contrast_ratio ~= ratio or self.bright_colors ~= bright then
    self.colors, self.contrast_ratio, self.bright_colors = colors, ratio, bright
    self.contrast_foreground = {}
    core.redraw = true
  end
end

function TerminalView:get_name()
  if self.task_view then return "Task Terminal" end
  return (self.modified_since_last_focus and "* " or "") .. (self.terminal and self.terminal:name() or "Terminal")
end
function TerminalView:supports_text_input() return true end

function TerminalView:new(options)
  TerminalView.super.new(self)
  options = common.merge(common.merge({}, config.plugins.terminal), options)
  self.size.y = options.drawer_height
  self.options = options
  self:update_colors()
  self.cursor = "ibeam"
  self.scrollable = true
  self.last_size = { x = self.size.x, y = self.size.y }
  self.focused = false
  self.modified_since_last_focus = false
  self.mouse_buttons = {}
end


function TerminalView:shift_selection_update()
  local callback = self.task and self.task.on_output
  local shifts, chunk = self.terminal:update(callback ~= nil)
  if chunk and callback then core.try(callback, chunk) end
  if shifts and not self.focused then self.modified_since_last_focus = true end
  if self.selection and shifts then
    self.selection[2] = self.selection[2] - shifts
    self.selection[4] = self.selection[4] - shifts
    if math.abs(math.min(self.selection[2], self.selection[4])) > self.options.scrollback_limit then
      self.selection = nil
    end
  end
  return shifts
end


local function native_environment(defaults, overrides)
  if PLATFORM ~= "Windows" then return common.merge(defaults, overrides) end
  local inherited, entries = {}, {}
  for _, variables in ipairs { terminal_native.getenv(), defaults, overrides } do
    for key, value in pairs(variables) do inherited[key:upper()] = key .. "=" .. value end
  end
  for _, entry in pairs(inherited) do entries[#entries + 1] = entry end
  table.sort(entries, function(a, b) return a:upper() < b:upper() end)
  return table.concat(entries, "\0") .. "\0\0"
end

local function new_process(view, executable, arguments, options)
  return terminal_native.new(view.columns or 80, view.lines or 24,
    view.options.scrollback_limit, view.options.term, executable, arguments,
    native_environment(view.options.environment, options.environment), view.options.debug, options.cwd)
end

function TerminalView:spawn()
  self.terminal = new_process(self, self.options.shell, self.options.arguments,
    { cwd = core.root_project().path })
  if self.task_view then return end
  -- We make this weak so that any other method of closing the view gets caught up in the garbage collection and the coroutine doesn't count as a reference for gc purposes.
  local weak_table = { self = self }
  setmetatable(weak_table, { __mode = "v" })
  self.routine = self.routine or core.add_background_thread(function()
    local count = 0
    while weak_table.self and weak_table.self.terminal do
      -- do not redraw when hidden
      if weak_table.self.size.y > 0 then
        core.redraw = weak_table.self:shift_selection_update() or core.redraw
        if core.active_view == self and not core.redraw then
          coroutine.yield(0.5)
        else
          coroutine.yield(1/30)
        end
      else
        if weak_table.self:shift_selection_update() then
          weak_table.self:update()
        end
        coroutine.yield(1)
      end
      -- make sure to exit if no longer part of the root view
      if count >= 500 then
        local found = false
        local views = core.root_view.root_node:get_children()
        for _, view in ipairs(views) do
          if view == weak_table.self then found = true break end
        end
        if not found then break end
        count = 0
      else
        count = count + 1
      end
    end
  end)
end


---Can be overriden by widgets to listen for scale change events to apply
---any neccesary changes in sizes, padding, etc...
---@param new_scale number
---@param prev_scale number
function TerminalView:on_scale_change(new_scale, prev_scale)
  TerminalView.super.on_scale_change(self, new_scale, prev_scale)
  if self.options.font ~= style.code_font then
    self.options.font:set_size(
      self.options.font:get_size() * (new_scale / prev_scale)
    )
  end
end


function TerminalView:update()
  if self.closed then return end
  TerminalView.super.update(self)
  if self.task_view and self.size.y <= 0 then return end
  self:update_colors()
  if self.last_font_size and self.last_font_size ~= self.options.font:get_size() then
    self.options.bold_font:set_size(self.options.font:get_size())
  end
  if (self.last_font_size and self.last_font_size ~= self.options.font:get_size()) or self.size.x > 0 and self.size.y > 0 and not self.terminal or self.last_size.x ~= self.size.x or self.last_size.y ~= self.size.y then
    self.columns = math.max(math.floor((self.size.x - self.options.padding.x*2) / self.options.font:get_width("W")), 1)
    self.lines = math.max(math.floor((self.size.y - self.options.padding.y*2) / self.options.font:get_height()), 1)
    if self.lines > 0 and self.columns > 0 then
      if not self.terminal then
        self:spawn()
      else
        self.terminal:size(self.columns, self.lines)
        self.last_size = { x = self.size.x, y = self.size.y }
      end
    end
  end
  if self.terminal then
    if not self.task_view then core.redraw = self:shift_selection_update() or core.redraw end
    if self.deferred_input then
      self:input(self.deferred_input)
      self.deferred_input = nil
    end
    if self.task_view or self.terminal:exited() == false then
      self.cursor = "ibeam"
      if self.terminal:mouse_tracking_mode()
         or self.v_scrollbar.hovering.track
         or self.v_scrollbar.hovering.track then
        self.cursor = "arrow"
      end
      if (core.active_view == self and not self.focused) or (core.active_view ~= self and self.focused) then
        self.focused = core.active_view == self
        self.modified_since_last_focus = false
        self.terminal:focused(self.focused)
      end
      local x, y, mode = self.terminal:cursor()
      if mode == "blinking" and not config.disable_blink then
        local T, t0 = config.blink_period, core.blink_start
        local ta, tb = core.blink_timer, system.get_time()
        if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
          core.redraw = true
        end
        core.blink_timer = tb
        if core.request_update and self.focused
          and system.window_has_focus(core.window) and self.terminal:scrollback() == 0
        then
          core.request_update(T / 2 - (tb - t0) % (T / 2))
        end
      end
      if self.scrolling_offscreen then
        local now = system.get_time()
        if not self.last_scroll_time or now - self.last_scroll_time >= self.options.scrolling_speed then
          self.last_scroll_time = now
          self.terminal:scrollback(self.terminal:scrollback() + self.scrolling_offscreen)
          core.redraw = true
        end
        if core.request_update then
          core.request_update(self.last_scroll_time + self.options.scrolling_speed - now)
        end
      end
      local scrollback, total_scrollback = self.terminal:scrollback()
      local lh = self.options.font:get_height()
      -- 0 should be if we're at max scrollback. 1 should be if we're at 0 scrollback.
      self.v_scrollbar:set_size(self.position.x, self.position.y, self.size.x, self.size.y, self:get_scrollable_size())
      self.v_scrollbar:set_percent(1.0 - (scrollback / total_scrollback))
      self.v_scrollbar:update()
    else
      core.add_thread(function()
        self:close()
      end)
    end
  end
  self.last_font_size = self.options.font:get_size()
end


function TerminalView:set_target_size(axis, value)
  if axis == "y" then
    self.size.y = value
    return true
  end
end

function TerminalView:convert_color(int, target, should_bright)
  local attributes = bit.rshift(int, 24)
  local type = bit.band(attributes, 0x7)
  if type == 0 then
    if target == "foreground" then return style.text, attributes end
    return style.background, attributes
  elseif type == 1 then
    if target == "foreground" then return style.background, attributes end
    return style.text, attributes
  elseif type == 2 then
    local index = bit.band(bit.rshift(int, 16), 0xFF)
    if index < 8 and should_bright and (bit.band(bit.rshift(attributes, 3), 0x1) ~= 0) then index = index + 8 end
    return self.colors[tonumber(index)], attributes
  elseif type == 3 then
    return {
      tonumber(bit.band(bit.rshift(int, 16), 0xFF)),
      tonumber(bit.band(bit.rshift(int, 8), 0xFF)),
      tonumber(bit.band(bit.rshift(int, 0), 0xFF)),
      255
    }, attributes
  end
  return nil
end

function TerminalView:sorted_selection()
  if not self.selection then return nil end
  local selection = { table.unpack(self.selection) }
  if selection[2] > selection[4] or (selection[2] == selection[4] and selection[1] > selection[3]) then
    selection = { selection[3], selection[4], selection[1], selection[2] }
  end
  return selection
end


function TerminalView:draw()
  TerminalView.super.draw_background(self, style.background)
  if self.terminal then
    local cursor_x, cursor_y, mode = self.terminal:cursor()
    local space_width = self.options.font:get_width(" ")

    local y = self.position.y + self.options.padding.y
    local lh = self.options.font:get_height()


    local selection = self:sorted_selection()
    for line_idx, line in ipairs(self.terminal:lines()) do
      local x = self.position.x + self.options.padding.x
      local should_draw_cursor = false
      if mode ~= "hidden" and core.active_view == self and line_idx - 1 == cursor_y and self.terminal:scrollback() == 0 then
        if mode == "blinking" and not config.disable_blink then
          local T = config.blink_period
          if (core.blink_timer - core.blink_start) % T < T / 2 then
            should_draw_cursor = true
          end
        else
          should_draw_cursor = true
        end
      end
      local offset = 0
      local foreground, background, text_style
      for i = 1, #line, 2 do
        local packed = math.tointeger(line[i])
        background = self:convert_color(bit.band(packed, 0xFFFFFFFF), "background")
        foreground, text_style = self:convert_color(bit.rshift(packed, 32), "foreground", self.bright_colors)

        if self.contrast_ratio > 0 then
          if not self.contrast_foreground[line[i]] then
            self.contrast_foreground[line[i]] = ensureContrastRatio(background, foreground, self.contrast_ratio)
          end
          foreground = self.contrast_foreground[line[i]]
        end

        local font = (bit.band(bit.rshift(text_style, 3), 0x1) ~= 0) and self.options.bold_font or self.options.font
        local text = line[i+1]
        local length = text:ulen()
        local valid_utf8 = length ~= nil
        local subfunc, lengthfunc = string.usub, string.ulen
        if not valid_utf8 then
          length = #text
          lengthfunc = function(str) return #str end
          subfunc = string.sub
        end
        local idx = (line_idx - 1) - self.terminal:scrollback()
        local sections = { { background, foreground, text } }
        if selection then
          if ((idx == selection[2] and selection[1] <= offset) or selection[2] < idx) and (selection[4] > idx or (idx == selection[4] and (selection[3] >= offset + length))) then -- overlaps all
            sections = { { foreground, background, text } }
          elseif (idx == selection[2] and idx == selection[4] and selection[1] > offset and selection[3] < offset + length) then -- overlaps in middle
            sections = { { background, foreground, subfunc(text, 1, selection[1] - offset) }, { foreground, background, subfunc(text, selection[1] - offset + 1, selection[3] - offset) }, { background, foreground, subfunc(text, selection[3] - offset + 1, length) } }
          elseif (selection[2] < idx or (idx == selection[2] and selection[1] <= offset)) and (idx == selection[4] and selection[3] < offset + length and selection[3] >= offset) then -- overlaps start
            sections = { { foreground, background, subfunc(text, 1, selection[3] - offset) }, { background, foreground, subfunc(text, selection[3] - offset + 1, length) } }
          elseif (idx == selection[2] and selection[1] < offset + length and selection[1] >= offset) and (selection[4] > idx or (selection[4] == idx and selection[3] >= offset + length)) then -- overlaps end
            sections = { { background, foreground, subfunc(text, 1, selection[1] - offset) }, { foreground, background, subfunc(text, selection[1] - offset + 1, length) } }
          end
        end
        -- Split the run at the cursor cell to draw it in the theme's caret color.
        if should_draw_cursor and cursor_x >= offset and cursor_x < offset + length then
          local local_offset = offset
          for i,v in ipairs(sections) do
            local len = lengthfunc(v[3])
            if cursor_x >= local_offset and cursor_x < local_offset + len then
              sections[i] = nil
              local target = i
              if cursor_x ~= local_offset then
                table.insert(sections, target, { v[1], v[2], subfunc(v[3], 1, cursor_x - local_offset) })
                target = target + 1
              end
              table.insert(sections, target, { style.caret, style.background, subfunc(v[3], cursor_x - local_offset + 1, cursor_x - local_offset + 1) })
              target = target + 1
              if cursor_x ~= local_offset + len - 1 then
                table.insert(sections, target, { v[1], v[2], subfunc(v[3], cursor_x - local_offset + 2) })
              end
              break
            end
            local_offset = local_offset + len
          end
        end
        for i, section in ipairs(sections) do
          if section then
            local background, foreground, text = table.unpack(section)
            if background and background ~= style.background then
              renderer.draw_rect(x, y, (text:ulen() or #text)*space_width, lh, background)
            end
            x = renderer.draw_text(font, text, x, y, foreground)
          end
        end
        offset = offset + length
      end
      y = y + lh
    end
  end
  TerminalView.super.draw_scrollbar(self)
end

function TerminalView:convert_coordinates(x, y)
  local w = self.options.font:get_width(" ")
  local col_exact = math.floor((x - self.position.x - self.options.padding.x) / w)
  local col_approx = common.round((x - self.position.x - self.options.padding.x) / w)
  local row = math.floor((y - self.position.y - self.options.padding.y) / self.options.font:get_height())
  return math.max(0, col_exact), math.max(0, row), math.max(0, col_approx)
end

function TerminalView:get_mouse_tracking()
  if not self.terminal  then return end
  local mode = self.terminal:mouse_tracking_mode()
  if not mode then return nil end
  return mode, self.terminal:mouse_encoding()
end

function TerminalView:get_mouse_button_code(button)
  if button == "left" then return 0 end
  if button == "middle" then return 1 end
  if button == "right" then return 2 end
end

function TerminalView:get_active_mouse_button_code()
  for _, button in ipairs({ "left", "middle", "right" }) do
    if self.mouse_buttons[button] then
      return self:get_mouse_button_code(button)
    end
  end
  return 3
end

function TerminalView:send_mouse_event(button_code, col, row, suffix, encoding)
  if encoding == "sgr" then
    self.terminal:input("\x1B[<" .. button_code .. ";" .. (col + 1) .. ";" .. (row + 1) .. suffix)
  else
    self.terminal:input("\x1B[M" .. string.char(32 + button_code) .. string.char(32 + col + 1) .. string.char(32 + row + 1))
  end
end

function TerminalView:get_word_boundaries(col, row)
  for line_idx, line in ipairs(self.terminal:lines()) do
    if line_idx == row + 1 then
      local text = ""
      for i = 1, #line, 2 do
        text = text .. line[i+1]
      end
      local scrollback = self.terminal:scrollback()
      row = row - scrollback
      if text:sub(col + 1, col + 1):match("%s") then
        return col, row, col + 1, row
      end
      local next_space = text:find("%s", col + 1) or #text
      local last_space = 0
      local idx = text:reverse():find("%s", #text - col)
      if idx then
        last_space = (#text - idx) + 1
      end
      return last_space, row, next_space - 1, row
    end
  end
end

function TerminalView:on_mouse_pressed(button, x, y, clicks)
  local result = self.v_scrollbar:on_mouse_pressed(button, x, y, clicks)
  if result then
    if result ~= true then
      local _, total_scrollback = self.terminal:scrollback()
      self.terminal:scrollback(math.floor((1.0 - result) * total_scrollback))
    end
    return true
  end
  self.mouse_x = x
  self.mouse_y = y
  local col, row = self:convert_coordinates(x, y)
  local inverted = config.plugins.terminal.inversion_key and keymap.modkeys[config.plugins.terminal.inversion_key]
  local mouse_mode, mouse_encoding = self:get_mouse_tracking()
  local button_code = self:get_mouse_button_code(button)
  if not inverted and mouse_mode and button_code ~= nil then
    self.mouse_buttons[button] = true
    self:send_mouse_event(button_code, col, row, "M", mouse_encoding)
    return true
  end
  if button == "left" then
    if clicks % 4 == 1 then
      self.selection = nil
      self.pressing = true
    elseif clicks % 4 == 2 then
      self.word_selecting = { self:get_word_boundaries(col, row) }
      self.selection = { table.unpack(self.word_selecting) }
    elseif clicks % 4 == 3 then
      local scrollback = self.terminal:scrollback()
      row = row - scrollback
      self.row_selecting = { 0, row, 0, row + 1 }
      self.selection = { 0, row, 0, row + 1 }
    end
  end
end

function TerminalView:on_mouse_moved(x, y, dx, dy)
  local result = self.v_scrollbar:on_mouse_moved(x, y, dx, dy)
  if result then
    if result ~= true then
      local _, total_scrollback = self.terminal:scrollback()
      self.terminal:scrollback(math.floor((1.0 - result) * total_scrollback))
    end
    return true
  end
  self.mouse_x = x
  self.mouse_y = y
  local inverted = config.plugins.terminal.inversion_key and keymap.modkeys[config.plugins.terminal.inversion_key]
  local mouse_mode, mouse_encoding = self:get_mouse_tracking()
  if not inverted and mouse_mode then
    local button_code = self:get_active_mouse_button_code()
    if mouse_mode == "any" or (mouse_mode == "button" and button_code ~= 3) then
      local col, row = self:convert_coordinates(x, y)
      self:send_mouse_event(button_code + 32, col, row, "M", mouse_encoding)
      return true
    end
  end
  if self.pressing or self.word_selecting or self.row_selecting then
    if y < self.position.y then
      self.scrolling_offscreen = 1
    elseif y > self.position.y + self.size.y then
      self.scrolling_offscreen = -1
    else
      self.scrolling_offscreen = nil
    end
    local col, line, col_approx = self:convert_coordinates(x, y)
    local scrollback = self.terminal:scrollback()
    if not self.selection then self.selection = { col_approx, line - scrollback } end
    if not self.word_selecting and not self.row_selecting then
      self.selection[3] = col_approx
      self.selection[4] = line - scrollback
    elseif self.word_selecting then
      local col1, line1, col2, line2 = self:get_word_boundaries(col, line)
      if not col1 then
        self.selection[3] = col
        self.selection[4] = line - scrollback
      elseif self.word_selecting[2] > line1 or (self.word_selecting[2] == line1 and self.word_selecting[1] >= col1) then
        self.selection[1] = col1
        self.selection[2] = line1
        self.selection[3] = self.word_selecting[3]
        self.selection[4] = self.word_selecting[4]
      else
        self.selection[1] = self.word_selecting[1]
        self.selection[2] = self.word_selecting[2]
        self.selection[3] = col2
        self.selection[4] = line2
      end
    else
      self.selection[1] = 0
      self.selection[2] = math.min(self.row_selecting[2], line - scrollback)
      self.selection[3] = 0
      self.selection[4] = math.max(self.row_selecting[4], line - scrollback + 1)
    end
  end
end


function TerminalView:on_mouse_released(button, x, y)
  self.v_scrollbar:on_mouse_released(button, x, y)
  self.mouse_x = x
  self.mouse_y = y
  local col, row = self:convert_coordinates(x, y)
  local inverted = config.plugins.terminal.inversion_key and keymap.modkeys[config.plugins.terminal.inversion_key]
  local mouse_mode, mouse_encoding = self:get_mouse_tracking()
  local button_code = self:get_mouse_button_code(button)
  if button_code ~= nil and not inverted and mouse_mode and mouse_mode ~= "x10" then
    self:send_mouse_event(3, col, row, "m", mouse_encoding)
  end
  if button_code ~= nil then
    self.mouse_buttons[button] = nil
  end
  if button == "left" then
    self.pressing = false
    self.word_selecting = nil
    self.row_selecting = nil
    self.scrolling_offscreen = nil
  end
end


function TerminalView:get_scrollable_size()
  if not self.terminal then return self.size.y end
  local lh = self.options.font:get_height()
  local _, total_scrollback = self.terminal:scrollback()
  return total_scrollback * lh + self.size.y
end


function TerminalView:input(text)
  if self.task_view and not self.task then return false end
  if self.terminal then
    self.terminal:input(text)
    if self.terminal:scrollback() ~= 0 then self.terminal:scrollback(0) end
    self:shift_selection_update()
    core.redraw = true
    return true
  else
    self.deferred_input = (self.deferred_input or "") .. text
  end
  return false
end

function TerminalView:on_text_input(text)
  return self:input(text)
end


---Run an argv command in an idle task view and retain earlier stages' output.
---@param argv string[] Executable and literal arguments.
---@param options {cwd?:string, environment?:table<string,string>, on_output?:fun(chunk:string), on_exit?:fun(status:integer)}
function TerminalView:start_task(argv, options)
  assert(self.task_view and not self.task and not self.closed, "Task terminal is busy or closed")
  local child = new_process(self, argv[1], { table.unpack(argv, 2) }, options)
  if self.terminal then
    child:inherit_screen(self.terminal)
    self.terminal:close()
  end
  self.terminal, self.task = child, options
  self.deferred_input = nil
  core.add_background_thread(function()
    while self.task == options do
      core.redraw = self:shift_selection_update() or core.redraw
      local code, signal = child:exited(true)
      if code ~= false then
        self.task = nil
        if options.on_exit then core.try(options.on_exit, signal and signal > 0 and 128 + signal or code) end
        break
      end
      coroutine.yield(1 / 60)
    end
  end)
end

---Interrupt a task or kill its process group.
---@param force boolean
function TerminalView:stop_task(force)
  if not self.task then return end
  if force then self.terminal:kill() else self.terminal:input("\3") end
end

---Release the process and notify its owner when a terminal view is removed.
---@param do_close function Removes the view from its node.
function TerminalView:try_close(do_close)
  local task = self.task
  self.task, self.closed = nil, true
  if self.terminal then self.terminal:close() end
  self.terminal, self.routine = nil, nil
  if core.terminal_view == self then
    core.terminal_view, core.terminal_view_node, core.terminal_view_closed = nil, nil, nil
  end
  do_close()
  if task and task.on_exit then core.try(task.on_exit, 1) end
end

function TerminalView:close()
  local root = core.root_view.root_node
  local node = root:get_node_for_view(self)
  if node then node:close_view(root, self)
  elseif not self.closed then self:try_close(function() end) end
end


function TerminalView:get_text(line1, col1, line2, col2)
  local full_buffer = {}
  for line_idx, line in ipairs(self.terminal:lines(line1, line2)) do
    local idx = line_idx - 1 + line1
    local offset = 0
    for i = 1, #line, 2 do
      local text = line[i + 1]
      local length = text:ulen()
      local usub = string.usub
      if length == nil then
        length = #text
        usub = string.sub
      end
      if idx == line1 and idx == line2 then
        if offset + length >= col1 and offset <= col2 then
          local s = math.max(col1 - offset, 0) + 1
          local e = math.min(col2 - offset, length)
          table.insert(full_buffer, usub(text, s, e))
        end
      elseif idx == line1 then
        if offset + length >= col1 then
          local s = math.max(col1 - offset, 0) + 1
          table.insert(full_buffer, usub(text, s, length))
        end
      elseif idx > line1 and idx < line2 then
        table.insert(full_buffer, text)
      elseif idx == line2 then
        if offset <= col2 then
          local e = math.min(col2 - offset, length)
          table.insert(full_buffer, usub(text, 1, e))
        end
      end
      offset = offset + length
    end
  end
  return table.concat(full_buffer)
end


command.add(function(amount)
  -- core.root_view.overlapping_view is not in any release yet (as of 2.1.3)
  local view = core.root_view.overlapping_view
                or (core.root_view.overlapping_node and core.root_view.overlapping_node.active_view)
                or core.active_view
  return (view and view:is(TerminalView) and view.terminal), view, amount
end, {
  ["terminal:scroll"] = function(view, amount)
    if not view.terminal then return end
    local inverted = config.plugins.terminal.inversion_key and keymap.modkeys[config.plugins.terminal.inversion_key]
    local mouse_mode, mouse_encoding = view:get_mouse_tracking()
    if not inverted and mouse_mode and mouse_mode ~= "x10" then
      local col, row = view:convert_coordinates(view.mouse_x or view.position.x, view.mouse_y or view.position.y)
      view:send_mouse_event(amount > 0 and 64 or 65, col, row, "M", mouse_encoding)
    else
      view.accumulated_scroll = (view.accumulated_scroll or 0) + (amount or 1)
      if math.abs(view.accumulated_scroll) >= 1 then
        local delta = math.floor(view.accumulated_scroll + 0.5)
        view.terminal:scrollback(view.terminal:scrollback() + delta)
        view.accumulated_scroll = view.accumulated_scroll - math.floor(view.accumulated_scroll + 0.5)
      end
    end
  end
})


local active_terminal_predicate = function(...)
  return (core.active_view:is(TerminalView) and core.active_view.terminal), core.active_view, ...
end
command.add(active_terminal_predicate, {
  ["terminal:backspace"] = function(view) view:input(view.options.backspace) end,
  ["terminal:ctrl-backspace"] = function(view) view:input(view.options.backspace == "\b" and "\x7F" or "\b") end,
  ["terminal:alt-backspace"] = function(view) view:input("\x1B" .. view.options.backspace) end,
  ["terminal:insert"] = function(view) view:input("\x1B[2~") end,
  ["terminal:delete"] = function(view) view:input(view.options.delete) end,
  ["terminal:return"] = function(view) view:input(view.options.newline) end,
  ["terminal:enter"] = function(view) view:input(view.terminal:cursor_keys_mode() == "application" and "\x1BOM" or view.options.newline) end,
  ["terminal:break"] = function(view) view:input("\x03") end,
  ["terminal:eof"] = function(view) view:input("\x04") end,
  ["terminal:suspend"] = function(view) view:input("\x1A") end,
  ["terminal:tab"] = function(view) view:input("\t") end,
  ["terminal:paste"] = function(view)
    if view.terminal:paste_mode() == "bracketed" then
      view:input("\x1B[200~" .. system.get_clipboard() .. "\x1B[201~")
    else
      view:input(system.get_clipboard())
    end
  end,
  ["terminal:page-up"] = function(view) view:input("\x1B[5~") end,
  ["terminal:page-down"] = function(view) view:input("\x1B[6~") end,
  ["terminal:scroll-up"] = function(view) view.terminal:scrollback(view.terminal:scrollback() + view.lines) end,
  ["terminal:scroll-down"] = function(view) view.terminal:scrollback(view.terminal:scrollback() - view.lines) end,
  ["terminal:scroll-to-end"] = function(view) view.terminal:scrollback(0) end,
  ["terminal:scroll-to-top"] = function(view) view.terminal:scrollback(view.options.scrollback_limit) end,
  ["terminal:up"] = function(view) view:input(view.terminal:cursor_keys_mode() == "application" and "\x1BOA" or "\x1B[A") end,
  ["terminal:down"] = function(view) view:input(view.terminal:cursor_keys_mode() == "application" and "\x1BOB" or "\x1B[B") end,
  ["terminal:left"] = function(view) view:input(view.terminal:cursor_keys_mode() == "application" and "\x1BOD" or "\x1B[D") end,
  ["terminal:right"] = function(view) view:input(view.terminal:cursor_keys_mode() == "application" and "\x1BOC" or "\x1B[C") end,
  ["terminal:jump-up"] = function(view) view:input("\x1B[1;5A") end,
  ["terminal:jump-down"] = function(view) view:input("\x1B[1;5B") end,
  ["terminal:jump-right"] = function(view) view:input("\x1B[1;5C") end,
  ["terminal:jump-left"] = function(view) view:input("\x1B[1;5D") end,
  ["terminal:home"] = function(view) view:input(view.terminal:cursor_keys_mode() == "application" and "\x1BOH" or "\x1B[H") end,
  ["terminal:end"] = function(view) view:input(view.terminal:cursor_keys_mode() == "application" and "\x1BOF" or "\x1B[F") end,
  ["terminal:f1"]  = function(view) view:input("\x1BOP") end,
  ["terminal:f2"]  = function(view) view:input("\x1BOQ") end,
  ["terminal:f3"]  = function(view) view:input("\x1BOR") end,
  ["terminal:f4"]  = function(view) view:input("\x1BOS") end,
  ["terminal:f5"]  = function(view) view:input("\x1B[15~") end,
  ["terminal:f6"]  = function(view) view:input("\x1B[17~") end,
  ["terminal:f7"]  = function(view) view:input("\x1B[18~") end,
  ["terminal:f8"]  = function(view) view:input("\x1B[19~") end,
  ["terminal:f9"]  = function(view) view:input("\x1B[20~") end,
  ["terminal:f10"]  = function(view) view:input("\x1B[21~") end,
  ["terminal:f11"]  = function(view) view:input("\x1B[23~") end,
  ["terminal:f12"]  = function(view) view:input("\x1B[24~") end,
  ["terminal:escape"]  = function(view) view:input("\x1B") end,
  ["terminal:start"] = function(view) view:input("\x13") end,
  ["terminal:stop"] = function(view) view:input("\x11") end,
  ["terminal:cancel"] = function(view) view:input("\x18") end,
  ["terminal:start-of-heading"] = function(view) view:input("\x01") end,
  ["terminal:start-of-text"] = function(view) view:input("\x02") end,
  ["terminal:enquiry"] = function(view) view:input("\x05") end,
  ["terminal:acknowledge"] = function(view) view:input("\x06") end,
  ["terminal:bell"] = function(view) view:input("\x07") end,
  ["terminal:vertical-tab"] = function(view) view:input("\x0B") end,
  ["terminal:redraw"] = function(view) view:input("\x0C") end,
  ["terminal:carriage-feed"] = function(view) view:input("\x0D") end,
  ["terminal:shift-out"] = function(view) view:input("\x0E") end,
  ["terminal:shift-in"] = function(view) view:input("\x0F") end,
  ["terminal:data-line-escape"] = function(view) view:input("\x10") end,
  ["terminal:history"] = function(view) view:input("\x12") end,
  ["terminal:transpose"] = function(view) view:input("\x14") end,
  ["terminal:negative-acknowledge"] = function(view) view:input("\x15") end,
  ["terminal:synchronous-idel"] = function(view) view:input("\x16") end,
  ["terminal:end-of-transmission-block"] = function(view) view:input("\x17") end,
  ["terminal:end-of-medium"] = function(view) view:input("\x19") end,
  ["terminal:file-separator"] = function(view) view:input("\x1C") end,
  ["terminal:group-separator"] = function(view) view:input("\x1D") end,
  ["terminal:clear"] = function(view) view.terminal:clear() view:input(view.options.newline) end,
  ["terminal:close-tab"] = function(view) view:close() end
});
if system.get_primary_selection then -- check for master vs. 2.1.7
  command.add(active_terminal_predicate, {
    ["terminal:primary-paste"] = function(view)
      if view.terminal:paste_mode() == "bracketed" then
        view:input("\x1B[200~" .. system.get_primary_selection() .. "\x1B[201~")
      else
        view:input(system.get_primary_selection())
      end
    end
  })
end

command.add(function()
  return core.active_view and core.active_view:is(TerminalView) and core.active_view.selection and #core.active_view.selection == 4
end, {
  ["terminal:copy"] = function()
    local selection = core.active_view:sorted_selection()
    system.set_clipboard(core.active_view:get_text(selection[2], selection[1], selection[4], selection[3]))
  end
})

---Create or reveal the shared terminal drawer and give it keyboard focus.
local function open_drawer()
  local view = core.terminal_view
  if not view then
    view = TerminalView()
    core.terminal_view = view
    core.terminal_view_node = core.root_view:get_active_node_default():split("down", view, { y = true }, true)
  elseif view.size.y == 0 then
    core.terminal_view_node = core.root_view.root_node:get_node_for_view(view)
    core.terminal_view_node:resize("y", core.terminal_view_closed or view.options.drawer_height)
    core.terminal_view_closed = nil
  end
  if core.active_view ~= view then core.set_active_view(view) end
end

---Return keyboard focus to the previous view if it is still displayed.
local function leave_drawer()
  local previous = core.last_active_view
  local node = previous and core.root_view.root_node:get_node_for_view(previous)
  if not node or node.active_view ~= previous or previous.size.y <= 0 then
    previous = core.root_view:get_primary_node().active_view
  end
  core.set_active_view(previous)
end

---Hide or reopen the shared drawer, keeping its process and height.
local function toggle_drawer()
  local view = core.terminal_view
  if not view or view.size.y == 0 then return open_drawer() end
  core.terminal_view_closed = view.size.y
  core.terminal_view_node = core.root_view.root_node:get_node_for_view(view)
  core.terminal_view_node:resize("y", 0)
  if core.active_view == view then leave_drawer() end
end

---Switch focus between the drawer and the editor without hiding the drawer.
local function swap_drawer()
  if core.terminal_view and core.active_view == core.terminal_view then
    leave_drawer()
  else
    open_drawer()
  end
end

command.add(nil, {
  ["terminal:open-drawer"] = open_drawer,
  ["terminal:toggle-drawer"] = toggle_drawer,
  ["terminal:swap-drawer"] = swap_drawer,
  ["terminal:execute"] = function(text)
    local function send_command(text)
      if not core.terminal_view then open_drawer() end
      local target_view = core.active_view:is(TerminalView) and core.active_view or core.terminal_view
      target_view:input(text .. target_view.options.newline)
    end
    if not text then
      core.command_view:enter("Execute Command", { submit = send_command })
    else
      send_command(text)
    end
  end,
  ["terminal:open-tab"] = function()
    local tv = TerminalView(config.plugins.terminal)
    core.root_view:get_active_node_default():add_view(tv)
  end
})
command.add(function() return core.terminal_view and core.active_view ~= core.terminal_view end, {
  ["terminal:focus"] = open_drawer
})

core.status_view:add_item({
  predicate = function()
    return core.active_view:is(TerminalView) and core.active_view.terminal
  end,
  name = "terminal:info",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local dv = core.active_view
    local x, y = dv.terminal:size()
    return {
      style.text, style.font, (dv.terminal:name() or config.plugins.terminal.shell),
      style.dim, style.font, core.status_view.separator2,
      style.text, style.font, x .. "x" .. y
    }
  end
})

-- add in the terminal metacommands not related to actually sending things to the temrinal first
keymap.add({
  ["ctrl+shift+`"] = "terminal:open-tab",
  ["alt+t"] = "terminal:toggle-drawer",
  ["shift+alt+t"] = "terminal:open-drawer"
})
local keys = {
  ["return"] = "terminal:return",
  ["ctrl+return"] = "terminal:return",
  ["shift+return"] = "terminal:return",
  ["keypad enter"] = "terminal:return",
  ["ctrl+keypad enter"] = "terminal:return",
  ["shift+keypad enter"] = "terminal:return",
  ["enter"] = "terminal:enter",
  ["backspace"] = "terminal:backspace",
  ["shift+backspace"] = "terminal:backspace",
  ["delete"] = "terminal:delete",
  ["ctrl+backspace"] = "terminal:ctrl-backspace",
  ["alt+backspace"] = "terminal:alt-backspace",
  ["ctrl+shift+c"] = "terminal:copy",
  ["ctrl+shift+v"] = "terminal:paste",
  ["mclick"] = "terminal:primary-paste",
  ["wheel"] = "terminal:scroll",
  ["tab"] = "terminal:tab",
  ["pageup"] = "terminal:page-up",
  ["pagedown"] = "terminal:page-down",
  ["shift+pageup"] = "terminal:scroll-up",
  ["shift+pagedown"] = "terminal:scroll-down",
  ["shift+end"] = "terminal:scroll-to-end",
  ["shift+home"] = "terminal:scroll-to-top",
  ["up"] = "terminal:up",
  ["down"] = "terminal:down",
  ["left"] = "terminal:left",
  ["right"] = "terminal:right",
  ["ctrl+up"] = "terminal:jump-up",
  ["ctrl+down"] = "terminal:jump-down",
  ["ctrl+left"] = "terminal:jump-left",
  ["ctrl+right"] = "terminal:jump-right",
  ["alt+left"] = "terminal:jump-left",
  ["alt+right"] = "terminal:jump-right",
  ["home"] = "terminal:home",
  ["end"] = "terminal:end",
  ["f1"] = "terminal:f1",
  ["f2"] = "terminal:f2",
  ["f3"] = "terminal:f3",
  ["f4"] = "terminal:f4",
  ["f5"] = "terminal:f5",
  ["f6"] = "terminal:f6",
  ["f7"] = "terminal:f7",
  ["f8"] = "terminal:f8",
  ["f9"] = "terminal:f9",
  ["f10"] = "terminal:f10",
  ["f11"] = "terminal:f11",
  ["f12"] = "terminal:f11",
  ["escape"] = "terminal:escape",
  ["ctrl+a"] = "terminal:start-of-heading",
  ["ctrl+b"] = "terminal:start-of-text",
  ["ctrl+c"] = "terminal:break",
  ["ctrl+d"] = "terminal:eof",
  ["ctrl+e"] = "terminal:enquiry",
  ["ctrl+f"] = "terminal:acknowledge",
  ["ctrl+g"] = "terminal:bell",
  ["ctrl+h"] = "terminal:backspace",
  ["ctrl+i"] = "terminal:tab",
  ["ctrl+j"] = "terminal:return",
  ["ctrl+k"] = "terminal:vertical-tab",
  ["ctrl+l"] = "terminal:redraw",
  ["ctrl+m"] = "terminal:carriage-feed",
  ["ctrl+n"] = "terminal:shift-out",
  ["ctrl+o"] = "terminal:shift-in",
  ["ctrl+p"] = "terminal:data-line-escape",
  ["ctrl+q"] = "terminal:stop",
  ["ctrl+r"] = "terminal:history",
  ["ctrl+s"] = "terminal:start",
  ["ctrl+t"] = "terminal:transpose",
  ["ctrl+u"] = "terminal:negative-acknowledge",
  ["ctrl+v"] = "terminal:synchronous-idel",
  ["ctrl+w"] = "terminal:end-of-transmission-block",
  ["ctrl+x"] = "terminal:cancel",
  ["ctrl+y"] = "terminal:end-of-medium",
  ["ctrl+z"] = "terminal:suspend",
  ["ctrl+["] = "terminal:escape",
  ["ctrl+\\"] = "terminal:file-separator",
  ["ctrl+]"] = "terminal:group-separator"
}
local non_omitted_keys = {}
for k,v in pairs(keys) do if config.plugins.terminal.omit_escapes == nil or not k:find(config.plugins.terminal.omit_escapes) then non_omitted_keys[k] = v end end
keymap.add(non_omitted_keys)

if config.plugins.terminal.inversion_key then
  local settings = {}
  local commands = {}
  for i = string.byte('a'), string.byte('z') do
    local keymaps = {}
    for i,v in ipairs(keymap.map["ctrl+" .. string.char(i)] or {}) do
      if not v:find("terminal") then
        table.insert(keymaps, "terminal:" .. v)
        commands["terminal:" .. v] = function(...) command.perform(v, ...) end
      end
    end
    if #keymaps > 0 and not keymap.map["ctrl+" .. config.plugins.terminal.inversion_key .. "+" .. string.char(i)] then
      settings["ctrl+" .. config.plugins.terminal.inversion_key .. "+" .. string.char(i)] = keymaps
    end
  end
  command.add(active_terminal_predicate, commands)
  keymap.add(settings)
end

return {
  class = TerminalView,

  ---Create an unattached, interactive task terminal owned by the caller.
  ---@return plugins.terminal.view
  new_task_view = function()
    assert(terminal_native.inherit_screen, "Update the Terminal native library to use task terminals")
    local view = TerminalView({ shell = "DUMMY", arguments = {} })
    view.task_view = true
    return view
  end
}
