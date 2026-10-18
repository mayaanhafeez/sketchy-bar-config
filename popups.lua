local sbar = require("sketchybar")
local settings = require("settings")
local keys = require("helpers.popup_keys")
local c = settings.colors
local config = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local function popup_background(color)
  local opacity = math.max(0, math.min(1, settings.popup_opacity or 1))
  return (color & 0x00ffffff) | (math.floor(opacity * 255 + 0.5) << 24)
end
local M = {}
local active
local display_layouts
local volume_binary = quote(config .. "/helpers/volume_panel/bin/volume_panel")
local volume_owners = {}
local volume_launch

function M.set_displays(displays)
  display_layouts = displays
end

function M.close()
  if active then active.close() end
end

function M.toggle_volume()
  if not volume_launch or not display_layouts then return false end
  local anchors = ""
  for _, entry in ipairs(volume_owners) do
    local bounds = entry.owner:query().bounding_rects or {}
    for _, display in ipairs(display_layouts) do
      local rect = bounds["display-" .. display["arrangement-id"]]
      if rect and rect.origin[1] ~= -9999 and rect.size[1] > 1 then
        anchors = anchors .. string.format(" --screen-anchor %d,%.1f,%.1f,%d", display.DirectDisplayID,
          rect.origin[1] + rect.size[1] / 2 + entry.width / 2,
          rect.origin[2] - display.frame.y + rect.size[2] + 6, entry.width)
      end
    end
  end
  if anchors == "" then return false end
  M.close()
  -- The resident host picks the mouse's screen itself. No process/display
  -- detection subprocesses or asynchronous Lua callbacks before opening.
  sbar.exec(volume_launch .. anchors .. " >/dev/null 2>&1 &")
  return true
end

local function with_anchor(owner, width, launch, hardware)
  local bounds = owner:query().bounding_rects or {}
  local function locate(hardware)
    local mouse_display
    if type(hardware) == "table" then
      for _, display in ipairs(hardware) do
        if display.mouse then mouse_display = display.id; break end
      end
    end
    local function place(displays)
      if type(displays) ~= "table" then return end
      local selected, rectangle
      for _, display in ipairs(displays) do
        local rect = bounds["display-" .. display["arrangement-id"]]
        if rect and rect.origin[1] ~= -9999 and rect.size[1] > 1 then
          selected, rectangle = display, rect
          if display.DirectDisplayID == mouse_display then break end
        end
      end
      if not selected then return end
      -- Swift's anchor is the panel's top-right. Offset by half its width to
      -- center the panel below the widget; its screen-edge clamp still applies.
      local x = rectangle.origin[1] + rectangle.size[1] / 2 + width / 2
      local y = rectangle.origin[2] - selected.frame.y + rectangle.size[2] + 6
      launch(string.format(" --display-id %d --anchor-x %.1f --anchor-y %.1f",
        selected.DirectDisplayID, x, y))
    end
    if display_layouts then place(display_layouts)
    else sbar.exec("sketchybar --query displays", place) end
  end
  if type(hardware) == "table" then locate(hardware)
  else sbar.exec(quote(config .. "/helpers/displays"), locate) end
end

