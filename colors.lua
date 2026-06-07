local colors = {
bar = {
  bg = 0xfc191724,
  border = 0xff191724,
},
popup = {
  bg = 0xc0191724,
  border = 0xff6e6a86
},
  base =        0xff191724,
  surface =     0xff1f1d2e,
  overlay =     0xff26233a,
  muted =       0xff6e6a86,
  subtle =      0xff908caa,
  text =        0xffe0def4,
  love =        0xffeb6f92,
  gold =        0xfff6c177,
  rose =        0xffebbcba,
  pine =        0xff31748f,
  foam =        0xff9ccfd8,
  iris =        0xffc4a7e7,
  highlight_low =  0xff21202e,
  highlight_med =  0xff403d52,
  highlight_high = 0xff524f67,

  -- aliases to keep compatibility with existing config
  bg1 =         0xff191724,
  bg2 =         0xff26233a,
  black =       0xff191724,
  white =       0xffe0def4,
  grey =        0xff6e6a86,
  red =         0xffeb6f92,
  blue =        0xff31748f,
  transparent = 0x00000000,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
return (color & 0x00ffffff) | (math.floor(alpha * 255.0) * 16777216)
  end,
}

return colors
