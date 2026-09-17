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
  drawing = false,
  icon = {
    string = icons.amphetamine,
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Regular"],
      size = 12.0,
    },
    color = colors.text,
    padding_left = 4,
    padding_right = 4,
  },
  label = { drawing = false },
  background = { border_width = 0 },
  update_freq = 5,
  -- `updates` defaults to when_shown, which would be a one-way trip: the
  -- item hides itself when the session ends and then never polls again to
  -- notice the next one starting.
  updates = true,
})

-- The bar only carries the cup while a session is up; an idle Amphetamine is
-- the default state and does not need a permanent reminder.
local function refresh()
  sbar.exec(AMPHETAMINE .. " get", function(out)
    amphetamine:set({ drawing = (out or ""):match("active=1") ~= nil })
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
-- which would otherwise leave the cup lingering for a few seconds after the
-- session ends.
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
-- active session would go unmarked for the first few seconds after a reload.
refresh()
