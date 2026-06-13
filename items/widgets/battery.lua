local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

local battery = sbar.add("item", "widgets.battery", {
  position = "right",
  icon = {
    font = {
      style = settings.font.style_map["Regular"],
      size = 13.0,
    }
  },
  label = { drawing = false },
  update_freq = 250,
  popup = { align = "center" }
})

local battery_pct = sbar.add("item", {
  position = "popup." .. battery.name,
  icon = {
    string = "Charge:",
    width = 100,
    align = "left"
  },
  label = {
    string = "?%",
    width = 100,
    align = "right"
  },
})

local remaining_time = sbar.add("item", {
  position = "popup." .. battery.name,
  icon = {
    string = "Time remaining:",
    width = 100,
    align = "left"
  },
  label = {
    string = "??:??h",
    width = 100,
    align = "right"
  },
})

local battery_icons = {
  "󰂎", -- 0–9%
  "󰁺", -- 10–19%
  "󰁻", -- 20–29%
  "󰁼", -- 30–39%
  "󰁽", -- 40–49%
  "󰁾", -- 50–59%
  "󰁿", -- 60–69%
  "󰂀", -- 70–79%
  "󰂁", -- 80–89%
  "󰂂", -- 90–99%
  "󰁹", -- 100%
}

battery:subscribe({"routine", "power_source_change", "system_woke"}, function()
  sbar.exec("pmset -g batt", function(batt_info)
    local icon = "!"
    local label = "?"

    local found, _, charge = batt_info:find("(%d+)%%")
    if found then
      charge = tonumber(charge)
      label = charge .. "%"
      local idx = math.min(math.floor(charge / 10) + 1, 11)
      icon = battery_icons[idx]
    end

    local charging = batt_info:find("AC Power")
    if charging then
      icon = icon .. " 󱐋"
    end

    local lead = ""
    if found and charge < 10 then
      lead = "0"
    end

    battery:set({ icon = { string = icon, color = colors.text } })
    battery_pct:set({ label = { string = lead .. label } })
  end)
end)

battery:subscribe("mouse.clicked", function(env)
  local drawing = battery:query().popup.drawing
  battery:set({ popup = { drawing = "toggle" } })

  if drawing == "off" then
    sbar.exec("pmset -g batt", function(batt_info)
      local found, _, remaining = batt_info:find(" (%d+:%d+) remaining")
      local label = found and remaining .. "h" or "No estimate"
      remaining_time:set({ label = label })
    end)
  end
end)

sbar.add("item", "widgets.battery.padding", {
  position = "right",
  width = 2
})
