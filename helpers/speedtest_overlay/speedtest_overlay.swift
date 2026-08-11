// Full-screen speed-test overlay: darkens the desktop and shows a download and
// an upload dial that track a run live.
//
// It renders somebody else's data -- helpers/wifi_speedtest.sh detaches
// `macwifi speedtest --format jsonl` and this tails the event stream that run
// writes. Nothing here starts or owns the test, so the Wi-Fi popup and this
// overlay can watch the same run without either driving the other.
//
//   speedtest_overlay [--stream <path>] [--title <text>] [--linger <seconds>]
//                     [--accent <hex>] [--exit-when-idle]
//
//   --stream          JSONL file to follow. Defaults to the cache path that
//                     wifi_speedtest.sh writes to.
//   --title           Caption above the dials. Defaults to the network you are
//                     currently on, resolved from macwifi.
//   --linger          Seconds to hold the final figures before closing.
//                     0 keeps the overlay up until it is dismissed.
//   --accent          Dial colour, "#rrggbb" or "0xaarrggbb".
//   --dim             Backdrop colour, alpha included, e.g. "0xd0191724".
//                     The Wi-Fi widget passes both of these from the active
//                     sketchybar theme, so the overlay matches the bar.
//   --exit-when-idle  Close if the stream produces nothing at all, instead of
//                     waiting for a run to appear.
//
// Escape or a click dismisses it. The window sits at screen-saver level and
// joins every space, so it covers full-screen apps too; it needs no
// accessibility or screen-recording permission.

import AppKit
import QuartzCore

// MARK: - options

struct Options {
    var stream: String = NSString(string: "~/Library/Caches/sketchybar/speedtest/run.jsonl")
        .expandingTildeInPath
    /// nil means "resolve the current SSID at launch".
    var title: String? = nil
    var linger: Double = 8
    var accent: NSColor = NSColor(calibratedWhite: 0.96, alpha: 1)
    var dim: NSColor = NSColor.black.withAlphaComponent(0.78)
    var exitWhenIdle: Bool = false

    static func parse(_ argv: [String]) -> Options {
        var opts = Options()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            let next: String? = (i + 1 < argv.count) ? argv[i + 1] : nil
            switch arg {
            case "--stream":
                if let v = next { opts.stream = NSString(string: v).expandingTildeInPath; i += 1 }
            case "--title":
                if let v = next { opts.title = v; i += 1 }
            case "--linger":
                if let v = next, let d = Double(v) { opts.linger = d; i += 1 }
            case "--accent":
                if let v = next, let c = NSColor(hex: v) { opts.accent = c; i += 1 }
            case "--dim":
                if let v = next, let c = NSColor(hex: v) { opts.dim = c; i += 1 }
            case "--exit-when-idle":
                opts.exitWhenIdle = true
            default:
                break
            }
            i += 1
        }
        return opts
    }
}

extension NSColor {
    // "#rrggbb", "rrggbb", "0xaarrggbb" -- the same argb form sketchybar uses.
    convenience init?(hex: String) {
        var text = hex.lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.hasPrefix("0x") { text.removeFirst(2) }
        guard let value = UInt32(text, radix: 16) else { return nil }
        let a, r, g, b: CGFloat
        switch text.count {
        case 8:
            a = CGFloat((value >> 24) & 0xff) / 255
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
        case 6:
            a = 1
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
        default:
            return nil
        }
        self.init(calibratedRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - stream

/// Follows an append-only JSONL file, surviving the file not existing yet and
/// being truncated when a new run starts.
final class StreamTail {
    private let path: String
    private var offset: UInt64 = 0
    private var partial = Data()

    init(path: String) { self.path = path }

    func poll() -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        // A fresh run replaces the file: rewind rather than reading garbage.
        if fileSize < offset {
            offset = 0
            partial.removeAll()
        }
        guard fileSize > offset else { return [] }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return []
        }
        let chunk = handle.readDataToEndOfFile()
        guard !chunk.isEmpty else { return [] }
        offset += UInt64(chunk.count)
        partial.append(chunk)

        var events: [[String: Any]] = []
        while let newline = partial.firstIndex(of: 0x0a) {
            let lineData = partial.subdata(in: partial.startIndex ..< newline)
            partial.removeSubrange(partial.startIndex ... newline)
            guard !lineData.isEmpty else { continue }
            if let object = try? JSONSerialization.jsonObject(with: lineData),
               let event = object as? [String: Any] {
                events.append(event)
            }
        }
        return events
    }
}

// MARK: - gauge

final class Gauge {
    let root = CALayer()

    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let ticks = CAShapeLayer()
    private let needle = CAShapeLayer()
    private let valueLabel = CATextLayer()
    private let unitLabel = CATextLayer()
    private let captionLabel = CATextLayer()