-- Native panels, with the current theme and display sizing.
function M.native(owner, kind, laptop, bind_click)
  local process = kind .. "_panel"
  local others = {}
  for _, name in ipairs({ "wifi_panel", "volume_panel", "agents_panel", "calendar_panel" }) do
    if name ~= process and name ~= "volume_panel" then others[#others + 1] = name end
  end
  -- One process-table scan, not one pkill process per other panel.
  local close_others = "pkill -x " .. quote("(" .. table.concat(others, "|") .. ")") .. " >/dev/null 2>&1; "
  if kind ~= "volume" then close_others = close_others .. volume_binary .. " --hide >/dev/null 2>&1 & " end
  local flags = ""
  for key, color in pairs({ foreground = c.text, background = popup_background(c.panel), accent = c.active,
      urgent = c.warning, muted = c.muted, border = c.border }) do
    flags = flags .. string.format(" --%s 0x%08x", key, color)
  end
  if kind == "wifi" then
    flags = flags .. " --macwifi " .. quote(os.getenv("MACWIFI_BIN") or "/usr/local/bin/macwifi")
      .. " --helpers " .. quote(config .. "/helpers")
  elseif kind == "agents" then
    flags = flags .. " --helpers " .. quote(config .. "/helpers")
      .. " --assets " .. quote(config .. "/assets") .. " --provider claude"
  elseif kind == "volume" then
    flags = flags .. " --switcher /opt/homebrew/bin/SwitchAudioSource"
  end
  local width = kind == "agents" and (laptop and 320 or 340) or (laptop and 340 or 380)
  if kind == "calendar" then width = laptop and 260 or 280 end
  local command = quote(config .. "/helpers/" .. process .. "/bin/" .. process) .. flags
    .. " --font " .. quote(settings.font)
    .. " --radius " .. settings.corner_radius
    .. " --width " .. width
  if kind == "volume" then
    volume_owners[#volume_owners + 1] = { owner = owner, width = width }
    volume_launch = volume_launch or (close_others .. command .. " --toggle")
  end
  if kind == "volume" and not laptop then
    -- Rebuild once per config reload, never on the click path. The hidden host
    -- has no polling/keyboard grab and stops its audio observations when shut.
    sbar.exec("pkill -x volume_panel >/dev/null 2>&1; " .. command .. " --prepare >/dev/null 2>&1 &")
  end
  local function launch(hardware)
    with_anchor(owner, width, function(anchor)
      sbar.exec(close_others .. command .. (kind == "volume" and " --toggle" or "")
        .. anchor .. " >/dev/null 2>&1 &")
    end, hardware)
  end
  local function open(hardware)
    if kind == "volume" and M.toggle_volume() then return end
    M.close()
    if kind == "volume" then launch(hardware); return end
    sbar.exec("pgrep -x " .. process .. " >/dev/null && echo up || echo down", function(output)
      if output:match("up") then sbar.exec("pkill -x " .. process)
      else launch(hardware) end
    end)
  end
  if bind_click ~= false then owner:subscribe("mouse.clicked", function(env)
    if env.BUTTON == "right" then
      if kind == "agents" then sbar.exec("pkill -x agents_panel >/dev/null 2>&1 || true")
      else
        sbar.exec(kind == "wifi" and "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'"
          or "open 'x-apple.systempreferences:com.apple.Sound-Settings.extension'")
      end
    else open() end
  end) end
  return open
end

-- Port of items/widgets/battery.lua from the original config: the same three
-- rows, Low Power Mode helper, focus ring and keyboard/authorization behavior.
-- Only item names and the existing bar owner are adapted for the two displays.
function M.battery(owner)
  local p = { open = false }
  local nav
  local supported, low_power_on, busy = true, false, false
  local low_power
  local helper = quote(config .. "/helpers/lowpowermode.sh")

  owner:set({ popup = {
    align = "right", height = 28,
    blur_radius = 50,
    background = { border_width = 2, corner_radius = 9, border_color = c.border,
      color = popup_background(c.popup), shadow = { drawing = true } },
  } })

  local function row(key, label, value)
    return sbar.add("item", owner.name .. ".popup." .. key, {
      position = "popup." .. owner.name,
      -- The popup's owner selects its screen; don't inherit the bar's mask.
      ignore_association = true,
      padding_left = 5, padding_right = 5,
      icon = { string = label, drawing = true, width = 140, align = "left",
        padding_left = 3, padding_right = 3, color = c.text,
        font = { family = settings.font, style = "SemiBold", size = 14 } },
      label = { string = value, drawing = true, width = 110, align = "right",
        padding_left = 3, padding_right = 3, color = c.text,
        font = { family = settings.font, style = "Medium", size = 13 } },
      background = { drawing = false, height = 28, corner_radius = 9, border_width = 0 },
    })
  end
  local charge = row("charge", "Charge:", "?%")
  local remaining = row("remaining", "Time remaining:", "??:??h")
  low_power = row("low_power", "Low power mode:", "Off")
  low_power:set({ background = { drawing = true, height = 22, corner_radius = 4,
    color = c.transparent } })

  local function render_focus()
    low_power:set({ background = { color = supported and c.surface or c.transparent } })
  end
  local function render_low_power()
    low_power:set({ drawing = supported, label = {
      string = busy and "…" or (low_power_on and "On" or "Off"),
      color = low_power_on and c.battery or c.muted,
    } })
    render_focus()
  end
  local function apply_low_power(output)
    local state = output:match("state=(%w+)")
    supported = state == "0" or state == "1"
    low_power_on = state == "1"
    busy = false
    render_low_power()
  end
  local function refresh_low_power()
    if not busy then sbar.exec(helper .. " get", apply_low_power) end
  end
  local function toggle_low_power()
    if not supported or busy then return end
    busy = true
    render_low_power()
    -- Release the keyboard for macOS's authorization dialog, as in the old bar.
    keys.stop_all()
    sbar.exec(helper .. " set " .. (low_power_on and "0" or "1"), function(output)
      apply_low_power(output)
      if p.open then nav.start() end
    end)
  end

  low_power:subscribe("mouse.entered", render_focus)
  low_power:subscribe("mouse.exited", render_focus)
  low_power:subscribe("mouse.clicked", toggle_low_power)

  function p.update(output)
    local percent = tonumber(output:match("(%d+)%%"))
    charge:set({ label = percent and string.format("%02d%%", percent) or "?%" })
    refresh_low_power()
  end
  function p.close()
    if not p.open then return end
    p.open = false
    owner:set({ popup = { drawing = false } })
    nav.stop()
    if active == p then active = nil end
  end
  function p.toggle()
    if p.open then p.close(); return end
    M.close()
    sbar.exec("pkill -x '(wifi_panel|agents_panel|calendar_panel)' >/dev/null 2>&1; "
      .. volume_binary .. " --hide >/dev/null 2>&1 &")
    p.open = true
    active = p
    owner:set({ popup = { drawing = true } })
    render_focus()
    nav.start()
    sbar.exec("pmset -g batt", function(output)
      p.update(output)
      local time = output:match(" (%d+:%d+) remaining")
      remaining:set({ label = time and (time .. "h") or "No estimate" })
    end)
  end
  nav = keys.bind(owner.name, function(key)
    if not p.open then return end
    if key == "escape" then p.close()
    elseif key == "return" then toggle_low_power()
    elseif key == "up" or key == "down" or key == "left" or key == "right" then render_focus() end
  end)
  owner:subscribe("mouse.clicked", p.toggle)
  return p
end

return M
