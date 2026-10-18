// Volume panel: omarchy's audio panel, as far as macOS lets it go.
//
// The shape is the same -- hero with a mute switch, an OUTPUT section with a
// level slider and the devices under it, then the same again for INPUT. What is
// missing is the per-app SOURCES section: omarchy reads PipeWire, where every
// playback stream is a node it can address individually. CoreAudio exposes no
// public equivalent, so there is no honest way to draw per-app volumes here and
// the section is left out rather than faked.
//
//   volume_panel [--anchor-x <px>] [--anchor-y <px>] [--width <px>]
//                [--radius <px>] [--font <family>] [--switcher <path>]
//                [--stay] [...palette]
//   --prepare    Build a hidden, reusable window at bar startup.
//   --toggle     Show/hide that window through a per-user Mach port.
//   --hide       Hide it without quitting or starting a new host.
//
//   --switcher   Path to SwitchAudioSource, used only when switching devices.
//                Reads, levels and mute use CoreAudio directly.
//
// Colours are "#rrggbb" or "0xaarrggbb", the argb form sketchybar uses:
//
//   --foreground --background --accent --urgent --muted --border

import AppKit
import SwiftUI
import Combine

// MARK: - palette

struct Palette {
    var foreground = NSColor(calibratedWhite: 0.88, alpha: 1)
    var background = NSColor(calibratedRed: 0.14, green: 0.13, blue: 0.20, alpha: 1)
    var accent     = NSColor(calibratedRed: 0.77, green: 0.65, blue: 0.90, alpha: 1)
    var urgent     = NSColor(calibratedRed: 0.92, green: 0.44, blue: 0.57, alpha: 1)
    var muted      = NSColor(calibratedWhite: 0.55, alpha: 1)
    var border     = NSColor(calibratedWhite: 0.43, alpha: 1)
}

struct Options {
    var anchorX: CGFloat? = nil
    var anchorY: CGFloat? = nil
    var displayID: UInt32? = nil
    var width: CGFloat = 340
    var radius: CGFloat = 10
    var font = "JetBrainsMono Nerd Font"
    var switcher = "/opt/homebrew/bin/SwitchAudioSource"
    var exitOnBlur = true
    var palette = Palette()
    var screenAnchors: [UInt32: [Double]] = [:]

    func resolvedAnchor() -> Options {
        guard !screenAnchors.isEmpty,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let anchor = screenAnchors[id] else { return self }
        var options = self
        options.displayID = id
        options.anchorX = anchor[0]
        options.anchorY = anchor[1]
        options.width = anchor[2]
        return options
    }

    func sameView(as other: Options) -> Bool {
        width == other.width && radius == other.radius && font == other.font &&
        palette.foreground == other.palette.foreground && palette.background == other.palette.background &&
        palette.accent == other.palette.accent && palette.urgent == other.palette.urgent &&
        palette.muted == other.palette.muted && palette.border == other.palette.border
    }

