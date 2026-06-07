local settings = require("settings")
local colors = require("colors")

sbar.add("item", { position = "right", width = settings.group_paddings })

local cal = sbar.add("item", {
  icon = {
    color = colors.white,
    width = 90,
    padding_left = 8,
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Regular"],
      size = 13.0,
    },
  },
  label = {
    color = colors.white,
    padding_right = 8,
    width = 75,
    align = "right",
    font = { family = settings.font.numbers, style = settings.font.style_map["Regular"], size = 13.0 },
  },
  position = "right",
  update_freq = 30,
  padding_left = 1,
  padding_right = 1,
  click_script = "open -a 'Calendar'"
})

sbar.add("item", { position = "right", width = settings.group_paddings })

cal:subscribe({ "forced", "routine", "system_woke" }, function(env)
  cal:set({ icon = os.date("%A %d"), label = os.date("%I:%M %p") })
end)
