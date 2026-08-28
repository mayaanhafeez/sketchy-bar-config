local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local keys = require("helpers.popup_keys")

local popup_width = 250

local volume_percent = sbar.add("item", "widgets.volume1", {
  position = "right",
  width = 0,
  icon = { drawing = false },
  label = {
    padding_left = 1,
    font = { family = settings.font.numbers }
  },
})

local volume_icon = sbar.add("item", "widgets.volume2", {
  position = "right",
  padding_right = 1,
  icon = {
    width = 0,
    align = "left",
    color = colors.grey,
    font = {
      style = settings.font.style_map["Regular"],
      size = 0,
    },
  },
  label = {
    width = 25,
    align = "left",
    font = {
      style = settings.font.style_map["Regular"],
      size = 0,
    },
  },
})

local volume_bracket = sbar.add("bracket", "widgets.volume.bracket", {
  volume_icon.name,
}, {
  popup = { align = "right" }
})

sbar.add("item", "widgets.volume.padding", {
  position = "right",
  width = 0
})

local volume_slider = sbar.add("slider", popup_width, {
  position = "popup." .. volume_bracket.name,
  slider = {
    highlight_color = colors.blue,
    background = {
      height = 6,
      corner_radius = 3,
      color = colors.bg2,
    },
    knob = {
      string = "􀀁",
      drawing = true,
    },
  },
  background = { color = colors.bg1, height = 2, y_offset = -20 },
  click_script = 'osascript -e "set volume output volume $PERCENTAGE"'
})

-- Mirrors the system volume so the arrow keys have something to step from;
-- the bar hears about every change through volume_change, including its own.
-- volume_change only fires on a change, so the starting value is read once
-- here -- otherwise the first arrow press after a reload would step from zero.
local current_volume = 0
sbar.exec("osascript -e 'output volume of (get volume settings)'", function(out)
  current_volume = tonumber(out) or 0
end)

volume_percent:subscribe("volume_change", function(env)
  local volume = tonumber(env.INFO)
  current_volume = volume
  local icon = icons.volume._0
  if volume > 60 then
    icon = icons.volume._100
  elseif volume > 30 then
    icon = icons.volume._66
  elseif volume > 10 then
    icon = icons.volume._33
  elseif volume > 0 then
    icon = icons.volume._10
  end

  volume_icon:set({ label = icon })
  volume_slider:set({ slider = { percentage = volume } })
end)

-- ---------------------------------------------------------------- devices
-- The output list is rebuilt every time the popup opens, so the rows are
-- tracked here rather than queried back out of sketchybar: the keyboard needs
-- to know which row is which, and in what order they were drawn.
local device_rows = {}
local device_focus = 1
local current_audio_device = "None"

-- Focus is a filled row; the active output stays the white one. Both can land
-- on the same row, which is exactly what opening the popup does.
local function render_devices()
  for index, row in ipairs(device_rows) do
    row.item:set({
      label = { color = row.name == current_audio_device and colors.white or colors.grey },
      background = { color = index == device_focus and colors.bg2 or colors.transparent },
    })
  end
end

local function move_device_focus(delta)
  local count = #device_rows
  if count == 0 then return end
  device_focus = ((device_focus - 1 + delta) % count) + 1
  render_devices()
end

-- Enter commits; walking the list on its own does not switch outputs, since
-- every switch drops and re-establishes the audio route.
local function apply_device_focus()
  local row = device_rows[device_focus]
  if not row then return end
  sbar.exec('SwitchAudioSource -s "' .. row.name .. '"', function()
    current_audio_device = row.name
    render_devices()
  end)
end

local VOLUME_STEP = 5

local function nudge_volume(delta)
  local target = math.max(0, math.min(100, current_volume + delta))
  if target == current_volume then return end
  current_volume = target
  -- Move the slider now rather than waiting for volume_change to come back
  -- around, so held arrow keys track the keypresses instead of lagging them.
  volume_slider:set({ slider = { percentage = target } })
  sbar.exec('osascript -e "set volume output volume ' .. target .. '"')
end

local nav

local function volume_collapse_details()
  nav.stop()
  local drawing = volume_bracket:query().popup.drawing == "on"
  if not drawing then return end
  volume_bracket:set({ popup = { drawing = false } })
  sbar.remove('/volume.device\\.*/')
  device_rows = {}