    static func parse(_ argv: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            let next: String? = (i + 1 < argv.count) ? argv[i + 1] : nil
            switch arg {
            case "--anchor-x":   if let v = next, let d = Double(v) { o.anchorX = CGFloat(d); i += 1 }
            case "--anchor-y":   if let v = next, let d = Double(v) { o.anchorY = CGFloat(d); i += 1 }
            case "--display-id": if let v = next, let d = UInt32(v) { o.displayID = d; i += 1 }
            case "--screen-anchor":
                if let v = next {
                    let parts = v.split(separator: ",")
                    if parts.count == 4, let id = UInt32(parts[0]) {
                        let anchor = parts.dropFirst().compactMap { Double($0) }
                        if anchor.count == 3 { o.screenAnchors[id] = anchor }
                    }
                    i += 1
                }
            case "--width":      if let v = next, let d = Double(v) { o.width = CGFloat(d); i += 1 }
            case "--radius":     if let v = next, let d = Double(v) { o.radius = CGFloat(d); i += 1 }
            case "--font":       if let v = next { o.font = v; i += 1 }
            case "--switcher":   if let v = next { o.switcher = v; i += 1 }
            case "--stay":       o.exitOnBlur = false
            case "--foreground": if let v = next, let c = NSColor(hex: v) { o.palette.foreground = c; i += 1 }
            case "--background": if let v = next, let c = NSColor(hex: v) { o.palette.background = c; i += 1 }
            case "--accent":     if let v = next, let c = NSColor(hex: v) { o.palette.accent = c; i += 1 }
            case "--urgent":     if let v = next, let c = NSColor(hex: v) { o.palette.urgent = c; i += 1 }
            case "--muted":      if let v = next, let c = NSColor(hex: v) { o.palette.muted = c; i += 1 }
            case "--border":     if let v = next, let c = NSColor(hex: v) { o.palette.border = c; i += 1 }
            default: break
            }
            i += 1
        }
        return o
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var t = hex.lowercased()
        if t.hasPrefix("#") { t.removeFirst() }
        if t.hasPrefix("0x") { t.removeFirst(2) }
        guard let v = UInt32(t, radix: 16) else { return nil }
        let hasAlpha = t.count == 8
        self.init(calibratedRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255,
                  alpha: hasAlpha ? CGFloat((v >> 24) & 0xff) / 255 : 1)
    }

    func darker(_ factor: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.deviceRGB) else { return self }
        return NSColor(deviceRed: c.redComponent / factor, green: c.greenComponent / factor,
                       blue: c.blueComponent / factor, alpha: c.alphaComponent)
    }
}

// MARK: - design tokens (qs.Commons.Style at its 12px root)

enum T {
    static let caption: CGFloat   = 10
    static let bodySmall: CGFloat = 11
    static let body: CGFloat      = 12
    static let subtitle: CGFloat  = 13
    static let title: CGFloat     = 14
    static let display: CGFloat   = 24

    static let xxs: CGFloat = 2
    static let sm: CGFloat  = 4
    static let md: CGFloat  = 6
    static let lg: CGFloat  = 8
    static let xl: CGFloat  = 10
    static let xxl: CGFloat = 12
    static let xxxl: CGFloat = 14

    static let popupPadding: CGFloat  = 14
    static let controlHeight: CGFloat = 28
    static let controlGap: CGFloat    = 8

    /// PanelSlider's proportions: a thin track with a knob that overhangs it.
    static let trackHeight: CGFloat = 4
    static let knobSize: CGFloat    = 14

    static let normalFillAlpha: CGFloat   = 0.04
    static let hoverFillAlpha: CGFloat    = 0.08
    static let selectedFillAlpha: CGFloat = 0.18
    static let hoverBorderAlpha: CGFloat  = 0.25
}

// MARK: - model

// MARK: - formatting

enum Fmt {
    /// The Waybar pulseaudio glyph set omarchy kept, for the same reason: the
    /// Material Design speaker marks render visually smaller in JetBrainsMono.
    static func outputGlyph(volume: Double, muted: Bool, headphones: Bool) -> String {
        // Written as escapes, not literals: U+F026-F028 and U+EEE8 sit in the
        // basic-plane private use area and do not survive every editor or
        // pipeline intact -- they were silently dropped from this file once
        // already, which is why the hero rendered blank.
        if headphones { return "\u{f02cb}" }        // headphones
        if muted { return "\u{eee8}" }              // muted
        if volume >= 0.67 { return "\u{f028}" }     // high
        if volume >= 0.34 { return "\u{f027}" }     // medium
        if volume > 0 { return "\u{f026}" }         // low
        return "\u{eee8}"                           // silent reads as muted
    }

    static func inputGlyph(muted: Bool) -> String {
        muted ? "\u{f036d}" : "\u{f036c}"
    }

