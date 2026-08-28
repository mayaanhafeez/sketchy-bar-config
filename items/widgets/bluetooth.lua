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

local function open_settings()
  sbar.exec("open 'x-apple.systempreferences:com.apple.BluetoothSettings'")
end

bluetooth:subscribe("mouse.clicked", open_settings)

-- What the skhd binding hits: `sketchybar --trigger bluetooth_settings` is the
-- same as clicking the widget.
sbar.add("event", "bluetooth_settings")
bluetooth:subscribe("bluetooth_settings", open_settings)
