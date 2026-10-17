-- Reuse the previous config's keyboard helper without a global sbar variable.
local sbar = require("sketchybar")
local config = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local M = {}

function M.stop_all()
  sbar.exec("pkill -x popup_keys >/dev/null 2>&1 || true")
end

function M.bind(name, handler)
  local event = "popup_key_" .. name:gsub("%W", "_")
  sbar.add("event", event)
  local listener = sbar.add("item", "keys." .. name, { drawing = false, updates = true })
  listener:subscribe(event, function(env)
    if env.KEY then handler(env.KEY) end
  end)
  return {
    start = function()
      sbar.exec("pkill -x popup_keys >/dev/null 2>&1; "
        .. quote(config .. "/helpers/popup_keys/bin/popup_keys")
        .. " --event " .. quote(event) .. " >/dev/null 2>&1 &")
    end,
    stop = M.stop_all,
  }
end

return M
