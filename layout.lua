local api = require("sketchybar")
local settings = require("settings")
local popups = require("popups")
local c = settings.colors
local config = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

-- Separate items are needed because SketchyBar fonts/padding are per item,
-- not per display. Both layouts receive the same live events and controls.
return function(laptop)
local items = {}
local prefix = laptop and "laptop." or ""
local sbar = setmetatable({
  add = function(kind, name, ...)
    local item = api.add(kind, prefix .. name, ...)
    items[#items + 1] = item
    return item
  end,
}, { __index = api })
local font_size = laptop and settings.laptop_font_size or settings.font_size
local panel_height = laptop and settings.laptop_panel_height or settings.panel_height
local inset = laptop and 8 or 14
local workspace_inset = laptop and 6 or 9
local clock_inset = laptop and 10 or 16

sbar.default({
  -- No matching display until init.lua assigns this layout to its screens.
  display = "31",
  padding_left = 0,
  padding_right = 0,
  icon = {
    font = { family = settings.font, style = "Regular", size = font_size },
    color = c.text,
    padding_left = inset,
    padding_right = laptop and 6 or 8,
  },
  label = {
    font = { family = settings.font, style = "Regular", size = font_size },
    color = c.text,
    padding_left = 0,
    padding_right = inset,
  },
  background = {
    drawing = false,
    color = c.panel,
    height = panel_height,
    corner_radius = settings.corner_radius,
    border_width = 0,
  },
  popup = { background = { color = c.panel, corner_radius = 5, border_width = 0 } },
})

-- Match the side inset to the vertical gap above the pills on each screen.
local edge = (settings.height - panel_height) / 2
for _, side in ipairs({ "left", "right" }) do
  sbar.add("item", "edge." .. side, {
    position = side, width = edge,
    icon = { drawing = false }, label = { drawing = false }, background = { drawing = false },
  })
end

local spaces, focused, present = {}, "1", {}
local function paint_spaces()
  for index, item in ipairs(spaces) do
    local id = tostring(index)
    item:set({
      drawing = present[id] or id == focused or false,
      icon = { string = id .. ":", color = id == focused and c.active or c.lavender },
      label = { string = id == focused and "" or "", color = id == focused and c.active or c.lavender },
    })
  end
end
local function refresh_spaces()
  sbar.exec(settings.hyprspace .. " list-workspaces --all --format '%{workspace}|%{workspace-is-focused}'", function(output)
    present = {}
    for id, active in output:gmatch("([^\n|]+)|(%a+)") do
      present[id] = true
      if active == "true" then focused = id end
    end
    paint_spaces()
  end)
end
for index = 1, settings.workspace_count do
  local id = tostring(index)
  local item = sbar.add("item", "space." .. id, {
    position = "left",
    drawing = index <= 5,
    icon = { string = id .. ":", padding_left = workspace_inset, padding_right = laptop and 3 or 4, color = c.lavender },
    label = { string = "", padding_right = workspace_inset, color = c.lavender },
    click_script = settings.hyprspace .. " workspace " .. id,
  })
  item:subscribe("mouse.entered", function() item:set({ icon = { color = c.hover }, label = { color = c.hover } }) end)
  item:subscribe("mouse.exited", paint_spaces)
  spaces[index] = item
end
local workspace_members = {}
for _, item in ipairs(spaces) do workspace_members[#workspace_members + 1] = item.name end
sbar.add("bracket", "workspaces", workspace_members, { background = { drawing = true } })
local workspace_listener = sbar.add("item", "workspace.listener", { drawing = false, updates = true, update_freq = 3 })
workspace_listener:subscribe({ "routine", "hyprspace_windows_change", "system_woke" }, refresh_spaces)
workspace_listener:subscribe("hyprspace_workspace_change", function(env)
  if env.FOCUSED_WORKSPACE then focused = env.FOCUSED_WORKSPACE; paint_spaces() end
  refresh_spaces()
end)

local clock = sbar.add("item", "clock", {
  position = laptop and "right" or "center",
  padding_left = laptop and 8 or 0,
  update_freq = 10,
  icon = { drawing = false },
  label = { color = c.clock, padding_left = clock_inset, padding_right = clock_inset },
  background = { drawing = true },
})
local show_weekday = false
local open_calendar = popups.native(clock, "calendar", laptop, false)
local function update_clock()
  clock:set({ label = os.date(show_weekday and "%a %d - %H:%M" or "%d - %H:%M") })
end
clock:subscribe({ "routine", "system_woke" }, update_clock)
clock:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then open_calendar()
  else
    show_weekday = not show_weekday
    update_clock()
  end
end)

-- SketchyBar adds right-aligned items from the outside inward.
local memory = sbar.add("item", "memory", { position = "right", icon = "", label = "--.-G/--.-G" })
local cpu = sbar.add("item", "cpu", { position = "right", icon = "", label = "▁▁▁▁  0%" })
local network = sbar.add("item", "network", {
  position = "right",
  icon = { string = "󰤠", padding_left = inset, padding_right = inset },
  label = { drawing = false },
  update_freq = 5,
})
local battery = sbar.add("item", "battery", {
  position = "right",
  icon = { string = "󰁹", color = c.battery },
  label = { string = "--%", color = c.battery },
  update_freq = 60,
})
local volume = sbar.add("item", "volume", {
  position = "right",
  icon = { string = "", color = c.volume },
  label = { string = "--%", color = c.volume },
  update_freq = 30,
})
-- Right items grow leftward: coffee · agents · volume · battery · network…
local icon_width = laptop and 26 or 32
local function gap(name)
  return sbar.add("item", name, {
    position = "right", width = 4,
    icon = { drawing = false }, label = { drawing = false }, background = { drawing = false },
  })
end
local agents_gap = gap("agents.gap")
local agents = sbar.add("item", "agents", {
  position = "right", width = icon_width,
  icon = { string = "󰚩", color = c.lavender, width = icon_width, align = "center",
    padding_left = 0, padding_right = 0 },
  label = { drawing = false }, background = { drawing = false },
  updates = true, update_freq = 5,
})
local open_agents = popups.native(agents, "agents", laptop)
local function refresh_agents()
  sbar.exec(quote(config .. "/helpers/agent_status.sh"), function(output)
    local state = output:match("^(%a+)")
    if not state then return end
    local visible = state ~= "none"
    agents:set({ drawing = visible, icon = { color = state == "busy" and c.active or c.lavender } })
    agents_gap:set({ drawing = visible })
  end)
end
agents:subscribe({ "routine", "system_woke" }, refresh_agents)

gap("coffee.gap")
local coffee = sbar.add("item", "coffee", {
  position = "right", width = icon_width,
  icon = { string = "󰛊", color = c.muted, width = icon_width, align = "center",
    padding_left = 0, padding_right = 0 },
  label = { drawing = false }, background = { drawing = false },
  updates = true, update_freq = 5,
})
local amphetamine_helper = quote(config .. "/helpers/amphetamine.sh")
local coffee_busy = false
local function refresh_coffee()
  if coffee_busy then return end
  sbar.exec(amphetamine_helper .. " get", function(output)
    local active = output:match("active=1") ~= nil
    coffee:set({ icon = { string = active and "󰅶" or "󰛊", color = active and c.active or c.muted } })
  end)
end
local function toggle_coffee()
  if coffee_busy then return end
  coffee_busy = true
  sbar.exec(amphetamine_helper .. " toggle", function()
    coffee_busy = false
    refresh_coffee()
  end)
end
coffee:subscribe({ "routine", "system_woke" }, refresh_coffee)
coffee:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then sbar.exec(amphetamine_helper .. " menu") else toggle_coffee() end
end)
-- Only one subscriber, even with both screen profiles loaded.
if not laptop then coffee:subscribe("amphetamine_toggle", toggle_coffee) end

