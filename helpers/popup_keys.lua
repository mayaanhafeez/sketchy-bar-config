-- Keyboard control for popups.
--
-- Sketchybar cannot receive key events, so each popup that wants them runs
-- helpers/popup_keys/bin/popup_keys while it is open; that helper holds key
-- focus and triggers a custom event per keystroke, with the key name in $KEY.
-- This module owns both halves of that: it registers the event, subscribes a
-- hidden item to it, and starts/stops the helper.
--
--   local keys = require("helpers.popup_keys")
--   local nav = keys.bind("wifi", function(key) ... end)
--   nav.start()   -- popup opened
--   nav.stop()    -- popup closed
--
-- Only one grabber runs at a time: start() kills any other first, because two
-- of them would fight over key focus and the losing popup would go deaf. That
-- matches how the bar behaves anyway -- opening a popup closes the last one.
local M = {}

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local BIN = "'" .. config_dir .. "/helpers/popup_keys/bin/popup_keys'"

-- -x matches the process name exactly, so it cannot match the shell running
-- the line that spawns the next grabber.
local KILL = "pkill -x popup_keys >/dev/null 2>&1"

function M.stop_all()
  sbar.exec(KILL .. " || true")
end

function M.bind(name, handler)
  local event = "popup_key_" .. name
  sbar.add("event", event)

  -- The listener is a bar item rather than a popup one: popup items only
  -- process events while their popup is drawn, and this has to keep working
  -- for the keystroke that closes it.
  local listener = sbar.add("item", "keys." .. name, {
    drawing = false,
    updates = true,
  })

  listener:subscribe(event, function(env)
    local key = env.KEY
    if key and key ~= "" then handler(key) end
  end)

  local nav = {}

  function nav.start()
    sbar.exec(KILL .. "; " .. BIN .. " --event " .. event .. " >/dev/null 2>&1 &")
  end

  function nav.stop()
    M.stop_all()
  end

  return nav
end

return M
