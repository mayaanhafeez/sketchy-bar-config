local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local keys = require("helpers.popup_keys")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")

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
  popup = { align = "right" }
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
    width = 110,
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
    width = 110,
    align = "right"
  },
})

-- ------------------------------------------------------------ low power mode
-- The only row in here that does anything. Flipping it needs root, so the
-- helper puts up the system authorization dialog; everything on this side just
-- reports whatever pmset says afterwards.
local LOWPOWER = "'" .. config_dir .. "/helpers/lowpowermode.sh'"

local low_power_supported = true
local low_power_on = false
local low_power_busy = false

local low_power = sbar.add("item", "widgets.battery.lowpower", {
  position = "popup." .. battery.name,
  icon = {
    string = "Low power mode:",
    width = 100,
    align = "left",
  },
  label = {
    string = "Off",
    width = 110,
    align = "right",
  },
  background = {
    drawing = true,
    height = 22,
    corner_radius = 4,
    border_width = 0,
    color = colors.transparent,
  },
})

-- Focus ring over the actionable rows. Low Power Mode is the only one today --
-- charge and time remaining are readouts -- so the arrows have a single stop,
-- but a second control joins by appending to the ring and nothing else.
local ring = {}
local focus_index = 1

local function render_focus()
  for index, entry in ipairs(ring) do
    entry.item:set({
      background = { color = index == focus_index and colors.bg2 or colors.transparent },
    })
  end
end

local function render_low_power()
  low_power:set({
    drawing = low_power_supported,
    label = {
      -- The dialog can sit there for a while, so the row says something is in
      -- flight rather than showing the old value as though nothing happened.
      string = low_power_busy and "…" or (low_power_on and "On" or "Off"),
      color = low_power_on and colors.gold or colors.grey,
    },
  })
  render_focus()
end

local function apply_low_power(out)
  local state = (out or ""):match("state=(%w+)")
  low_power_supported = state ~= "unsupported"
  low_power_on = state == "1"
  low_power_busy = false
  ring = low_power_supported and { { item = low_power, kind = "lowpower" } } or {}
  if focus_index > #ring then focus_index = 1 end
  render_low_power()
end

local function refresh_low_power()
  sbar.exec(LOWPOWER .. " get", function(out) apply_low_power(out) end)
end

-- Restarted after the dialog is done with, if the popup is still up.
local nav

local function toggle_low_power()
  if not low_power_supported or low_power_busy then return end
  low_power_busy = true
  render_low_power()

  -- The authorization dialog needs the keyboard, and the popup's key grabber
  -- is holding it. Hand it over for the duration.
  keys.stop_all()

  sbar.exec(LOWPOWER .. " set " .. (low_power_on and "0" or "1"), function(out)
    apply_low_power(out)
    if battery:query().popup.drawing == "on" then
      nav.start()
    end
  end)
end

low_power:subscribe("mouse.entered", function()
  low_power:set({ background = { color = colors.bg2 } })
end)
low_power:subscribe("mouse.exited", render_focus)
low_power:subscribe("mouse.clicked", function()
  focus_index = 1
  toggle_low_power()
end)

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

local function move_focus(delta)
  if #ring == 0 then return end
  focus_index = ((focus_index - 1 + delta) % #ring) + 1
  render_focus()
end

local function activate_focus()
  local entry = ring[focus_index]
  if not entry then return end
  if entry.kind == "lowpower" then
    toggle_low_power()
  end
end

local function close_popup()
  battery:set({ popup = { drawing = false } })
  nav.stop()
end

-- One column, so left and right walk it too rather than sitting dead.
nav = keys.bind("battery", function(key)
  if key == "escape" then
    close_popup()
  elseif key == "up" or key == "left" then
    move_focus(-1)
  elseif key == "down" or key == "right" then
    move_focus(1)
  elseif key == "return" then
    activate_focus()
  end
end)

local function toggle_popup()
  local drawing = battery:query().popup.drawing
  battery:set({ popup = { drawing = "toggle" } })

  if drawing == "on" then
    nav.stop()
    return
  end

  focus_index = 1
  render_focus()
  nav.start()
  refresh_low_power()

  sbar.exec("pmset -g batt", function(batt_info)
    local found, _, remaining = batt_info:find(" (%d+:%d+) remaining")
    local label = found and remaining .. "h" or "No estimate"
    remaining_time:set({ label = label })
  end)
end

battery:subscribe("mouse.clicked", toggle_popup)

-- What the skhd binding hits: `sketchybar --trigger battery_popup_toggle`.
sbar.add("event", "battery_popup_toggle")
battery:subscribe("battery_popup_toggle", toggle_popup)

-- Low Power Mode can also be flipped from System Settings or by plugging in,
-- so the row is re-read whenever the power situation changes rather than only
-- when the popup opens.
battery:subscribe({ "power_source_change", "system_woke" }, refresh_low_power)

refresh_low_power()

sbar.add("item", "widgets.battery.padding", {
  position = "right",
  width = 2
})
