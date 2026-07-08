local settings = require("settings")
local display = require("helpers.display")

sbar.bar({
  height = settings.height_internal,
  color = require("colors").bar.bg,
  padding_right = 2,
  padding_left = 2,
  topmost = "window",
})

sbar.add("event", "display_change_check")
sbar.add("item", { drawing = false, position = "left" }):subscribe("display_change_check", function()
  display.detect(display.update_bar_height)
end)

display.detect(display.update_bar_height)