local colors = require("colors")
local settings = require("settings")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local POPUP_WIDTH, PAD, ROW_HEIGHT = 320, 22, 22
local CONTENT, DAY_ROWS, MODEL_ROWS = POPUP_WIDTH - 2 * PAD, 7, 6
local TRACK = colors.with_alpha(colors.white, 0.13)
local FILL = colors.with_alpha(colors.white, 0.55)
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

local function spacer(name)
  return item(name, { width = CONTENT, padding_left = 0, padding_right = 0, icon = { drawing = false }, label = { drawing = false }, background = { drawing = false } })
end

local function divider(name)
  local line = _G.add_ai_divider(name)
  line:set({ drawing = false })
  return line
end

local divider1 = divider("widgets.codex.divider1")
local limits_title = row("widgets.codex.limits.title", { icon = "LIMITS", icon_color = colors.grey, icon_font = font(9, "Bold") })

-- Codex enforces a rolling 5-hour cap alongside the weekly one, so both get a
-- meter here. Rows are added in this order because a popup lays its items out
-- in the order they were created.
local LIMITS = { { key = "session", title = "Session" }, { key = "weekly", title = "Weekly" } }
local meters = {}
for _, limit in ipairs(LIMITS) do
  local base = "widgets.codex." .. limit.key
  meters[limit.key] = {
    head = row(base, { icon = limit.title, icon_font = font(13), label = "--", label_width = VALUE_W }),
    meter = slider(base .. ".meter", 0, 0),
    reset = row(base .. ".reset", { icon = "", icon_color = colors.grey, icon_font = font(9.5) }),
  }
end
local divider_limits = divider("widgets.codex.divider.limits")
local days_title = row("widgets.codex.days.title", { icon = "TOKENS BY DAY", icon_color = colors.grey, icon_font = font(9, "Bold") })
local day_rows = {}
for i = 1, DAY_ROWS do day_rows[i] = slider("widgets.codex.day." .. i, 6, 8) end
local divider2 = divider("widgets.codex.divider2")
local models_title = row("widgets.codex.models.title", { icon = "TOKENS BY MODEL", icon_color = colors.grey, icon_font = font(9, "Bold") })

-- Model rows use the shared block style defined by the Claude widget: name and
-- value composed inside one full-width block, fill drawn behind the text.
local model_rows = {}
for i = 1, MODEL_ROWS do
  local block = _G.add_ai_block_row("widgets.codex.model." .. i)
  block:set({ drawing = false })
  model_rows[i] = block
end
local footer = spacer("widgets.codex.footer")

local content = { divider1, limits_title, divider_limits, days_title, divider2, models_title, footer }
for _, limit in ipairs(LIMITS) do
  local entry = meters[limit.key]
  table.insert(content, entry.head)
  table.insert(content, entry.meter)
  table.insert(content, entry.reset)
end
for _, entry in ipairs(day_rows) do table.insert(content, entry) end
for _, entry in ipairs(model_rows) do table.insert(content, entry) end

local function render(data)
  _G.set_codex_plan(data.plan and string.upper(data.plan) or "OPENCODE")
  -- Before the tab guard below: the bar icon answers for both providers, so it
  -- has to hear about Codex even while Claude is the tab on screen.
  if _G.set_ai_alarm then
    local hot = false
    for _, key in ipairs({ "session", "weekly" }) do
      local pct = tonumber(data[key .. "_pct"])
      if pct and pct >= 90 then hot = true end
    end
    _G.set_ai_alarm("codex", hot)
  end
  -- A slow refresh must not repaint Codex rows after switching back to Claude.
  if _G.ai_tab ~= "codex" then return end
  local any_limit = false
  for _, limit in ipairs(LIMITS) do
    local entry = meters[limit.key]
    local pct = tonumber(data[limit.key .. "_pct"])
    local reset = data[limit.key .. "_reset"]
    any_limit = any_limit or pct ~= nil
    entry.head:set({ drawing = pct ~= nil, label = { string = pct and pct .. "%" or "--" } })
    entry.meter:set({ drawing = pct ~= nil, slider = { percentage = pct or 0 } })
    entry.reset:set({ drawing = pct ~= nil and reset ~= nil, icon = { string = reset and "Resets in " .. reset or "" } })
  end
  limits_title:set({ drawing = any_limit })
  divider_limits:set({ drawing = any_limit })
  for i = 1, DAY_ROWS do
    local label, value, pct = (data["day." .. i] or ""):match("^([^|]*)|([^|]*)|(%d+)$")
    local today = label == "Today"
    day_rows[i]:set({ drawing = label ~= nil, icon = { string = pad_right(label, 6), color = today and colors.white or colors.grey, font = font(10.5, today and "Bold" or "Regular") }, label = { string = value or "", color = today and colors.white or DIM }, slider = { percentage = tonumber(pct) or 0 } })
  end
  for i = 1, MODEL_ROWS do
    local label, value, pct = (data["model." .. i] or ""):match("^([^|]*)|([^|]*)|(%d+)$")
    if label and #label > 0 then
      _G.set_ai_block_row(model_rows[i], label, value, pct)
    else
      model_rows[i]:set({ drawing = false })
    end
  end
end

local function refresh()
  sbar.exec(detail_cmd .. " 2>/dev/null", function(result)
    local data = {}
    for line in result:gmatch("[^\r\n]+") do local key, value = line:match("^([^=]+)=(.*)$"); if key then data[key] = value end end
    render(data)
  end)
end

_G.refresh_codex = refresh

_G.show_codex_content = function(show)
  for _, entry in ipairs(content) do entry:set({ drawing = show }) end
  if show then refresh() end
end