sbar.add("bracket", "system", {
  coffee.name, agents.name, volume.name, battery.name, network.name, cpu.name, memory.name,
}, { background = { drawing = true } })

local function open_btop()
  popups.close()
  sbar.exec(quote(config .. "/helpers/btop_launch.command"))
end
local function open_htop()
  popups.close()
  sbar.exec(quote(config .. "/helpers/btop_launch.command") .. " htop")
end
cpu:subscribe("mouse.clicked", open_htop)
memory:subscribe("mouse.clicked", open_btop)
local battery_popup = popups.battery(battery)
local open_wifi = popups.native(network, "wifi", laptop)
local open_volume = popups.native(volume, "volume", laptop)

local levels = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local metrics = sbar.add("item", "metrics.listener", { drawing = false, updates = true, update_freq = 2 })
local function update_metrics()
  sbar.exec(quote(config .. "/helpers/metrics"), function(data)
    if type(data) ~= "table" or not data.cores then return end
    local graph = ""
    for _, load in ipairs(data.cores) do
      graph = graph .. levels[math.max(1, math.min(8, math.floor(load / 100 * 7) + 1))]
    end
    cpu:set({ label = string.format("%s %2.0f%%", graph, data.cpu) })
    memory:set({ label = string.format("%.1fG/%.1fG", data.used, data.total) })
  end)
