// Keyboard grabber for sketchybar popups.
//
// Sketchybar's own windows never take keyboard focus, so a popup can only be
// driven with the mouse. This helper supplies the missing half: while a popup
// is open the widget launches one of these, it takes key focus with an
// invisible 1x1 window, and every arrow / return / escape press is forwarded
// back into the bar as a custom event:
//
//     sketchybar --trigger <event> KEY=<up|down|left|right|return|escape|tab>
//
//   popup_keys --event <name> [--sketchybar <path>] [--stay]
//
//   --event       sketchybar event to trigger. Required in practice; it must
//                 already exist (`sketchybar --add event <name>`).
//   --sketchybar  path to the sketchybar binary. Defaults to resolving it on
//                 PATH, with the two homebrew prefixes appended.
//   --stay        keep running after the window loses focus. Off by default:
//                 clicking into another app should hand the keyboard straight
//                 back rather than leave a grabber sitting on it.
//
// Escape is forwarded and then exits, since every popup treats it as "close".
// The app runs as an accessory, so it owns no Dock tile and no menu bar, and
// the frontmost application from before the grab is reactivated on the way out
// -- taking focus for the length of a popup should not be something the user
// has to undo. No accessibility or input-monitoring permission is involved:
// these are ordinary key events delivered to our own key window.

import AppKit

// MARK: - options

struct Options {
    var event = "popup_key"
    var sketchybar: String? = nil
    var exitOnBlur = true

    static func parse(_ argv: [String]) -> Options {
        var opts = Options()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            let next: String? = (i + 1 < argv.count) ? argv[i + 1] : nil
            switch arg {
            case "--event":
                if let next { opts.event = next; i += 1 }
            case "--sketchybar":
                if let next { opts.sketchybar = next; i += 1 }
            case "--stay":
                opts.exitOnBlur = false
            default:
                break
            }
            i += 1
        }
        return opts
    }
}

// MARK: - key names

/// Only the keys a popup can act on. Anything else is swallowed rather than
/// forwarded -- the grab is exclusive while it is up, so passing unmapped keys
/// through to nobody is the honest behaviour.
private let keyNames: [UInt16: String] = [
    126: "up",
    125: "down",
    123: "left",
    124: "right",
    36: "return",
    76: "return",   // keypad enter
    53: "escape",
    48: "tab",
]

// MARK: - bar bridge

/// Triggers are serialised on one queue so a fast key repeat cannot deliver
/// them to the bar out of order.
final class Bar {
    private let event: String
    private let binary: String?
    private let queue = DispatchQueue(label: "popup_keys.trigger")

    init(event: String, binary: String?) {
        self.event = event
        self.binary = binary
    }

    func send(_ key: String) {
        queue.async { [event, binary] in
            let process = Process()
            if let binary {
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["--trigger", event, "KEY=\(key)"]
            } else {
                // Launched from sketchybar, so PATH is whatever the bar was
                // started with -- often a login shell's, sometimes not.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["sketchybar", "--trigger", event, "KEY=\(key)"]
                var environment = ProcessInfo.processInfo.environment
                let path = environment["PATH"] ?? "/usr/bin:/bin"
                environment["PATH"] = path + ":/opt/homebrew/bin:/usr/local/bin"
                process.environment = environment
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}

// MARK: - window

/// A borderless window is not key-eligible by default; this is the whole
/// reason for the subclass.
final class GrabWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - app

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let opts: Options
    private let bar: Bar
    private var window: GrabWindow?
    private var monitor: Any?
    private let previous = NSWorkspace.shared.frontmostApplication

    init(opts: Options) {
        self.opts = opts
        self.bar = Bar(event: opts.event, binary: opts.sketchybar)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = GrabWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.hasShadow = false
        // Above the popup it serves, but invisible and click-through, so the
        // popup underneath keeps receiving every mouse event as before.
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

        // A local monitor sees the key events before any responder-chain
        // handling can beep at an unhandled one.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event.keyCode)
            return nil
        }
    }

    private func handle(_ code: UInt16) {
        guard let name = keyNames[code] else { return }
        bar.send(name)
        if name == "escape" {
            NSApp.terminate(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard opts.exitOnBlur else { return }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        // Only worth restoring if we are the ones holding focus; on a blur exit
        // the user has already chosen where it should go.
        guard NSApp.isActive, let previous, previous != NSRunningApplication.current else { return }
        if #available(macOS 14.0, *) {
            previous.activate()
        } else {
            previous.activate(options: [])
        }
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller(opts: options)
app.delegate = controller
app.run()
