local icons = require("icons")

local cpu = sbar.add("item", "widgets.cpu", {
  position = "right",
  icon = { string = icons.cpu },
  label = { drawing = false },
  background = { border_width = 0 },
})

local function launch_btop()
  sbar.exec("\"$CONFIG_DIR/helpers/btop_launch.command\"")
end

cpu:subscribe("mouse.clicked", launch_btop)

-- What the skhd binding hits: `sketchybar --trigger btop_launch` is the same
-- as clicking the widget.
sbar.add("event", "btop_launch")
cpu:subscribe("btop_launch", launch_btop)
