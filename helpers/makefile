all: metrics displays
	(cd speedtest_overlay && $(MAKE)) >/dev/null
	(cd popup_keys && $(MAKE)) >/dev/null
	(cd wifi_panel && $(MAKE)) >/dev/null
	(cd agents_panel && $(MAKE)) >/dev/null
	(cd volume_panel && $(MAKE)) >/dev/null
	(cd calendar_panel && $(MAKE)) >/dev/null

metrics: metrics.c
	$(CC) -O2 -Wall -Wextra $< -o $@

displays: displays.c
	$(CC) -O2 -Wall -Wextra $< -o $@ -framework CoreGraphics -framework CoreFoundation

.PHONY: all
