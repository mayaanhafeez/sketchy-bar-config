local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local keys = require("helpers.popup_keys")

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
local BLOCK_FILL = colors.with_alpha(colors.white, 0.20)
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
local CHAR_W = ROW_FONT * 0.6 -- monospace advance width, exact for JetBrains Mono

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

-- A model row in the reference style: one full-width block with the name and
-- value set inside it, and a proportional fill behind the text. The whole
-- text is a single CONTENT-wide monospace icon string -- name left, value
-- padded to the right edge -- and the fill is that element's background,
-- shortened from the right with background.padding_right. Backgrounds and
-- their paddings never enter sketchybar's item length, so no percentage can
-- stretch the popup.
local BLOCK_H = ROW_HEIGHT - 6
local BLOCK_CH = math.floor(CONTENT / CHAR_W)

local function add_block_row(name)
  return sbar.add("item", name, {
    position = popup_pos,
    width = CONTENT,
    padding_left = PAD,
    padding_right = PAD,
    -- The item background spans the full row including the item paddings, so
    -- it is padded back to CONTENT: the left pad shifts its start to the text
    -- edge, and the right pad shortens it by both insets.
    background = {
      drawing = true,
      color = BLOCK,
      height = BLOCK_H,
      corner_radius = 4,
      border_width = 0,
      padding_left = PAD,
      padding_right = PAD * 2,
    },
    icon = {
      string = "",
      align = "left",
      width = CONTENT,
      padding_left = 0,
      padding_right = 0,
      color = colors.white,
      font = font(ROW_FONT),
      background = {
        drawing = false,
        color = BLOCK_FILL,
        height = BLOCK_H,
        corner_radius = 4,
        border_width = 0,
      },
    },
    label = { drawing = false },
  })
end

