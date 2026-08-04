local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")

local POPUP_WIDTH = 320
local PAD = 22                -- inset of popup content from the popup edges
local ROW_HEIGHT = 22         -- popup.height: sketchybar's per-row height in a popup
local DAY_ROWS = 7
local MODEL_ROWS = 6
local DETAIL_INTERVAL = 120   -- seconds between background refreshes of the popup data

local CONTENT = POPUP_WIDTH - 2 * PAD
local VALUE_W = 54            -- right-hand column holding a percentage, in points
local DAY_CH = 6              -- weekday column, in characters; one wider than "Today"
                              -- so its bold weight cannot push the bar right
local MODEL_CH = 10           -- model-name column, in characters
local VALUE_CH = 8            -- token-count column, in characters, gutter included
local LOGO_W = 26             -- rendered width of the Claude mark in the header
local LOGO_GAP = 10           -- space between the mark and the product name

-- Sketchybar pins a background image to its item's left edge and ignores every
-- padding and offset property, so assets/claude.png carries the mark's inset in
-- its own canvas: a 480px-wide image whose visible mark spans 210..420. Scaling
-- by LOGO_W/210 therefore renders the mark LOGO_W wide, LOGO_W in from the edge.
local LOGO_SCALE = LOGO_W / 210
local LOGO_SPAN = 420 * LOGO_SCALE -- where the mark ends, in points

local TRACK = colors.with_alpha(colors.white, 0.13)
local FILL = colors.with_alpha(colors.white, 0.55)
local BLOCK = colors.with_alpha(colors.white, 0.11)
local DIM = colors.with_alpha(colors.white, 0.45)

local status_cmd = "'" .. config_dir .. "/helpers/agent_status.sh'"
local detail_cmd = "'" .. config_dir .. "/helpers/claude_usage.py'"

-- The popup is set entirely in the same monospace face the clock uses, so it
-- follows whatever `settings.font.numbers` is configured to.
local function font(size, style)
  return {
    family = settings.font.numbers,
    style = settings.font.style_map[style or "Regular"],
    size = size,
  }
end

local ROW_FONT = 10.5
local CHAR_W = ROW_FONT * 0.6 -- monospace advance width, near enough for both SF Mono and JetBrains Mono

