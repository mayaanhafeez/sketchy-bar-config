#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  uint32_t count = 0;
  if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return 1;
  CGDirectDisplayID *displays = calloc(count, sizeof(*displays));
  if (!displays) return 1;
  if (CGGetOnlineDisplayList(count, displays, &count) != kCGErrorSuccess || count == 0) {
    free(displays);
    return 1;
  }
  putchar('[');
  CGEventRef event = CGEventCreate(NULL);
  CGPoint mouse = event ? CGEventGetLocation(event) : CGPointMake(-1, -1);
  if (event) CFRelease(event);
  for (uint32_t index = 0; index < count; index++) {
    printf("%s{\"id\":%u,\"built_in\":%s,\"mouse\":%s}", index ? "," : "",
           displays[index], CGDisplayIsBuiltin(displays[index]) ? "true" : "false",
           CGRectContainsPoint(CGDisplayBounds(displays[index]), mouse) ? "true" : "false");
  }
  puts("]");
  free(displays);
  return 0;
}
