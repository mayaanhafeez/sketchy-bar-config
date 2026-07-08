local colors = require("colors")
local settings = require("settings")

local hyprspace = os.getenv("HYPRSPACE_BIN") or "/opt/homebrew/bin/hyprspace"
local workspace_ids = { "1", "2", "3", "4", "5", "6"}

sbar.add("event", "hyprspace_workspace_change")

for _, sid in ipairs(workspace_ids) do
  local space = sbar.add("item", "space." .. sid, {
    icon = {
      font = { family = settings.font.numbers },
      string = sid,
      padding_left = 4,
      padding_right = 4,
      color = colors.white,
    },
    label = {
      padding_left = 0,
      padding_right = 0,
      drawing = false,
      color = colors.grey,
      highlight_color = colors.white,
      font = "sketchybar-app-font:Regular:16.0",
      y_offset = -1,
    },
    padding_right = 3,
    padding_left = 3,
    background = {
      color = colors.transparent,
      height = 16,
      corner_radius = 6,
      border_width = 0,
      border_color = colors.transparent,
    },
  })

  sbar.add("item", "space.padding." .. sid, {
    width = 3,
  })

  local current_sid = sid
  space:subscribe("hyprspace_workspace_change", function(env)
    local selected = env.FOCUSED_WORKSPACE == current_sid
    space:set({
      icon = { color = selected and colors.transparent or colors.white },
      label = { highlight = selected },
      background = { color = selected and colors.white or colors.transparent },
    })
  end)

  space:subscribe("mouse.clicked", function(env)
    sbar.exec(hyprspace .. " workspace " .. current_sid)
  end)
end