-- A slider row's bar starts wherever its icon text ends, so weekday and model
-- names are padded to a fixed character count to hold that edge steady. Values
-- are not padded -- leading spaces make sketchybar truncate the label.
local function pad_right(s, n)
  s = s or ""
  return s .. string.rep(" ", math.max(n - #s, 0))
end

--------------------------------------------------------------------------
-- bar item
--------------------------------------------------------------------------

-- Spacers on both sides: right-positioned items are laid out right-to-left,
-- so the one added before this item is the gap to its right. That side needs
-- the wider pad -- the neighbouring widget brings no padding of its own, and a
-- single group_padding leaves the two icons noticeably tighter than the rest.
sbar.add("item", { position = "right", width = settings.group_paddings * 2 })

local claude = sbar.add("item", "widgets.claude", {
  position = "right",
  drawing = false,
  updates = true, -- keep polling while hidden, so it can bring itself back
  update_freq = 5,
  icon = {
    string = icons.robot,
    font = { family = settings.font.text, style = settings.font.style_map["Regular"], size = 16.0 },
    color = colors.white,
    padding_left = 4,
    padding_right = 4,
  },
  label = { drawing = false },
  popup = {
    align = "center",
    height = ROW_HEIGHT, -- popup rows default to the bar height, which is far too tall
  },
})

sbar.add("item", { position = "right", width = settings.group_paddings })

--------------------------------------------------------------------------
-- popup scaffolding
--------------------------------------------------------------------------

local popup_pos = "popup." .. claude.name

local function row_defaults(opts)
  return {
    position = popup_pos,
    drawing = opts.drawing ~= false,
    padding_left = 0,
    padding_right = 0,
    background = { drawing = false },
    icon = {
      string = opts.icon or "",
      align = "left",
      color = opts.icon_color or colors.white,
      font = opts.icon_font or font(ROW_FONT),
      padding_left = opts.indent or PAD,
      padding_right = 0,
    },
    label = {
      string = opts.label or "",
      align = "right",
      color = opts.label_color or DIM,
      font = opts.label_font or font(ROW_FONT),
      padding_left = 0,
      padding_right = PAD,
    },
  }
end

-- A plain text row: label hugs the right edge, icon takes the rest.
--
-- Measured sizing rules for a plain item: with a label it spans
-- icon.width + label.width, but with no label the icon's left padding adds on
-- top instead. Both cases are normalised to POPUP_WIDTH so that no row is
-- wider than the rest and stretches the popup.
local function add_row(name, opts)
  opts = opts or {}
  local cfg = row_defaults(opts)
  local value_w = opts.label_width or 0
  if value_w > 0 then
    cfg.icon.width = POPUP_WIDTH - value_w
    cfg.label.width = value_w
  else
    cfg.icon.width = POPUP_WIDTH - (opts.indent or PAD)
  end
  return sbar.add("item", name, cfg)
end

-- A row whose middle column is a real progress bar: name | bar | value.
-- Column widths come from the padded strings, so the bar width is whatever is
-- left of CONTENT once those characters are accounted for.
local function add_bar_row(name, opts)
  opts = opts or {}
  local cfg = row_defaults(opts)
  cfg.padding_left = PAD
  cfg.padding_right = PAD
  cfg.scroll_texts = false -- inherited from the defaults, and it truncates these
  cfg.icon.padding_left = 0
  cfg.label.padding_right = 0
  local icon_w = (opts.icon_chars or 0) * CHAR_W
  local value_w = (opts.label_chars or 0) * CHAR_W
  cfg.icon.width = icon_w
  cfg.label.width = value_w
  local text_w = icon_w + value_w
  local thickness = opts.thickness or 4
  cfg.slider = {
    highlight_color = opts.fill or FILL,
    background = {
      height = thickness,
      corner_radius = opts.radius or thickness / 2,
      color = TRACK,
    },
    knob = { drawing = false },
    percentage = 0,
  }
  return sbar.add("slider", name, CONTENT - text_w, cfg)
end

local function add_section(name, title)
  return add_row(name, {
    icon = title,
    icon_color = colors.grey,
    icon_font = font(9.0, "Bold"),
  })
end

-- An empty row. The popup would otherwise start and end flush against its
-- first and last rows; one of these at each end gives it even margins.
local function add_spacer(name)
  return sbar.add("item", name, {
    position = popup_pos,
    width = CONTENT,
    padding_left = 0,
    padding_right = 0,
    icon = { drawing = false },
    label = { drawing = false },
    background = { drawing = false },
  })
end

-- The rule is the item's background: its left padding provides the inset, and
-- only that side is padded, since a right pad shortens the drawn line.
local function add_divider(name)
  return sbar.add("item", name, {
    position = popup_pos,
    width = CONTENT,
    padding_left = 0,
    padding_right = 0,
    icon = { drawing = false },
    label = { drawing = false },
    background = {
      drawing = true,
      height = 1,
      corner_radius = 0,
      border_width = 0,
      color = TRACK,
      padding_left = PAD,
      padding_right = 0,
    },
  })
end

--------------------------------------------------------------------------
-- popup contents
--------------------------------------------------------------------------

-- Header and plan share one structure -- an empty icon acting as the logo
-- gutter, then a left-aligned label -- so their text starts on the same edge.
local function add_header_row(name, opts)
  return sbar.add("item", name, {
    position = popup_pos,
    padding_left = 0,
    padding_right = 0,
    background = { drawing = false },
    icon = {
      string = "",
      width = LOGO_SPAN + LOGO_GAP,
      padding_left = PAD,
      padding_right = 0,
      background = opts.logo and {
        drawing = true,
        color = colors.transparent,
        border_width = 0,
        corner_radius = 0,
        -- nudged down half a row so it centres against both header lines
        y_offset = -ROW_HEIGHT / 2,
        image = {
          string = config_dir .. "/assets/claude.png",
          scale = LOGO_SCALE,
          border_width = 0,
          corner_radius = 0,
        },
      } or { drawing = false },
    },
    label = {
      string = opts.label or "",
      align = "left",
      width = CONTENT - LOGO_SPAN - LOGO_GAP,
      color = opts.color or colors.white,
      font = opts.font,
      padding_left = 0,
      padding_right = PAD,
    },
  })
end

-- The two popup implementations stay separate so each can refresh from its
-- native local data source, while the tabs make them feel like one widget.
local function add_switcher(name)
  return sbar.add("item", name, {
    position = popup_pos,
    width = CONTENT,
    padding_left = 0,
    padding_right = 0,
    icon = {
      string = "Claude Code",
      align = "center",
      width = CONTENT / 2,
      padding_left = 0,
      padding_right = 0,
      color = colors.white,
      font = font(11.5, "Bold"),
      background = {
        drawing = true,
        border_width = 1,
        border_color = colors.white,
        color = BLOCK,
        corner_radius = 0,
        height = ROW_HEIGHT - 2,
      },
    },
    label = {
      string = "Codex",
      align = "center",
      width = CONTENT / 2,
      padding_left = 0,
      padding_right = 0,
      color = colors.white,
      font = font(11.5),
      background = {
        drawing = true,
        border_width = 1,
        border_color = colors.grey,
        color = colors.transparent,
        corner_radius = 0,
        height = ROW_HEIGHT - 2,
      },
    },
    background = { drawing = false },
  })
end

add_spacer("widgets.claude.topper")
local header = add_header_row("widgets.claude.header", {
  label = "Claude Code",
  font = font(14.0, "Bold"),
  logo = true,
})

local plan_row = add_header_row("widgets.claude.plan", {
  font = font(10.0),
  color = colors.grey,
})

local switcher = add_switcher("widgets.claude.switcher")

switcher:subscribe("mouse.clicked", function()
  local codex_visible = _G.codex_visible
  if codex_visible then
    _G.show_codex_content(false)
    _G.show_claude_content(true)
    header:set({ label = { string = "Claude Code" } })
    switcher:set({
      icon = { font = font(11.5, "Bold"), background = { border_color = colors.white, color = BLOCK } },
      label = { font = font(11.5), background = { border_color = colors.grey, color = colors.transparent } },
    })
    _G.codex_visible = false
  else
    _G.show_claude_content(false)
    _G.show_codex_content(true)
    header:set({ label = { string = "Codex" } })
    plan_row:set({ label = { string = "OpenCode" } })
    switcher:set({
      icon = { font = font(11.5), background = { border_color = colors.grey, color = colors.transparent } },
      label = { font = font(11.5, "Bold"), background = { border_color = colors.white, color = BLOCK } },
    })
    _G.codex_visible = true
  end
end)

local divider1 = add_divider("widgets.claude.divider1")
local limits_title = add_section("widgets.claude.limits.title", "LIMITS")

local meters = {}
for _, key in ipairs({ "session", "weekly" }) do
  local base = "widgets.claude." .. key
  meters[key] = {
    head = add_row(base, {
      icon = key == "session" and "Session" or "Weekly",
      icon_font = font(13.0),
      icon_color = colors.white,
      label = "--",
      label_width = VALUE_W,
    }),
    meter = add_bar_row(base .. ".meter", { thickness = 4, radius = 2 }),
    reset = add_row(base .. ".reset", {
      icon = "",
      icon_color = colors.grey,
      icon_font = font(9.5),
    }),
  }
end

local divider2 = add_divider("widgets.claude.divider2")
local days_title = add_section("widgets.claude.days.title", "TOKENS BY DAY")

local day_rows = {}
for i = 1, DAY_ROWS do
  day_rows[i] = add_bar_row("widgets.claude.day." .. i, {
    icon_chars = DAY_CH,
    icon_color = colors.grey,
    label_chars = VALUE_CH,
  })
end

local divider3 = add_divider("widgets.claude.divider3")
local models_title = add_section("widgets.claude.models.title", "TOKENS BY MODEL")

-- Model rows read as filled blocks rather than hairlines, matching the way
-- the reference weights this section more heavily than the daily one.
local model_rows = {}
for i = 1, MODEL_ROWS do
  model_rows[i] = add_bar_row("widgets.claude.model." .. i, {
    icon_chars = MODEL_CH,
    icon_color = colors.white,
    label_chars = VALUE_CH,
    thickness = ROW_HEIGHT - 6,
    radius = 4,
    fill = BLOCK,
  })
end

add_spacer("widgets.claude.footer")

local claude_content = { divider1, limits_title, divider2, days_title, divider3, models_title }
for _, row in pairs(meters) do
  table.insert(claude_content, row.head)
  table.insert(claude_content, row.meter)
  table.insert(claude_content, row.reset)
end
for _, row in ipairs(day_rows) do table.insert(claude_content, row) end
for _, row in ipairs(model_rows) do table.insert(claude_content, row) end

_G.show_claude_content = function(show)
  for _, item in ipairs(claude_content) do item:set({ drawing = show }) end
end

--------------------------------------------------------------------------
-- data
--------------------------------------------------------------------------

local function render(data)
  -- A refresh started while Claude was visible can finish after the user has
  -- switched tabs. It must not redraw Claude rows over the Codex view.
  if _G.codex_visible then return end
  local subscribed = data.subscribed == "1"

  plan_row:set({ label = { string = data.plan and string.upper(data.plan) or "" } })

  -- Limits exist only on a subscription; API-key usage is billed, not capped.
  local show_limits = subscribed and data.limits == "1"
  limits_title:set({ drawing = show_limits })
  divider1:set({ drawing = show_limits })
  for key, row in pairs(meters) do
    local pct = tonumber(data[key .. "_pct"])
    local visible = show_limits and pct ~= nil
    local reset = data[key .. "_reset"]
    row.head:set({ drawing = visible })
    row.meter:set({ drawing = visible })
    row.reset:set({ drawing = visible and reset ~= nil })
    if visible then
      row.head:set({ label = { string = pct .. "%" } })
      row.meter:set({ slider = { percentage = pct } })
      if reset then
        row.reset:set({ icon = { string = "Resets in " .. reset } })
      end
    end
  end

  local shown_days = tonumber(data.days) or 0
  days_title:set({ drawing = shown_days > 0 })
  divider2:set({ drawing = shown_days > 0 })
  for i = 1, DAY_ROWS do
    local entry = data["day." .. i]
    if entry then
      local label, value, pct = entry:match("^([^|]*)|([^|]*)|(%d+)$")
      local today = label == "Today"
      day_rows[i]:set({
        drawing = true,
        icon = {
          string = pad_right(label, DAY_CH),
          color = today and colors.white or colors.grey,
          font = font(ROW_FONT, today and "Bold" or "Regular"),
        },
        label = {
          string = value,
          color = today and colors.white or DIM,
        },
        slider = { percentage = tonumber(pct) or 0 },
      })
    else
      day_rows[i]:set({ drawing = false })
    end
  end

  local shown_models = tonumber(data.models) or 0
  models_title:set({ drawing = shown_models > 0 })
  divider3:set({ drawing = shown_models > 0 })
  for i = 1, MODEL_ROWS do
    local entry = data["model." .. i]
    if entry then
      local label, value, pct = entry:match("^([^|]*)|([^|]*)|(%d+)$")
      model_rows[i]:set({
        drawing = true,
        icon = { string = pad_right(label, MODEL_CH) },
        label = { string = value },
        slider = { percentage = tonumber(pct) or 0 },
      })
    else
      model_rows[i]:set({ drawing = false })
    end
  end
end

local function refresh_detail(callback)
  sbar.exec(detail_cmd .. " 2>/dev/null", function(result)
    local data = {}
    for line in result:gmatch("[^\r\n]+") do
      local key, value = line:match("^([^=]+)=(.*)$")
      if key then data[key] = value end
    end
    render(data)
    if callback then callback() end
  end)
end

switcher:subscribe("mouse.clicked", function()
  if _G.codex_visible then
    _G.codex_visible = false
    _G.show_codex_content(false)
    _G.show_claude_content(true)
    header:set({ drawing = true })
    codex_header:set({ drawing = false })
    switcher:set({
      icon = { font = font(11.5, "Bold"), background = { border_color = colors.white, color = BLOCK } },
      label = { font = font(11.5), background = { border_color = colors.grey, color = colors.transparent } },
    })
    refresh_detail()
  else
    _G.codex_visible = true
    _G.show_claude_content(false)
    _G.show_codex_content(true)
    header:set({ drawing = false })
    codex_header:set({ drawing = true })
    plan_row:set({ label = { string = "OpenCode" } })
    switcher:set({
      icon = { font = font(11.5), background = { border_color = colors.grey, color = colors.transparent } },
      label = { font = font(11.5, "Bold"), background = { border_color = colors.white, color = BLOCK } },
    })
  end
end)

--------------------------------------------------------------------------
-- visibility + interaction
--------------------------------------------------------------------------

local last_detail = 0

local function update_visibility()
  sbar.exec(status_cmd, function(result)
    local state = result:match("(%a+)")
    if not state then return end

    local active = state ~= "none"
    claude:set({ drawing = active })

    if not active then
      claude:set({ popup = { drawing = false } })
      return
    end

    -- Keep the caches warm so opening the popup is instant.
    local now = os.time()
    if now - last_detail >= DETAIL_INTERVAL then
      last_detail = now
      refresh_detail()
    end
  end)
end

local function collapse()
  if claude:query().popup.drawing == "on" then
    claude:set({ popup = { drawing = false } })
  end
end

claude:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then
    collapse()
    return
  end
  if claude:query().popup.drawing == "on" then
    collapse()
  else
    last_detail = os.time()
    refresh_detail(function()
      claude:set({ popup = { drawing = true } })
    end)
  end
end)

claude:subscribe("mouse.exited.global", collapse)
claude:subscribe({ "routine", "forced", "system_woke" }, update_visibility)

update_visibility()
