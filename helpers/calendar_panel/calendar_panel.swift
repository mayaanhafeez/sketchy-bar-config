import AppKit
import SwiftUI
import Combine

extension NSColor {
    convenience init?(hex: String) {
        let raw = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex.replacingOccurrences(of: "#", with: "")
        guard let value = UInt32(raw, radix: 16) else { return nil }
        self.init(calibratedRed: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255,
                  alpha: raw.count == 8 ? CGFloat((value >> 24) & 255) / 255 : 1)
    }
}

struct Options {
    var width: CGFloat = 280
    var radius: CGFloat = 5
    var anchorX: CGFloat?
    var anchorY: CGFloat?
    var displayID: UInt32?
    var font = "JetBrainsMono Nerd Font"
    var foreground = NSColor.labelColor
    var background = NSColor.windowBackgroundColor
    var accent = NSColor.controlAccentColor
    var urgent = NSColor.systemRed
    var muted = NSColor.secondaryLabelColor
    var border = NSColor.separatorColor

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        while i + 1 < args.count {
            let value = args[i + 1]
            switch args[i] {
            case "--width": if let n = Double(value) { o.width = CGFloat(n) }
            case "--radius": if let n = Double(value) { o.radius = CGFloat(n) }
            case "--anchor-x": if let n = Double(value) { o.anchorX = CGFloat(n) }
            case "--anchor-y": if let n = Double(value) { o.anchorY = CGFloat(n) }
            case "--display-id": o.displayID = UInt32(value)
            case "--font": o.font = value
            case "--foreground": if let c = NSColor(hex: value) { o.foreground = c }
            case "--background": if let c = NSColor(hex: value) { o.background = c }
            case "--accent": if let c = NSColor(hex: value) { o.accent = c }
            case "--urgent": if let c = NSColor(hex: value) { o.urgent = c }
            case "--muted": if let c = NSColor(hex: value) { o.muted = c }
            case "--border": if let c = NSColor(hex: value) { o.border = c }
            default: break
            }
            i += 2
        }
        return o
    }
}

struct MonthGrid {
    let first: Date
    let cells: [Int]
    let title: String
    let weekdays: [String]

    init(date: Date, calendar: Calendar) {
        first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let leading = calendar.component(.weekday, from: first) - 1 // Sunday first.
        var days = Array(repeating: 0, count: leading) + Array(1...count)
        days += Array(repeating: 0, count: (7 - days.count % 7) % 7)
        cells = days
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "LLLL yyyy"
        title = formatter.string(from: first)
        weekdays = formatter.shortWeekdaySymbols.map { String($0.prefix(2)) }
    }
}

final class CalendarModel: ObservableObject {
    @Published var month = Date()
    @Published var today = Date()
    let calendar = Calendar.autoupdatingCurrent

    var grid: MonthGrid { MonthGrid(date: month, calendar: calendar) }
    func move(_ delta: Int) {
        month = calendar.date(byAdding: .month, value: delta, to: grid.first) ?? month
    }
    func reset() { today = Date(); month = today }
    func isToday(_ day: Int) -> Bool {
        day > 0 && calendar.isDate(month, equalTo: today, toGranularity: .month)
            && calendar.component(.day, from: today) == day
    }
}

