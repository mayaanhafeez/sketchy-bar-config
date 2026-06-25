local icons = require("icons")

local cpu = sbar.add("item", "widgets.cpu", {
  position = "right",
  icon = { string = icons.cpu },
  label = { drawing = false },
  background = { border_width = 0 },
})

cpu:subscribe("mouse.clicked", function(env)
  sbar.exec("\"$CONFIG_DIR/helpers/btop_launch.command\"")
end)
