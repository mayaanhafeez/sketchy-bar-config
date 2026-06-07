local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

local wifi = sbar.add("item", "widgets.wifi.padding", {
  position = "right",
  label = { drawing = false },
})

sbar.add("item", { position = "right", width = settings.group_paddings })

wifi:subscribe({"wifi_change", "system_woke"}, function(env)
  sbar.exec("ipconfig getifaddr en0", function(ip)
    local connected = not (ip == "")
    wifi:set({
      icon = {
        string = connected and icons.wifi.connected or icons.wifi.disconnected,
        color = connected and colors.white or colors.red,
      },
    })
  end)
end)

wifi:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.wifi'")
end)