    // A 270-degree sweep with the gap at the bottom: zero sits at the lower
    // left, full scale at the lower right, travelling clockwise over the top.
    private let startAngle: CGFloat = 5 * .pi / 4
    private let sweep: CGFloat = 3 * .pi / 2

    private let radius: CGFloat
    private let accent: NSColor
    private var scale: Double = 10

    private(set) var value: Double = 0

    init(caption: String, radius: CGFloat, accent: NSColor, scaleFactor: CGFloat) {
        self.radius = radius
        self.accent = accent

        let side = (radius + 26) * 2
        root.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        root.contentsScale = scaleFactor

        let center = CGPoint(x: side / 2, y: side / 2)

        for layer in [track, progress, ticks, needle] {
            layer.frame = root.bounds
            layer.contentsScale = scaleFactor
            layer.fillColor = nil
            root.addSublayer(layer)
        }

        track.path = arc(center: center, radius: radius, from: startAngle, sweep: sweep)
        track.strokeColor = accent.withAlphaComponent(0.16).cgColor
        track.lineWidth = 3
        track.lineCap = .round

        progress.path = track.path
        progress.strokeColor = accent.cgColor
        progress.lineWidth = 3
        progress.lineCap = .round
        progress.strokeEnd = 0

        ticks.path = tickMarks(center: center)
        ticks.strokeColor = accent.withAlphaComponent(0.38).cgColor
        ticks.lineWidth = 1
        ticks.lineCap = .butt

        // Drawn pointing along +x so a rotation about the layer's centre puts
        // it at the angle we want.
        let needlePath = CGMutablePath()
        needlePath.move(to: CGPoint(x: center.x + 8, y: center.y))
        needlePath.addLine(to: CGPoint(x: center.x + radius - 20, y: center.y))
        needle.path = needlePath
        needle.strokeColor = accent.cgColor
        needle.lineWidth = 2
        needle.lineCap = .round

        let mono = Gauge.font(size: 34, weight: .medium)
        valueLabel.string = "0.0"
        valueLabel.font = mono
        valueLabel.fontSize = 34
        valueLabel.alignmentMode = .center
        valueLabel.foregroundColor = accent.cgColor
        valueLabel.contentsScale = scaleFactor
        valueLabel.frame = CGRect(x: 0, y: center.y - 6, width: side, height: 44)
        root.addSublayer(valueLabel)

        unitLabel.string = "Mbps"
        unitLabel.font = Gauge.font(size: 11, weight: .regular)
        unitLabel.fontSize = 11
        unitLabel.alignmentMode = .center
        unitLabel.foregroundColor = accent.withAlphaComponent(0.55).cgColor
        unitLabel.contentsScale = scaleFactor
        unitLabel.frame = CGRect(x: 0, y: center.y - 22, width: side, height: 16)
        root.addSublayer(unitLabel)

        captionLabel.string = caption
        captionLabel.font = Gauge.font(size: 11, weight: .semibold)
        captionLabel.fontSize = 11
        captionLabel.alignmentMode = .center
        captionLabel.foregroundColor = accent.withAlphaComponent(0.65).cgColor
        captionLabel.contentsScale = scaleFactor
        captionLabel.frame = CGRect(x: 0, y: center.y - radius - 24, width: side, height: 16)
        root.addSublayer(captionLabel)
    }

    private static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont(name: "JetBrainsMono Nerd Font", size: size)
            ?? NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func arc(center: CGPoint, radius: CGFloat, from: CGFloat, sweep: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius,
                    startAngle: from, endAngle: from - sweep, clockwise: true)
        return path
    }