    /// Straight from Model.outputVolumeName -- the status line is a mood, not a
    /// number, because the number is already on the OUTPUT header.
    static func volumeName(_ volume: Double, muted: Bool) -> String {
        if muted { return "Muted" }
        let p = Int((volume * 100).rounded())
        if p == 0 { return "Silenced" }
        if p >= 100 { return "Concert hall" }
        if p >= 85 { return "Party mode" }
        if p >= 70 { return "Cranked up" }
        if p >= 50 { return "Steady groove" }
        if p >= 30 { return "Easy listening" }
        if p >= 15 { return "Murmur" }
        return "Whisper"
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

// MARK: - store

@MainActor
final class AudioStore: ObservableObject {
    @Published var outputVolume: Double = 0
    @Published var inputVolume: Double = 0
    @Published var outputMuted = false
    @Published var outputDevices: [Device] = []
    @Published var inputDevices: [Device] = []

    /// Preserve the panel's input-mute behavior: zero silences the input, and
    /// unmuting restores its previous level. Not all devices have a mute flag.
    @Published private(set) var inputRestore: Double = 0.5
    var inputMuted: Bool { inputVolume <= 0.001 }

    var anyAudible: Bool { (!outputMuted && outputVolume > 0) || !inputMuted }

    private let opts: Options
    private let work = DispatchQueue(label: "volume_panel.io", qos: .userInitiated)
    /// Keep hardware reads off the UI and separate from writes.
    private let reads = DispatchQueue(label: "volume_panel.reads", qos: .utility)
    private var monitor: AudioMonitor?
    private var loading = false
    private var reloadPending = false
    private var refreshTask: Task<Void, Never>?
    private var active = false

    /// A drag fires far faster than hardware writes can keep up, so each channel has
    /// at most one write in flight and only the newest level waits behind it.
    private var pendingLevel: [Channel: Int] = [:]
    private var writingLevel: Set<Channel> = []
    /// Writes still out, and a counter bumped on every local change. A read
    /// that overlaps either is stale and would yank the knob back mid-drag.
    private var inFlight = 0
    private var changes = 0

    init(opts: Options) {
        self.opts = opts
    }

    func start() {
        guard !active else { return }
        active = true
        monitor = AudioMonitor { [weak self] in
            Task { @MainActor in self?.scheduleLoad() }
        }
        load()
    }

    func stop() {
        active = false
        monitor = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    // ---------------------------------------------------------------- reads

    private func scheduleLoad() {
        // One hardware change can notify master, virtual and channel controls.
        // Coalesce that burst rather than re-rendering once per property.
        guard active, refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            guard let self else { return }
            self.refreshTask = nil
            self.load()
        }
    }

    func load() {
        guard active else { return }
        guard !loading else { reloadPending = true; return }
        loading = true
        let started = changes
        reads.async { [weak self] in
            guard let self else { return }
            let out = AudioHardware.level(.output)
            let inp = AudioHardware.level(.input)
            let muted = AudioHardware.outputMuted()
            let outDevices = AudioHardware.devices(.output)
            let inDevices = AudioHardware.devices(.input)
            Task { @MainActor in
                if self.inFlight == 0 && self.changes == started {
                    if let out, out != self.outputVolume { self.outputVolume = out }
                    if let inp, inp != self.inputVolume { self.inputVolume = inp }
                    if let inp, inp > 0, inp != self.inputRestore { self.inputRestore = inp }
                    if muted != self.outputMuted { self.outputMuted = muted }
                }
                if outDevices != self.outputDevices { self.outputDevices = outDevices }
                if inDevices != self.inputDevices { self.inputDevices = inDevices }
                self.loading = false
                if self.reloadPending { self.reloadPending = false; self.load() }
            }
        }
    }

    /// The connected output being headphones changes the hero glyph. There is
    /// no CoreAudio flag for it, so this reads the device name the way a person
    /// would -- good enough for an icon, and wrong in no worse a way than a
    /// missing icon would be.
    var outputIsHeadphones: Bool {
        guard let name = outputDevices.first(where: { $0.current })?.name.lowercased()
        else { return false }
        for hint in ["headphone", "airpod", "buds", "headset", "beats"] where name.contains(hint) {
            return true
        }
        return false
    }

    // --------------------------------------------------------------- writes

    func setOutputVolume(_ v: Double) {
        let clamped = min(max(v, 0), 1)
        outputVolume = clamped                       // answer the drag immediately
        if clamped > 0 && outputMuted { outputMuted = false }
        pushLevel(.output, Int((clamped * 100).rounded()))
    }

    func setInputVolume(_ v: Double) {
        let clamped = min(max(v, 0), 1)
        inputVolume = clamped
        if clamped > 0 { inputRestore = clamped }
        pushLevel(.input, Int((clamped * 100).rounded()))
    }

    func toggleOutputMute() {
        let next = !outputMuted
        outputMuted = next
        write { AudioHardware.setOutputMuted(next) }
    }

    func toggleInputMute() {
        setInputVolume(inputMuted ? inputRestore : 0)
    }

    /// The hero switch is the whole panel's on/off, so it carries both channels
    /// at once: muting everything reads as switching audio off.
    func toggleAll() {
        let silence = anyAudible
        outputMuted = silence
        if silence {
            if inputVolume > 0 { inputRestore = inputVolume }
            inputVolume = 0
        } else {
            inputVolume = inputRestore
        }
        write { AudioHardware.setOutputMuted(silence) }
        pushLevel(.input, silence ? 0 : Int((inputRestore * 100).rounded()))
    }

    /// Latest-wins: if a write for this channel is already out, the new level
    /// just replaces whatever was waiting, and goes out when that one lands.
    private func pushLevel(_ channel: Channel, _ percent: Int) {
        changes += 1
        pendingLevel[channel] = percent
        guard !writingLevel.contains(channel) else { return }
        writingLevel.insert(channel)
        drainLevel(channel)
    }

    private func drainLevel(_ channel: Channel) {
        guard let percent = pendingLevel.removeValue(forKey: channel) else {
            writingLevel.remove(channel)
            return
        }
        write({
            AudioHardware.setLevel(Double(percent) / 100, on: channel)
            if channel == .output && percent > 0 { AudioHardware.setOutputMuted(false) }
        }, then: { [weak self] in self?.drainLevel(channel) })
    }

    private func write(_ action: @escaping () -> Void, then done: (@MainActor () -> Void)? = nil) {
        changes += 1
        inFlight += 1
        work.async { [weak self] in
            action()
            Task { @MainActor in
                self?.inFlight -= 1
                done?()
                self?.scheduleLoad()
            }
        }
    }

    func select(_ device: Device, on channel: Channel) {
        // Repaint the tick straight away; the reload below confirms it.
        switch channel {
        case .output: outputDevices = outputDevices.map { Device(id: $0.id, name: $0.name, current: $0.id == device.id) }
        case .input:  inputDevices  = inputDevices.map  { Device(id: $0.id, name: $0.name, current: $0.id == device.id) }
        }
        let switcher = opts.switcher
        let name = device.name
        let type = channel.rawValue
        work.async { [weak self] in
            _ = Self.shell(switcher, ["-s", name, "-t", type])
            Task { @MainActor in self?.load() }
        }
    }

    // ------------------------------------------------------------- plumbing

    nonisolated private static func shell(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - chrome

struct Theme {
    let palette: Palette
    let font: String
    let radius: CGFloat

    var fg: Color { Color(palette.foreground) }
    var bg: Color { Color(palette.background) }
    var accent: Color { Color(palette.accent) }
    var urgent: Color { Color(palette.urgent) }
    var dim: Color { Color(palette.foreground.darker(1.4)) }

    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(font, size: size).weight(weight)
    }

    var normalFill: Color { fg.opacity(T.normalFillAlpha) }
    var hoverFill: Color { fg.opacity(T.hoverFillAlpha) }
    var selectedFill: Color { fg.opacity(T.selectedFillAlpha) }
    var hoverBorder: Color { fg.opacity(T.hoverBorderAlpha) }
    /// The slider track, and the same ground every meter in the agents panel
    /// sits on.
    var track: Color { fg.opacity(T.selectedFillAlpha) }
}

/// A Nerd Font icon, rasterised from its ink box.
///
/// SwiftUI lays a Text out on the font's advance, and these marks paint far
/// wider than they advance -- Text then crops to that box, and no frame around
/// it moves the crop. Drawing through CoreText onto a canvas measured from
/// CTLineGetImageBounds sidesteps text layout entirely. Template image, so the
/// colour still comes from the view.
struct Glyph: View {
    let text: String
    let size: CGFloat
    let family: String
    var color: Color? = nil

    var body: some View {
        if let image = Glyph.rasterise(text, family: family, size: size) {
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(color ?? .primary)
        } else {
            Text(text).font(.custom(family, size: size)).foregroundStyle(color ?? .primary)
        }
    }

    @MainActor private static var cache: [String: NSImage?] = [:]

    @MainActor static func rasterise(_ text: String, family: String, size: CGFloat) -> NSImage? {
        let key = "\(text)|\(family)|\(size)"
        if let hit = cache[key] { return hit }
        guard let font = NSFont(name: family, size: size) else {
            cache[key] = NSImage?.none
            return nil
        }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let ink = CTLineGetImageBounds(line, nil)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let width = ceil(max(ink.maxX, attributed.size().width)) + 2
        let height = ceil(ascent + descent) + 2
        guard width > 0, height > 0 else { cache[key] = NSImage?.none; return nil }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setAllowsAntialiasing(true)
            ctx.textPosition = CGPoint(x: 1, y: descent + 1)
            CTLineDraw(line, ctx)
        }
        image.unlockFocus()
        image.isTemplate = true
        cache[key] = image
        return image
    }
}

struct SectionHeader: View {
    let text: String
    let theme: Theme
    var body: some View {
        Text(text)
            .font(theme.mono(T.caption, .bold))
            .kerning(1.2)
            .foregroundStyle(theme.dim)
            .padding(.top, ceil(T.caption * 0.15))
    }
}

struct Separator: View {
    let theme: Theme
    var body: some View { Rectangle().fill(theme.fg.opacity(0.12)).frame(height: 1) }
}

/// ToggleSwitch: track, sliding knob, cursor ring drawn outside the track.
struct ToggleSwitchView: View {
    let checked: Bool
    let hasCursor: Bool
    let theme: Theme
    let action: () -> Void

    @State private var hovering = false
    private let trackH: CGFloat = 22
    private var trackW: CGFloat { trackH * 1.9 }
    private var knob: CGFloat { (trackH * 0.72).rounded() }
    private var inset: CGFloat { max(1, ((trackH - knob) / 2).rounded()) }
    private var hot: Bool { hasCursor || hovering }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.radius)
                .strokeBorder(theme.hoverBorder, lineWidth: hot ? 1 : 0)
                .frame(width: trackW + 12, height: trackH + 12)
            ZStack(alignment: checked ? .trailing : .leading) {
                Capsule()
                    .fill(checked ? theme.selectedFill : theme.normalFill)
                    .overlay(Capsule().strokeBorder(checked ? theme.fg : theme.fg.opacity(0.4), lineWidth: 1))
                Circle()
                    .fill(checked ? theme.fg : theme.dim)
                    .frame(width: knob, height: knob)
                    .padding(.horizontal, inset)
            }
            .frame(width: trackW, height: trackH)
        }
        .frame(width: trackW + 12, height: trackH + 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.12), value: checked)
    }
}

