local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local helpers = config_dir .. "/helpers"
-- MACWIFI_BIN points this (and helpers/wifi_speedtest.sh) at a different build,
-- e.g. target/debug/macwifi while a feature is still unreleased.
local MACWIFI = os.getenv("MACWIFI_BIN") or "/usr/local/bin/macwifi"

local width = 336
local pad = 12

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

-- Shared by every popup row, so the icon and label boxes below can be
-- positioned in absolute pixels. `inset` pulls the whole row (its background
-- included) in from both edges of the panel.
local function row(name, inset, opts)
  opts.position = "popup.widgets.wifi"
  opts.width = width - 2 * inset
  opts.padding_left = inset
  opts.padding_right = inset
  opts.scroll_texts = false
  return sbar.add("item", name, opts)
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
local scheduler_active = false
local scan_active = false
local scan_again = false

-- ------------------------------------------------------- forward references
local render_networks
local refresh
local schedule_refresh

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

  speed_row:set({
    icon = { string = left, color = left_color },
    label = { string = button, color = button_color },
  })
end

speed_row:subscribe("mouse.entered", function()
  speed_row:set({ label = { background = { border_color = colors.subtle, color = colors.bg2 } } })
end)
speed_row:subscribe("mouse.exited", function()
  speed_row:set({ label = { background = { border_color = colors.muted, color = colors.transparent } } })
end)

speed_row:subscribe("mouse.clicked", function(env)
  if env.BUTTON ~= "left" then return end
  if state.speedtest.supported == false then return end

  -- Sketchybar draws its popup above the overlay window, so close it first.
  popup_open = false
  wifi:set({ popup = { drawing = false } })

  start_speedtest()

  -- pkill -x matches the process name only, so it cannot match the shell that
  -- is running this line. Keeps a second click from stacking overlays.
  sbar.exec("pkill -x speedtest_overlay >/dev/null 2>&1; "
    .. OVERLAY .. overlay_palette()
    .. " >/dev/null 2>&1 &")
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
  power_row:set({
    label = {
      align = state.powered and "right" or "left",
      color = state.powered and colors.text or colors.muted,
      background = { color = state.powered and colors.highlight_high or colors.overlay },
    },
  })
end

-- ---------------------------------------------------------------- networks
local nets_header

local function add_network_row(index, net)
  local connected = net.ssid == state.ssid
  local pending = net.ssid == state.pending

  local status = ""
  local status_color = colors.muted
  if pending then
    status = state.pending_kind == "disconnect" and "Disconnecting…"
      or state.pending_kind == "forget" and "Forgetting…"
      or "Connecting…"
    status_color = colors.gold
  elseif connected then
    status = "Connected"
  end

  if is_secured(net.sec) then
    status = status == "" and icons.wifi.lock or (status .. "  " .. icons.wifi.lock)
  end

  local net_row = row("wifi.net." .. index, 8, {
    background = {
      drawing = true,
      height = connected and 34 or 32,
      corner_radius = 8,
      border_width = 0,
      color = connected and colors.bg2 or colors.transparent,
    },
    icon = {
      string = bars(net.rssi) .. "  " .. net.ssid,
      width = 192,
      align = "left",
      padding_left = 12,
      padding_right = 0,
      font = font(SZ_NET, FONT_SEMI),
      color = connected and colors.text or colors.subtle,
    },
    label = {
      string = status,
      width = width - 16 - 192,
      align = "right",
      padding_left = 0,
      padding_right = 14,
      font = font(SZ_PILL),
      color = status_color,
    },
  })

  net_row:subscribe("mouse.entered", function()
    net_row:set({ background = { color = colors.bg2 } })
  end)
  net_row:subscribe("mouse.exited", function()
    net_row:set({ background = { color = connected and colors.bg2 or colors.transparent } })
  end)
  net_row:subscribe("mouse.clicked", function(env)
    if env.BUTTON == "right" then
      if not connected and net.known and is_secured(net.sec) then
        forget_network(net.ssid)
      end
      return
    end
    if state.pending ~= "" then return end
    if connected then
      disconnect_network()
    else
      connect_network(net.ssid, is_secured(net.sec), net.known)
    end
  end)
end

render_networks = function()
  sbar.remove("/wifi\\.net\\../")
  sbar.remove("/wifi\\.section\\../")

  if nets_header then
    nets_header:set({
      drawing = state.scanning,
      label = { string = "SCANNING WI-FI…" },
    })
  end

  if not state.powered then
    return
  end

  local nets = {}
  for _, n in ipairs(state.networks) do
    n.connected = n.ssid == state.ssid
    nets[#nets + 1] = n
  end

  table.sort(nets, function(a, b)
    if a.connected ~= b.connected then return a.connected end
    if a.known ~= b.known then return a.known end
    return a.rssi > b.rssi
  end)

  local last_title = ""
  local index = 0
  for i, net in ipairs(nets) do
    local title = ""
    if net.known and i == 1 then
      title = "KNOWN NETWORKS"
    elseif not net.known and (i == 1 or nets[i - 1].known) then
      title = "OTHER NETWORKS"
    end
    if title ~= "" and title ~= last_title then
      last_title = title
      section_header(title)
    end
    add_network_row(index, net)
    index = index + 1
  end

  spacer(10, "wifi.section.pad")
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
  for line in (out or ""):gmatch("([^\n]+)") do
    local ssid, rssi, ch, sec, bssid, known =
      line:match("^(.-)\t(.*)\t(.*)\t(.*)\t(.*)\t(.*)$")
    if ssid then
      networks[#networks + 1] = {
        ssid = ssid,
        rssi = tonumber(rssi) or -100,
        ch = tonumber(ch) or 0,
        sec = sec,
        bssid = bssid,
        known = known == "1",
      }
    end
  end
  state.networks = networks
  return true
end

local function render_all()
  render_bar()
  render_hero()
  render_details()
  render_power()
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
-- Only drawn while a scan is in flight; the KNOWN / OTHER headers below it
-- carry the labelling once results land.
nets_header = section_header("SCANNING WI-FI…", "wifi.nets.hdr")
nets_header:set({ drawing = false })

-- ---------------------------------------------------------------- events
wifi:subscribe("mouse.clicked", function(env)
  -- Right click opens the full macwifi TUI. There is no `mouse.right` event in
  -- sketchybar -- the button arrives as $BUTTON on mouse.clicked -- so this has
  -- to branch here rather than be its own subscription.
  if env.BUTTON == "right" then
    sbar.exec(sh(config_dir .. "/helpers/wifi_launch.command"))
    return
  end
  if env.BUTTON ~= "left" then return end

  local drawing = wifi:query().popup.drawing
  popup_open = drawing == "off"
  wifi:set({ popup = { drawing = "toggle" } })
  if popup_open then
    refresh(true)
    -- macwifi may have been upgraded since the config loaded, so re-check
    -- whether it can run a speed test now. This is the only moment the Run
    -- button is visible, so it is the only moment the answer matters.
    probe_speedtest()
  end
end)

wifi:subscribe({ "wifi_change", "system_woke" }, function()
  refresh(false)
end)

refresh(false)

probe_speedtest()
-- Adopt a run still in flight, e.g. across a config reload.
poll_speedtest(0)
