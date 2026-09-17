local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local display = require("helpers.display")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local AMPHETAMINE = "'" .. config_dir .. "/helpers/amphetamine.sh'"

-- Deliberately no separate padding item: this one moves between the widget row
-- and the centred clock, and a sibling spacer would get left behind. The gap
-- lives in the icon's own padding instead.
local amphetamine = sbar.add("item", "widgets.amphetamine", {
  position = "right",
  icon = {
    string = icons.amphetamine.off,
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Regular"],
      size = 12.0,
    },
    color = colors.grey,
    padding_left = 4,
    padding_right = 4,
  },
  label = { drawing = false },
  background = { border_width = 0 },
  update_freq = 5,
})

-- The cup keeps its spot either way and says which state it is in by its
-- shape: filled and at full strength while a session is up, outlined and
-- dimmed to the muted grey the rest of the bar uses for "off" when it is not.
local function refresh()
  sbar.exec(AMPHETAMINE .. " get", function(out)
    local active = (out or ""):match("active=1") ~= nil
    amphetamine:set({
      icon = {
        string = active and icons.amphetamine.on or icons.amphetamine.off,
        color = active and colors.text or colors.grey,
      },
    })
  end)
end

-- Right-hand widget row on the built-in display, immediately left of the clock
-- once the clock moves to the centre. Item order decides both, and for
-- right-anchored items the list runs right to left -- hence "after" the
-- battery's trailing padding to land on the battery's left.
local function update_position(display_type)
  if display_type == "external" then
    amphetamine:set({ position = "center" })
    sbar.exec("sketchybar --move widgets.amphetamine before calendar")
  else
    amphetamine:set({ position = "right" })
    sbar.exec("sketchybar --move widgets.amphetamine after widgets.battery.padding")
  end
end

amphetamine:subscribe({ "routine", "forced", "system_woke" }, refresh)

amphetamine:subscribe("display_change", function()
  display.detect(update_position)
end)

-- Left toggles an indefinite session, right opens Amphetamine's own menu. The
-- toggle repaints straight away rather than waiting for the next routine tick,
-- which would otherwise leave the cup showing the old state for a few seconds
-- after the click.
local function toggle_session()
  sbar.exec(AMPHETAMINE .. " toggle", refresh)
end

amphetamine:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then
    sbar.exec(AMPHETAMINE .. " menu")
  else
    toggle_session()
  end
end)

-- What the skhd binding hits: `sketchybar --trigger amphetamine_toggle`.
sbar.add("event", "amphetamine_toggle")
amphetamine:subscribe("amphetamine_toggle", toggle_session)

display.detect(update_position)

-- routine only comes around every update_freq seconds, so without this an
-- active session would show the dimmed cup for the first few seconds after a
-- reload.
refresh()
