local settings = require("settings")
local colors = require("colors")

local spacer_before = sbar.add("item", { position = "right", width = settings.group_paddings })

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

local spacer_after = sbar.add("item", { position = "right", width = settings.group_paddings })

local function update_position()
  sbar.exec("system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:'", function(output)
    local count = tonumber(output) or 1
    if count >= 2 then
      cal:set({ position = "center" })
      spacer_before:set({ drawing = false })
      spacer_after:set({ drawing = false })
    else
      cal:set({ position = "right" })
      spacer_before:set({ drawing = true })
      spacer_after:set({ drawing = true })
    end
  end)
end

cal:subscribe({ "forced", "routine", "system_woke" }, function(env)
  cal:set({ icon = os.date("%A %d"), label = os.date("%I:%M %p") })
end)

cal:subscribe("display_change", function(env)
  update_position()
end)

update_position()
