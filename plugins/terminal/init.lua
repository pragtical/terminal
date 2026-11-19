-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local common = require "core.common"
local View = require "core.view"
local keymap = require "core.keymap"
local StatusView = require "core.statusview"

local cellgraphics = require "plugins.terminal.cellgraphics"
local keyboard = require "plugins.terminal.keyboard"
local modifiers = require("core.modkeys-" .. (PLATFORM == "Mac OS X" and "macos" or "generic"))
local palette = require "plugins.terminal.palette"
local terminal_native = require "plugins.terminal.libterminal"

-- Several views can share a custom font. Apply each UI scale change to it once.
local font_scales = setmetatable({}, { __mode = "k" })
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
  -- Keep completed agent tabs available for reviewing their output.
  agent_close_on_exit = "never",
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
  blink_caret = true,
  draw_cell_graphics = true,
  -- padding around the edges of the terminal
  padding = { x = 0, y = 0 },
  -- show bold text in bright colors
  bold_text_in_bright_colors = true,
  -- set to 0 to disable color adjustments based on background
  minimum_contrast_ratio = 0,
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
    description = "Use a separate terminal font. When disabled, follow the editor code font.",
    path = "use_custom_font", type = "TOGGLE",
    default = false
  },
  {
    label = "Font",
    description = "Monospace font to use when Use Custom Font is enabled.",
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
      local terminal = config.plugins.terminal
      font_scales[terminal.font] = SCALE
      terminal.bold_font = terminal.font:copy(terminal.font:get_size(), { bold = true })
    end
  },
  {
    label = "Caret Blinking",
    description = "Allow applications to blink the idle caret using the editor's cursor blinking settings.",
    path = "blink_caret", type = "TOGGLE"
  },
  {
    label = "Draw Box and Block Symbols",
    description = "Draw borders and blocks aligned to the terminal grid. Turn off to use the terminal font for these symbols.",
    path = "draw_cell_graphics", type = "TOGGLE"
  },
  {
    label = "Show Bold Text In Bright Colors",
    description = "Display emboldened text with brighter colors.",
    path = "bold_text_in_bright_colors", type = "TOGGLE",
    default = true
  },
  {
    label = "Minimum Contrast Ratio",
    description = "Increase text contrast against its background. Zero preserves application colors.",
    path = "minimum_contrast_ratio", type = "NUMBER",
    default = 0
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
    description = "Extra arguments to pass to the shell on startup.",
    path = "arguments", type = "LIST_STRINGS"
  },
  {
    label = "Agent Close on Exit",
    description = "Choose when Spawn Agent closes its tab after the command exits.",
    path = "agent_close_on_exit", type = "selection",
    values = {
      { "Never", "never" }, { "Only on Successful Exit", "clean_exit" }, { "Always", "always" }
    }
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
font_scales[config.plugins.terminal.font] = SCALE

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

local function pack_rgb(color)
  return color[1] * 65536 + color[2] * 256 + color[3]
end

---Refresh indexed colors and discard contrast adjustments from the previous palette.
function TerminalView:update_colors()
  local colors = palette.get(style)
  local ratio = config.plugins.terminal.minimum_contrast_ratio
  local bright = self.options.bold_text_in_bright_colors
  if self.colors ~= colors or self.contrast_ratio ~= ratio or self.bright_colors ~= bright then
    self.colors, self.contrast_ratio, self.bright_colors = colors, ratio, bright
    self.run_styles = setmetatable({}, { __mode = "v" })
    if self.terminal then self.terminal:colors(pack_rgb(style.text), pack_rgb(style.background)) end
    core.redraw = true
  end
end

function TerminalView:get_name()
  if self.agent_command then
    local title = self.terminal and self.terminal:name() or self.agent_command
    return self.exit_status and string.format("%s [exit %d]", title, self.exit_status) or title
  end
  if self.task_view then return "Task Terminal" end
  return (self.modified_since_last_focus and "* " or "") .. (self.terminal and self.terminal:name() or "Terminal")
end
function TerminalView:supports_text_input() return true end

function TerminalView:new(options)
  TerminalView.super.new(self)
  self.font_override = options and options.font
  self.bold_font_override = options and options.bold_font
  options = common.merge(config.plugins.terminal, options)
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


local function native_environment(options, overrides)
  local capabilities = { TERM = options.term, COLORTERM = "truecolor" }
  if PLATFORM ~= "Windows" then
    return common.merge(common.merge(capabilities, options.environment), overrides)
  end
  local inherited, entries = {}, {}
  for _, variables in ipairs { terminal_native.getenv(), capabilities, options.environment, overrides } do
    for key, value in pairs(variables) do inherited[key:upper()] = key .. "=" .. value end
  end
  for _, entry in pairs(inherited) do entries[#entries + 1] = entry end
  table.sort(entries, function(a, b) return a:upper() < b:upper() end)
  return table.concat(entries, "\0") .. "\0\0"
end

local function new_process(view, executable, arguments, options)
  local terminal = terminal_native.new(view.columns or 80, view.lines or 24,
    view.options.scrollback_limit, view.options.term, executable, arguments,
    native_environment(view.options, options.environment), view.options.debug, options.cwd)
  terminal:colors(pack_rgb(style.text), pack_rgb(style.background))
  return terminal
end

---Build the configured shell's argv for an interactive, single-command session.
local function agent_argv(options, text)
  local shell = (options.shell:match("[^/\\]+$") or options.shell):lower():gsub("%.exe$", "")
  local argv = { options.shell, table.unpack(options.arguments) }
  local flags = { "-i", "-c" }
  if shell == "cmd" then
    flags = { "/d", "/s", "/c" }
  elseif shell == "pwsh" or shell == "powershell" then
    flags = { "-Command" }
  end
  for _, flag in ipairs(flags) do table.insert(argv, flag) end
  table.insert(argv, text)
  return argv
end

function TerminalView:spawn()
  if self.agent_command then
    local function on_exit(status)
      if self.closed then return end
      self.exit_status = status
      core.redraw = true
      local policy = self.options.agent_close_on_exit
      if policy == "always" or (policy == "clean_exit" and status == 0) then
        local focused = core.active_view
        self:close()
        if focused ~= self and focused ~= core.active_view then core.set_active_view(focused) end
      end
    end
    local ok, err = core.try(self.start_task, self, agent_argv(self.options, self.agent_command),
      { cwd = core.root_project().path, on_exit = on_exit })
    if not ok then
      self.terminal = new_process(self, "DUMMY", {}, {})
      self.terminal:input(tostring(err))
      on_exit(127)
    end
    return
  end
  local ok, child = core.try(new_process, self, self.options.shell, self.options.arguments,
    { cwd = core.root_project().path })
  if not ok then
    self:close()
    return
  end
  self.terminal = child
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
        -- Interactive programs time out terminal capability and color queries.
        coroutine.yield(1 / 60)
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


-- Settings can replace the editor font group, while zoom resizes it in place.
-- Refresh the faces and cell metrics for either kind of change.
local function update_font(self)
  local terminal = config.plugins.terminal
  local font, bold = self.font_override, self.bold_font_override
  if not font and terminal.use_custom_font then
    font, bold = terminal.font, bold or terminal.bold_font
  end
  font = font or style.code_font
  if font ~= style.code_font and font_scales[font] ~= SCALE then
    local old_scale = font_scales[font]
    if old_scale then font:set_size(font:get_size() * SCALE / old_scale) end
    font_scales[font] = SCALE
  end
  local font_size = font:get_size()
  if self.options.font == font and self.last_font_size == font_size and self.last_bold_font == bold then
    return false
  end
  self.options.font, self.last_font_size, self.last_bold_font = font, font_size, bold
  if not bold then
    bold = font:copy(font_size, { bold = true })
  elseif bold:get_size() ~= font_size then
    bold = bold:copy(font_size)
  end
  self.options.bold_font = bold
  self.italic_font = font:copy(font_size, { italic = true })
  self.bold_italic_font = font:copy(font_size, { bold = true, italic = true })
  self.cell_width = math.max(1, math.ceil(font:get_width("M")))
  self.cell_height = math.max(1, math.ceil(font:get_height()))
  self.integral_fonts = {}
  for _, face in ipairs { font, bold, self.italic_font, self.bold_italic_font } do
    self.integral_fonts[face] = face:get_width("M") == self.cell_width
  end
  return true
end

local function cursor_blinks(mode)
  return mode == "blinking" and config.plugins.terminal.blink_caret and not config.disable_blink
end

local function restart_cursor_blink(view)
  view.cursor_blink_start = system.get_time()
  view.cursor_blink_visible = true
  core.redraw = true
end

function TerminalView:update()
  if self.closed then return end
  TerminalView.super.update(self)
  if self.task_view and self.size.y <= 0 then return end
  self:update_colors()
  local font_changed = update_font(self)
  if config.plugins.terminal.draw_cell_graphics then
    if font_changed or not self.cell_shapes then
      self.cell_shapes = cellgraphics.build(self.cell_width, self.cell_height)
      core.redraw = true
    end
  elseif self.cell_shapes then
    self.cell_shapes = nil
    core.redraw = true
  end
  if self.size.x > 0 and self.size.y > 0 and (font_changed or not self.terminal or self.last_size.x ~= self.size.x or self.last_size.y ~= self.size.y) then
    self.columns = math.max(math.floor((self.size.x - self.options.padding.x*2) / self.cell_width), 1)
    self.lines = math.max(math.floor((self.size.y - self.options.padding.y*2) / self.cell_height), 1)
    self.last_size.x, self.last_size.y = self.size.x, self.size.y
    if not self.terminal then
      self:spawn()
    else
      self.terminal:size(self.columns, self.lines)
    end
  end
  if self.terminal then
    if not self.task_view then core.redraw = self:shift_selection_update() or core.redraw end
    if self.sync_deadline and system.get_time() >= self.sync_deadline then
      self.terminal:screen_state(false)
      self.sync_deadline = nil
      core.redraw = true
    end
    if self.deferred_input then
      self:input(self.deferred_input)
      self.deferred_input = nil
    end
    if self.task_view or self.terminal:exited() == false then
      self.cursor = "ibeam"
      if self.terminal:mouse_tracking_mode()
         or self.v_scrollbar.hovering.track then
        self.cursor = "arrow"
      end
      if (core.active_view == self and not self.focused) or (core.active_view ~= self and self.focused) then
        self.focused = core.active_view == self
        self.modified_since_last_focus = false
        self.terminal:focused(self.focused)
        if self.focused then restart_cursor_blink(self) end
      end
      local scrollback, total_scrollback = self.terminal:scrollback()
      local _, _, mode = self.terminal:cursor()
      if self.focused and scrollback == 0 and not self.exit_status and cursor_blinks(mode) then
        local period = config.blink_period
        local phase = (system.get_time() - self.cursor_blink_start) % period
        local visible = phase < period / 2
        if self.cursor_blink_visible ~= visible then
          self.cursor_blink_visible = visible
          core.redraw = true
        end
        if core.request_update and system.window_has_focus(core.window) then
          core.request_update(period / 2 - phase % (period / 2))
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
      -- 0 should be if we're at max scrollback. 1 should be if we're at 0 scrollback.
      self.v_scrollbar:set_size(self.position.x, self.position.y, self.size.x, self.size.y, self:get_scrollable_size())
      self.v_scrollbar:set_percent(total_scrollback > 0 and 1 - scrollback / total_scrollback or 1)
      self.v_scrollbar:update()
    else
      core.add_thread(function()
        self:close()
      end)
    end
  end
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


-- Decode each native style once per theme. Apply faint after contrast adjustment.
local function run_style(view, key)
  local cached = view.run_styles[key]
  if cached then return cached end
  local packed = math.tointeger(key)
  local bg, decorations = view:convert_color(bit.band(packed, 0xFFFFFFFF), "background")
  -- The view already painted the default background. Repainting it for an
  -- explicit RGB match can erase box-drawing strokes that cross cell edges.
  local base = style.background
  if bg ~= base and bg[1] == base[1] and bg[2] == base[2] and bg[3] == base[3]
    and (bg[4] or 255) == (base[4] or 255) then bg = base end
  local fg, flags = view:convert_color(bit.rshift(packed, 32), "foreground", view.bright_colors)
  if view.contrast_ratio > 0 then fg = ensureContrastRatio(bg, fg, view.contrast_ratio) end
  if bit.band(flags, 64) ~= 0 then
    fg = { math.floor((fg[1]+bg[1])/2), math.floor((fg[2]+bg[2])/2), math.floor((fg[3]+bg[3])/2), fg[4] or 255 }
  end
  if bit.band(decorations, 8) ~= 0 then fg = bg end
  cached = { strike = bit.band(decorations, 16) ~= 0, background = bg, foreground = fg, bold = bit.band(flags, 8) ~= 0,
    italic = bit.band(flags, 16) ~= 0, underline = bit.band(flags, 32) ~= 0 }
  view.run_styles[key] = cached
  return cached
end

-- Native lines batch adjacent cells with the same style. A wide or composed
-- glyph has its own run whose width is measured in terminal cells.
local function line_run(line, i)
  local text = line[i]
  if text:sub(-1) == "\n" then text = text:sub(1, -2) end
  local cluster = line.widths and line.widths[i]
  return text, cluster or text:ulen(), cluster
end

local function draw_glyphs(view, span, y)
  local face, text, x, fg = span.face, span.text, span.x, span.fg
  if text:find("%S") then
    if span.cluster or (view.integral_fonts[face] and not text:find("[\128-\255]")) then
      renderer.draw_text(face, text, x, y, fg)
    else
      local gx = x
      for glyph in text:gmatch("[^\128-\191][\128-\191]*") do
        local shape = view.cell_shapes and #glyph > 1 and view.cell_shapes[glyph]
        if shape then
          for _, rect in ipairs(shape) do
            renderer.draw_rect(gx + rect[1], y + rect[2], rect[3], rect[4], fg)
          end
        elseif glyph ~= " " then
          renderer.draw_text(face, glyph, gx, y, fg)
        end
        gx = gx + view.cell_width
      end
    end
  end
  if span.style.strike then renderer.draw_rect(x, y + math.floor(view.cell_height / 2), span.width, 1, fg) end
  if span.style.underline then renderer.draw_rect(x, y + view.cell_height - 2, span.width, 1, fg) end
end

function TerminalView:draw()
  self:draw_background(style.background)
  if not self.terminal then return end
  local revision, synchronized = self.terminal:screen_state()
  if synchronized then
    if not self.sync_deadline then
      self.sync_deadline = system.get_time() + 1
      if core.request_update then core.request_update(1) end
    end
  else
    self.sync_deadline = nil
    if revision ~= self.screen_revision or self.screen_terminal ~= self.terminal then
      self.screen_rows = self.terminal:lines()
      self.screen_cursor = { self.terminal:cursor() }
      self.screen_scrollback = self.terminal:scrollback()
      self.screen_revision, self.screen_terminal = revision, self.terminal
    end
  end
  if not self.screen_rows then return end
  local cursor_x, cursor_y, mode, shape = table.unpack(self.screen_cursor)
  local scrollback = self.screen_scrollback
  local show_cursor = not self.exit_status and mode ~= "hidden" and core.active_view == self and scrollback == 0
  if cursor_blinks(mode) then
    show_cursor = show_cursor and self.cursor_blink_visible ~= false
  end
  local origin = self.position.x + self.options.padding.x
  local y = self.position.y + self.options.padding.y
  local selection = self:sorted_selection()
  local spans = self.row_spans or {}
  self.row_spans = spans
  local max_spans = 0
  for row, line in ipairs(self.screen_rows) do
    local count = 0
    local offset, first, last = 0, 0, 0
    local index = row - 1 - scrollback
    if selection and selection[2] <= index and index <= selection[4] then
      first = index == selection[2] and selection[1] or 0
      last = index == selection[4] and selection[3] or self.columns
    end
    local caret = show_cursor and row - 1 == cursor_y and cursor_x or -1
    for i = 1, #line, 2 do
      local run = run_style(self, line[i])
      local face = run.bold and (run.italic and self.bold_italic_font or self.options.bold_font)
        or (run.italic and self.italic_font or self.options.font)
      local text, cells, cluster = line_run(line, i+1)
      local col, stop = offset, offset + cells
      while col < stop do
        local edge = stop
        if not cluster then
          if first > col then edge = math.min(edge, first) end
          if last > col then edge = math.min(edge, last) end
          if caret > col then edge = math.min(edge, caret)
          elseif caret == col then edge = math.min(edge, caret + 1) end
        end
        local bg, fg = run.background, run.foreground
        if shape == "block" and caret >= col and caret < edge then bg, fg = style.caret, style.background
        elseif first < edge and last > col then bg, fg = fg, bg end
        local part = text
        if col ~= offset or edge ~= stop then part = text:usub(col-offset+1, edge-offset) end
        count = count + 1
        local span = spans[count] or {}
        spans[count] = span
        span.x, span.width = origin + col*self.cell_width, (edge-col)*self.cell_width
        span.face, span.text, span.cluster, span.style, span.fg = face, part, cluster, run, fg
        if bg ~= style.background then renderer.draw_rect(span.x, y, span.width, self.cell_height, bg) end
        col = edge
      end
      offset = stop
    end
    -- Paint the whole row's backgrounds before glyphs that overhang adjacent cells.
    for i = 1, count do draw_glyphs(self, spans[i], y) end
    max_spans = math.max(max_spans, count)
    if caret >= 0 then
      local x = origin + caret*self.cell_width
      if shape == "bar" then renderer.draw_rect(x, y, 2, self.cell_height, style.caret)
      elseif shape == "underline" then renderer.draw_rect(x, y+self.cell_height-2, self.cell_width, 2, style.caret)
      elseif caret >= offset then renderer.draw_rect(x, y, self.cell_width, self.cell_height, style.caret) end
    end
    y = y + self.cell_height
  end
  for i = #spans, max_spans + 1, -1 do spans[i] = nil end
  TerminalView.super.draw_scrollbar(self)
end

function TerminalView:convert_coordinates(x, y)
  local w = self.cell_width or math.max(1, math.ceil(self.options.font:get_width("M")))
  local col_exact = math.floor((x - self.position.x - self.options.padding.x) / w)
  local col_approx = common.round((x - self.position.x - self.options.padding.x) / w)
  local row = math.floor((y - self.position.y - self.options.padding.y) / (self.cell_height or self.options.font:get_height()))
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
  if keymap.modkeys.shift then button_code = button_code + 4 end
  if keymap.modkeys.alt then button_code = button_code + 8 end
  if keymap.modkeys.ctrl then button_code = button_code + 16 end
  col = common.clamp(col, 0, self.columns - 1)
  row = common.clamp(row, 0, self.lines - 1)
  if encoding == "sgr" then
    self.terminal:input("\x1B[<" .. button_code .. ";" .. (col + 1) .. ";" .. (row + 1) .. suffix)
  elseif col < 223 and row < 223 then
    self.terminal:input("\x1B[M" .. string.char(32 + button_code) .. string.char(32 + col + 1) .. string.char(32 + row + 1))
  end
end

---Report a vertical wheel step if the running application requested wheel input.
local function report_wheel(view, delta, x, y)
  local override = config.plugins.terminal.inversion_key
  if view.exit_status or (view.task_view and not view.task) or keymap.modkeys[override] then
    return false
  end
  local mode, encoding = view:get_mouse_tracking()
  if not mode or mode == "x10" then return false end
  local col, row = view:convert_coordinates(x, y)
  view:send_mouse_event(delta > 0 and 64 or 65, col, row, "M", encoding)
  return true
end

---Offer Ctrl+wheel to mouse-tracking applications before editor zoom bindings.
---@param delta number Vertical wheel movement
---@return boolean? consumed
function TerminalView:on_mouse_wheel(delta)
  if delta ~= 0 and keymap.modkeys.ctrl then
    local mouse = core.root_view.mouse
    if self:hit_test(mouse.x, mouse.y) then
      return report_wheel(self, delta, mouse.x, mouse.y)
    end
  end
end

function TerminalView:get_word_boundaries(col, row)
  local index = row - self.terminal:scrollback()
  local line = self.terminal:lines(index, index)[1]
  if not line then return col, index, col + 1, index end
  local start, offset = 0, 0
  for i = 2, #line, 2 do
    local text, cells, cluster = line_run(line, i)
    if cluster then
      offset = offset + cells
    else
      for glyph in text:gmatch("[^\128-\191][\128-\191]*") do
        if glyph:match("%s") then
          if col == offset then return col, index, col + 1, index end
          if col < offset then return start, index, offset, index end
          start = offset + 1
        end
        offset = offset + 1
      end
    end
  end
  if col >= offset then return col, index, col + 1, index end
  return start, index, offset, index
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
    self:send_mouse_event(mouse_encoding == "sgr" and button_code or 3, col, row, "m", mouse_encoding)
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
  if self.closed or (self.task_view and not self.task) then return false end
  if self.terminal then
    self.terminal:input(text)
    if core.active_view == self then restart_cursor_blink(self) end
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
  local result = {}
  for number, line in ipairs(self.terminal:lines(line1, line2)) do
    local row = line1 + number - 1
    local first = row == line1 and col1 or 0
    local last = row == line2 and col2 or math.huge
    local offset = 0
    for i = 2, #line, 2 do
      local text, cells, cluster = line_run(line, i)
      local start, stop = math.max(0, first-offset), math.min(cells, last-offset)
      if stop > start then
        result[#result+1] = cluster and text or text:usub(start+1, stop)
      end
      offset = offset + cells
    end
    if last > offset and line[#line]:sub(-1) == "\n" then result[#result+1] = "\n" end
  end
  return table.concat(result)
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
    amount = amount or 1
    if report_wheel(view, amount, view.mouse_x or view.position.x, view.mouse_y or view.position.y) then
      return
    end
    view.accumulated_scroll = (view.accumulated_scroll or 0) + amount
    if math.abs(view.accumulated_scroll) >= 1 then
      local delta = math.floor(view.accumulated_scroll + 0.5)
      view.terminal:scrollback(view.terminal:scrollback() + delta)
      view.accumulated_scroll = view.accumulated_scroll - delta
    end
  end
})


local active_terminal_predicate = function(...)
  local view = core.active_view
  return view and view:extends(TerminalView) and view.terminal, view, ...
end

---Discard selections and gestures referring to erased screen contents.
local function clear_selection(view)
  view.selection, view.pressing, view.word_selecting, view.row_selecting = nil, nil, nil, nil
  view.scrolling_offscreen = nil
  core.redraw = true
end

command.add(active_terminal_predicate, {
  ["terminal:backspace"] = function(view) view:input(view.options.backspace) end,
  ["terminal:ctrl-backspace"] = function(view) view:input(view.options.backspace == "\b" and "\x7F" or "\b") end,
  ["terminal:alt-backspace"] = function(view) view:input("\x1B" .. view.options.backspace) end,
  ["terminal:insert"] = function(view) view:input("\x1B[2~") end,
  ["terminal:delete"] = function(view) view:input(view.options.delete) end,
  ["terminal:return"] = function(view) view:input(view.options.newline) end,
  ["terminal:enter"] = function(view) view:input(view.terminal:keypad_keys_mode() == "application" and "\x1BOM" or view.options.newline) end,
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
  ["terminal:clear"] = function(view)
    view.terminal:clear()
    view.screen_rows = nil
    clear_selection(view)
  end,
  ["terminal:reset"] = function(view)
    view.terminal:reset()
    view.mouse_buttons = {}
    view.accumulated_scroll, view.sync_deadline = nil, nil
    clear_selection(view)
  end,
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
  if view and view.terminal and view.terminal:exited() ~= false then
    view:close()
    view = nil
  end
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
  return view
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

---Open a shell or a dedicated agent tab in the current editor pane.
local function open_tab(agent_command)
  local view = TerminalView()
  view.agent_command = agent_command
  view.task_view = agent_command ~= nil
  local node = core.root_view:get_active_node_default()
  node:add_view(view)
  node:update_layout()
  view:update()
  return view
end

---Use a supplied command or prompt for it before creating a terminal.
local function with_command(label, text, run)
  local function submit(value)
    if type(value) == "string" and value:find("%S") then run(value) end
  end
  if text == nil then
    core.command_view:enter(label, { submit = submit })
  else
    submit(text)
  end
end

local function send_command(view, text)
  view:input(text .. view.options.newline)
end

command.add(nil, {
  ["terminal:open-drawer"] = open_drawer,
  ["terminal:toggle-drawer"] = toggle_drawer,
  ["terminal:swap-drawer"] = swap_drawer,
  ["terminal:execute"] = function(text)
    with_command("Execute Command", text, function(value)
      if not core.terminal_view then open_drawer() end
      local target_view = core.active_view:is(TerminalView) and core.active_view or core.terminal_view
      send_command(target_view, value)
    end)
  end,
  ["terminal:open-tab"] = function() open_tab() end,
  ["terminal:run-command-in-tab"] = function(text)
    with_command("Run Command in Tab", text, function(value) send_command(open_tab(), value) end)
  end,
  ["terminal:run-command-in-drawer"] = function(text)
    with_command("Run Command in Drawer", text, function(value) send_command(open_drawer(), value) end)
  end,
  ["terminal:spawn-agent"] = function(text)
    with_command("Spawn Agent", text, open_tab)
  end,
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
  ["keypad enter"] = "terminal:enter",
  ["enter"] = "terminal:enter",
  ["backspace"] = "terminal:backspace",
  ["shift+backspace"] = "terminal:backspace",
  ["delete"] = "terminal:delete",
  ["insert"] = "terminal:insert",
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
  ["f12"] = "terminal:f12",
  ["escape"] = "terminal:escape",
  ["ctrl+a"] = "terminal:start-of-heading",
  ["ctrl+b"] = "terminal:start-of-text",
  ["ctrl+c"] = "terminal:break",
  ["ctrl+d"] = "terminal:eof",
  ["ctrl+e"] = "terminal:enquiry",
  ["ctrl+f"] = "terminal:acknowledge",
  ["ctrl+g"] = "terminal:bell",
  ["ctrl+i"] = "terminal:tab",
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
      if type(v) == "string" and not v:find("terminal") then
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

-- Keep editor tab navigation and the outer command palette accessible from a PTY.
local editor_keys = { ["ctrl+tab"] = true, ["ctrl+shift+tab"] = true, ["ctrl+shift+p"] = true }
local previous_key_pressed = keymap.on_key_pressed
function keymap.on_key_pressed(key, ...)
  local active, view = active_terminal_predicate()
  if not active or modifiers.map[key] or key:find("click", 1, true) or key:find("wheel", 1, true) then
    return previous_key_pressed(key, ...)
  end
  local mods = keymap.modkeys
  local parts = {}
  for _, name in ipairs(modifiers.keys) do
    if mods[name] then parts[#parts + 1] = name end
  end
  parts[#parts + 1] = key
  local stroke = table.concat(parts, "+")
  local omitted = config.plugins.terminal.omit_escapes
  if mods.cmd or mods.super or editor_keys[stroke] or (omitted and stroke:find(omitted)) then
    return previous_key_pressed(key, ...)
  end
  local action
  local bindings = keymap.map[stroke]
  for _, binding in ipairs(bindings or {}) do
    if type(binding) == "string" and binding:match("^terminal:") then
      action = binding
      break
    end
  end
  local inversion = config.plugins.terminal.inversion_key
  if not action and bindings and inversion and mods[inversion] and mods.ctrl
    and #parts == 3 and key:match("^[a-z]$") then
    return previous_key_pressed(key, ...)
  end
  local printable = #key == 1 or key == "space"
  local text_input = printable and (mods.altgr or not (mods.ctrl or mods.alt or mods.option))
  local bytes = not action and not text_input and keyboard.encode(key, mods)
  if not action and not text_input and not bytes then return previous_key_pressed(key, ...) end
  if core.root_view.on_key_pressed and core.root_view:on_key_pressed(stroke, ...) then return true end
  if action then command.perform(action, ...)
  elseif bytes then view:input(bytes)
  else return false end -- SDL supplies layout-aware text and IME composition.
  return true
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
