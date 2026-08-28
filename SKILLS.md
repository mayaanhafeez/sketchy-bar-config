# SketchyBar — Agent Skills Reference

Working reference for agents editing this config. Covers the SketchyBar API in full,
the SbarLua binding this repo actually uses, and this repo's own conventions.

**If you are building or changing a popup, read §4 first.** SketchyBar has no layout
engine; every panel here is faked with fixed widths, monospace padding and background
rectangles, and the rules that make it work are measured behavior rather than documented
API.

Sources: SketchyBar docs (`documentation` branch of FelixKratz/SketchyBar),
[SbarLua](https://github.com/FelixKratz/SbarLua).

---

## 1. Orientation — what this repo is

**This is a Lua config, not a shell config.** `sketchybarrc` is a `#!/usr/bin/env lua`
script that loads the SbarLua C module and runs an event loop. Nearly every SketchyBar
tutorial you'll find online is bash (`sketchybar --add item ...`). Do **not** paste bash
config into this repo — translate it (§6).

```
sketchybarrc          entry point: require helpers, init, sbar module; begin_config →
                      bar/default/items → end_config → event_loop
init.lua              (loaded by sketchybarrc)
bar.lua               sbar.bar{...} — global bar properties + display-change hook
default.lua           sbar.default{...} — inherited defaults for all later items
settings.lua          theme name, paddings, bar heights, font stack, icon set
colors.lua            loads themes/<settings.theme>.lua, adds colors.with_alpha()
icons.lua             sf_symbols / NerdFont glyph tables
themes/*.lua          10 palettes (rose_pine, catppuccin_mocha, tokyo_night, …)
items/init.lua        requires apple, spaces, calendar, widgets, media
items/widgets/init.lua  battery, volume, wifi, bluetooth, cpu, vorssaint, claude, codex
helpers/init.lua      sets package.cpath for sketchybar_lua/?.so, runs `make` in helpers/
helpers/*.sh|*.py     data providers (wifi scan, claude/codex usage, agent status,
                      low power mode)
helpers/*.command     double-clickable launchers (btop, wifi UI)
helpers/menus/        C binary `bin/menus` — reads/clicks macOS menu bar items
helpers/popup_keys.lua  Lua side of popup keyboard control (§4.6)
helpers/popup_keys/   Swift binary `bin/popup_keys` — holds key focus for an open popup
helpers/event_providers/  C binaries: cpu_load, network_load (push events into the bar)
```

`items/menus.lua` exists but is **not** required by `items/init.lua` — it's dormant.
Don't assume it's live.

---

## 2. The mental model

The bar is a rectangle holding **items**. Each item has an **icon** and a **label**
(both are *text* objects), plus a **background**, an optional **popup**, and optional
**shadow**/**image**. Items update by running a **script** — either on a timer
(`update_freq`) or, preferably, when an **event** they've **subscribed** to fires.

**Components** are items with extra powers: `graph`, `space`, `bracket`, `alias`, `slider`.

Positions: `left`, `right`, `center`, plus `q` (left of notch) and `e` (right of notch).
Items appear in the order added, and can be reordered/moved/cloned/renamed later.

---

## 3. Complete property reference

### 3.1 Type nomenclature

| type | values |
| --- | --- |
| `<boolean>` | `on`, `off`, `yes`, `no`, `true`, `false`, `1`, `0`, `toggle` |
| `<argb_hex>` | 8-digit hex `0xAARRGGBB` (alpha, red, green, blue) |
| `<path>` | absolute file path |
| `<string>` | any UTF-8 string or symbol |
| `<float>` / `<integer>` / `<positive_integer>` | as named |
| `<positive_integer list>` | comma-separated positive integers |

Booleans negate with `!` (e.g. `!on`). Every `<argb_hex>` field also exposes
`.alpha`, `.red`, `.green`, `.blue` sub-properties taking a float 0–1 —
e.g. `sketchybar --bar color.alpha=0.5`.

### 3.2 Bar properties — `sketchybar --bar` / `sbar.bar{}`

| setting | value | default | description |
| --- | --- | --- | --- |
| `color` | `<argb_hex>` | `0x44000000` | Color of the bar |
| `border_color` | `<argb_hex>` | `0xffff0000` | Color of the bar's border |
| `position` | `top`, `bottom` | `top` | Position on screen |
| `height` | `<integer>` | `25` | Height of the bar |
| `notch_display_height` | `<integer>` | `0` | Height override on notched displays |
| `margin` | `<integer>` | `0` | Margin around the bar |
| `y_offset` | `<integer>` | `0` | Vertical offset from default position |
| `corner_radius` | `<positive_integer>` | `0` | Corner radius |
| `border_width` | `<positive_integer>` | `0` | Border width |
| `blur_radius` | `<positive_integer>` | `0` | Blur behind the bar |
| `padding_left` | `<positive_integer>` | `0` | Left border → leftmost item |
| `padding_right` | `<positive_integer>` | `0` | Right border → rightmost item |
| `notch_width` | `<positive_integer>` | `200` | Notch width to account for |
| `notch_offset` | `<positive_integer>` | `0` | Extra `y_offset` on notched screens only |
| `display` | `main`, `all`, `<positive_integer list>` | `all` | Which display(s) show the bar |
| `hidden` | `<boolean>`, `current` | `off` | Hide all / the current bar |
| `topmost` | `<boolean>`, `window` | `off` | Draw above everything, or above `window`s |
| `sticky` | `<boolean>` | `on` | Sticky during space changes |
| `font_smoothing` | `<boolean>` | `off` | Smoothen fonts |
| `shadow` | `<boolean>` | `off` | Bar drop shadow |

### 3.3 Item geometry

| property | value | default | description |
| --- | --- | --- | --- |
| `drawing` | `<boolean>` | `on` | Draw the item into the bar |
| `position` | `left`, `right`, `center` | | Placement in the bar |
| `space` | `<positive_integer list>` | `0` | Mission Control spaces to show on |
| `display` | `<positive_integer list>`, `active` | `0` | Displays to show on |
| `ignore_association` | `<boolean>` | `off` | Ignore all space/display associations |
| `y_offset` | `<integer>` | `0` | Vertical offset |
| `padding_left` / `padding_right` | `<integer>` | `0` | Padding around the item |
| `width` | `<positive_integer>`, `dynamic` | `dynamic` | Fixed width in points |
| `scroll_texts` | `<boolean>` | `off` | Auto-scroll texts truncated by `max_chars` |
| `blur_radius` | `<positive_integer>` | `0` | Blur behind the item |
| `background.<background_property>` | | | Items support all background properties |

### 3.4 Icon & label

- `icon` = `<string>`; `icon.<text_property>` — icons support all text properties.
- `label` = `<string>`; `label.<text_property>` — labels support all text properties.

### 3.5 Scripting

| property | value | default | description |
| --- | --- | --- | --- |
| `script` | `<path>`, `<string>` | | Script to run on an event |
| `click_script` | `<path>`, `<string>` | | Script to run on mouse click |
| `update_freq` | `<positive_integer>` | `0` | Seconds between routine runs (`0` = never) |
| `updates` | `<boolean>`, `when_shown` | `on` | If/when the item updates |
| `mach_helper` | `<string>` | | Register a compiled helper for direct event notifications |

`click_script` differs from the `mouse.clicked` event — see SketchyBar discussion #109.
In SbarLua, prefer `item:subscribe("mouse.clicked", fn)` so you stay in Lua.

### 3.6 Text properties (apply under `icon.`, `label.`, `slider.knob.`)

| text_property | value | default | description |
| --- | --- | --- | --- |
| `drawing` | `<boolean>` | `on` | If the text renders |
| `highlight` | `<boolean>` | `off` | Use `highlight_color` instead of `color` |
| `color` | `<argb_hex>` | `0xffffffff` | Text color |
| `highlight_color` | `<argb_hex>` | `0xff000000` | Highlight color (e.g. active space) |
| `padding_left` / `padding_right` | `<integer>` | `0` | Padding around the text |
| `y_offset` | `<integer>` | `0` | Vertical offset |
| `font` | `<family>:<type>:<size>` | `Hack Nerd Font:Bold:14.0` | Font shorthand |
| `font.family` | `<string>` | `Hack Nerd Font` | Font family |
| `font.style` | `<string>` | `Bold` | Font style |
| `font.size` | `<float>` | `14.0` | Font size |
| `string` | `<string>` | | Set the text |
| `scroll_duration` | `<positive_integer>` | `100` | Scroll speed when `scroll_texts` is on |
| `max_chars` | `<positive_integer>` | `0` | Max characters displayed (scrollable) |
| `width` | `<positive_integer>`, `dynamic` | `dynamic` | Fixed text width in points |
| `align` | `center`, `left`, `right` | `left` | Align within a fixed `width` |
| `background.<background_property>` | | | Texts support all background properties |
| `shadow.<shadow_property>` | | | Texts support all shadow properties |

`align` only does something when `width` is fixed and larger than the content.
That pairing is how the popup rows in `items/widgets/battery.lua` get their
label-left / value-right layout.

### 3.7 Background properties

| background_property | value | default | description |
| --- | --- | --- | --- |
| `drawing` | `<boolean>` | `off` | If the background renders |
| `color` | `<argb_hex>` | `0x00000000` | Fill color |
| `border_color` | `<argb_hex>` | `0x00000000` | Border color |
| `border_width` | `<positive_integer>` | `0` | Border width |
| `height` | `<positive_integer>` | `0` | Override background height |
| `corner_radius` | `<positive_integer>` | `0` | Corner radius |
| `padding_left` / `padding_right` | `<integer>` | `0` | Padding |
| `y_offset` / `x_offset` | `<integer>` | `0` | Offsets |
| `clip` | `<float>` | `0.0` | How much the background clips the bar (transparent holes) |
| `image` | `<path>`, `app.<bundle-id>`, `app.<name>`, `media.artwork` | | Image to display |
| `image.<image_property>` | | | All image properties |
| `shadow.<shadow_property>` | | | All shadow properties |

### 3.8 Image properties

| image_property | value | default | description |
| --- | --- | --- | --- |
| `drawing` | `<boolean>` | `off` | If the image draws |
| `scale` | `<float>` | `1.0` | Scale factor |
| `border_color` | `<argb_hex>` | `0x00000000` | Border color |
| `border_width` | `<positive_integer>` | `0` | Border width |
| `corner_radius` | `<positive_integer>` | `0` | Corner radius |
| `padding_left` / `padding_right` | `<integer>` | `0` | Padding |
| `y_offset` | `<integer>` | `0` | Vertical offset |
| `string` | `<path>`, `app.<bundle-id>`, `app.<name>`, `media.artwork` | | The image |
| `shadow.<shadow_property>` | | | All shadow properties |

`app.<bundle-id>` / `app.<name>` pull a live app icon — no asset file needed.
`media.artwork` pulls now-playing artwork.

### 3.9 Shadow properties

| shadow_property | value | default | description |
| --- | --- | --- | --- |
| `drawing` | `<boolean>` | `off` | If the shadow draws |
| `color` | `<argb_hex>` | `0xff000000` | Shadow color |
| `angle` | `<positive_integer>` | `30` | Shadow angle |
| `distance` | `<positive_integer>` | `5` | Shadow distance |

### 3.10 Popup properties

Every item has a popup. Set via `popup.<popup_property>`.

| popup_property | value | default | description |
| --- | --- | --- | --- |
| `drawing` | `<boolean>` | `off` | If the popup renders |
| `horizontal` | `<boolean>` | `off` | Render horizontally |
| `topmost` | `<boolean>` | `on` | Always above other windows |
| `height` | `<positive_integer>` | bar height | Vertical spacing between popup items |
| `blur_radius` | `<positive_integer>` | `0` | Blur behind the popup |
| `y_offset` | `<integer>` | `0` | Vertical offset |
| `align` | `left`, `right`, `center` | `left` | Alignment against the parent item |
| `background.<background_property>` | | | All background properties |

**Adding items to a popup:** set the child item's `position` to `popup.<parent name>`.
In Lua: `position = "popup." .. parent.name`.

Toggle pattern used throughout this repo:

```lua
item:subscribe("mouse.clicked", function(env)
  local was_open = item:query().popup.drawing  -- "on" / "off"
  item:set({ popup = { drawing = "toggle" } })
  if was_open == "off" then
    -- refresh popup contents only when opening
  end
end)
```

Right-side widgets should use `popup = { align = "right" }` so the popup doesn't
run off screen (see battery/volume).

### 3.11 Components

**Graph** — `sketchybar --add graph <name> <position> <width>` /
`sbar.add("graph", name, width, props)`

| property | value | default | description |
| --- | --- | --- | --- |
| `graph.color` | `<argb_hex>` | `0xffcccccc` | Line color |
| `graph.fill_color` | `<argb_hex>` | `0xffcccccc` | Fill color |
| `graph.line_width` | `<float>` | `0.5` | Line width in points |

Push data with `--push <name> <point>…` / `graph:push({…})`, each point a float 0–1.
A graph uses the full bar height unless you give it a background with a `height`, in
which case it draws inside that and honors `y_offset`.

**Space** — `sketchybar --add space <name> <position>`. Binds an item to a Mission
Control space via the `space` property (and optionally `display`). Scripts get
`$SELECTED`, `$SID`, `$DID`. Default script is
`sketchybar --set $NAME icon.highlight=$SELECTED`, and it only runs when `$SELECTED`
changes. **This repo does not use `space` components** — `items/spaces.lua` uses plain
items driven by a custom event instead (§7).

**Bracket** — `sketchybar --add bracket <name> <member>…` /
`sbar.add("bracket", name, {members}, props)`. A shared background spanning members.
Members may be regex in slashes: `'/menu\\..*/'`. Brackets support background
properties only, and can span items in different positions.

**Alias** — `sketchybar --add alias <application_name> <position>`, or
`"<window_owner>,<window_name>"` for apps with multiple widgets
(`"Control Center,WiFi"`, `"Control Center,Bluetooth"`). Requires **screen capture
permission**. Extra properties: `alias.color`, `alias.scale`, `alias.update_freq`
(defaults to 1s). List available names with `sketchybar --query default_menu_items`.
Don't alias apps that aren't always running — SketchyBar will search for them forever.

**Slider** — `sketchybar --add slider <name> <position> <width>` /
`sbar.add("slider", name, width, props)`

| property | value | default | description |
| --- | --- | --- | --- |
| `slider.width` | `<positive_integer>` | `100` | Total width in points |
| `slider.percentage` | `<positive_integer>` | `0` | Progression 0–100 |
| `slider.highlight_color` | `<argb_hex>` | `0xff0000ff` | Progression highlight color |
| `slider.knob` | `<string>` | | Knob glyph |
| `slider.knob.<text_property>` | | | Knob supports all text properties |
| `slider.background.<background_property>` | | | All background properties |

Subscribe a slider to `mouse.clicked` to make it interactive; the script receives
`$PERCENTAGE` for the click location. Dragging tracks the mouse and emits a single
event on release.

---

## 4. Popups & UI layout

**Read this section before touching any popup.** SketchyBar has no layout engine — no
flexbox, no grid, no rows and columns, no measurement API. A popup is a vertical stack of
ordinary bar items, and each item gives you exactly **two text boxes**. Every panel in this
repo that looks like a real UI is that primitive faked with fixed widths, monospace
padding, and background rectangles. The rules below are measured behavior, most of it
recorded in comments in `items/widgets/wifi.lua` and `items/widgets/claude.lua` after it
was gotten wrong the first time.

### 4.1 Structure

A popup hangs off **any** item — or off a **bracket** (`items/widgets/volume.lua` puts the
popup on a bracket so the popup anchors to the group, not one icon). Children join it by
setting their `position`:

```lua
local parent = sbar.add("item", "widgets.thing", { popup = { align = "right" } })
sbar.add("item", "thing.row.1", { position = "popup." .. parent.name, ... })
```

Three facts that determine everything else:

1. **Rows stack vertically, one item per row.** There is no horizontal placement inside a
   popup except `popup.horizontal = true`, which turns the *whole* popup into one row.
2. **The popup is as wide as its widest row.** One row that measures wider than the rest
   stretches the entire panel. This is the #1 cause of a popup that "randomly" changes
   width when data updates — a long SSID or model name grew a row. Fix: give every row an
   explicit, identical width, and truncate strings yourself.
3. **`popup.height` is the row pitch, and it defaults to the bar height** — far too tall.
   Two working strategies, both in this repo:

   | strategy | when | example |
   | --- | --- | --- |
   | `popup.height = ROW_HEIGHT` | all rows the same height | `claude.lua` (`ROW_HEIGHT = 22`) |
   | `popup.height = 1`, every row states its own `background.height` | rows differ in height | `wifi.lua` |

   With the second strategy a **transparent background still reserves its height**, which
   is how spacers and variable-height rows work.

`popup.align` is relative to the parent item: use `"right"` for right-side widgets or the
panel hangs off the screen edge, `"center"` for a wide panel under a narrow icon.

### 4.2 The two-box rule

A row has an **icon box** spanning `[0, icon.width]` and a **label box** starting
immediately after it. That's all. `align` positions text *inside its own box* and does
nothing until that box has a fixed `width` larger than the text.

So: **two columns are free, a third costs you a trick.** The tricks, all in `wifi.lua`:

```lua
-- "key<spaces>value" filling exactly `chars` monospaced cells → value lands flush right
local function pair(key, value, chars)
  local gap = chars - #key - #value
  if gap < 1 then gap = 1 end
  return key .. string.rep(" ", gap) .. value
end

-- centre each entry in an equal share of a monospaced run → a row of evenly spaced choices
local function slots(choices, total_chars)
  local per = math.floor(total_chars / #choices)
  local out = {}
  for _, choice in ipairs(choices) do
    local left = math.floor((per - #choice) / 2)
    out[#out + 1] = string.rep(" ", left) .. choice .. string.rep(" ", per - #choice - left)
  end
  return table.concat(out)
end
```

A four-column stat line becomes two boxes each holding one `pair()` run (`stat_line` /
`set_stats` in `wifi.lua`). This only works in a **monospaced font** — `settings.font.numbers`
is JetBrainsMono, and the advance width is exactly `size * 0.6`:

```lua
local CHAR_W = ROW_FONT * 0.6 -- exact for JetBrains Mono
```

Use that constant to convert between character counts and points when a box width and a
padded string have to agree.

### 4.3 Measured sizing rules

These are not in the docs. They were derived by measurement and they are what makes rows
line up:

- **With a label, an item's length is `icon.width + label.width`.** Padding inside those
  boxes insets the text, it does not extend the item.
- **With no label, the icon's `padding_left` adds on top of `icon.width`.** The asymmetry
  is real; normalize both cases to your popup width (see `add_row` in `claude.lua`).
- **Backgrounds and their paddings never count toward an item's length.** This is the
  escape hatch for proportional fills — a background can grow and shrink with a percentage
  without ever stretching the popup.
- **An undrawn icon still reserves its padding**, which shoves the label box sideways. Zero
  it out on label-only rows:
  ```lua
  local hidden = { drawing = false, width = 0, padding_left = 0, padding_right = 0 }
  ```
- **Leading spaces in a label make SketchyBar truncate it.** Pad on the right only
  (`pad_right`), and get right-alignment from `align = "right"` on a fixed-width box.
- **`scroll_texts` is inherited.** `default.lua` sets it globally to `true`, which turns
  long popup rows into marquees and truncates them. Set `scroll_texts = false` on popup
  rows — both `wifi.lua`'s `row()` and `claude.lua`'s `add_bar_row` do this explicitly.
- **A slider's bar starts where its icon text ends.** Pad name strings to a fixed character
  count so the bar's left edge holds still across rows.
- **A background image is pinned to the item's left edge and ignores every padding and
  offset property.** If you need the image inset, bake the inset into the asset's canvas
  and scale. `assets/claude.png` is 480px wide with the visible mark spanning 210..420
  precisely so `scale = LOGO_W/210` renders it `LOGO_W` wide and `LOGO_W` in from the edge.

### 4.4 Row recipes

**The scaffold.** Every row goes through one builder that pins the width and the inset, so
no row can stretch the panel:

```lua
local width, pad = 336, 12

local function row(name, inset, opts)
  opts.position = "popup.widgets.wifi"
  opts.width = width - 2 * inset
  opts.padding_left = inset
  opts.padding_right = inset
  opts.scroll_texts = false
  return sbar.add("item", name, opts)
end
```

**Spacer** — a transparent background is pure vertical space:

```lua
local function block(height, color)
  return { drawing = true, height = height, corner_radius = 0,
           border_width = 0, color = color or colors.transparent }
end
row("gap.1", 0, { icon = hidden, label = hidden, background = block(9) })
```

**Divider** — the same thing with `height = 1` and a visible color.

**Section header** — a label-only row, small bold, muted, `align = "left"`, `background = block(22)`.

**Two-column key/value** — fixed `width` on both boxes, `align = "left"` / `"right"`.

**Progress bar** — use the real `slider` component, sized by what's left after the text
columns (`add_bar_row` in `claude.lua`):

```lua
cfg.slider = {
  highlight_color = FILL,
  background = { height = 4, corner_radius = 2, color = TRACK },
  knob = { drawing = false },   -- a bar is a knobless slider
  percentage = 0,
}
sbar.add("slider", name, CONTENT - text_w, cfg)
```

**Full-width block with a proportional fill** — the trick that needs the "backgrounds don't
count toward length" rule. One `CONTENT`-wide monospace string holds name and value; the
fill is the *icon's background*, and the fill amount is the icon's `width`:

```lua
set_block_row = function(item, name, value, pct)
  local text = " " .. name .. string.rep(" ", gap) .. value .. " "
  local fill = math.floor(CONTENT * pct / 100 + 0.5)
  item:set({ icon = { string = text, width = fill,
                      background = { drawing = fill > 2 } } })
end
```

The icon keeps rendering the full text while its `width` independently drives the fill —
no percentage can stretch the popup.

**Toggle switch** — a fixed-width label background with the knob glyph flipped between
`align = "left"` and `align = "right"`, track color swapped (`render_power` in `wifi.lua`).

**Hover** — subscribe the row and set a background color, remembering to restore to the
row's *conditional* resting color, not a constant:

```lua
net_row:subscribe("mouse.entered", function()
  net_row:set({ background = { color = colors.bg2 } })
end)
net_row:subscribe("mouse.exited", function()
  net_row:set({ background = { color = connected and colors.bg2 or colors.transparent } })
end)
```

Hit testing is **per item**, so a "button" drawn inside a row highlights when the mouse is
anywhere in that row. To get a real button, it must be its own row item.

**Open / close:**

```lua
parent:subscribe("mouse.clicked", function(env)
  if env.BUTTON ~= "left" then return end
  local opening = parent:query().popup.drawing == "off"
  parent:set({ popup = { drawing = "toggle" } })
  if opening then refresh() end   -- fetch data only when opening
end)
```

Auto-close on leaving the bar with `mouse.exited.global` (`volume.lua`).

### 4.5 Dynamic rows

Rebuild by removing with a regex and re-adding:

```lua
sbar.remove("/wifi\\.net\\../")
```

Two traps:

1. **New items append to the end of the popup.** There is no insert-at-index. Any content
   that gets rebuilt must live at the *bottom* of the panel, below everything static — or
   you rebuild the whole popup every time. `wifi.lua` is laid out exactly this way: all
   static chrome is created at load, network rows are appended last, and the trailing
   spacer is re-added on every render.
2. **The regex is an unanchored substring match**, so name prefixes collide. In `wifi.lua`,
   `/wifi\.section\../` also matches `wifi.section.pad.1` — intentional there, but it means
   a naming scheme is load-bearing. Keep dynamic families under a distinct dotted prefix
   and check what else your pattern sweeps up before using it.

Guard against re-entrancy while an action is in flight (`state.pending` in `wifi.lua`) —
`sbar.exec` callbacks are asynchronous and a user can click again mid-flight.

### 4.6 Keyboard control

SketchyBar windows never take key focus, so a popup cannot see a keystroke. The
workaround is `helpers/popup_keys/bin/popup_keys` (Swift, built by `helpers/makefile`):
while a popup is open it holds focus with an invisible 1×1 window and forwards arrows,
return, tab and escape into the bar as `sketchybar --trigger <event> KEY=<name>`. It runs
as an accessory app, needs no accessibility permission, exits on escape or when it loses
focus, and hands focus back to the app it took it from.

Wiring it up is `helpers/popup_keys.lua`:

```lua
local keys = require("helpers.popup_keys")

local nav = keys.bind("wifi", function(key) ... end)  -- registers popup_key_wifi
nav.start()   -- popup opened
nav.stop()    -- popup closed
```

Rules that fall out of this:

1. **Only one grabber runs at a time.** `start()` kills any other first; two would fight
   over key focus. Every popup must `stop()` on *every* close path it has — the click
   toggle, `mouse.exited.global`, and anything that hides the widget outright.
2. **The listener is a bar item, not a popup item** (`keys.bind` adds it with
   `updates = true`). A popup item stops processing events while hidden, which is exactly
   when the escape keystroke arrives.
3. **Keep a focus ring, don't diff.** Dynamic rows (§4.5) are destroyed on every rebuild,
   so `wifi.lua` rebuilds its ring alongside its rows and re-anchors focus by SSID.
   Repaint every focusable row on each change rather than tracking the one that moved.
4. Focus needs a colour that isn't already spoken for. `wifi.lua` uses `highlight_med`
   for network rows, and a border on the power pill, whose fill already means on/off.
5. **Release the keyboard before anything that prompts.** The grabber holds key focus, so
   an `osascript` dialog (the Wi-Fi password, the Low Power Mode authorization) cannot be
   typed into while it is up. Call `keys.stop_all()` first and `nav.start()` again in the
   callback if the popup is still open — `battery.lua` does both.

**Opening a popup without the mouse.** Each panel also registers a custom event that runs
the same function its click handler does, so a hotkey daemon can open it and land in the
same state a click would:

| Event | Effect |
| --- | --- |
| `wifi_popup_toggle` | toggles the Wi-Fi panel |
| `volume_popup_toggle` | toggles the volume panel |
| `agents_popup_toggle` | toggles the Claude/Codex panel (ignored while the widget is hidden) |
| `battery_popup_toggle` | toggles the battery panel |
| `btop_launch` | same as clicking the CPU widget |
| `bluetooth_settings` | same as clicking the Bluetooth widget |
| `calendar_open` | opens Calendar, as clicking the clock does |

The bindings live in `~/.skhdrc` (outside this repo) as
`alt + ctrl - w : sketchybar --trigger wifi_popup_toggle`, and so on for `v`, `a`, `p`,
`t`, `b` and `cmd + alt + ctrl - d`. Route a hotkey through the widget's own handler
rather than setting `popup.drawing` or re-typing the command in `~/.skhdrc` — for a popup
the toggle is what starts the key grabber and resets focus, and for the rest it keeps one
definition of what the widget does.

### 4.7 How to actually get this right

The failure mode is deriving geometry from first principles and being confidently wrong.
The two files in this repo even record *different* mental models for how background
padding composes with item padding (`add_block_row` vs `add_divider` in `claude.lua`),
and both render correctly — meaning at least one comment is a rationalization of a
number that was tuned by eye.

So:

- **Copy a working row builder** from `wifi.lua` or `claude.lua` and adjust numerically.
  Don't invent a new layout approach.
- **Run `sketchybar` in the foreground** (`brew services stop sketchybar` first) so Lua
  errors are visible; `sketchybar --reload` after each edit.
- **Change one constant at a time and look at it.** Widths, insets and paddings interact
  in ways the docs don't describe.
- **`sketchybar --query <item>`** dumps the item's real geometry — use it instead of
  guessing what a width resolved to.
- Ask for a screenshot when the result is "it looks wrong". There is no way to verify
  visual output from the shell.

---

## 5. Events

`sketchybar --subscribe <name> <event>…` / `item:subscribe(events, fn)`

| event | description | `$INFO` |
| --- | --- | --- |
| `front_app_switched` | Front application changed (not on same-app window focus) | front app name |
| `space_change` | Active Mission Control space changed | JSON: active spaces per display |
| `space_windows_change` | Window created/destroyed on a space | JSON: space + app windows |
| `display_change` | Active display changed | new active display id |
| `volume_change` | System audio volume changed | new volume percent |
| `brightness_change` | Display brightness changed | new brightness percent |
| `power_source_change` | Power source changed | `AC` or `BATTERY` |
| `wifi_change` | Wi-Fi connect/disconnect | SSID or empty — **broken since macOS Sonoma** |
| `media_change` | Now-playing media changed | JSON media info — **deprecated on macOS 26.0** |
| `system_will_sleep` | System preparing to sleep | |
| `system_woke` | System woke from sleep | |
| `mouse.entered` / `mouse.exited` | Mouse over / leaving an item | |
| `mouse.entered.global` / `mouse.exited.global` | Mouse over / leaving any part of the bar | |
| `mouse.clicked` | Item clicked | button + modifier info |
| `mouse.scrolled` | Scrolled over an item | scroll delta |
| `mouse.scrolled.global` | Scrolled over an empty bar region | scroll delta |

**Environment available to every script:** `$NAME` (invoking item), `$SENDER` (event
name, or `routine` for `update_freq` runs), `$CONFIG_DIR` (absolute dir of the active
`sketchybarrc`), `$BAR_NAME` (for multi-bar setups).
On click: `$BUTTON` (`left`/`right`/`other`) and `$MODIFIER` (`shift`/`ctrl`/`alt`/`cmd`).
On scroll: `$SCROLL_DELTA`.

Scripts are killed after 60s and do not run while the system sleeps.

**Custom events:**

```bash
sketchybar --add event <name> [<NSDistributedNotificationName>]
sketchybar --trigger <event> [VAR=value …]
```

The optional second argument hooks an `NSDistributedNotificationCenter` notification —
e.g. `com.spotify.client.PlaybackStateChanged`, `com.apple.screenIsUnlocked` — and
delivers notification payload in `$INFO` when available. Variables passed to `--trigger`
land as env vars in subscriber scripts (this is exactly how `FOCUSED_WORKSPACE` reaches
the workspace items in §7).

`sketchybar --update` forces every script to run and every event to fire. Use it once
at the end of a bash config to initialize items. **Never call it inside an item script**
— infinite loop.

---

## 6. SbarLua — the binding this repo uses

Install / path (already handled by `helpers/init.lua`):

```lua
package.cpath = package.cpath .. ";/Users/" .. os.getenv("USER") .. "/.local/share/sketchybar_lua/?.so"
sbar = require("sketchybar")
```

### Translation rule

**Every dot in the docs becomes a nested table.** `icon.font.size=13.0` →
`icon = { font = { size = 13.0 } }`. There is no separate Lua doc for properties —
§3 *is* the Lua reference, read through this rule.

### API

```lua
sbar.bar(props)                                  -- --bar
sbar.default(props)                              -- --default
sbar.add("item"|"space"|"alias", name?, props)   -- --add
sbar.add("bracket", name?, members, props)       -- members = table of names/regexes
sbar.add("slider"|"graph", name?, width, props)
sbar.add("event", name, nsdistributednotification?)
item:set(props)                                  -- --set
item:subscribe(event_or_table, function(env) end)
item:query()                                     -- returns a Lua table
graph:push({floats})
sbar.trigger(event, env_table?)
sbar.animate(curve, duration, function() … end)  -- wrap animated sets inside
sbar.exec(command, function(result, exit_code) end)
sbar.set_bar_name("bottom_bar")
sbar.begin_config() / sbar.end_config()          -- batch the whole initial config
sbar.event_loop()                                -- REQUIRED, last line; runs callbacks
```

`item.name` holds the item's name — used for `position = "popup." .. item.name`.

### Hard rules

1. **Never use `os.execute` or `io.popen` for runtime work** — they block the event
   handler thread and freeze the bar. Use `sbar.exec(cmd, callback)`. The one
   legitimate exception is config-load time: `helpers/init.lua` calls `os.execute` to
   `make` the helper binaries before the event loop starts.
2. `sbar.exec` **auto-parses JSON output into a Lua table.** If the command emits JSON,
   the callback receives a table, not a string. Emit plain text if you want to
   string-match it (as `battery.lua` does with `pmset -g batt`).
3. `sbar.event_loop()` must be the last statement in `sketchybarrc`, or no callbacks run.
4. Everything between `begin_config()` and `end_config()` is batched into one message —
   keep initial setup inside it for fast startup.
5. Closures capture by reference. Inside `for _, sid in ipairs(...)` loops, copy the
   loop variable (`local current_sid = sid`) before using it in a subscription callback —
   `items/spaces.lua` does this deliberately.
6. `item:query()` is synchronous and returns strings for booleans (`"on"` / `"off"`),
   not Lua booleans. Compare against `"off"`, never `not x`.

---

## 7. Repo conventions to follow

**Adding a widget**

1. Create `items/widgets/<name>.lua`.
2. `require("items.widgets.<name>")` in `items/widgets/init.lua`.
3. Pull colors from `require("colors")` and glyphs from `require("icons")` — never
   hardcode a hex or a glyph inline, or you break the 10-theme system.
4. Use `settings.font.style_map[...]` for font styles; the map is per-font
   (JetBrainsMono maps `"Bold"` → `"SemiBold"`, etc.), so literal style names are wrong.
5. Right-side widgets: `position = "right"`, and add a trailing
   `sbar.add("item", "widgets.<name>.padding", { position = "right", width = 2 })`.
6. Naming: `widgets.<name>`, `widgets.<name>.padding`, `space.<sid>`,
   `space.padding.<sid>`. Keep the dotted scheme — bracket regexes depend on it.

**Themes.** `settings.theme` names a file in `themes/`. `colors.lua` `pcall`s it and
falls back to `rose_pine`. Any new color key must exist in **all ten** theme files or
the other themes break. `colors.with_alpha(color, alpha)` recomputes the alpha channel.

**Bar height** is display-dependent: `settings.height_internal` (38, notched built-in)
vs `height_external` (30). `helpers/display.lua` shells out to `system_profiler` to
detect which, and `bar.lua` re-runs it on `display_change` via a hidden item. Don't set
a literal bar height.

**Workspace items.** `items/spaces.lua` does not use the `space` component (that binds
to Mission Control spaces, which this setup doesn't track). It registers a custom event,
builds one plain item per workspace from a **hardcoded id list** (`{ "1".."6" }`), and
flips the icon glyph on the active one when the event fires with a workspace id in
`env`. Adding a workspace means editing that list. Nothing in this repo fires the event
at startup, so the highlight is only correct after the first change arrives — that's the
cause if you're chasing a "no workspace highlighted on launch" bug.

**Helper scripts.** Shell/Python helpers live in `helpers/` and are invoked as
`"$CONFIG_DIR/helpers/<name>"` — `$CONFIG_DIR` is set by SketchyBar; relative paths do
**not** resolve. `chmod +x` anything new. C helpers are built by `helpers/makefile`,
which `helpers/init.lua` runs on every config load.

---

## 8. Workflow

```bash
sketchybar --reload             # reload config (same as restart)
sketchybar --reload <path>      # load a different config
sketchybar --hotload on         # auto-reload when the config dir changes
sketchybar --query bar          # JSON dump of bar state
sketchybar --query <item>       # JSON dump of one item
sketchybar --query defaults     # current --default values
sketchybar --query events       # known events
sketchybar --query displays     # display configuration
sketchybar --query default_menu_items   # macOS menu bar item names, for aliases
sketchybar --load-font <path>   # load a font from a non-standard directory
```

To debug: `brew services stop sketchybar`, then run `sketchybar` in the foreground —
that's the only way to see Lua errors and script stderr. Test helper scripts standalone
before wiring them in.

Prerequisite for correct behavior: *System Settings → Desktop & Dock → Displays have
separate Spaces* must be **on** (the default).

---

## 9. Animation

```bash
sketchybar --animate <curve> <duration> --bar … --set …
```

```lua
sbar.animate("sin", 30, function() item:set({ ... }) end)
```

Curves: `linear`, `quadratic`, `tanh`, `sin`, `exp`, `circ`.
`<duration>` is a **frame count at 60Hz** — seconds = duration / 60.

Animatable value types: `<argb_hex>`, `<integer>`, `<positive_integer>`. Animation always
runs from the current value to the specified one. Chain keyframes by setting the same
property multiple times in one call (`--bar y_offset=10 y_offset=0`); you can change the
curve between segments, and you can make a property "wait" by setting it to its current
value in the first segment. A plain `--set` on an animating property cancels the queue and
snaps; a new animated `--set` cancels the queue and re-animates from the current state.

---

## 10. Performance

- Batch config commands (bash `\` continuations / arrays; Lua `begin_config`/`end_config`).
- Prefer event subscriptions over `update_freq` polling.
- Set `updates = "when_shown"` for items that needn't run while hidden — this repo sets it
  globally in `default.lua`, so **an item that must update while off-screen has to opt out
  explicitly**.
- Lower `update_freq` on scripts and aliases.
- Don't alias apps that aren't always running.
- For hot paths, use a compiled `mach_helper` (SketchyBar ≥ 2.9.0) —
  [example](https://github.com/FelixKratz/SketchyBarHelper).

---

## 11. Gotchas checklist

- Bash examples from the internet won't work here — translate to SbarLua (§6).
- No trailing whitespace after a `\` line continuation in shell helpers.
- `wifi_change` is broken on macOS ≥ Sonoma; `media_change` is deprecated on macOS 26.
  This repo works around Wi-Fi with `helpers/wifi_status.sh` / `wifi_scan.sh`.
- `background.drawing` and `image.drawing` default to **off** — set them explicitly.
- Item and text `width` default to `dynamic`; `align` is a no-op until width is fixed.
- Scripts are hard-killed at 60s.
- `--update` inside an item script = infinite loop.
- Regex targets must be wrapped in slashes: `/space\..*/` (`'/space\\..*/'` in Lua), and
  they match as **unanchored substrings** — check what else a pattern sweeps up.
- Aliases need screen capture permission.

Popup/UI specifically (§4 has the full treatment):

- **There is no `mouse.right` event.** The only mouse events are `mouse.entered`,
  `mouse.exited`, `mouse.entered.global`, `mouse.exited.global`, `mouse.clicked`,
  `mouse.scrolled`, `mouse.scrolled.global`. Right-click = `mouse.clicked` with
  `env.BUTTON == "right"`. (`items/widgets/wifi.lua:730` subscribes to `mouse.right` and
  is therefore dead code.)
- The popup is as wide as its widest row — one long string silently resizes the panel.
- `popup.height` defaults to the **bar** height; set it, or set it to 1 and give each row
  a `background.height`.
- A row has **two** text boxes, not N columns. Third column = monospace padding.
- `scroll_texts` is `true` in this repo's `default.lua` and truncates popup rows — turn it
  off per row.
- Leading spaces in a label cause truncation; pad right and use `align`.
- An undrawn icon still reserves its padding.
- Backgrounds never contribute to item length — that's what makes proportional fills safe.
- Background images ignore padding/offsets and pin to the item's left edge.
- New popup items always append at the bottom; there is no insert-at-index.
- Hit testing is per item, so an inline "button" can't hover independently of its row.
- Workspace ids are hardcoded in `items/spaces.lua`; adding one means editing that list.
- New color keys must be added to all ten `themes/*.lua` files.