    private func tickMarks(center: CGPoint) -> CGPath {
        let path = CGMutablePath()
        let count = 40
        for i in 0 ... count {
            let angle = startAngle - sweep * CGFloat(i) / CGFloat(count)
            let major = i % 5 == 0
            let outer = radius - 6
            let inner = radius - (major ? 16 : 11)
            path.move(to: CGPoint(x: center.x + cos(angle) * inner,
                                  y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer,
                                     y: center.y + sin(angle) * outer))
        }
        return path
    }

    /// Both dials share one full-scale value so they stay directly comparable;
    /// the controller owns it and pushes it in.
    func setScale(_ newScale: Double, animated: Bool) {
        guard newScale != scale else { return }
        scale = newScale
        set(value: value, animated: animated)
    }

    func set(value newValue: Double, animated: Bool) {
        value = max(0, newValue)

        let fraction = min(1, scale > 0 ? value / scale : 0)
        let angle = startAngle - sweep * CGFloat(fraction)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        // The needle path is drawn along +x, i.e. at absolute angle 0, so the
        // rotation is the absolute angle -- not its offset from the start.
        needle.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        progress.strokeEnd = CGFloat(fraction)
        CATransaction.commit()

        // The digits must snap. Left to the implicit animation they cross-fade,
        // which renders the old and new number on top of each other.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        valueLabel.string = value >= 100 ? String(format: "%.0f", value)
                                         : String(format: "%.1f", value)
        CATransaction.commit()
    }

    /// The inactive dial fades back, so whichever direction is being measured
    /// reads as the live one.
    func setActive(_ active: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        root.opacity = active ? 1.0 : 0.42
        CATransaction.commit()
    }
}

// MARK: - view

final class OverlayView: NSView {
    private let dim = CALayer()
    private let titleLabel = CATextLayer()
    private let statusLabel = CATextLayer()
    let download: Gauge
    let upload: Gauge

    init(frame: NSRect, options: Options, scaleFactor: CGFloat) {
        let radius: CGFloat = min(140, max(96, frame.height * 0.13))
        download = Gauge(caption: "DOWNLOAD", radius: radius,
                         accent: options.accent, scaleFactor: scaleFactor)
        upload = Gauge(caption: "UPLOAD", radius: radius,
                       accent: options.accent, scaleFactor: scaleFactor)
        super.init(frame: frame)

        wantsLayer = true
        let host = CALayer()
        host.frame = bounds
        host.contentsScale = scaleFactor
        layer = host

        dim.frame = bounds
        dim.backgroundColor = options.dim.cgColor
        dim.contentsScale = scaleFactor
        host.addSublayer(dim)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let spread = radius + 34

        download.root.position = CGPoint(x: center.x - spread, y: center.y)
        upload.root.position = CGPoint(x: center.x + spread, y: center.y)
        host.addSublayer(download.root)
        host.addSublayer(upload.root)

        titleLabel.string = (options.title ?? "").uppercased()
        titleLabel.font = NSFont(name: "JetBrainsMono Nerd Font", size: 12)
            ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.fontSize = 12
        titleLabel.alignmentMode = .center
        titleLabel.foregroundColor = options.accent.withAlphaComponent(0.75).cgColor
        titleLabel.contentsScale = scaleFactor
        titleLabel.frame = CGRect(x: 0, y: center.y + radius + 62,
                                  width: bounds.width, height: 20)
        host.addSublayer(titleLabel)

        statusLabel.string = "STARTING…"
        statusLabel.font = NSFont(name: "JetBrainsMono Nerd Font", size: 10)
            ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.fontSize = 10
        statusLabel.alignmentMode = .center
        statusLabel.foregroundColor = options.accent.withAlphaComponent(0.42).cgColor
        statusLabel.contentsScale = scaleFactor
        statusLabel.frame = CGRect(x: 0, y: center.y - radius - 84,
                                   width: bounds.width, height: 16)
        host.addSublayer(statusLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setTitle(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLabel.string = text.uppercased()
        CATransaction.commit()
    }

    func setStatus(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusLabel.string = text
        CATransaction.commit()
    }
}

// MARK: - window

final class OverlayWindow: NSWindow {
    // Borderless windows refuse key status by default, which would swallow Escape.
    override var canBecomeKey: Bool { true }
}

// MARK: - controller

final class Controller: NSObject, NSApplicationDelegate {
    private let options: Options
    private let tail: StreamTail
    private var window: OverlayWindow!
    private var view: OverlayView!
    private var timer: Timer?
    private var finished = false
    private var closing = false
    private var sawAnything = false
    private var idleTicks = 0
    private var peak: Double = 0

    init(options: Options) {
        self.options = options
        self.tail = StreamTail(path: options.stream)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let scaleFactor = screen.backingScaleFactor

        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.setFrame(screen.frame, display: true)

        view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                           options: options, scaleFactor: scaleFactor)
        window.contentView = view

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 1
        }

        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            if event.type == .keyDown && event.keyCode != 53 { return event } // 53 = Escape
            self?.dismiss()
            return nil
        }