end
metrics:subscribe({ "routine", "system_woke" }, update_metrics)

local battery_icons = { "󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹" }
local function update_battery()
  sbar.exec("pmset -g batt", function(output)
    local percent = tonumber(output:match("(%d+)%%"))
    if not percent then battery:set({ drawing = false }); return end
    local charging = output:find("AC Power", 1, true) ~= nil
    local color = percent <= 20 and not charging and c.warning or c.battery
    battery:set({
      drawing = true,
      icon = { string = charging and "󰂄" or battery_icons[math.min(11, math.floor(percent / 10) + 1)], color = color },
      label = { string = percent .. "%", color = color },
    })
    battery_popup.update(output)
  end)
end
battery:subscribe({ "routine", "power_source_change", "system_woke" }, update_battery)

local function update_volume(value)
  if value then
    local percent = tonumber(value)
    if percent then
      volume:set({ icon = percent == 0 and "" or (percent < 34 and "" or (percent < 67 and "" or "")), label = math.floor(percent + 0.5) .. "%" })
    end
    return
  end
  sbar.exec([[osascript -e 'set v to get volume settings' -e 'return (output volume of v as text) & ":" & (output muted of v as text)']], function(output)
    local percent, muted = output:match("(%d+):(%a+)")
    -- Devices without software volume (HDMI/DP) report "missing value"; never
    -- recurse on a nil percent or this respawns osascript forever.
    if muted == "true" then volume:set({ icon = "", label = "mute" })
    elseif percent then update_volume(percent)
    else volume:set({ label = "--" }) end
  end)
end
-- SketchyBar already supplies the effective volume (zero while muted). Don't
-- spawn another AppleScript read on both layouts for every slider/media-key tick.
volume:subscribe("volume_change", function(env)
  local percent = tonumber(env.INFO)
  -- Zero alone cannot distinguish mute from a silent level; keep the mute label.
  if percent and percent > 0 then update_volume(percent) else update_volume() end
end)
volume:subscribe({ "routine", "system_woke" }, function() update_volume() end)
volume:subscribe("mouse.scrolled", function(env)
  local delta = (tonumber(env.SCROLL_DELTA) or 0) > 0 and 5 or -5
  sbar.exec("osascript -e 'set volume output volume ((output volume of (get volume settings)) + (" .. delta .. "))'", function() update_volume() end)
end)

local network_command = [[interface=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}');
if [ -z "$interface" ]; then echo disconnected;
elif /usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '/Hardware Port:/{wifi=($0 ~ /Wi-Fi|AirPort/)} /^Device:/{if(wifi) print $2}' | /usr/bin/grep -qx "$interface"; then echo wifi;
else echo ethernet; fi]]
local function update_network()
  sbar.exec(network_command, function(output)
    network:set({ icon = output:match("disconnected") and "󰤠" or (output:match("wifi") and "󰤢" or "󰈀") })
  end)
end
network:subscribe({ "routine", "wifi_change", "system_woke" }, update_network)

local assigned_displays
return {
  popups = { cpu = open_htop, memory = open_btop, battery = battery_popup.toggle,
    wifi = open_wifi, volume = open_volume, agents = open_agents, calendar = open_calendar },
  set_displays = function(displays)
    local value = #displays > 0 and table.concat(displays, ",") or "31"
    if value == assigned_displays then return end
    assigned_displays = value
    for _, item in ipairs(items) do item:set({ display = value }) end
  end,
  start = function()
    refresh_spaces()
    update_clock()
    refresh_coffee()
    refresh_agents()
    update_metrics()
    update_battery()
    update_volume()
    update_network()
  end,
}
end
