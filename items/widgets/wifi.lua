local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local keys = require("helpers.popup_keys")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local helpers = config_dir .. "/helpers"
-- MACWIFI_BIN points this (and helpers/wifi_speedtest.sh) at a different build,
-- e.g. target/debug/macwifi while a feature is still unreleased.
local MACWIFI = os.getenv("MACWIFI_BIN") or "/usr/local/bin/macwifi"

local width = 336
local pad = 12
local NETWORK_PAGE_SIZE = 6
local NETWORK_ROW_HEIGHT = 32
local NETWORK_NAME_WIDTH = 190

-- Wi-Fi panel, ported from omarchy's network panel (Panel.qml) onto a
-- sketchybar popup. Everything macwifi can do is wired up (status, scan,
-- connect, disconnect, forget, power, speed test); the controls macwifi has no
-- backend for (QR share, DNS provider) stay on screen for UI parity but do
-- nothing when clicked.
--
-- Layout notes: a popup stacks its items vertically, one item per line, and a
-- row is as tall as that item's background, so popup.height is dropped to 1
-- and every row states its own height (transparent backgrounds still reserve
-- the space). Within a row there are only two boxes to work with: the icon
-- box spans [0, icon.width] and the label box picks up right after it, with
-- padding insetting the text inside its own box. Columns past the second are
-- therefore spaced out with the monospaced font rather than with more boxes.
local wifi = sbar.add("item", "widgets.wifi", {
  position = "right",
  icon = { string = icons.wifi.off, color = colors.white },
  label = { drawing = false },
  popup = { align = "right", height = 1 },
})

sbar.add("item", "widgets.wifi.padding", {
  position = "right",
  width = settings.group_paddings,
})

-- ---------------------------------------------------------------- utilities
local function sh(v)
  return "'" .. tostring(v):gsub("'", "'\\''") .. "'"
end

local function strip(v)
  return (v or ""):gsub("%s+$", ""):gsub("^%s+", "")
end

local function escape_dialog(s)
  return tostring(s):gsub('[\\"]', '\\%0')
end

local FONT_REG = settings.font.style_map["Regular"]
local FONT_SEMI = settings.font.style_map["Semibold"]
local FONT_BOLD = settings.font.style_map["Bold"]

local SZ_TITLE = 13.0
local SZ_SMALL = 9.5
local SZ_STAT = 9.5
local SZ_NET = 12.0
local SZ_PILL = 10.5

local function font(size, style)
  return { family = settings.font.text, style = style or FONT_REG, size = size }
end

local function bars(rssi)
  local idx = 0
  if rssi >= -50 then idx = 4
  elseif rssi >= -60 then idx = 3
  elseif rssi >= -70 then idx = 2
  elseif rssi >= -80 then idx = 1
  end
  return icons.wifi.bars[idx + 1]
end

local function fmt_band(ch)
  if not ch or ch <= 0 then return "" end
  if ch <= 14 then return "2.4GHZ" end
  if ch <= 165 then return "5GHZ" end
  return "6GHZ"
end

local function fmt_channel(ch)
  local band = fmt_band(ch)
  if band == "" then return tostring(ch) end
  return ch .. " (" .. band:lower() .. ")"
end

local function is_secured(sec)
  return sec ~= "" and sec ~= "OPEN"
end

