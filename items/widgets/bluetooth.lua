local colors = require("colors")

local bluetooth = sbar.add("item", "widgets.bluetooth", {
  position = "right",
  icon = {
    string = "󰂯",
    color = colors.white,
  },
  label = { drawing = false },
  background = { border_width = 0 },
})

bluetooth:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.BluetoothSettings'")
end)
