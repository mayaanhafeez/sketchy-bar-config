local settings = require("settings")

local M = {}

function M.detect(callback)
  sbar.exec("system_profiler SPDisplaysDataType 2>/dev/null | awk '/Resolution:/{t++} /Built-in.*Display/{b++} END{if(t==b){print \"internal\"}else{print \"external\"}}'", function(output)
    callback(output:match("external") and "external" or "internal")
  end)
end

function M.update_bar_height(display_type)
  local height = display_type == "external" and settings.height_external or settings.height_internal
  sbar.bar({ height = height })
end

return M