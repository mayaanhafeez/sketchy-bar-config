local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local display = require("helpers.display")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local AMPHETAMINE = "'" .. config_dir .. "/helpers/amphetamine.sh'"
local CURSOR_ON_BAR = "'" .. config_dir .. "/helpers/cursor_on_bar/bin/cursor_on_bar'"

-- A fixed box rather than whatever each glyph happens to measure: the filled
-- cup is a pixel wider than the outline, and the mirror below has to be able
-- to match this width exactly for the clock to stay put.
local CUP_WIDTH = 26

-- Five seconds is plenty for a cup nobody is looking at. While the pointer is
-- on the bar the same tick doubles as the hover safety net further down, so it
-- runs often enough that a missed exit event is corrected before it registers
-- as a stuck icon.
local TICK_IDLE = 5
local TICK_HOVER = 1

local amphetamine = sbar.add("item", "widgets.amphetamine", {
  position = "right",
  drawing = false,
  width = CUP_WIDTH,
  padding_left = 0,
  padding_right = 0,
  icon = {
    string = icons.amphetamine.off,
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Regular"],
      size = 12.0,
    },
    color = colors.grey,
    width = CUP_WIDTH,
    align = "center",
    padding_left = 0,
    padding_right = 0,
  },
  label = { drawing = false },
  background = { border_width = 0 },
  update_freq = TICK_IDLE,
  -- Load-bearing, and the whole reason hover works. `when_shown` -- the default
  -- -- stops delivering events to an item that is not drawn, including the
  -- hover events this one needs in order to come back, so hiding itself would
  -- be a one-way trip.
  updates = true,
})

-- Centring centres the whole centre group, so a cup appearing to the clock's
-- left drags the clock right by half its width. This sits on the clock's right
-- and comes and goes with the cup, keeping the group symmetrical about the
-- clock so the clock itself never moves. Only earns its keep while the clock is
-- centred; in the widget row there is nothing to balance.
local mirror = sbar.add("item", "widgets.amphetamine.mirror", {
  position = "right",
  drawing = false,
  width = CUP_WIDTH,
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  label = { drawing = false },
})

local active = false
local hovering = false
local centred = false
local bar_height = settings.height_external

-- An idle Amphetamine is the ordinary state and does not earn permanent space,
-- so the dimmed outline only surfaces while the cursor is on the bar. A running
-- session is the thing worth catching out of the corner of an eye, so the
-- filled cup stays put whether or not anyone is pointing at it.
local function render()
  local visible = active or hovering
  amphetamine:set({
    drawing = visible,
    icon = {
      string = active and icons.amphetamine.on or icons.amphetamine.off,
      color = active and colors.text or colors.grey,
    },
  })
  mirror:set({ drawing = centred and visible })
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
local function set_hovering(value)
  if hovering == value then return end
  hovering = value
  amphetamine:set({ update_freq = value and TICK_HOVER or TICK_IDLE })
  render()
end

amphetamine:subscribe("mouse.entered.global", function()
  set_hovering(true)
  -- The cup is about to become visible, so give it the current answer rather
  -- than whatever the last routine tick left behind.
  refresh()
end)

amphetamine:subscribe("mouse.exited.global", function()
  set_hovering(false)
end)

-- mouse.exited.global is how the cup normally learns to put itself away, but it
-- does not always arrive: cross into sketchybar-toggle's trigger zone and the
-- bar can be hidden out from under the pointer before sketchybar works out that
-- it left, so the event is never sent and the cup sits there until something
-- else disturbs it. Asking where the pointer actually is puts a floor under
-- that. Only ever runs while the cup is up for hover reasons, so the usual case
-- costs nothing, and a helper that is missing or unbuilt just leaves the old
-- event-only behaviour in place.
local function verify_hover()
  if not hovering then return end
  sbar.exec(CURSOR_ON_BAR .. " " .. bar_height, function(out)
    if (out or ""):match("off") then set_hovering(false) end
  end)
end

-- Right-hand widget row on the built-in display, immediately left of the clock
-- once the clock moves to the centre. Item order decides both, and for
-- right-anchored items the list runs right to left -- hence "after" the
-- battery's trailing padding to land on the battery's left.
local function update_position(display_type)
  centred = display_type == "external"
  bar_height = centred and settings.height_external or settings.height_internal
  if centred then
    amphetamine:set({ position = "center" })
    mirror:set({ position = "center" })
    sbar.exec("sketchybar --move widgets.amphetamine before calendar"
      .. " --move widgets.amphetamine.mirror after calendar")
  else
    amphetamine:set({ position = "right" })
    mirror:set({ position = "right" })
    sbar.exec("sketchybar --move widgets.amphetamine after widgets.battery.padding")
  end
  render()
end

-- Still polled, even though the cup is usually out of sight: a session can
-- start or end from Amphetamine's own menu or a Trigger, and the bar should
-- not be waiting on a hover to find that out.
amphetamine:subscribe({ "routine", "forced", "system_woke" }, function()
  refresh()
  verify_hover()
end)

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