/// PanelSlider: thin track, filled to the value, knob overhanging it and
/// swelling slightly while hot. Right-click is a secondary action on the whole
/// track -- audio uses it to mute the channel the slider belongs to.
struct PanelSlider: View {
    @Binding var value: Double
    let theme: Theme
    var enabled: Bool = true
    let onCommit: (Double) -> Void
    var onRightClick: () -> Void = {}

    @State private var hovering = false
    @State private var dragging = false
    private var hot: Bool { hovering || dragging }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track).frame(height: T.trackHeight)
                Capsule().fill(theme.fg).frame(width: w * p, height: T.trackHeight)
                Circle()
                    .fill(theme.fg)
                    .overlay(Circle().strokeBorder(theme.bg, lineWidth: 2))
                    .frame(width: T.knobSize, height: T.knobSize)
                    .scaleEffect(hot ? 1.15 : 1.0)
                    .offset(x: min(max(w * p - T.knobSize / 2, 0), w - T.knobSize))
                    .animation(.easeOut(duration: 0.11), value: hot)
            }
            .frame(height: max(T.knobSize, T.trackHeight))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        dragging = true
                        value = min(max(g.location.x / max(w, 1), 0), 1)
                    }
                    .onEnded { _ in
                        dragging = false
                        onCommit(value)
                    })
            .onHover { hovering = $0 }
            // A right-click anywhere on the track mutes that channel, which is
            // the gesture omarchy's slider carries.
            .simultaneousGesture(TapGesture().modifiers(.control).onEnded { onRightClick() })
        }
        .frame(height: T.controlHeight)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// One device row. Mouse hover moves the panel's cursor rather than colouring
