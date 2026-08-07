local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

local config_dir = os.getenv("CONFIG_DIR") or (os.getenv("HOME") .. "/.config/sketchybar")
local helpers = config_dir .. "/helpers"
local MACWIFI = "/usr/local/bin/macwifi"

local width = 280

-- Wi-Fi panel, ported from omarchy's network panel (Panel.qml) onto a
-- sketchybar popup. Everything macwifi can do is wired up (status, scan,
-- connect, disconnect, forget, power); the controls macwifi has no backend
-- for (QR share, speed test, band pinning, DNS provider) stay on screen for
-- UI parity but do nothing when clicked.
local wifi = sbar.add("item", "widgets.wifi", {
  position = "right",
  icon = { string = icons.wifi.off, color = colors.white },
  label = { drawing = false },
  popup = { align = "center" },
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

-- ------------------------------------------------------------- row builders
local flat = { drawing = false }

local function detail_row(label)
  return {
    position = "popup.widgets.wifi",
    width = width,
    icon = {
      string = label,
      width = 150,
      align = "left",
      font = { family = settings.font.text, style = FONT_REG, size = 12.0 },
      color = colors.muted,
    },
    label = {
      string = "--",
      width = 116,
      align = "right",
      font = { family = settings.font.text, style = FONT_REG, size = 12.0 },
      color = colors.text,
    },
    background = flat,
  }
end

local section_seq = 0
local function section_header(text, prefix)
  section_seq = section_seq + 1
  prefix = prefix or "wifi.section"
  return sbar.add("item", prefix .. "." .. section_seq, {
    position = "popup.widgets.wifi",
    width = width,
    icon = { drawing = false },
    label = {
      string = text,
      padding_left = 8,
      font = { family = settings.font.text, style = FONT_BOLD, size = 11.0 },
      color = colors.muted,
    },
    background = flat,
  })
end

local function pill_button(name, text, handler)
  local item = sbar.add("item", name, {
    position = "popup.widgets.wifi",
    width = width,
    icon = { drawing = false },
    label = {
      string = text,
      align = "center",
      font = { family = settings.font.text, style = FONT_SEMI, size = 13.0 },
      color = colors.text,
    },
  })
  item:subscribe("mouse.entered", function()
    item:set({ background = { color = colors.bg2 } })
  end)
  item:subscribe("mouse.exited", function()
    item:set({ background = { color = colors.transparent } })
  end)
  if handler then
    item:subscribe("mouse.left", handler)
  end
  return item
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
}

local popup_open = false
local scheduler_active = false

-- ------------------------------------------------------- forward references
local render_networks
local refresh
local schedule_refresh

-- ---------------------------------------------------------------- actions
local function join(ssid, password)
  local cmd = helpers .. "/wifi_join.command " .. sh(ssid)
  if password then
    cmd = "PASS=" .. sh(password) .. " " .. cmd
  end
  sbar.exec(cmd, function() schedule_refresh(4) end)
end

local function connect_network(ssid, secured)
  if state.pending ~= "" then return end
  state.pending = ssid
  state.pending_kind = "connect"
  render_networks()

  if not secured then
    join(ssid, nil)
    return
  end

  -- Reuse macwifi's own login-keychain cache when we have one (silent path).
  sbar.exec("security find-generic-password -s macwifi-wifi -a " .. sh(ssid) .. " -w 2>/dev/null", function(pw)
    pw = strip(pw)
    if pw ~= "" then
      join(ssid, pw)
      return
    end
    -- Otherwise ask; cancelling just leaves the row as it was.
    sbar.exec(
      'osascript -e \'set pw to text returned of (display dialog "Password for '
        .. escape_dialog(ssid)
        .. ':" default answer "" with hidden answer)\'',
      function(pw)
        pw = strip(pw)
        if pw ~= "" then
          join(ssid, pw)
        else
          state.pending = ""
          state.pending_kind = ""
          render_networks()
        end
      end
    )
  end)
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

-- ---------------------------------------------------------------- static UI
local hero = sbar.add("item", "wifi.hero", {
  position = "popup.widgets.wifi",
  width = width,
  icon = {
    string = icons.wifi.off,
    font = { family = settings.font.text, style = FONT_REG, size = 18.0 },
    color = colors.text,
  },
  label = {
    string = "Wi-Fi",
    font = { family = settings.font.text, style = FONT_SEMI, size = 15.0 },
    color = colors.text,
  },
  background = flat,
})

local hero_meta = sbar.add("item", "wifi.meta", {
  position = "popup.widgets.wifi",
  width = width,
  icon = { drawing = false },
  label = {
    string = "NOT CONNECTED",
    padding_left = 8,
    font = { family = settings.font.text, style = FONT_BOLD, size = 11.0 },
    color = colors.muted,
  },
  background = flat,
})

-- QR sharing and the speed test have no macwifi backend: kept for UI parity,
-- no handler attached, so clicking them does nothing.
pill_button("wifi.qr", icons.wifi.qr .. "   QR code")
pill_button("wifi.speed", icons.wifi.speed .. "   Speed test")

local power_row = pill_button("wifi.power", icons.wifi.power .. "   Wi-Fi", toggle_power)

local function detail(name, label)
  return sbar.add("item", name, detail_row(label))
end

local sig_row = detail("wifi.detail.signal", "Signal")
local noise_row = detail("wifi.detail.noise", "Noise")
local chan_row = detail("wifi.detail.channel", "Channel")
local rate_row = detail("wifi.detail.txrate", "TX rate")
local bssid_row = detail("wifi.detail.bssid", "BSSID")
local iface_row = detail("wifi.detail.iface", "Interface")

-- Band: macwifi can't pin a band, so the header only reports the live band
-- (derived from the channel) and these controls exist but do nothing.
local band_header = section_header("WI-FI BAND", "wifi.band.hdr")
pill_button("wifi.band.auto", "AUTOMATIC  ·  On")
pill_button("wifi.band.2.4", "2.4GHZ")
pill_button("wifi.band.5", "5GHZ")

-- DNS provider: no macwifi backend, so the pills do nothing.
local dns_header = section_header("DNS PROVIDER", "wifi.dns.hdr")
pill_button("wifi.dns.dhcp", "DHCP")
pill_button("wifi.dns.cloudflare", "Cloudflare")
pill_button("wifi.dns.google", "Google")
pill_button("wifi.dns.custom", "Custom")

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
      string = connected and bars(state.rssi) or icons.wifi.off,
      color = colors.text,
    },
    label = {
      string = connected and state.ssid or (state.powered and "Not connected" or "Wi-Fi is off"),
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
  hero_meta:set({ label = { string = meta, color = meta_color } })
end

local function render_details()
  local dash = "--"
  local connected = state.ssid ~= "" and state.powered
  sig_row:set({ label = { string = connected and (state.rssi .. " dBm") or dash } })
  noise_row:set({ label = { string = connected and (state.noise .. " dBm") or dash } })
  chan_row:set({ label = { string = connected and fmt_channel(state.channel) or dash } })
  rate_row:set({ label = { string = connected and (state.txrate .. " Mbps") or dash } })
  bssid_row:set({ label = { string = connected and state.bssid or dash } })
  iface_row:set({ label = { string = state.iface ~= "" and state.iface or dash } })
end

local function render_power()
  power_row:set({
    label = {
      string = icons.wifi.power .. "   Wi-Fi  ·  " .. (state.powered and "On" or "Off"),
    },
  })
end

local function render_band()
  local band = fmt_band(state.channel)
  band_header:set({
    label = { string = band ~= "" and ("WI-FI BAND: " .. band) or "WI-FI BAND" },
  })
end

-- ---------------------------------------------------------------- networks
local nets_header

local function add_network_row(index, net)
  local connected = net.ssid == state.ssid
  local pending = net.ssid == state.pending

  local label = net.ssid
  local label_color = colors.subtle
  if pending then
    local busy = state.pending_kind == "disconnect" and "Disconnecting…"
      or state.pending_kind == "forget" and "Forgetting…"
      or "Connecting…"
    label = label .. "  —  " .. busy
    label_color = colors.gold
  elseif connected then
    label = label .. "  —  Connected"
    label_color = colors.text
  end

  local icon = bars(net.rssi)
  if is_secured(net.sec) then
    icon = icons.wifi.lock .. " " .. icon
  end

  local row = sbar.add("item", "wifi.net." .. index, {
    position = "popup.widgets.wifi",
    width = width,
    background = {
      height = 30,
      corner_radius = 8,
      border_width = 1,
      border_color = connected and colors.pine or colors.bg2,
      color = colors.transparent,
    },
    icon = {
      string = icon,
      font = { family = settings.font.text, style = FONT_REG, size = 14.0 },
      color = connected and colors.pine or colors.subtle,
    },
    label = {
      string = label,
      font = { family = settings.font.text, style = FONT_SEMI, size = 13.0 },
      color = label_color,
    },
  })

  row:subscribe("mouse.entered", function()
    row:set({ background = { color = colors.bg2 } })
  end)
  row:subscribe("mouse.exited", function()
    row:set({ background = { color = colors.transparent } })
  end)
  row:subscribe("mouse.clicked", function(env)
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
      connect_network(net.ssid, is_secured(net.sec))
    end
  end)
end

render_networks = function()
  sbar.remove("/wifi\\.net\\../")
  sbar.remove("/wifi\\.section\\../")

  if not state.powered then
    if nets_header then
      nets_header:set({ label = { string = "WI-FI NETWORKS" } })
    end
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

  if nets_header then
    nets_header:set({
      label = { string = state.scanning and "SCANNING WI-FI…" or "WI-FI NETWORKS" },
    })
  end

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
end

-- ---------------------------------------------------------------- refresh
local function apply_status(out)
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
end

local function apply_scan(out)
  state.networks = {}
  for line in (out or ""):gmatch("([^\n]+)") do
    local ssid, rssi, ch, sec, bssid, known =
      line:match("^(.-)\t(.*)\t(.*)\t(.*)\t(.*)\t(.*)$")
    if ssid then
      state.networks[#state.networks + 1] = {
        ssid = ssid,
        rssi = tonumber(rssi) or -100,
        ch = tonumber(ch) or 0,
        sec = sec,
        bssid = bssid,
        known = known == "1",
      }
    end
  end
end

local function render_all()
  render_bar()
  render_hero()
  render_details()
  render_power()
  render_band()
end

local function scan_networks()
  state.scanning = true
  sbar.exec(helpers .. "/wifi_scan.sh", function(out)
    state.scanning = false
    apply_scan(out)
    render_networks()
  end)
end

local function ping_status()
  sbar.exec(helpers .. "/wifi_status.sh", function(out)
    apply_status(out)
    render_all()
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
    apply_status(out)
    render_all()
    scan_networks()
  end)
end

-- ---------------------------------------------------------------- networks header
nets_header = section_header("WI-FI NETWORKS", "wifi.nets.hdr")

-- ---------------------------------------------------------------- events
wifi:subscribe("mouse.clicked", function(env)
  if env.BUTTON ~= "left" then return end
  local drawing = wifi:query().popup.drawing
  popup_open = drawing == "off"
  wifi:set({ popup = { drawing = "toggle" } })
  if popup_open then
    refresh(true)
  end
end)

-- Right click still opens the full macwifi TUI.
wifi:subscribe("mouse.right", function()
  sbar.exec("'" .. config_dir .. "/helpers/wifi_launch.command'")
end)

wifi:subscribe({ "wifi_change", "system_woke" }, function()
  refresh(false)
end)

refresh(false)