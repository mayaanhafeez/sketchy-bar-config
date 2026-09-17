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
  -- Load-bearing, and the whole reason hover works. `when_shown` -- the default
  -- -- stops delivering events to an item that is not drawn, including the
  -- hover events this one needs in order to come back, so hiding itself would
  -- be a one-way trip.
  updates = true,
})

local active = false
local hovering = false

-- An idle Amphetamine is the ordinary state and does not earn permanent space,
-- so the dimmed outline only surfaces while the cursor is on the bar. A running
-- session is the thing worth catching out of the corner of an eye, so the
-- filled cup stays put whether or not anyone is pointing at it.
local function render()
  amphetamine:set({
    drawing = active or hovering,
    icon = {
      string = active and icons.amphetamine.on or icons.amphetamine.off,
      color = active and colors.text or colors.grey,
    },
  })
end

local function refresh()
  sbar.exec(AMPHETAMINE .. " get", function(out)
    active = (out or ""):match("active=1") ~= nil
    render()
  end)
end

-- The ".global" pair is about the bar as a whole rather than this item: they
-- fire over empty stretches of bar too, which is the only reason an item that
-- has hidden itself is reachable again. Hover costs nothing to watch -- these
-- arrive as events, so there is no cursor polling anywhere in here.
amphetamine:subscribe("mouse.entered.global", function()
  hovering = true
  render()
  -- The cup is about to become visible, so give it the current answer rather
  -- than whatever the last routine tick left behind.
  refresh()
end)

amphetamine:subscribe("mouse.exited.global", function()
  hovering = false
  render()
end)

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

-- Still polled, even though the cup is usually out of sight: a session can
-- start or end from Amphetamine's own menu or a Trigger, and the bar should
-- not be waiting on a hover to find that out.
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

-- routine only comes around every update_freq seconds, so without this a live
-- session would go unmarked for the first few seconds after a reload.
refresh()