-- Centre each entry in an equal share of a monospaced run, so a single label
-- can hold a row of evenly spaced choices.
local function slots(choices, total_chars)
  local per = math.floor(total_chars / #choices)
  local out = {}
  for _, choice in ipairs(choices) do
    local left = math.floor((per - #choice) / 2)
    out[#out + 1] = string.rep(" ", left) .. choice .. string.rep(" ", per - #choice - left)
  end
  return table.concat(out)
end

-- "key<spaces>value" filling exactly `chars` monospaced cells, so the value
-- ends flush with the right edge of its column.
local function pair(key, value, chars)
  local gap = chars - #key - #value
  if gap < 1 then gap = 1 end
  return key .. string.rep(" ", gap) .. value
end

-- ------------------------------------------------------------- row builders
-- An undrawn icon still reserves its padding, which would shove the label box
-- sideways; zero it out wherever a row is label-only.
local hidden = { drawing = false, width = 0, padding_left = 0, padding_right = 0 }

-- A background that only exists to give its row a height.
local function block(height, color)
  return {
    drawing = true,
    height = height,
    corner_radius = 0,
    border_width = 0,
    color = color or colors.transparent,
  }
end

-- Every popup row, in creation order, so the scroll wheel can be wired to all
-- of them at the bottom of the file.
local popup_rows = {}

-- Shared by every popup row, so the icon and label boxes below can be
-- positioned in absolute pixels. `inset` pulls the whole row (its background
-- included) in from both edges of the panel.
local function row(name, inset, opts)
  opts.position = "popup.widgets.wifi"
  opts.width = width - 2 * inset
  opts.padding_left = inset
  opts.padding_right = inset
  opts.scroll_texts = false
  local item = sbar.add("item", name, opts)
  popup_rows[#popup_rows + 1] = item
  return item
end

local gap_seq = 0
local function spacer(height, prefix)
  gap_seq = gap_seq + 1
  return row((prefix or "wifi.gap") .. "." .. gap_seq, 0, {
    icon = hidden,
    label = hidden,
    background = block(height),
  })
end

local rule_seq = 0
local function divider()
  rule_seq = rule_seq + 1
  return row("wifi.rule." .. rule_seq, pad, {
    icon = hidden,
    label = hidden,
    background = {
      drawing = true,
      height = 1,
      corner_radius = 0,
      border_width = 0,
      color = colors.highlight_med,
    },
  })
end

local section_seq = 0
local function section_header(text, prefix)
  section_seq = section_seq + 1
  prefix = prefix or "wifi.section"
  return row((prefix or "wifi.section") .. "." .. section_seq, pad, {
    icon = hidden,
    label = {
      string = text,
      width = width - 2 * pad,
      align = "left",
      padding_left = 0,
      padding_right = 0,
      font = font(SZ_SMALL, FONT_BOLD),
      color = colors.muted,
    },
    background = block(22),
  })
end

-- Two "key .... value" pairs per line, one per half of the row. Each half is a
-- 24 cell monospaced run, which puts both values flush against the right edge
-- of their column.
local STAT_CHARS = 24

local function stat_line(name)
  local half = {
    width = (width - 2 * pad) // 2,
    align = "left",
    padding_left = 0,
    padding_right = 0,
    font = font(SZ_STAT),
    color = colors.subtle,
  }
  local icon, label = {}, {}
  for k, v in pairs(half) do
    icon[k], label[k] = v, v
  end
  return row(name, pad, { icon = icon, label = label, background = block(18) })
end

local function set_stats(item, left_key, left_val, right_key, right_val)
  item:set({
    icon = { string = pair(left_key, left_val, STAT_CHARS) },
    label = { string = pair(right_key, right_val, STAT_CHARS) },
  })
end

-- ---------------------------------------------------------------- state
local state = {
  powered = false,
  iface = "",
  ssid = "",
  bssid = "",
  rssi = 0,
  noise = 0,
  channel = 0,
  txrate = 0,
  hwaddr = "",
  networks = {},             -- { ssid, rssi, ch, sec, bssid, known }
  pending = "",              -- ssid with an action in flight
  pending_kind = "",         -- "connect" | "disconnect" | "forget"
  scanning = false,
  speedtest = {
    supported = nil,         -- nil until probed, then true / false
    state = "idle",          -- idle | running | done | failed
    provider = "",
    download = nil,          -- Mbps; live sample while running, final when done
    upload = nil,            -- Mbps
    ping = nil,              -- ms
    elapsed_ms = 0,
    duration_ms = nil,
    responsiveness = nil,    -- Apple's responsiveness score, in RPM
    interface = "",
    server = "",
    error = "",
  },
}

local popup_open = false
-- The popup's keyboard grabber; bound at the bottom, once the actions its keys
-- fire are all defined.
local nav
local scheduler_active = false
local scan_active = false
local scan_again = false

-- ---------------------------------------------------------------- focus
-- Keyboard focus ring over everything in the popup that does something: the
-- power switch, the speed-test button, then every network in the scan, in the
-- order the list sorts them.
--
-- Focus is a value -- "power", "speed", or an SSID -- rather than an index
-- into the drawn rows. The rows are a scrolling window over the networks, so
-- an index into them means something different after every scroll and after
-- every scan re-sort; an SSID keeps the highlight on the network the user
-- actually picked, on screen or not.
local focus = { kind = "power" }
local sorted_networks = {}

-- First network visible in the row window.
local network_offset = 1

local function focused_kind()
  return focus.kind
end

local function find_network(ssid)
  for _, net in ipairs(sorted_networks) do
    if net.ssid == ssid then return net end
  end
  return nil
end

-- A network row carries three states in one background colour: focused, then
-- connected, then plain. Hover paints over this and hands it back on exit.
local function row_color(net)
  if focus.kind == "network" and focus.ssid == net.ssid then return colors.highlight_med end
  return net.connected and colors.bg2 or colors.transparent
end

-- Assigned further down, once the rows it repaints exist.
local render_focus = function() end

-- ------------------------------------------------------- forward references
local render_networks
local refresh
local schedule_refresh
local scroll_networks
local paint_slot

-- ---------------------------------------------------------------- actions
local function clear_pending()
  state.pending = ""
  state.pending_kind = ""
  render_networks()
end

-- Without a password macwifi joins from its own saved credential. It reports
-- back that it had none by printing NEEDPASS, which only happens for a secured
-- network we asked it to join blind.
local function join(ssid, password, on_needs_password)
  local cmd = helpers .. "/wifi_join.command " .. sh(ssid)
  if password then
    cmd = "PASS=" .. sh(password) .. " " .. cmd
  end
  sbar.exec(cmd, function(out)
    local result = strip(out or "")
    if on_needs_password and result == "NEEDPASS" then
      on_needs_password()
    elseif result == "BUSY" then
      clear_pending()
      schedule_refresh(1)
    else
      schedule_refresh(4)
    end
  end)
end

-- Ask for a password and hand it to macwifi, which saves it for next time.
-- Cancelling just leaves the row as it was.
local function prompt_and_join(ssid)
  sbar.exec(
    'osascript -e \'set pw to text returned of (display dialog "Password for '
      .. escape_dialog(ssid)
      .. ':" default answer "" with hidden answer)\'',
    function(pw)
      pw = strip(pw)
      if pw ~= "" then
        join(ssid, pw)
      else
        clear_pending()
      end
    end
  )
end

local function connect_network(ssid, secured, known)
  if state.pending ~= "" then return end
  state.pending = ssid
  state.pending_kind = "connect"
  render_networks()

  -- Let macwifi own the join. An open network needs nothing from us, and for
  -- one macwifi already knows it reads its own keychain item silently -- which
  -- is precisely what reading that item through `security` here could not do,
  -- since the item trusts macwifi.app alone.
  if not secured then
    join(ssid, nil)
  elseif known then
    join(ssid, nil, function() prompt_and_join(ssid) end)
  else
    prompt_and_join(ssid)
  end
end

local function disconnect_network()
  if state.pending ~= "" or state.ssid == "" then return end
  state.pending = state.ssid
  state.pending_kind = "disconnect"
  render_networks()
  sbar.exec(MACWIFI .. " disconnect", function() schedule_refresh(3) end)
end

local function forget_network(ssid)
  if state.pending ~= "" then return end
  state.pending = ssid
  state.pending_kind = "forget"
  render_networks()
  sbar.exec(MACWIFI .. " forget " .. sh(ssid), function() schedule_refresh(2) end)
end

local function toggle_power()
  local target = state.powered and "off" or "on"
  sbar.exec(MACWIFI .. " power " .. target, function() schedule_refresh(2) end)
end

-- ------------------------------------------------------------- speed test
-- A speed test runs for 30s to several minutes and sbar.exec cannot stream a
-- subprocess, so helpers/wifi_speedtest.sh detaches the run and this polls it
-- once a second while it is live. Everything here only maintains
-- state.speedtest; drawing it is the UI pass's job.
local SPEEDTEST = sh(helpers .. "/wifi_speedtest.sh")
local OVERLAY = sh(helpers .. "/speedtest_overlay/bin/speedtest_overlay")
local POLL_SECONDS = 1

-- The helper and the overlay both resolve macwifi the same way this file does:
-- MACWIFI_BIN when it is set, otherwise the installed binary. They are child
-- processes, so they inherit that from sketchybar's environment on their own.
-- Builds without the subcommand are caught by the capability probe below.

-- The overlay draws in the running theme's palette so it reads as part of the
-- bar rather than a separate app. Every key used here exists in all ten themes;
-- the accent names carry the same meaning throughout (foam teal, iris purple,
-- love red), and collapse to greys on the monochrome ones.
local function overlay_palette()
  local function hex(color)
    return string.format("0x%08x", color)
  end
  return " --accent-down " .. hex(colors.foam)
    .. " --accent-up " .. hex(colors.iris)
    .. " --value " .. hex(colors.text)
    .. " --muted " .. hex(colors.muted)
    .. " --title-color " .. hex(colors.subtle)
    .. " --fail " .. hex(colors.love)
    .. " --dim " .. hex(colors.with_alpha(colors.base, 0.82))
end

local speedtest_polling = false

-- Called after every change to state.speedtest. Reassigned for real once the
-- speed-test row exists further down; the callbacks below close over the
-- variable, so they pick up the real one.
local render_speedtest = function() end

-- poll omits the keys that do not apply to the current state, so each poll
-- replaces the table wholesale rather than merging -- otherwise a finished run
-- would keep showing the last live sample alongside its final figures.
local function apply_speedtest(out)
  local fresh = {
    supported = state.speedtest.supported,
    state = "idle",
    provider = "",
    elapsed_ms = 0,
    interface = "",
    server = "",
    error = "",
  }
  for line in (out or ""):gmatch("([^\n]+)") do
    local k, v = line:match("^([^=]+)=(.+)$")
    if k and v then
      if k == "state" then fresh.state = v
      elseif k == "provider" then fresh.provider = v
      elseif k == "download_mbps" then fresh.download = tonumber(v)
      elseif k == "upload_mbps" then fresh.upload = tonumber(v)
      elseif k == "ping_ms" then fresh.ping = tonumber(v)
      elseif k == "elapsed_ms" then fresh.elapsed_ms = tonumber(v) or 0
      elseif k == "duration_ms" then fresh.duration_ms = tonumber(v)
      elseif k == "responsiveness_rpm" then fresh.responsiveness = tonumber(v)
      elseif k == "interface" then fresh.interface = v
      elseif k == "server" then fresh.server = v
      elseif k == "error" then fresh.error = v end
    end
  end
  state.speedtest = fresh
end

local function poll_speedtest(delay)
  if speedtest_polling then return end
  speedtest_polling = true
  local cmd = SPEEDTEST .. " poll"
  if delay and delay > 0 then
    cmd = "sleep " .. tostring(delay) .. "; " .. cmd
  end
  sbar.exec(cmd, function(out)
    speedtest_polling = false
    apply_speedtest(out)
    render_speedtest()
    -- Keep polling to completion even with the popup shut, so the result is
    -- already there when it is reopened.
    if state.speedtest.state == "running" then
      poll_speedtest(POLL_SECONDS)
    end
  end)
end

-- `provider` is optional: omitting it leaves the choice to macwifi's own
-- ~/.config/macwifi/config.toml. Valid values are apple, ookla, netflix, custom.
local function start_speedtest(provider)
  if state.speedtest.supported == false then return end
  if state.speedtest.state == "running" then return end

  local cmd = SPEEDTEST .. " start"
  if provider and provider ~= "" then
    cmd = cmd .. " " .. sh(provider)
  end

  -- Optimistic, so a UI can show the run immediately rather than a frame later.
  state.speedtest.state = "running"
  state.speedtest.elapsed_ms = 0
  render_speedtest()

  sbar.exec(cmd, function(out)
    apply_speedtest(out)
    render_speedtest()
    if state.speedtest.state == "running" then
      poll_speedtest(POLL_SECONDS)
    end
  end)
end

local function cancel_speedtest()
  sbar.exec(SPEEDTEST .. " cancel", function(out)
    apply_speedtest(out)
    render_speedtest()
  end)
end

-- Older macwifi builds have no speedtest subcommand; probe once so the UI can
-- disable the control instead of failing on click.
local function probe_speedtest()
  sbar.exec(SPEEDTEST .. " capability", function(out)
    state.speedtest.supported = (out or ""):match("supported=1") ~= nil
    render_speedtest()
  end)
end

-- ---------------------------------------------------------------- static UI
spacer(9)

-- Title line: signal glyph + SSID on the left, QR share button on the right.
-- QR sharing has no macwifi backend: kept for UI parity, no handler attached.
local hero = row("wifi.hero", pad, {
  icon = {
    string = icons.wifi.off .. "  Wi-Fi",
    width = width - 2 * pad - 28,
    align = "left",
    padding_left = 0,
    padding_right = 0,
    font = font(SZ_TITLE, FONT_BOLD),
    color = colors.text,
  },
  label = {
    string = icons.wifi.qr,
    width = 28,
    align = "center",
    padding_left = 0,
    padding_right = 0,
    font = font(12.0),
    color = colors.subtle,
    background = {
      drawing = true,
      height = 26,
      corner_radius = 8,
      border_width = 1,
      border_color = colors.muted,
      color = colors.transparent,
    },
  },
  background = block(26),
})

hero:subscribe("mouse.entered", function()
  hero:set({ label = { background = { border_color = colors.subtle, color = colors.bg2 } } })
end)
hero:subscribe("mouse.exited", function()
  hero:set({ label = { background = { border_color = colors.muted, color = colors.transparent } } })
end)

-- Status line: connection state on the left, power switch on the right.
local hero_meta = row("wifi.meta", pad, {
  icon = {
    string = "NOT CONNECTED",
    width = width - 2 * pad - 44,
    align = "left",
    padding_left = 30,
    padding_right = 0,
    font = font(SZ_SMALL, FONT_BOLD),
    color = colors.muted,
  },
  label = {
    string = "●",
    width = 44,
    align = "right",
    padding_left = 6,
    padding_right = 6,
    font = font(15.0),
    color = colors.muted,
    background = {
      drawing = true,
      height = 20,
      corner_radius = 10,
      border_width = 0,
      color = colors.overlay,
    },
  },
  background = block(22),
})

local power_row = hero_meta
power_row:subscribe("mouse.clicked", function(env)
  if env.BUTTON ~= "left" then return end
  toggle_power()
end)

spacer(8)

local radio_row = stat_line("wifi.detail.radio")
spacer(6)
local link_row = stat_line("wifi.detail.link")
spacer(6)
local device_row = stat_line("wifi.detail.device")
spacer(16)

divider()
spacer(11)

-- DNS provider: no macwifi backend, so the choices do nothing.
section_header("DNS PROVIDER", "wifi.dns.hdr")
row("wifi.dns", pad, {
  icon = hidden,
  label = {
    string = slots({ "DHCP", "Cloudflare", "Google", "Custom" }, 44),
    width = width - 2 * pad,
    align = "center",
    padding_left = 0,
    padding_right = 0,
    font = font(SZ_PILL),
    color = colors.text,
  },
  background = {
    drawing = true,
    height = 28,
    corner_radius = 8,
    border_width = 1,
    border_color = colors.muted,
    color = colors.transparent,
  },
})

spacer(12)
divider()
spacer(6)

-- Clicking Run starts a test and throws up the full-screen dial overlay. The
-- row itself keeps reporting state, so the numbers are still here after the
-- overlay closes.
local speed_row = row("wifi.speed", pad, {
  icon = {
    string = "SPEED TEST",
    width = width - 2 * pad - 52,
    align = "left",
    padding_left = 0,
    padding_right = 0,
    font = font(SZ_SMALL, FONT_BOLD),
    color = colors.muted,
  },
  label = {
    string = "Run",
    width = 52,
    align = "center",
    padding_left = 0,
    padding_right = 0,
    font = font(SZ_PILL, FONT_SEMI),
    color = colors.text,
    background = {
      drawing = true,
      height = 22,
      corner_radius = 8,
      border_width = 1,
      border_color = colors.muted,
      color = colors.transparent,
    },
  },
  background = block(26),
})

render_speedtest = function()
  local st = state.speedtest
  local left, left_color = "SPEED TEST", colors.muted
  local button, button_color = "Run", colors.text

  if st.supported == false then
    left = "SPEED TEST   UNAVAILABLE"
    button, button_color = "--", colors.muted
  elseif st.state == "running" then
    left = "SPEED TEST   MEASURING…"
    button, button_color = "···", colors.gold
  elseif st.state == "done" then
    left = string.format("SPEED TEST   %s %.1f  %s %.1f",
      icons.wifi.down, st.download or 0,
      icons.wifi.up, st.upload or 0)
    left_color = colors.text
  elseif st.state == "failed" then
    left = "SPEED TEST   FAILED"
    left_color = colors.red
  end

  local on_focus = focused_kind() == "speed"
  speed_row:set({
    icon = { string = left, color = left_color },
    label = {
      string = button,
      color = button_color,
      background = {
        border_color = on_focus and colors.text or colors.muted,
        color = on_focus and colors.bg2 or colors.transparent,
      },
    },
  })
end

speed_row:subscribe("mouse.entered", function()
  speed_row:set({ label = { background = { border_color = colors.subtle, color = colors.bg2 } } })
end)
speed_row:subscribe("mouse.exited", function()
  speed_row:set({ label = { background = { border_color = colors.muted, color = colors.transparent } } })
end)

-- Shared by the Run button and the keyboard, which reach it through the focus
-- ring rather than through a click.
local function run_speedtest()
  if state.speedtest.supported == false then return end

  -- Sketchybar draws its popup above the overlay window, so close it first.
  popup_open = false
  wifi:set({ popup = { drawing = false } })
  keys.stop_all()

  start_speedtest()

  -- pkill -x matches the process name only, so it cannot match the shell that
  -- is running this line. Keeps a second click from stacking overlays.
  sbar.exec("pkill -x speedtest_overlay >/dev/null 2>&1; "
    .. OVERLAY .. overlay_palette()
    .. " >/dev/null 2>&1 &")
end

speed_row:subscribe("mouse.clicked", function(env)
  if env.BUTTON ~= "left" then return end
  run_speedtest()
end)

spacer(6)
divider()
spacer(6)

-- ---------------------------------------------------------------- rendering
local function render_bar()
  local connected = state.ssid ~= "" and state.powered
  wifi:set({
    icon = {
      string = connected and bars(state.rssi) or icons.wifi.off,
      color = connected and colors.white or colors.red,
    },
  })
end

local function render_hero()
  local connected = state.ssid ~= "" and state.powered
  hero:set({
    icon = {
      string = (connected and bars(state.rssi) or icons.wifi.off)
        .. "   "
        .. (connected and state.ssid or (state.powered and "Not connected" or "Wi-Fi is off")),
    },
  })
  local meta = "NOT CONNECTED"
  local meta_color = colors.muted
  if not state.powered then
    meta = "WIFI OFF"
    meta_color = colors.red
  elseif connected then
    meta = "CONNECTED"
    meta_color = colors.pine
  end
  hero_meta:set({ icon = { string = meta, color = meta_color } })
end

local function render_details()
  local dash = "--"
  local connected = state.ssid ~= "" and state.powered
  set_stats(radio_row,
    "Signal", connected and (state.rssi .. " dBm") or dash,
    "Noise", connected and (state.noise .. " dBm") or dash)
  set_stats(link_row,
    "Channel", connected and fmt_channel(state.channel) or dash,
    "TX rate", connected and (state.txrate .. " Mbps") or dash)
  set_stats(device_row,
    "Interface", state.iface ~= "" and state.iface or dash,
    "BSSID", connected and state.bssid or dash)
end

-- Knob to the right on a lit track when the radio is on, to the left on a
-- dark track when it is off.
local function render_power()
  -- The pill's fill already encodes on/off, so keyboard focus is a border
  -- around it rather than another colour inside it.
  local on_focus = focused_kind() == "power"
  power_row:set({
    label = {
      align = state.powered and "right" or "left",
      color = state.powered and colors.text or colors.muted,
      background = {
        color = state.powered and colors.highlight_high or colors.overlay,
        border_width = on_focus and 1 or 0,
        border_color = colors.text,
      },
    },
  })
end

-- ---------------------------------------------------------------- networks
local nets_header
local nets_footer
local network_slots = {}

-- Everything about a row that sketchybar has to be told, flattened so an
-- unchanged row can be recognised and skipped instead of re-sent.
local function slot_text(net)
  local status = ""
  local status_color = colors.muted
  if net.ssid == state.pending then
    status = state.pending_kind == "disconnect" and "Disconnecting…"
      or state.pending_kind == "forget" and "Forgetting…"
      or "Connecting…"
    status_color = colors.gold
  elseif net.connected then
    status = "Connected"
  elseif net.known then
    -- The list used to carry KNOWN / OTHER section headers, but a header is a
    -- row of its own height and scrolling one through a fixed window makes the
    -- panel jump. The same fact rides along on the row instead.
    status = "Saved"
  end

  if is_secured(net.sec) then
    status = status == "" and icons.wifi.lock or (status .. "  " .. icons.wifi.lock)
  end

  return bars(net.rssi) .. "  " .. net.ssid,
    net.connected and colors.text or colors.subtle,
    status,
    status_color
end

-- Background is repainted on its own by hover and by focus moves, so it is
-- tracked separately from the text and never forces a full row rewrite.
paint_slot = function(slot, color)
  if slot.applied.bg == color then return end
  slot.applied.bg = color
  slot.item:set({ background = { color = color } })
end

local function render_slot(slot, net)
  if not net then
    if slot.net == nil then return end
    slot.net = nil
    slot.applied = {}
    slot.item:set({ drawing = false })
    return
  end

  slot.net = net
  local name, name_color, status, status_color = slot_text(net)
  local color = row_color(net)
  local sig = table.concat({ name, tostring(name_color), status, tostring(status_color) }, "\31")
  if slot.applied.sig == sig then
    paint_slot(slot, color)
    return
  end
  slot.applied.sig = sig
  slot.applied.bg = color
  slot.item:set({
    drawing = true,
    icon = { string = name, color = name_color },
    label = { string = status, color = status_color },
    background = { color = color },
  })
end

render_networks = function()
  -- refresh() can land before the list below this function has been built.
  if not nets_footer then
    render_power()
    render_speedtest()
    return
  end

  local nets = {}
  if state.powered then
    for _, n in ipairs(state.networks) do
      n.connected = n.ssid == state.ssid
      nets[#nets + 1] = n
    end
  end

  -- Bucketing the signal keeps the order still. Raw RSSI wanders a few dB
  -- between scans, and sorting on it directly had rows swapping places under
  -- the pointer every few seconds; the SSID tiebreak makes the rest of the
  -- order reproducible, which table.sort on its own does not guarantee.
  table.sort(nets, function(a, b)
    if a.connected ~= b.connected then return a.connected end
    if a.known ~= b.known then return a.known end
    local ba, bb = math.floor(a.rssi / 5), math.floor(b.rssi / 5)
    if ba ~= bb then return ba > bb end
    return a.ssid < b.ssid
  end)
  sorted_networks = nets

  -- Focus is held as an SSID, so a network that dropped out of the scan (or
  -- the radio going off under it) hands the ring back to the power switch.
  if focus.kind == "network" and not find_network(focus.ssid) then
    focus = { kind = "power" }
  end

  local max_offset = math.max(1, #nets - NETWORK_PAGE_SIZE + 1)
  network_offset = math.max(1, math.min(network_offset, max_offset))
  local last_visible = math.min(#nets, network_offset + NETWORK_PAGE_SIZE - 1)

  for slot_index, slot in ipairs(network_slots) do
    render_slot(slot, nets[network_offset + slot_index - 1])
  end

  nets_header:set({
    label = { string = state.scanning and "SCANNING WI-FI…" or "NETWORKS" },
  })

  local readout = ""
  if #nets > NETWORK_PAGE_SIZE then
    readout = (network_offset > 1 and "↑" or " ")
      .. "     " .. network_offset .. "–" .. last_visible .. " of " .. #nets .. "     "
      .. (last_visible < #nets and "↓" or " ")
  end
  nets_footer:set({ label = { string = readout } })

  render_power()
  render_speedtest()
end

-- SCROLL_DELTA is a line count, not a pixel count, and sketchybar has already
-- summed every event of the last 150ms into it before handing it over -- so
-- one delivery is one deliberate flick of the wheel and its magnitude is worth
-- honouring. The old handler threw the magnitude away and moved a single row
-- per delivery, which is what made a fast scroll feel like it was ignoring
-- most of the gesture. A page is the most one delivery may move: past that the
-- list has jumped somewhere the eye cannot follow.
scroll_networks = function(delta)
  local max_offset = math.max(1, #sorted_networks - NETWORK_PAGE_SIZE + 1)
  if max_offset == 1 then return end

  -- Positive delta is a scroll towards the top of the list.
  local rows = -delta
  if rows > NETWORK_PAGE_SIZE then rows = NETWORK_PAGE_SIZE
  elseif rows < -NETWORK_PAGE_SIZE then rows = -NETWORK_PAGE_SIZE end

  local next_offset = math.max(1, math.min(network_offset + rows, max_offset))
  if next_offset == network_offset then return end
  network_offset = next_offset
  -- Scrolling moves the viewport and nothing else: the keyboard stays on the
  -- network it was on, visible or not.
  render_networks()
end

-- ---------------------------------------------------------------- keyboard
-- Focus is drawn by repainting the visible slots; the two fixed controls draw
-- their own focus state from `focus`.
render_focus = function()
  for _, slot in ipairs(network_slots) do
    if slot.net then paint_slot(slot, row_color(slot.net)) end
  end
  render_power()
  render_speedtest()
end

-- Where the current focus sits in the ring: 1 power, 2 speed test, then one
-- position per network in list order.
local function focus_position()
  if focus.kind == "power" then return 1 end
  if focus.kind == "speed" then return 2 end
  for i, net in ipairs(sorted_networks) do
    if net.ssid == focus.ssid then return i + 2 end
  end
  return 1
end

local function move_focus(delta)
  local total = #sorted_networks + 2
  local position = ((focus_position() - 1 + delta) % total) + 1

  if position == 1 then
    focus = { kind = "power" }
  elseif position == 2 then
    focus = { kind = "speed" }
  else
    local index = position - 2
    focus = { kind = "network", ssid = sorted_networks[index].ssid }
    -- Drag the viewport along only as far as it takes to show the new row.
    if index < network_offset then
      network_offset = index
    elseif index > network_offset + NETWORK_PAGE_SIZE - 1 then
      network_offset = index - NETWORK_PAGE_SIZE + 1
    end
  end
  render_networks()
end

-- Enter does whatever a left click on the focused row would do.
local function activate_focus()
  if focus.kind == "power" then
    toggle_power()
  elseif focus.kind == "speed" then
    run_speedtest()
  elseif focus.kind == "network" then
    local net = find_network(focus.ssid)
    if not net or state.pending ~= "" then return end
    if net.connected then
      disconnect_network()
    else
      connect_network(net.ssid, is_secured(net.sec), net.known)
    end
  end
end

-- ---------------------------------------------------------------- refresh
local function apply_status(out)
  if not (out or ""):match("^ok=1\n") then return false end
  for line in (out or ""):gmatch("([^\n]+)") do
    local k, v = line:match("^([^=]+)=(.+)$")
    if k and v then
      if k == "powered" then state.powered = v == "1"
      elseif k == "ssid" then state.ssid = v ~= "-" and v or ""
      elseif k == "rssi" then state.rssi = tonumber(v) or 0
      elseif k == "noise" then state.noise = tonumber(v) or 0
      elseif k == "channel" then state.channel = tonumber(v) or 0
      elseif k == "txrate" then state.txrate = tonumber(v) or 0
      elseif k == "bssid" then state.bssid = v
      elseif k == "iface" then state.iface = v
      elseif k == "hwaddr" then state.hwaddr = v end
    end
  end
  return true
end

local function apply_scan(out)
  if not (out or ""):match("^ok=1\n") then return false end
  local networks = {}
  local by_ssid = {}
  for line in (out or ""):gmatch("([^\n]+)") do
    local ssid, rssi, ch, sec, bssid, known =
      line:match("^(.-)\t(.*)\t(.*)\t(.*)\t(.*)\t(.*)$")
    -- macwifi scans per BSSID, so a mesh or a dual-band AP shows up once per
    -- radio under one SSID. The list keys off the SSID, so collapse them to
    -- the strongest sighting rather than drawing the same name several times.
    -- Every AP that does not broadcast its name comes back under the same
    -- "<hidden>" placeholder -- eighty-odd of them here -- and none of them
    -- can be joined by name, so they are dropped rather than deduplicated.
    if ssid and ssid ~= "" and ssid ~= "<hidden>" then
      local net = {
        ssid = ssid,
        rssi = tonumber(rssi) or -100,
        ch = tonumber(ch) or 0,
        sec = sec,
        bssid = bssid,
        known = known == "1",
      }
      local seen = by_ssid[ssid]
      if not seen then
        by_ssid[ssid] = net
        networks[#networks + 1] = net
      elseif net.rssi > seen.rssi then
        seen.rssi, seen.ch, seen.bssid = net.rssi, net.ch, net.bssid
      end
    end
  end
  state.networks = networks
  return true
end

local function render_all()
  render_bar()
  render_hero()
  render_details()
  -- The list carries the connected row and the power-off empty state, so a
  -- status-only refresh has to reach it too.
  render_networks()
end

local function scan_networks()
  if scan_active then
    scan_again = true
    return
  end
  scan_active = true
  state.scanning = true
  sbar.exec(helpers .. "/wifi_scan.sh", function(out)
    scan_active = false
    state.scanning = false
    if apply_scan(out) then render_networks() end
    if scan_again then
      scan_again = false
      scan_networks()
    end
  end)
end

local function ping_status()
  sbar.exec(helpers .. "/wifi_status.sh", function(out)
    if apply_status(out) then render_all() end
  end)
end

refresh = function(include_scan)
  ping_status()
  if include_scan then
    scan_networks()
  end
end

schedule_refresh = function(sec)
  if scheduler_active then return end
  scheduler_active = true
  sbar.exec("sleep " .. tostring(sec) .. "; " .. helpers .. "/wifi_status.sh", function(out)
    scheduler_active = false
    state.pending = ""
    state.pending_kind = ""
    if apply_status(out) then render_all() end
    scan_networks()
  end)
end

-- --------------------------------------------------------- networks header
-- Always drawn, so a scan starting or finishing cannot change the panel's
-- height under the pointer.
nets_header = section_header("NETWORKS", "wifi.nets.hdr")

-- A window of reusable rows over `sorted_networks`. They are created once,
-- with every fixed property (box widths, fonts, alignment, row height) already
-- in place, so scrolling only ever rewrites the two strings and their colours.
-- Creating them fully formed also keeps icon.drawing/label.drawing on: those
-- two are sticky in sketchybar, and a row built from the shared `hidden` stub
-- would never draw its text again no matter what string was set on it.
for i = 1, NETWORK_PAGE_SIZE do
  local slot = { net = nil, applied = {} }
  slot.item = row("wifi.net.slot." .. i, 8, {
    drawing = false,
    icon = {
      drawing = true,
      string = "",
      width = NETWORK_NAME_WIDTH,
      align = "left",
      padding_left = 12,
      padding_right = 0,
      font = font(SZ_NET, FONT_SEMI),
      color = colors.subtle,
    },
    label = {
      drawing = true,
      string = "",
      width = width - 16 - NETWORK_NAME_WIDTH,
      align = "right",
      padding_left = 0,
      padding_right = 14,
      font = font(SZ_PILL),
      color = colors.muted,
    },
    background = {
      drawing = true,
      height = NETWORK_ROW_HEIGHT,
      corner_radius = 8,
      border_width = 0,
      color = colors.transparent,
    },
  })
  slot.item:subscribe("mouse.entered", function()
    if slot.net then paint_slot(slot, colors.bg2) end
  end)
  slot.item:subscribe("mouse.exited", function()
    if slot.net then paint_slot(slot, row_color(slot.net)) end
  end)
  slot.item:subscribe("mouse.clicked", function(env)
    local net = slot.net
    if not net then return end
    -- Clicking a row is also a way of pointing at it, so the keyboard picks up
    -- where the mouse left off instead of from wherever it was before.
    focus = { kind = "network", ssid = net.ssid }
    render_focus()
    if env.BUTTON == "right" then
      if not net.connected and net.known and is_secured(net.sec) then
        forget_network(net.ssid)
      end
      return
    end
    if state.pending ~= "" then return end
    if net.connected then
      disconnect_network()
    else
      connect_network(net.ssid, is_secured(net.sec), net.known)
    end
  end)
  network_slots[#network_slots + 1] = slot
end

-- Scroll position readout. Also always drawn, for the same reason as the
-- header: a list that grows past the window must not shove the panel.
nets_footer = section_header("", "wifi.nets.footer")
nets_footer:set({ label = { align = "center", color = colors.muted } })

spacer(8, "wifi.nets.pad")

-- ---------------------------------------------------------------- events
local function close_popup()
  popup_open = false
  wifi:set({ popup = { drawing = false } })
  nav.stop()
end

-- Up/down walk the ring; left/right do the same, since the panel is one
-- column and an arrow that does nothing reads as a broken key. The ring wraps,
-- so the list is reachable from either end.
nav = keys.bind("wifi", function(key)
  if key == "escape" then
    close_popup()
  elseif key == "up" or key == "left" then
    move_focus(-1)
  elseif key == "down" or key == "right" then
    move_focus(1)
  elseif key == "return" then
    activate_focus()
  end
end)

-- The panel proper. Everything below this line still builds the sketchybar
-- popup, which stays as the fallback: left click opens the window, and the old
-- popup is still reachable through wifi_popup_toggle_inline.
--
-- The window exists for the data path, not the pixels. `macwifi scan` is ~13s
-- for a full sweep because every invocation is a cold process; CoreWLAN's
-- cached results answer in ~45ms, but only a process that outlives a single
-- click can hold that cache open and refresh it behind the user. See
-- helpers/wifi_panel/wifi_panel.swift.
local PANEL = helpers .. "/wifi_panel/bin/wifi_panel"

local function panel_palette()
  local function hex(color)
    return string.format("0x%08x", color)
  end
  return " --foreground " .. hex(colors.text)
    .. " --background " .. hex(colors.base)
    .. " --accent " .. hex(colors.iris)
    .. " --urgent " .. hex(colors.love)
    .. " --muted " .. hex(colors.muted)
    .. " --border " .. hex(colors.popup.border)
end

-- The panel dismisses itself on blur, so the only case this has to handle is a
-- second click on the bar item while it is up -- which should close it rather
-- than stack a second window. pkill either way, then relaunch if it was shut.
local function open_panel()
  -- One round trip answers both questions: is a panel already up, and if not,
  -- how tall is the bar it has to hang under. The bar height is not a constant
  -- here -- helpers/display.lua swaps it between the notched built-in display
  -- and an external one -- so it has to be read rather than assumed.
  sbar.exec(
    "pgrep -x wifi_panel >/dev/null && echo up "
      .. "|| sketchybar --query bar | /usr/bin/jq -r '.geometry.height // 30'",
    function(out)
      local answer = strip(out or "")
      if answer == "up" then
        sbar.exec("pkill -x wifi_panel")
        return
      end
      sbar.exec(sh(PANEL) .. panel_palette()
        .. " --font " .. sh(settings.font.text)
        .. " --macwifi " .. sh(MACWIFI)
        .. " --helpers " .. sh(helpers)
        .. " --anchor-y " .. (tonumber(answer) or 30)
        .. " >/dev/null 2>&1 &")
    end)
end

local function toggle_popup()
  local drawing = wifi:query().popup.drawing
  popup_open = drawing == "off"
  wifi:set({ popup = { drawing = "toggle" } })
  if not popup_open then
    nav.stop()
    return
  end
  -- Every open starts on the power switch, so the first arrow press always
  -- moves somewhere predictable.
  focus = { kind = "power" }
  network_offset = 1
  render_focus()
  nav.start()

  refresh(true)
  -- macwifi may have been upgraded since the config loaded, so re-check
  -- whether it can run a speed test now. This is the only moment the Run
  -- button is visible, so it is the only moment the answer matters.
  probe_speedtest()
end

wifi:subscribe("mouse.clicked", function(env)
  -- Right click opens the full macwifi TUI. There is no `mouse.right` event in
  -- sketchybar -- the button arrives as $BUTTON on mouse.clicked -- so this has
  -- to branch here rather than be its own subscription.
  if env.BUTTON == "right" then
    sbar.exec(sh(config_dir .. "/helpers/wifi_launch.command"))
    return
  end
  if env.BUTTON ~= "left" then return end
  open_panel()
end)

-- The wheel drives the network list from anywhere in the panel. Binding it to
-- the network rows alone meant hunting for them with the pointer, and a row
-- that scrolled away took its own scroll target with it.
local function on_scroll(env)
  local delta = tonumber(env.SCROLL_DELTA) or 0
  if delta ~= 0 then scroll_networks(delta) end
end

for _, item in ipairs(popup_rows) do
  item:subscribe("mouse.scrolled", on_scroll)
end

-- Opens the panel from anywhere: `sketchybar --trigger wifi_popup_toggle`,
-- which is how the skhd binding reaches it. Same path as a click, so the panel
-- comes up already focused and ready for the arrow keys.
sbar.add("event", "wifi_popup_toggle")
wifi:subscribe("wifi_popup_toggle", open_panel)

-- The sketchybar popup is still here and still works; it just is not what a
-- click opens any more. Kept reachable so there is a way back if the window
-- misbehaves on a machine where Location Services is refused.
sbar.add("event", "wifi_popup_toggle_inline")
wifi:subscribe("wifi_popup_toggle_inline", toggle_popup)

wifi:subscribe({ "wifi_change", "system_woke" }, function()
  refresh(false)
end)

refresh(false)

probe_speedtest()
-- Adopt a run still in flight, e.g. across a config reload.
poll_speedtest(0)
