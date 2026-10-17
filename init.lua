local sbar = require("sketchybar")
local settings = require("settings")
local create_layout = require("layout")
local config = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

sbar.begin_config()
sbar.bar({
  height = settings.height,
  color = settings.colors.transparent,
  border_width = 0,
  shadow = false,
  blur_radius = 0,
  margin = 0,
  padding_left = 16,
  padding_right = 16,
  topmost = "window",
  sticky = true,
  show_in_fullscreen = false,
  font_smoothing = true,
})
sbar.add("event", "hyprspace_workspace_change")
sbar.add("event", "hyprspace_windows_change")
sbar.add("event", "amphetamine_toggle")

local monitor = create_layout(false)
local laptop = create_layout(true)
local popup_events = {
  cpu_popup_toggle = "cpu", ram_popup_toggle = "memory", battery_popup_toggle = "battery",
  wifi_popup_toggle = "wifi", volume_popup_toggle = "volume",
  agents_popup_toggle = "agents",
  calendar_popup_toggle = "calendar",
}
for event, kind in pairs(popup_events) do
  sbar.add("event", event)
  local shortcut = sbar.add("item", "shortcut." .. event, { drawing = false, updates = true })
  shortcut:subscribe(event, function()
    sbar.exec(quote(config .. "/helpers/displays"), function(displays)
      if type(displays) ~= "table" then return end
      for _, display in ipairs(displays) do
        if display.mouse then
          local layout = display.built_in and laptop or monitor
          layout.popups[kind]()
          return
        end
      end
    end)
  end)
end
sbar.add("event", "btop_launch")
local btop_shortcut = sbar.add("item", "shortcut.btop", { drawing = false, updates = true })
btop_shortcut:subscribe("btop_launch", function() sbar.exec(quote(config .. "/helpers/btop_launch.command")) end)
local detecting = false
local function update_displays()
  if detecting then return end
  detecting = true
  sbar.exec(quote(config .. "/helpers/displays"), function(hardware)
    if type(hardware) ~= "table" or #hardware == 0 then detecting = false; return end
    local built_in = {}
    for _, display in ipairs(hardware) do built_in[display.id] = display.built_in end
    sbar.exec("sketchybar --query displays", function(displays)
      detecting = false
      if type(displays) ~= "table" or #displays == 0 then return end
      local monitor_ids, laptop_ids = {}, {}
      for _, display in ipairs(displays) do
        local ids = built_in[display.DirectDisplayID] and laptop_ids or monitor_ids
        ids[#ids + 1] = display["arrangement-id"]
      end
      monitor.set_displays(monitor_ids)
      laptop.set_displays(laptop_ids)
    end)
  end)
end
local listener = sbar.add("item", "display.listener", {
  drawing = false,
  updates = true,
  update_freq = 5,
})
listener:subscribe({ "routine", "display_change", "system_woke" }, update_displays)
sbar.end_config()
monitor.start()
laptop.start()
update_displays()

-- Preserve the existing native-menu-bar handoff.
sbar.exec("pgrep -x sketchybar-toggle >/dev/null || (sketchybar-toggle --trigger-zone 3 >/dev/null 2>&1 &)")
sbar.event_loop()