end

nav = keys.bind("volume", function(key)
  if key == "escape" then
    volume_collapse_details()
  elseif key == "up" then
    move_device_focus(-1)
  elseif key == "down" then
    move_device_focus(1)
  elseif key == "left" then
    nudge_volume(-VOLUME_STEP)
  elseif key == "right" then
    nudge_volume(VOLUME_STEP)
  elseif key == "return" then
    apply_device_focus()
  end
end)

local function volume_toggle_details(env)
  if env.BUTTON == "right" then
    sbar.exec("open /System/Library/PreferencePanes/Sound.prefpane")
    return
  end

  local should_draw = volume_bracket:query().popup.drawing == "off"
  if not should_draw then
    volume_collapse_details()
    return
  end

  volume_bracket:set({ popup = { drawing = true } })
  nav.start()
  sbar.exec("SwitchAudioSource -t output -c", function(result)
    current_audio_device = result:sub(1, -2)
    sbar.exec("SwitchAudioSource -a -t output", function(available)
      device_rows = {}
      device_focus = 1

      for device in string.gmatch(available, '[^\r\n]+') do
        local item = sbar.add("item", "volume.device." .. #device_rows, {
          position = "popup." .. volume_bracket.name,
          width = popup_width,
          align = "center",
          label = { string = device },
          background = {
            drawing = true,
            height = 22,
            corner_radius = 4,
            border_width = 0,
            color = colors.transparent,
          },
        })
        device_rows[#device_rows + 1] = { name = device, item = item }
        local index = #device_rows

        -- Clicking a row both switches to it and parks the keyboard there.
        item:subscribe("mouse.clicked", function()
          device_focus = index
          apply_device_focus()
        end)

        -- Opening the popup lands on whatever is playing now, so Enter on an
        -- untouched list is a no-op rather than a surprise.
        if device == current_audio_device then
          device_focus = index
        end
      end

      render_devices()
    end)
  end)
end

-- The panel proper: a real window, in place of the popup below. Same reason as
-- the wifi and agents panels -- sliders, device lists and a keyboard all want a
-- window rather than a stack of bar items. See helpers/volume_panel.
local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local VOL_PANEL = config_dir .. "/helpers/volume_panel/bin/volume_panel"

local function vol_panel_palette()
  local function hex(color)
    return string.format("0x%08x", color)
  end
  return " --foreground " .. hex(colors.text)
    .. " --background " .. hex(colors.base)
    .. " --accent " .. hex(colors.iris)
    .. " --urgent " .. hex(colors.love)
    .. " --muted " .. hex(colors.muted)
    .. " --border " .. hex(colors.popup.border)
end

-- The panel closes itself on blur, so the only case here is a second click on
-- the bar item while it is up.
local function open_volume_panel()
  sbar.exec(
    "pgrep -x volume_panel >/dev/null && echo up "
      .. "|| sketchybar --query bar | /usr/bin/jq -r '.geometry.height // 30'",
    function(out)
      local answer = (out or ""):gsub("^%s*(.-)%s*$", "%1")
      if answer == "up" then
        sbar.exec("pkill -x volume_panel")
        return
      end
      sbar.exec("'" .. VOL_PANEL .. "'" .. vol_panel_palette()
        .. " --font '" .. settings.font.text .. "'"
        .. " --anchor-y " .. (tonumber(answer) or 30)
        .. " >/dev/null 2>&1 &")
    end)
end

volume_icon:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then
    sbar.exec("open /System/Library/PreferencePanes/Sound.prefpane")
    return
  end
  open_volume_panel()
end)

volume_percent:subscribe("mouse.exited.global", volume_collapse_details)

-- Reachable from anywhere: `sketchybar --trigger volume_popup_toggle`, which
-- is how the skhd binding opens it. The handler fakes the left click the
-- toggle expects, since the right-click branch opens System Settings.
sbar.add("event", "volume_popup_toggle")
volume_icon:subscribe("volume_popup_toggle", open_volume_panel)

-- The sketchybar popup still works; it just is not what a click opens now.
sbar.add("event", "volume_popup_toggle_inline")
volume_icon:subscribe("volume_popup_toggle_inline", function()
  volume_toggle_details({ BUTTON = "left" })
end)
