return {
  theme = "rose_pine", -- available: rose_pine, rose_pine_moon, catppuccin_mocha, tokyo_night, tokyo_night_storm, tomorrow_night_burns, andromeda, hinterlands, matte_black, vanta_black

  paddings = 3,
  group_paddings = 5,

  -- Bar height: external monitor (no notch) vs built-in display (notch)
  height_external = 30,
  height_internal = 38,

  icons = "sf-symbols", -- alternatively available: NerdFont

  -- This is a font configuration for SF Pro and SF Mono (installed manually)
  -- font = require("helpers.default_font"),

  -- Alternatively, this is a font config for JetBrainsMono Nerd Font
  font = {
    text = "JetBrainsMono Nerd Font", -- Used for text
    numbers = "JetBrainsMono Nerd Font", -- Used for numbers
    style_map = {
      ["Regular"] = "Regular",
      ["Semibold"] = "Medium",
      ["Bold"] = "SemiBold",
      ["Heavy"] = "Bold",
      ["Black"] = "ExtraBold",
    },
  },
}
