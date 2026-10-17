-- set-theme writes this shared file before reloading SketchyBar.
local file = io.open(os.getenv("HOME") .. "/.config/theme", "r")
local theme = file and file:read("*a"):match("^%s*([%w_-]+)%s*$")
if file then file:close() end

local ok, palette = false, nil
if theme then
  ok, palette = pcall(require, "themes." .. theme:gsub("-", "_"))
end
if not ok then
  io.stderr:write("SketchyBar: missing palette for " .. (theme or "current theme") .. "; using rose-pine\n")
  palette = require("themes.rose_pine")
end

return {
  transparent = palette.transparent,
  panel = palette.base,
  surface = palette.surface,
  border = palette.popup.border,
  popup = palette.popup.bg,
  text = palette.text,
  muted = palette.subtle,
  lavender = palette.iris,
  active = palette.foam,
  hover = palette.blue,
  clock = palette.blue,
  battery = palette.gold,
  warning = palette.red,
  volume = palette.rose,
}
