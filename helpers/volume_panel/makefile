bin/volume_panel: volume_panel.swift AudioHardware.swift PanelIPC.swift | bin
	swiftc -O -parse-as-library $^ -o $@ -framework AppKit -framework SwiftUI -framework CoreAudio -framework AudioToolbox

bin:
	mkdir bin
