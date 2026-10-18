// Live integration test: opens/closes the volume popup five times, checks host
// reuse, and measures trigger-to-onscreen-window time (not just audio reads).
// Run with no other volume popup open. Does not change any audio settings.
// swiftc -O tests/popup_latency.swift -o /path/to/popup_latency -framework CoreGraphics
import Foundation
import CoreGraphics

func window() -> [String: Any]? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return windows.first {
        ($0[kCGWindowOwnerName as String] as? String) == "volume_panel" &&
        ($0[kCGWindowLayer as String] as? Int ?? 0) > 0
    }
}

func run(_ binary: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0)
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let binary = (ProcessInfo.processInfo.environment["CONFIG_DIR"] ?? home + "/.config/sketchybar")
    + "/helpers/volume_panel/bin/volume_panel"
var times: [Double] = []
var host: Int?
defer { try? run(binary, ["--hide"]) }
for _ in 0..<5 {
    try run(binary, ["--hide"])
    let closing = ProcessInfo.processInfo.systemUptime
    while window() != nil && ProcessInfo.processInfo.systemUptime - closing < 2 {
        Thread.sleep(forTimeInterval: 0.002)
    }
    precondition(window() == nil, "Popup did not hide")
    let start = ProcessInfo.processInfo.systemUptime
    let trigger = Process()
    trigger.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sketchybar")
    trigger.arguments = ["--trigger", "volume_popup_toggle"]
    try trigger.run()
    var visible: [String: Any]?
    while ProcessInfo.processInfo.systemUptime - start < 2 {
        if let found = window() { visible = found; break }
        Thread.sleep(forTimeInterval: 0.002)
    }
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    trigger.waitUntilExit()
    guard let visible, let pid = visible[kCGWindowOwnerPID as String] as? Int else {
        fatalError("No visible volume popup within two seconds")
    }
    precondition(host == nil || host == pid, "Popup restarted instead of reusing its host")
    host = pid
    times.append(elapsed)
    print(String(format: "%.1f ms (host %d)", elapsed, pid))
    Thread.sleep(forTimeInterval: 0.1)
}
print(String(format: "Median trigger-to-window: %.1f ms; all opens reused one host", times.sorted()[2]))
