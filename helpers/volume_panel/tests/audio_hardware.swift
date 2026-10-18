// Read-only hardware smoke test / benchmark, independent of AppKit and SwiftUI.
// swiftc -O -parse-as-library AudioHardware.swift tests/audio_hardware.swift \
//   -o /path/to/audio_hardware_test -framework CoreAudio -framework AudioToolbox
import Foundation

@main
enum AudioHardwareTest {
    enum Failure: Error { case check(String) }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }

    /// Opt-in integration test: move output by one percentage point, confirm
    /// the write and notification, then restore it even if a check throws.
    static func exerciseOutput() throws {
        let notification = DispatchSemaphore(value: 0)
        let monitor = AudioMonitor { notification.signal() }
        defer { withExtendedLifetime(monitor) {} }
        try require(notification.wait(timeout: .now() + 2) == .success, "listener startup")
        guard let original = AudioHardware.level(.output) else { throw Failure.check("output has no level") }
        defer { AudioHardware.setLevel(original, on: .output) }
        let target = original > 0.98 ? original - 0.01 : original + 0.01
        try require(AudioHardware.setLevel(target, on: .output), "output write")
        try require(notification.wait(timeout: .now() + 2) == .success, "level notification")
        try require(abs((AudioHardware.level(.output) ?? -1) - target) < 0.005, "output readback")
        try require(AudioHardware.setOutputMuted(AudioHardware.outputMuted()), "mute write (unchanged)")
    }

    static func main() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let output = AudioHardware.devices(.output)
        let input = AudioHardware.devices(.input)
        let outLevel = AudioHardware.level(.output)
        let inLevel = AudioHardware.level(.input)
        let muted = AudioHardware.outputMuted()
        let firstRead = ProcessInfo.processInfo.systemUptime - start

        for (channel, devices, level) in [(Channel.output, output, outLevel), (.input, input, inLevel)] {
            precondition(Set(devices.map(\.id)).count == devices.count)
            if let level { precondition((0...1).contains(level)) }
            if !devices.isEmpty {
                precondition(devices.filter(\.current).count == 1)
                precondition(devices.first(where: \.current)?.id == AudioHardware.current(channel))
            }
        }

        let warmStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            _ = AudioHardware.level(.output)
            _ = AudioHardware.level(.input)
            _ = AudioHardware.outputMuted()
            _ = AudioHardware.devices(.output)
            _ = AudioHardware.devices(.input)
        }
        let warm = (ProcessInfo.processInfo.systemUptime - warmStart) / 100
        let result: [String: Any] = [
            "output": output.map { ["id": $0.id, "name": $0.name, "current": $0.current] as [String: Any] },
            "input": input.map { ["id": $0.id, "name": $0.name, "current": $0.current] as [String: Any] },
            "outputVolume": outLevel as Any? ?? NSNull(),
            "inputVolume": inLevel as Any? ?? NSNull(),
            "outputMuted": muted,
            "firstReadMs": firstRead * 1000,
            "warmReadMs": warm * 1000,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if CommandLine.arguments.contains("--exercise-output") {
            try exerciseOutput()
            print("Output write, readback and notification checks passed; original level restored.")
        }
    }
}