        if options.title == nil { resolveNetworkName() }

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    /// The connected SSID, asked for off the main thread: `macwifi status` talks
    /// to a daemon over a socket, and blocking the UI on that would stall the
    /// overlay before it ever drew.
    private func resolveNetworkName() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let name = Controller.currentSSID()
            DispatchQueue.main.async {
                self?.view.setTitle(name ?? "SPEED TEST")
            }
        }
    }

    private static func currentSSID() -> String? {
        let binary = ProcessInfo.processInfo.environment["MACWIFI_BIN"]
            ?? "/usr/local/bin/macwifi"
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            // Split once only -- bssid and hw addr values are full of colons.
            let parts = line.split(separator: ":", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "ssid" && !value.isEmpty && value != "-" { return value }
        }
        return nil
    }

    private func tick() {
        let events = tail.poll()
        if events.isEmpty {
            if !sawAnything {
                idleTicks += 1
                // ~4s of nothing: either the run never started or it is already
                // over and the stream was cleaned up.
                if options.exitWhenIdle && idleTicks > 20 { dismiss() }
            }
            return
        }
        sawAnything = true

        for event in events {
            guard let kind = event["type"] as? String else { continue }
            switch kind {
            case "started":
                view.setStatus("MEASURING…")
            case "progress":
                apply(download: event["download_mbps"] as? Double,
                      upload: event["upload_mbps"] as? Double)
                if let ping = event["ping_ms"] as? Double {
                    view.setStatus(String(format: "MEASURING…   %.0f ms", ping))
                }
            case "complete":
                let result = event["result"] as? [String: Any] ?? [:]
                apply(download: result["download_mbps"] as? Double,
                      upload: result["upload_mbps"] as? Double)
                view.download.setActive(true)
                view.upload.setActive(true)
                var parts: [String] = []
                if let ping = result["ping_ms"] as? Double {
                    parts.append(String(format: "%.0f ms", ping))
                }
                if let host = (result["server"] as? [String: Any])?["host"] as? String {
                    parts.append(host)
                }
                view.setStatus(parts.isEmpty ? "DONE" : parts.joined(separator: "   "))
                finish()
            case "failed":
                let message = (event["error"] as? String) ?? "speed test failed"
                view.setStatus(message.uppercased())
                finish()
            default:
                break
            }
        }
    }

    private func apply(download newDownload: Double?, upload newUpload: Double?) {
        // Providers measure one direction at a time; highlight whichever moved.
        var downloadMoved = false
        var uploadMoved = false
        if let value = newDownload {
            downloadMoved = abs(value - view.download.value) > 0.05
            view.download.set(value: value, animated: true)
        }
        if let value = newUpload {
            uploadMoved = abs(value - view.upload.value) > 0.05
            view.upload.set(value: value, animated: true)
        }
        if downloadMoved != uploadMoved {
            view.download.setActive(downloadMoved)
            view.upload.setActive(uploadMoved)
        }
        applyScale()
    }

    /// Nice round full-scale values, shared by both dials and never shrinking
    /// mid-run so a needle cannot swing backwards while readings still climb.
    private func applyScale() {
        peak = max(peak, max(view.download.value, view.upload.value))
        let candidates: [Double] = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]
        let needed = peak * 1.15
        let scale = candidates.first { $0 >= needed } ?? max(needed, 10)
        view.download.setScale(scale, animated: true)
        view.upload.setScale(scale, animated: true)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        guard options.linger > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.linger) { [weak self] in
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard !closing else { return }
        closing = true
        timer?.invalidate()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: {
            NSApp.terminate(nil)
        })
    }
}

// MARK: - entry

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // overlay, not a dock app
let controller = Controller(options: options)
app.delegate = controller
app.run()
