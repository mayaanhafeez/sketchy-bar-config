local settings = require("settings")

local icons = {
  sf_symbols = {
    apple = "􀣺",
    cpu = "􀫥",

    volume = {
      _100 = "􀊩",
      _66  = "􀊧",
      _33  = "􀊥",
      _10  = "􀊡",
      _0   = "􀊣",
    },
    battery = {
      _100     = "󰁹",
      _75      = "󰁾",
      _50      = "󰁼",
      _25      = "󰁺",
      _0       = "󰂎",
      charging = "󰂆",
    },
    wifi = {
      connected    = "󰤨",
      disconnected = "󰤭",
    },
    media = {
      back       = "􀊊",
      forward    = "􀊌",
      play_pause = "􀊈",
    },
  },

  nerdfont = {
    apple = "",
    cpu = "",

    volume = {
      _100 = "",
      _66  = "",
      _33  = "",
      _10  = "",
      _0   = "",
    },
    battery = {
      _100     = "󰁹",
      _75      = "󰁾",
      _50      = "󰁼",
      _25      = "󰁺",
      _0       = "󰂎",
      charging = "󰂆",
    },
    wifi = {
      connected    = "󰖩",
      disconnected = "󰖪",
    },
    media = {
      back       = "",
      forward    = "",
      play_pause = "",
    },
  },
}

if not (settings.icons == "NerdFont") then
  return icons.sf_symbols
else
  return icons.nerdfont
end
