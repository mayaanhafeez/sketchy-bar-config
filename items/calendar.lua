local settings = require("settings")
local colors = require("colors")
local display = require("helpers.display")

local spacer_before = sbar.add("item", { position = "right", width = settings.group_paddings })

local cal = sbar.add("item", {
  icon = {
    color = colors.white,
    padding_left = 8,
    padding_right = 6,
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Regular"],
      size = 13.0,
    },
  },
  label = {
    color = colors.white,
    padding_right = 8,
    font = { family = settings.font.numbers, style = settings.font.style_map["Regular"], size = 13.0 },
  },
  position = "right",
  update_freq = 30,
  padding_left = 1,
  padding_right = 1,
  click_script = "open -a 'Calendar'"
})

local spacer_after = sbar.add("item", { position = "right", width = 2 })

local function update_position(display_type)
  if display_type == "external" then
    cal:set({ position = "center" })
    spacer_before:set({ drawing = false })
    spacer_after:set({ drawing = false })
  else
    cal:set({ position = "right" })
    spacer_before:set({ drawing = true })
    spacer_after:set({ drawing = true })
  end
end

cal:subscribe({ "forced", "routine", "system_woke" }, function(env)
  cal:set({ icon = os.date("%A %d"), label = os.date("%I:%M %p") })
end)

cal:subscribe("display_change", function(env)
  display.detect(update_position)
end)

display.detect(update_position)