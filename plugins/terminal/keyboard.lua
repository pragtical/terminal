local keyboard = {}

local cursor_keys = {
  up = "A", down = "B", right = "C", left = "D", home = "H", ["end"] = "F",
  f1 = "P", f2 = "Q", f4 = "S"
}
local numbered_keys = {
  insert = 2, delete = 3, pageup = 5, pagedown = 6,
  f3 = 13, f5 = 15, f6 = 17, f7 = 18, f8 = 19, f9 = 20, f10 = 21,
  f11 = 23, f12 = 24
}
local controls = {
  space = 0, ["2"] = 0, ["3"] = 27, ["4"] = 28, ["5"] = 29,
  ["6"] = 30, ["7"] = 31, ["8"] = 127, ["/"] = 31, ["?"] = 127
}
local special = { tab = 9, escape = 27, ["return"] = 13, ["keypad enter"] = 13 }

---Encode modified keys for the PTY. Plain printable input comes from SDL textinput.
---@param key string Pragtical key name
---@param mods table<string,boolean> Currently pressed modifiers
---@return string? bytes
function keyboard.encode(key, mods)
  local alt = mods.alt or mods.option
  local modifier = 1 + (mods.shift and 1 or 0) + (alt and 2 or 0) + (mods.ctrl and 4 or 0)
  if modifier == 1 then return end
  if cursor_keys[key] then return ("\27[1;%d%s"):format(modifier, cursor_keys[key]) end
  if numbered_keys[key] then return ("\27[%d;%d~"):format(numbered_keys[key], modifier) end
  local prefix = alt and "\27" or ""
  if special[key] then
    if key == "tab" and modifier == 2 then return "\27[Z" end
    if modifier == 3 then return prefix .. string.char(special[key]) end
    return ("\27[27;%d;%d~"):format(modifier, special[key])
  end
  if #key ~= 1 and key ~= "space" then return end
  if mods.ctrl then
    local code = controls[key]
    if not code and key:upper():match("^[@-_]$") then code = key:upper():byte() - 64 end
    if code and not mods.shift then return prefix .. string.char(code) end
    if not mods.shift and key:match("^%d$") then return prefix .. key end
    return ("\27[%d;%du"):format(key == "space" and 32 or key:byte(), modifier)
  end
  if alt then return prefix .. (key == "space" and " " or mods.shift and key:upper() or key) end
end

return keyboard
