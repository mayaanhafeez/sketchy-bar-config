local colors = require("colors")
local settings = require("settings")

local hyprspace = os.getenv("HYPRSPACE_BIN") or "/opt/homebrew/bin/hyprspace"
local workspace_ids = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
local spaces = {}
local paddings = {}
local focused_workspace

local refresh_spaces

refresh_spaces = function()
  sbar.exec(hyprspace .. " list-workspaces --focused", function(output)
    focused_workspace = output:match("%S+") or focused_workspace

    for _, sid in ipairs(workspace_ids) do
      local selected = sid == focused_workspace
      spaces[sid]:set({
        icon = {
          string = selected and "󱓻" or sid,
          color = colors.white,
        },
        label = { highlight = selected },
      })
    end

    for workspace = 6, 9 do
      local sid = tostring(workspace)
      sbar.exec(hyprspace .. " list-windows --workspace " .. sid .. " --count", function(count)
        local visible = sid == focused_workspace or tonumber(count) > 0
        spaces[sid]:set({ drawing = visible })
        paddings[sid]:set({ drawing = visible })
      end)
    end
  end)
end

sbar.add("event", "hyprspace_workspace_change")
sbar.add("event", "hyprspace_windows_change")

for _, sid in ipairs(workspace_ids) do
  local space = sbar.add("item", "space." .. sid, {
    width = 22,
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

  local padding = sbar.add("item", "space.padding." .. sid, {
    width = 3,
  })
  spaces[sid] = space
  paddings[sid] = padding

  local current_sid = sid
  space:subscribe("hyprspace_workspace_change", function(env)
    local selected = env.FOCUSED_WORKSPACE == current_sid
    space:set({
      icon = {
        string = selected and "󱓻" or current_sid,
        color = colors.white,
      },
      label = { highlight = selected },
    })

    if current_sid == "1" then refresh_spaces() end
  end)

  space:subscribe("mouse.clicked", function(env)
    sbar.exec(hyprspace .. " workspace " .. current_sid)
  end)
end

local window_listener = sbar.add("item", "space.window_listener", {
  drawing = false,
  updates = true,
  update_freq = 2,
})
window_listener:subscribe({ "hyprspace_windows_change", "routine" }, refresh_spaces)

refresh_spaces()
