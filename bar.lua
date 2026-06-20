local colors = require("colors")

-- Equivalent to the --bar domain
sbar.bar({
  height = 38,
  color = colors.bar.bg,
  padding_right = 2,
  padding_left = 2,
  -- Render above the native macOS menu bar so sketchybar-toggle can cleanly
  -- swap between the two (required by sketchybar-toggle).
  topmost = "window",
})
