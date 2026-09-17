import AppKit

// Answers whether the pointer is currently over sketchybar, for the widgets
// that reveal themselves on hover.
//
// mouse.exited.global is the normal way such a widget learns to put itself
// away, but it is not guaranteed to arrive. When the pointer crosses into
// sketchybar-toggle's trigger zone the bar can be hidden out from under it
// before sketchybar works out that the pointer left, and the event is simply
// never sent -- leaving the widget on screen until something else disturbs it.
// A widget that can ask where the pointer actually is has a floor under that.
//
// Usage: cursor_on_bar <bar height in points>   ->   prints "on" or "off"

let height = CommandLine.arguments.count > 1
  ? (Double(CommandLine.arguments[1]) ?? 0)
  : 0

let point = NSEvent.mouseLocation

// sketchybar draws across the top of every screen, so the bar is the top strip
// of whichever one the pointer is on rather than of the main display.
guard let screen = NSScreen.screens.first(where: { NSPointInRect(point, $0.frame) }) else {
  print("off")
  exit(0)
}

// mouseLocation has a bottom-left origin, so the drop below the top edge of
// that screen is maxY - y.
print(screen.frame.maxY - point.y <= height ? "on" : "off")
