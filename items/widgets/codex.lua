local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local POPUP_WIDTH, PAD, ROW_HEIGHT = 320, 22, 22
local CONTENT, DAY_ROWS, MODEL_ROWS = POPUP_WIDTH - 2 * PAD, 7, 6
local TRACK = colors.with_alpha(colors.white, 0.13)
local FILL = colors.with_alpha(colors.white, 0.55)
local BLOCK = colors.with_alpha(colors.white, 0.11)
local DIM = colors.with_alpha(colors.white, 0.45)
local VALUE_W = 54
local detail_cmd = "'" .. config_dir .. "/helpers/codex_usage.py'"
local popup_pos = "popup.widgets.claude"

local function font(size, style)
  return { family = settings.font.numbers, style = settings.font.style_map[style or "Regular"], size = size }
end

local function pad_right(text, width)
  return (text or "") .. string.rep(" ", math.max(width - #(text or ""), 0))
end

local function item(name, config)
  config.position = popup_pos
  config.drawing = false
  return sbar.add("item", name, config)
end

local function row(name, opts)
  opts = opts or {}
  return item(name, {
    width = opts.width or CONTENT, padding_left = 0, padding_right = 0,
    icon = { string = opts.icon or "", align = "left", color = opts.icon_color or colors.white, font = opts.icon_font or font(10.5), padding_left = opts.indent or PAD, padding_right = 0, width = opts.icon_width },
    label = { string = opts.label or "", align = "right", color = opts.label_color or DIM, font = opts.label_font or font(10.5), padding_left = 0, padding_right = PAD, width = opts.label_width },
    background = opts.background or { drawing = false },
  })
end

local function slider(name, chars, value_chars, thickness, fill)
  local char_w = 10.5 * 0.6
  return sbar.add("slider", name, CONTENT - (chars + value_chars) * char_w, {
    position = popup_pos, drawing = false, padding_left = PAD, padding_right = PAD,
    icon = { string = "", width = chars * char_w, align = "left", color = colors.grey, font = font(10.5), padding_left = 0, padding_right = 0 },
    label = { string = "", width = value_chars * char_w, align = "right", color = DIM, font = font(10.5), padding_left = 0, padding_right = 0 },
    slider = { percentage = 0, highlight_color = fill or FILL, background = { height = thickness or 4, corner_radius = 2, color = TRACK }, knob = { drawing = false } },
    background = { drawing = false },
  })
end

local divider1 = row("widgets.codex.divider1", { background = { drawing = true, height = 1, corner_radius = 0, border_width = 0, color = TRACK, padding_left = PAD, padding_right = 0 } })
local limits_title = row("widgets.codex.limits.title", { icon = "LIMITS", icon_color = colors.grey, icon_font = font(9, "Bold") })
local weekly_head = row("widgets.codex.weekly", { icon = "Weekly", icon_font = font(13), label = "--", label_width = VALUE_W })
local weekly_meter = slider("widgets.codex.weekly.meter", 0, 0)
local weekly_reset = row("widgets.codex.weekly.reset", { icon = "", icon_color = colors.grey, icon_font = font(9.5) })
local divider_limits = row("widgets.codex.divider.limits", { background = { drawing = true, height = 1, corner_radius = 0, border_width = 0, color = TRACK, padding_left = PAD, padding_right = 0 } })
local days_title = row("widgets.codex.days.title", { icon = "TOKENS BY DAY", icon_color = colors.grey, icon_font = font(9, "Bold") })
local day_rows = {}
for i = 1, DAY_ROWS do day_rows[i] = slider("widgets.codex.day." .. i, 6, 8) end
local divider2 = row("widgets.codex.divider2", { background = { drawing = true, height = 1, corner_radius = 0, border_width = 0, color = TRACK, padding_left = PAD, padding_right = 0 } })
local models_title = row("widgets.codex.models.title", { icon = "TOKENS BY MODEL", icon_color = colors.grey, icon_font = font(9, "Bold") })
local model_rows = {}
for i = 1, MODEL_ROWS do model_rows[i] = slider("widgets.codex.model." .. i, 10, 8, ROW_HEIGHT - 6, BLOCK) end

local content = { divider1, limits_title, weekly_head, weekly_meter, weekly_reset, divider_limits, days_title, divider2, models_title }
for _, entry in ipairs(day_rows) do table.insert(content, entry) end
for _, entry in ipairs(model_rows) do table.insert(content, entry) end

local function render(data)
  local weekly = tonumber(data.weekly_pct)
  local show_weekly = weekly ~= nil
  limits_title:set({ drawing = show_weekly })
  weekly_head:set({ drawing = show_weekly, label = { string = weekly and weekly .. "%" or "--" } })
  weekly_meter:set({ drawing = show_weekly, slider = { percentage = weekly or 0 } })
  weekly_reset:set({ drawing = show_weekly and data.weekly_reset ~= nil, icon = { string = data.weekly_reset and "Resets in " .. data.weekly_reset or "" } })
  divider_limits:set({ drawing = show_weekly })
  for i = 1, DAY_ROWS do
    local label, value, pct = (data["day." .. i] or ""):match("^([^|]*)|([^|]*)|(%d+)$")
    local today = label == "Today"
    day_rows[i]:set({ drawing = label ~= nil, icon = { string = pad_right(label, 6), color = today and colors.white or colors.grey, font = font(10.5, today and "Bold" or "Regular") }, label = { string = value or "", color = today and colors.white or DIM }, slider = { percentage = tonumber(pct) or 0 } })
  end
  for i = 1, MODEL_ROWS do
    local label, value, pct = (data["model." .. i] or ""):match("^([^|]*)|([^|]*)|(%d+)$")
    model_rows[i]:set({ drawing = label ~= nil, icon = { string = pad_right(label, 10) }, label = { string = value or "" }, slider = { percentage = tonumber(pct) or 0 } })
  end
end

local function refresh()
  sbar.exec(detail_cmd .. " 2>/dev/null", function(result)
    local data = {}
    for line in result:gmatch("[^\r\n]+") do local key, value = line:match("^([^=]+)=(.*)$"); if key then data[key] = value end end
    render(data)
  end)
end

_G.show_codex_content = function(show)
  for _, entry in ipairs(content) do entry:set({ drawing = show }) end
  if show then refresh() end
end