/// the row directly, so only one thing is highlighted at a time.
struct DeviceRow: View {
    let device: Device
    let theme: Theme
    let hasCursor: Bool
    let onHover: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: T.xl) {
            Glyph(text: device.current ? "󰄬" : " ", size: T.subtitle, family: theme.font,
                  color: device.current ? theme.fg : .clear)
            Text(device.name)
                .font(theme.mono(T.body))
                .foregroundStyle(device.current ? theme.fg : theme.dim)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.xl)
        .padding(.vertical, T.md)
        .background(
            RoundedRectangle(cornerRadius: theme.radius)
                .fill(hasCursor ? theme.hoverFill : (device.current ? theme.selectedFill : .clear))
                .overlay(RoundedRectangle(cornerRadius: theme.radius)
                    .strokeBorder(hasCursor ? theme.hoverBorder : .clear, lineWidth: 1)))
        .contentShape(Rectangle())
        .onHover { if $0 { onHover() } }
        .onTapGesture(perform: onSelect)
        .animation(.easeOut(duration: 0.06), value: hasCursor)
    }
}

// MARK: - panel

/// One highlight on screen at a time, keyboard and mouse alike: the hero
/// switch, either slider, or a device row.
enum Cursor: Equatable {
    case header
    case slider(Channel)
    case device(Channel, Int)