-- Composes " name        value " to the block's full character width so the
-- value lands on the right edge. The icon keeps rendering that full text, while
-- its fixed width independently controls the background fill.
local function set_block_row(item, name, value, pct)
  name = name or ""
  value = value or ""
  local inner = BLOCK_CH - 2
  local max_name = inner - #value - 2
  if #name > max_name then
    name = name:sub(1, math.max(max_name - 2, 1)) .. ".."
  end
  local text = " " .. name .. string.rep(" ", math.max(inner - #name - #value, 1)) .. value .. " "
  local fill = math.floor(CONTENT * (tonumber(pct) or 0) / 100 + 0.5)
  item:set({
    drawing = true,
    icon = {
      string = text,
      width = fill,
      background = { drawing = fill > 2 },
    },
  })
end

_G.add_ai_block_row = add_block_row
_G.set_ai_block_row = set_block_row

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

-- The rule is the item's background. An item background spans the content
-- between the item paddings (its own padding properties are ignored), so the
-- line is a CONTENT-wide blank icon between two PAD item paddings -- exactly
-- how the block rows land on the same edges.
local function add_divider(name)
  return sbar.add("item", name, {
    position = popup_pos,
    padding_left = PAD,
    padding_right = PAD,
    icon = {
      string = "",
      align = "left",
      width = CONTENT,
      padding_left = 0,
      padding_right = 0,
      font = font(ROW_FONT),
    },
    label = { drawing = false },
    background = {
      drawing = true,
      height = 1,
      corner_radius = 0,
      border_width = 0,
      color = TRACK,
    },
  })
end

_G.add_ai_divider = add_divider

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
      align = "left",
      width = LOGO_SPAN + LOGO_GAP,
      padding_left = PAD,
      padding_right = 0,
      color = colors.white,
      font = { family = settings.font.text, style = settings.font.style_map["Bold"], size = 13.0 },
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
local TAB_GAP = 8
local TAB_W = CONTENT / 2 - TAB_GAP / 2

local function add_switcher(name)
  return sbar.add("item", name, {
    position = popup_pos,
    -- Popup items only process events while shown, so the tab would refuse to
    -- switch from the CLI unless the popup happened to be open at the time.
    updates = true,
    padding_left = PAD,
    padding_right = PAD,
    icon = {
      string = "Claude Code",
      align = "center",
      width = TAB_W,
      padding_left = 0,
      padding_right = TAB_GAP,
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
      width = TAB_W,
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
    label_chars = 8,
  })
end

local divider3 = add_divider("widgets.claude.divider3")
local models_title = add_section("widgets.claude.models.title", "TOKENS BY MODEL")

local model_rows = {}
for i = 1, MODEL_ROWS do
  model_rows[i] = add_block_row("widgets.claude.model." .. i)
end

-- The footer hides with the rest of the tab. Left drawn it would sit between
-- the switcher and the Codex rows below it -- popup rows stack in creation
-- order -- padding the Codex tab one row lower than the Claude one.
local footer = add_spacer("widgets.claude.footer")

local claude_content = { divider1, limits_title, divider2, days_title, divider3, models_title, footer }
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
-- tab state
--------------------------------------------------------------------------

-- One source of truth for which tab is showing. Everything that switches --
-- highlight, header, plan line, row visibility -- goes through set_tab, so no
-- click can leave the pieces disagreeing with each other.
local current_tab = "claude"
_G.ai_tab = "claude"

local last_plan = ""    -- Claude's plan line, cached from the last render
local codex_plan = ""   -- Codex's, pushed in by codex.lua

_G.set_codex_plan = function(plan)
  codex_plan = plan or ""
  if current_tab == "codex" then
    plan_row:set({ label = { string = codex_plan } })
  end
end

local TAB_ACTIVE = { border_color = colors.white, color = BLOCK }
local TAB_IDLE = { border_color = colors.grey, color = colors.transparent }

local function apply_tab_style()
  local on_claude = current_tab == "claude"
  switcher:set({
    icon = {
      font = font(11.5, on_claude and "Bold" or "Regular"),
      background = on_claude and TAB_ACTIVE or TAB_IDLE,
    },
    label = {
      font = font(11.5, on_claude and "Regular" or "Bold"),
      background = on_claude and TAB_IDLE or TAB_ACTIVE,
    },
  })
end

-- The header never hides; it swaps identity. That keeps the switcher on the
-- same line no matter which tab is up. Codex has no bundled asset, so its
-- mark is a terminal glyph drawn in the same gutter the Claude logo uses.
local function apply_header()
  if current_tab == "claude" then
    header:set({
      icon = { string = "", background = { drawing = true } },
      label = { string = "Claude Code" },
    })
    plan_row:set({ label = { string = last_plan } })
  else
    header:set({
      icon = { string = "❯_", y_offset = 0, background = { drawing = false } },
      label = { string = "Codex" },
    })
    plan_row:set({ label = { string = codex_plan } })
  end
end

--------------------------------------------------------------------------
-- data
--------------------------------------------------------------------------

local last_data = nil

local function render(data)
  last_data = data
  last_plan = data.plan and string.upper(data.plan) or ""

  -- A refresh started while Claude was visible can finish after the user has
  -- switched tabs. It must not redraw Claude rows over the Codex view.
  if current_tab ~= "claude" then return end
  local subscribed = data.subscribed == "1"

  plan_row:set({ label = { string = last_plan } })

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
    local label, value, pct
    if entry then
      label, value, pct = entry:match("^([^|]*)|([^|]*)|(%d+)$")
    end
    if label and #label > 0 then
      set_block_row(model_rows[i], label, value, pct)
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

--------------------------------------------------------------------------
-- tab switching
--------------------------------------------------------------------------

local function set_tab(tab)
  if tab == current_tab then return end
  current_tab = tab
  _G.ai_tab = tab
  if tab == "claude" then
    _G.show_codex_content(false)
    _G.show_claude_content(true)
    if last_data then render(last_data) end
    refresh_detail()
  else
    _G.show_claude_content(false)
    _G.show_codex_content(true)
  end
  apply_header()
  apply_tab_style()
end

local function toggle_tab()
  set_tab(current_tab == "claude" and "codex" or "claude")
end

switcher:subscribe("mouse.clicked", toggle_tab)
-- Also reachable from the CLI: `sketchybar --trigger ai_tab_toggle`, which
-- needs the custom event to exist before anything can subscribe to it.
sbar.add("event", "ai_tab_toggle")
switcher:subscribe("ai_tab_toggle", toggle_tab)

--------------------------------------------------------------------------
-- visibility + interaction
--------------------------------------------------------------------------

local last_detail = 0

-- Assigned once collapse() exists, since the key handler closes the popup.
local nav

-- Whether the bar item is currently drawn. The widget hides itself when no
-- agent is running, and a popup has nothing to hang off then.
local widget_active = false

local function update_visibility()
  sbar.exec(status_cmd, function(result)
    local state = result:match("(%a+)")
    if not state then return end

    local active = state ~= "none"
    widget_active = active
    claude:set({ drawing = active })

    if not active then
      claude:set({ popup = { drawing = false } })
      nav.stop()
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
  nav.stop()
end

-- Left and right walk the tabs. With exactly two of them either direction
-- lands on the other one, so both arrows go through the same toggle the tab
-- strip uses -- no separate ordering to keep in sync with the switcher.
nav = keys.bind("claude", function(key)
  if key == "escape" then
    collapse()
  elseif key == "left" or key == "right" then
    toggle_tab()
  end
end)

local function toggle_popup()
  if claude:query().popup.drawing == "on" then
    collapse()
    return
  end
  last_detail = os.time()
  if current_tab == "codex" and _G.refresh_codex then _G.refresh_codex() end
  refresh_detail(function()
    claude:set({ popup = { drawing = true } })
    nav.start()
  end)
end

claude:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then
    collapse()
    return
  end
  toggle_popup()
end)

-- What the skhd binding hits: `sketchybar --trigger agents_popup_toggle`.
-- Ignored while the widget is hidden, since there is no icon on the bar for
-- the panel to drop out of.
sbar.add("event", "agents_popup_toggle")
claude:subscribe("agents_popup_toggle", function()
  if not widget_active then return end
  toggle_popup()
end)

claude:subscribe("mouse.exited.global", collapse)
claude:subscribe({ "routine", "forced", "system_woke" }, update_visibility)

update_visibility()
