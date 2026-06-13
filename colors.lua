local settings = require("settings")
local ok, colors = pcall(require, "themes." .. settings.theme)
if not ok then
  colors = require("themes.rose_pine")
end

colors.with_alpha = function(color, alpha)
  if alpha > 1.0 or alpha < 0.0 then return color end
  return (color & 0x00ffffff) | (math.floor(alpha * 255.0) * 16777216)
end

return colors