    static func == (a: Cursor, b: Cursor) -> Bool {
        switch (a, b) {
        case (.header, .header): return true
        case let (.slider(x), .slider(y)): return x == y
        case let (.device(c1, i1), .device(c2, i2)): return c1 == c2 && i1 == i2
        default: return false
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: AudioStore
    let theme: Theme
    let onClose: () -> Void

    @State private var cursor: Cursor = .slider(.output)
    @State private var cursorActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: T.xxxl) {
            hero
            Separator(theme: theme)
            channelSection(.output, title: "OUTPUT",
                           volume: store.outputVolume, muted: store.outputMuted,
                           devices: store.outputDevices)
            if !store.inputDevices.isEmpty {
                Separator(theme: theme)
                channelSection(.input, title: "INPUT",
                               volume: store.inputVolume, muted: store.inputMuted,
                               devices: store.inputDevices)
            }
        }
        .padding(T.popupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg)
        .onAppear { store.start() }
        // CoreAudio notifications keep media-key and device changes in sync;
        // no polling or subprocesses while the panel is sitting idle.
        .background(KeyCatcher(onMove: move, onActivate: activate, onClose: onClose))
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: T.xxxl) {
            Glyph(text: Fmt.outputGlyph(volume: store.outputVolume,
                                        muted: store.outputMuted,
                                        headphones: store.outputIsHeadphones),
                  size: T.display, family: theme.font, color: theme.fg)
                .opacity(store.outputMuted ? 0.5 : 1)

            VStack(alignment: .leading, spacing: T.xxs) {
                Text("Audio")
                    .font(theme.mono(T.title, .bold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                Text(Fmt.volumeName(store.outputVolume, muted: store.outputMuted).uppercased())
                    .font(theme.mono(T.caption, .bold))
                    .kerning(1.2)
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Checked means something is still audible, so muting everything
            // reads as switching audio off.
            ToggleSwitchView(checked: store.anyAudible,
                             hasCursor: cursorActive && cursor == .header,
                             theme: theme) {
                cursorActive = true
                cursor = .header
                store.toggleAll()
            }
        }
    }

    private func channelSection(_ channel: Channel, title: String,
                                volume: Double, muted: Bool,
                                devices: [Device]) -> some View {
        VStack(alignment: .leading, spacing: T.md) {
            HStack {
                SectionHeader(text: title, theme: theme)
                Spacer()
                Text(Fmt.percent(volume))
                    .font(theme.mono(T.caption, .bold))
                    .foregroundStyle(theme.dim)
                    .opacity(muted ? 0.5 : 1)
            }

            PanelSlider(
                value: Binding(
                    get: { volume },
                    set: { channel == .output ? store.setOutputVolume($0) : store.setInputVolume($0) }),
                theme: theme,
                enabled: true,
                onCommit: { _ in },
                onRightClick: { channel == .output ? store.toggleOutputMute() : store.toggleInputMute() })
                .padding(.horizontal, T.md)
                .background(
                    RoundedRectangle(cornerRadius: theme.radius)
                        .strokeBorder(cursorActive && cursor == .slider(channel)
                                      ? theme.hoverBorder : .clear, lineWidth: 1))
                .onHover { if $0 { cursorActive = true; cursor = .slider(channel) } }

            ForEach(Array(devices.enumerated()), id: \.element.id) { i, d in
                DeviceRow(device: d, theme: theme,
                          hasCursor: cursorActive && cursor == .device(channel, i),
                          onHover: { cursorActive = true; cursor = .device(channel, i) },
                          onSelect: { store.select(d, on: channel) })
            }
        }
    }

    // ------------------------------------------------------------- keyboard

    /// The vertical order is hero -> output slider -> output devices -> input
    /// slider -> input devices, flattened so j/k walk it without caring which
    /// section a row belongs to.
    private var order: [Cursor] {
        var out: [Cursor] = [.header, .slider(.output)]
        out += store.outputDevices.indices.map { .device(.output, $0) }
        if !store.inputDevices.isEmpty {
            out.append(.slider(.input))
            out += store.inputDevices.indices.map { .device(.input, $0) }
        }
        return out
    }

    private func move(_ dx: Int, _ dy: Int) {
        if !cursorActive {
            cursorActive = true
            if dy >= 0 { return }
        }
        // h/l adjust the level when the cursor is on a slider; elsewhere they
        // have nothing to say, so they stay inert rather than wrapping rows.
        if dx != 0 {
            if case .slider(let ch) = cursor {
                let step = 0.05 * Double(dx)
                if ch == .output { store.setOutputVolume(store.outputVolume + step) }
                else { store.setInputVolume(store.inputVolume + step) }
            }
            return
        }
        guard dy != 0, let i = order.firstIndex(of: cursor) else { return }
        cursor = order[min(max(i + dy, 0), order.count - 1)]
    }

    private func activate() {
        guard cursorActive else { return }
        switch cursor {
        case .header: store.toggleAll()
        case .slider(let ch): ch == .output ? store.toggleOutputMute() : store.toggleInputMute()
        case .device(let ch, let i):
            let list = ch == .output ? store.outputDevices : store.inputDevices
            guard list.indices.contains(i) else { return }
            store.select(list[i], on: ch)
        }
    }
}

struct KeyCatcher: NSViewRepresentable {
    let onMove: (Int, Int) -> Void
    let onActivate: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(self)
        return NSView()
    }
    func updateNSView(_ v: NSView, context: Context) { context.coordinator.owner = self }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var owner: KeyCatcher?
        private var monitor: Any?

        func install(_ o: KeyCatcher) {
            owner = o
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let o = self?.owner else { return e }
                switch e.keyCode {
                case 53: o.onClose(); return nil
                case 126: o.onMove(0, -1); return nil
                case 125: o.onMove(0, 1); return nil
                case 123: o.onMove(-1, 0); return nil
                case 124: o.onMove(1, 0); return nil
                case 36, 76: o.onActivate(); return nil
                default: break
                }
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "k": o.onMove(0, -1); return nil
                case "j": o.onMove(0, 1); return nil
                case "h": o.onMove(-1, 0); return nil
                case "l": o.onMove(1, 0); return nil
                default: return e
                }
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - window

final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var opts: Options
    private let store: AudioStore
    private var window: PanelWindow?
    private var previous: NSRunningApplication?
    private var targetScreen: NSScreen?
    private let resident: Bool
    private let prepare: Bool
    private var visible = false
    private var ipc: PanelIPC?

    @MainActor init(opts: Options, resident: Bool, prepare: Bool) {
        self.opts = opts.resolvedAnchor()
        self.resident = resident
        self.prepare = prepare
        self.store = AudioStore(opts: opts)
    }

    private func screen() -> NSScreen? {
        opts.displayID.flatMap { id in
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
        } ?? NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
    }

    @MainActor func applicationDidFinishLaunching(_ n: Notification) {
        if resident {
            ipc = PanelIPC { [weak self] command, arguments in
                MainActor.assumeIsolated { self?.handle(command, arguments: arguments) }
            }
            // A concurrent first click may have started another host already.
            guard ipc != nil else { NSApp.terminate(nil); return }
        }
        buildWindow()
        if prepare {
            // Warm CoreAudio and populate/layout the window before the click.
            // Observations are stopped once the initial read finishes.
            store.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.visible else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.store.stop()
            }
        } else { show() }
    }

