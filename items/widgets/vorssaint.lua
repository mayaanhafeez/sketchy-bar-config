local colors = require("colors")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")

-- Clicks the app's real status item, so the same panel the (hidden) menu bar
-- icon would open shows up. Falls back to just activating the app.
local click_menu_bar_item =
  "osascript -e 'tell application \"System Events\" to tell process \"Vorssaint\" "
  .. "to click menu bar item 1 of menu bar 2' || open -a Vorssaint"

local vorssaint = sbar.add("item", "widgets.vorssaint", {
  position = "right",
  drawing = false,
  updates = true, -- keep polling while hidden, so it can bring itself back
  update_freq = 5,
  icon = { drawing = false },
  label = { drawing = false },
  width = 26,
  background = {
    border_width = 0,
    color = colors.transparent,
    image = {
      string = config_dir .. "/assets/vorssaint.png",
      scale = 0.6,
    },
  },
})

local function update_visibility()
  sbar.exec("pgrep -qx Vorssaint && echo on || echo off", function(result)
    vorssaint:set({ drawing = result:match("on") ~= nil })
  end)
end

vorssaint:subscribe({ "routine", "forced", "front_app_switched", "system_woke" }, update_visibility)

vorssaint:subscribe("mouse.clicked", function()
  sbar.exec(click_menu_bar_item)
end)

update_visibility()