struct CalendarView: View {
    @ObservedObject var model: CalendarModel
    let options: Options
    let onClose: () -> Void
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        let grid = model.grid
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: model.reset) {
                    Text(grid.title).font(.custom(options.font, size: 14).weight(.bold))
                        .foregroundColor(Color(options.foreground))
                }
                .buttonStyle(.plain)
                .help("Return to this month")
                Spacer(minLength: 0)
                Button { model.move(-1) } label: { Text("‹") }
                    .help("Previous month")
                Button { model.move(1) } label: { Text("›") }
                    .help("Next month")
            }
            .buttonStyle(.plain)
            .font(.custom(options.font, size: 16))
            .foregroundColor(Color(options.muted))
            .padding(.bottom, 2)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(0..<7, id: \.self) { index in
                    Text(grid.weekdays[index])
                        .font(.custom(options.font, size: 13).weight(.bold))
                        .foregroundColor(Color(options.accent))
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                ForEach(grid.cells.indices, id: \.self) { index in
                    let day = grid.cells[index]
                    let today = model.isToday(day)
                    Text(day == 0 ? " " : String(day))
                        .font(.custom(options.font, size: 14).weight(today ? .bold : .medium))
                        .foregroundColor(Color(today ? options.urgent : options.foreground))
                        .underline(today, color: Color(options.urgent))
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
            }
        }
        .padding(12)
        .frame(width: options.width)
        .background(Color(options.background))
        .clipShape(RoundedRectangle(cornerRadius: options.radius))
        .background(KeyCatcher(onMove: model.move, onToday: model.reset, onClose: onClose))
        .onReceive(tick) { model.today = $0 }
    }
}

struct KeyCatcher: NSViewRepresentable {
    let onMove: (Int) -> Void
    let onToday: () -> Void
    let onClose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { context.coordinator.install(self); return NSView() }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.owner = self }
    final class Coordinator {
        var owner: KeyCatcher?
        var monitor: Any?
        func install(_ owner: KeyCatcher) {
            self.owner = owner
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let owner = self?.owner else { return event }
                switch event.keyCode {
                case 53: owner.onClose(); return nil
                case 123: owner.onMove(-1); return nil
                case 124: owner.onMove(1); return nil
                case 115, 49: owner.onToday(); return nil
                default: return event
                }
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: Options
    private let model = CalendarModel()
    private var window: PanelWindow?
    private let screen: NSScreen?
    private let previous = NSWorkspace.shared.frontmostApplication

    @MainActor init(options: Options) {
        self.options = options
        screen = options.displayID.flatMap { id in
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
        } ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        let root = CalendarView(model: model, options: options) { NSApp.terminate(nil) }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        let panel = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: options.width, height: 240),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.delegate = self
        if let view = panel.contentView {
            view.wantsLayer = true
            view.layer?.cornerRadius = options.radius
            view.layer?.masksToBounds = true
            view.layer?.borderWidth = 1
            view.layer?.borderColor = options.border.cgColor
        }
        window = panel
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func position() {
        guard let window, let screen else { return }
        let frame = screen.frame
        let margin: CGFloat = 6
        let x = min(max(frame.minX + margin, (options.anchorX ?? frame.midX + window.frame.width / 2) - window.frame.width),
                    frame.maxX - window.frame.width - margin)
        let y = max(frame.minY + margin, frame.maxY - (options.anchorY ?? 46) - window.frame.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    func windowDidResize(_ notification: Notification) { position() }
    func windowDidResignKey(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if NSApp.isActive, let previous, previous != NSRunningApplication.current { previous.activate() }
    }
}

if CommandLine.arguments.contains("--self-test") {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    for (year, month, leading, days, cells) in [(2025, 9, 1, 30, 35), (2024, 2, 4, 29, 35),
        (2026, 2, 0, 28, 28), (2026, 10, 4, 31, 35), (2026, 8, 6, 31, 42)] {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: 15))!
        let grid = MonthGrid(date: date, calendar: calendar)
        precondition(grid.cells.count == cells)
        precondition(Array(grid.cells.prefix(leading)) == Array(repeating: 0, count: leading))
        precondition(grid.cells.filter { $0 > 0 } == Array(1...days))
        precondition(grid.weekdays.count == 7)
    }
    print("Calendar grid tests passed: Sunday-first layout, leap year, and 4/5/6-week months.")
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MainActor.assumeIsolated { Controller(options: Options.parse(Array(CommandLine.arguments.dropFirst()))) }
    app.delegate = controller
    app.run()
}