    private func handle(_ command: PanelCommand, arguments: [String]) {
        if command == .hide { close(); return }
        if command == .toggle && visible { close(); return }
        let next = Options.parse(arguments).resolvedAnchor()
        let rebuild = !opts.sameView(as: next)
        opts = next
        if rebuild { buildWindow() }
        if command == .toggle { show() }
    }

    private func buildWindow() {
        window?.delegate = nil
        window?.close()
        window = nil
        let theme = Theme(palette: opts.palette, font: opts.font, radius: opts.radius)
        let root = PanelView(store: store, theme: theme) { [weak self] in self?.close() }
            .frame(width: opts.width)

        let hc = NSHostingController(rootView: AnyView(root))
        hc.sizingOptions = [.preferredContentSize]

        let w = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: opts.width, height: 420),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        w.contentViewController = hc
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .popUpMenu
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.delegate = self
        w.isMovable = false
        w.isReleasedWhenClosed = false

        if let cv = w.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = opts.radius
            cv.layer?.masksToBounds = true
            cv.layer?.borderWidth = 1
            cv.layer?.borderColor = opts.palette.border.cgColor
        }

        window = w
        w.contentView?.layoutSubtreeIfNeeded()
    }

    private func show() {
        guard let w = window else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front != NSRunningApplication.current { previous = front }
        targetScreen = screen()
        visible = true
        store.start()
        position(w, size: w.frame.size)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        guard resident else { NSApp.terminate(nil); return }
        guard visible else { return }
        visible = false
        store.stop()
        let restore = NSApp.isActive
        window?.orderOut(nil)
        if restore {
            NSApp.deactivate()
            previous?.activate()
        }
    }

    /// Anchored by its top edge, so a resize has to re-place it or the panel
    /// crawls down the screen as sections arrive.
    func windowDidResize(_ n: Notification) {
        guard let w = window else { return }
        position(w, size: w.frame.size)
    }

    private func position(_ w: NSWindow, size: NSSize) {
        guard let screen = targetScreen else { return }
        let f = screen.frame
        let margin: CGFloat = 6
        let x = min(max(f.minX + margin, (opts.anchorX ?? f.maxX - margin) - size.width),
                    f.maxX - size.width - margin)
        let y = max(f.minY + margin, f.maxY - (opts.anchorY ?? 32) - size.height)
        let origin = NSPoint(x: x, y: y)
        if w.frame.origin != origin { w.setFrameOrigin(origin) }
    }

    func windowDidResignKey(_ n: Notification) {
        guard visible, opts.exitOnBlur else { return }
        close()
    }

    func applicationWillTerminate(_ n: Notification) {
        guard NSApp.isActive, let previous, previous != NSRunningApplication.current else { return }
        previous.activate()
    }
}

@main
enum VolumePanel {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command: PanelCommand? = arguments.contains("--toggle") ? .toggle :
            (arguments.contains("--hide") ? .hide : (arguments.contains("--prepare") ? .prepare : nil))
        if let command, PanelIPC.send(command, arguments: arguments) { return }
        // Never launch a GUI just to close an absent host.
        if command == .hide { return }
        let options = Options.parse(arguments)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = Controller(opts: options, resident: command != nil, prepare: command == .prepare)
        app.delegate = controller
        app.run()
    }
}
