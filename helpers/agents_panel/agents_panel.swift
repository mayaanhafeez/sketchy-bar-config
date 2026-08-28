// Agents panel: the Claude/Codex usage dashboard as a window.
//
// Unlike the Wi-Fi panel, this one is not about speed -- claude_usage.py and
// codex_usage.py both answer in about 20ms, and the sketchybar popup drew them
// fine. It is about what the popup had to do to get there: 58 permanent bar
// items backing two popups, meters faked out of monospace padding, and every
// row a fixed height because a popup row is as tall as its background. Here a
// meter is a rounded rect and a column is a VStack.
//
//   agents_panel [--provider claude|codex] [--anchor-x <px>] [--anchor-y <px>]
//                [--width <px>] [--radius <px>] [--font <family>] [...palette]
//
//   --provider   Which tab opens first. Defaults to claude.
//   --helpers    Directory holding claude_usage.py / codex_usage.py.
//                Defaults to the directory this binary was launched from.
//   --assets     Directory holding claude.svg / codex.svg, used for the
//                provider logos. Falls back to a Nerd Font glyph when a file
//                is missing.
//   --anchor-x/y Top-right corner to hang from, y measured from the top.
//   --stay       Keep running after the panel loses focus, for inspection.
//
// Colours are "#rrggbb" or "0xaarrggbb", the argb form sketchybar uses:
//
//   --foreground --background --accent --urgent --muted --border
//
// Both helpers print flat key=value lines, with indexed rows for the two
// charts (`day.3=Mon|976.2K|7`, `model.1=Opus 5|33.2M|100`). The trailing
// number on those rows is already a percentage of the busiest day or heaviest
// model, so the bars scale to peak without this having to re-derive it.

import AppKit
import SwiftUI

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
    var provider = "claude"
    var helpers = FileManager.default.currentDirectoryPath
    var assets = FileManager.default.currentDirectoryPath
    var anchorX: CGFloat? = nil
    var anchorY: CGFloat? = nil
    var width: CGFloat = 340
    var radius: CGFloat = 10
    var font = "JetBrainsMono Nerd Font"
    var exitOnBlur = true
    var palette = Palette()

    static func parse(_ argv: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            let next: String? = (i + 1 < argv.count) ? argv[i + 1] : nil
            switch arg {
            case "--provider":   if let v = next { o.provider = v; i += 1 }
            case "--helpers":    if let v = next { o.helpers = (v as NSString).expandingTildeInPath; i += 1 }
            case "--assets":     if let v = next { o.assets = (v as NSString).expandingTildeInPath; i += 1 }
            case "--anchor-x":   if let v = next, let d = Double(v) { o.anchorX = CGFloat(d); i += 1 }
            case "--anchor-y":   if let v = next, let d = Double(v) { o.anchorY = CGFloat(d); i += 1 }
            case "--width":      if let v = next, let d = Double(v) { o.width = CGFloat(d); i += 1 }
            case "--radius":     if let v = next, let d = Double(v) { o.radius = CGFloat(d); i += 1 }
            case "--font":       if let v = next { o.font = v; i += 1 }
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
    static let title: CGFloat     = 14
    static let display: CGFloat   = 24

    static let xxs: CGFloat = 2
    static let sm: CGFloat  = 4
    static let md: CGFloat  = 6
    static let lg: CGFloat  = 8
    static let xl: CGFloat  = 10
    static let xxl: CGFloat = 12

    static let popupPadding: CGFloat  = 14
    static let controlPaddingY: CGFloat = 6
    static let controlHeight: CGFloat = 28

    /// Both charts and every limit meter share one bar thickness, which is
    /// what makes the three sections read as one dashboard.
    static let meter: CGFloat = 4
    static let dayLabelWidth: CGFloat = 52
}

// MARK: - model

struct LimitWindow: Identifiable {
    var title: String
    var percent: Double     // 0...1, negative when unknown
    var resetText: String
    var id: String { title }

    var alarming: Bool { percent >= 0.9 }
}

struct DayUsage: Identifiable {
    var label: String
    var tokens: String
    var ratio: Double       // 0...1, already scaled to the busiest day
    var id: String { label }

    /// The helpers label the last bucket "Today" rather than by weekday, so
    /// that is what picks out the run-up to right now.
    var isToday: Bool { label.lowercased() == "today" }
}

struct ModelUsage: Identifiable {
    var name: String
    var tokens: String
    var share: Double       // 0...1, scaled to the heaviest model
    var id: String { name }
}

struct Provider: Identifiable {
    var id: String
    var name: String
    var plan = ""
    var available = false
    var statusText = ""
    var limits: [LimitWindow] = []
    var days: [DayUsage] = []
    var models: [ModelUsage] = []
}

// MARK: - parsing

enum Usage {
    /// Both helpers emit flat `key=value`, one per line. Indexed rows carry
    /// pipe-separated fields; anything malformed is skipped rather than
    /// rendered as a half-row.
    static func parse(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    static func provider(id: String, name: String, from raw: String) -> Provider {
        let kv = parse(raw)
        var p = Provider(id: id, name: name)
        p.plan = kv["plan"] ?? ""

        // Claude reports login and subscription separately; Codex only ever
        // prints a plan, so its presence is the availability signal.
        let loggedIn = kv["logged_in"].map { $0 == "1" } ?? !p.plan.isEmpty
        p.available = loggedIn && !p.plan.isEmpty
        if !p.available {
            p.statusText = loggedIn
                ? "No subscription found for \(name)."
                : "Not signed in to \(name)."
        }

        // The two rolling windows every provider exposes. A missing percentage
        // is -1 rather than 0 so the meter can read "—" instead of "empty".
        func window(_ title: String, _ pctKey: String, _ resetKey: String) -> LimitWindow? {
            guard let pct = Double(kv[pctKey] ?? "") else { return nil }
            let reset = kv[resetKey] ?? ""
            return LimitWindow(title: title, percent: pct / 100,
                               resetText: reset.isEmpty ? "" : "Resets in \(reset)")
        }
        // Claude gates its limit readout behind `limits=1`; when it is off the
        // percentages are not meaningful and the section is dropped whole.
        if kv["limits"] != "0" {
            p.limits = [window("Session", "session_pct", "session_reset"),
                        window("Weekly", "weekly_pct", "weekly_reset")].compactMap { $0 }
        }

        p.days = indexed(kv, prefix: "day", count: kv["days"]).map {
            DayUsage(label: $0[0], tokens: $0[1], ratio: (Double($0[2]) ?? 0) / 100)
        }
        p.models = indexed(kv, prefix: "model", count: kv["models"]).map {
            ModelUsage(name: $0[0], tokens: $0[1], share: (Double($0[2]) ?? 0) / 100)
        }
        return p
    }

    /// `day.1` … `day.N`, each `field|field|field`. The count key is advisory:
    /// iterate to it, but stop early on the first row that is missing or short
    /// rather than trusting it blindly.
    private static func indexed(_ kv: [String: String], prefix: String, count: String?) -> [[String]] {
        guard let n = Int(count ?? ""), n > 0 else { return [] }
        var rows: [[String]] = []
        for i in 1...n {
            guard let raw = kv["\(prefix).\(i)"] else { break }
            let f = raw.components(separatedBy: "|")
            guard f.count >= 3 else { break }
            rows.append(f)
        }
        return rows
    }
}

@MainActor
final class AgentStore: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var selected = 0

    private let opts: Options
    private let work = DispatchQueue(label: "agents_panel.load", qos: .userInitiated)

    init(opts: Options) { self.opts = opts }

    var current: Provider? {
        providers.indices.contains(selected) ? providers[selected] : nil
    }

    func load() {
        let dir = opts.helpers
        let want = opts.provider
        work.async { [weak self] in
            let claude = Usage.provider(id: "claude", name: "Claude",
                                        from: Self.run(dir, "claude_usage.py"))
            let codex = Usage.provider(id: "codex", name: "Codex",
                                       from: Self.run(dir, "codex_usage.py"))
            Task { @MainActor in
                guard let self else { return }
                // Keep the tab the user is on across a refresh; only the first
                // load honours --provider.
                let keep = self.current?.id
                self.providers = [claude, codex]
                let target = keep ?? want
                self.selected = self.providers.firstIndex { $0.id == target } ?? 0
            }
        }
    }

    func select(_ i: Int) {
        guard providers.indices.contains(i) else { return }
        selected = i
    }

    nonisolated private static func run(_ dir: String, _ script: String) -> String {
        let path = (dir as NSString).appendingPathComponent(script)
        guard FileManager.default.isReadableFile(atPath: path) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Provider logos, the same artwork omarchy ships. NSImage reads SVG, but a
/// file that sizes itself only through a viewBox comes back as 1x1 -- codex.svg
/// does exactly that -- so the size is always set explicitly rather than
/// trusted from the file.
enum Logo {
    private static var cache: [String: NSImage] = [:]

    static func image(_ providerId: String, in dir: String, side: CGFloat) -> NSImage? {
        let key = "\(providerId)@\(Int(side))"
        if let hit = cache[key] { return hit }
        let path = (dir as NSString).appendingPathComponent("\(providerId).svg")
        guard FileManager.default.isReadableFile(atPath: path),
              let img = NSImage(contentsOfFile: path) else { return nil }
        img.size = NSSize(width: side, height: side)
        cache[key] = img
        return img
    }
}

/// A Nerd Font icon. These glyphs paint wider than the cell they advance, and
/// SwiftUI sizes a Text from the advance -- so without reserving the real ink
/// box the layout shears the right-hand side off. See the wifi panel's copy for
/// the measurements.
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

    /// Draws the glyph into a bitmap sized from its own ink box.
    ///
    /// SwiftUI lays a Text out on the font's *advance*, and these Nerd Font
    /// marks paint far wider than they advance -- 13.58pt of ink in an 8.40pt
    /// cell at 14pt. Text then crops to that box, and no combination of
    /// .fixedSize() or .frame(width:) moves the crop: both were tried, and both
    /// only re-position an already-cropped glyph. Rasterising through CoreText
    /// sidesteps text layout entirely, because the canvas is measured from the
    /// ink rather than the advance.
    ///
    /// Emitted as a template image so the colour still comes from the view,
    /// which keeps the cache independent of theme and row state.
    @MainActor static func rasterise(_ text: String, family: String, size: CGFloat) -> NSImage? {
        let key = "\(text)|\(family)|\(size)"
        if let hit = cache[key] { return hit }
        defer { }
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

        // A pixel of slack on each side: ink bounds are exact, and antialiasing
        // needs somewhere to land.
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

// MARK: - chrome

struct Theme {
    let palette: Palette
    let font: String
    let radius: CGFloat

    var fg: Color { Color(palette.foreground) }
    var bg: Color { Color(palette.background) }
    var accent: Color { Color(palette.accent) }
    var urgent: Color { Color(palette.urgent) }
    /// omarchy dims this section's secondary text harder than the network
    /// panel does -- 1.55 against 1.4 -- because the charts are dense.
    var dim: Color { Color(palette.foreground.darker(1.55)) }

    /// The shared meter track: the selected-state fill, so every bar sits on
    /// the same ground as a selected row elsewhere in the kit.
    var track: Color { fg.opacity(0.18) }

    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(font, size: size).weight(weight)
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
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Separator: View {
    let theme: Theme
    var body: some View { Rectangle().fill(theme.fg.opacity(0.12)).frame(height: 1) }
}

/// Rounded track with a fill showing the fraction used. The one primitive the
/// sketchybar popup could only approximate, by padding a monospace string.
struct Meter: View {
    let value: Double
    let alarming: Bool
    let theme: Theme
    var thickness: CGFloat = T.meter
    var fill: Color? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule()
                    .fill(alarming ? theme.urgent : (fill ?? theme.fg))
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: thickness)
        .animation(.easeOut(duration: 0.16), value: value)
    }
}

// MARK: - rows

struct LimitRowView: View {
    let window: LimitWindow
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: T.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(theme.mono(T.body))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: T.sm)
                Text(window.percent >= 0 ? "\(Int((window.percent * 100).rounded()))%" : "—")
                    .font(theme.mono(T.caption))
                    .foregroundStyle(window.alarming ? theme.urgent : theme.fg)
            }
            Meter(value: window.percent, alarming: window.alarming, theme: theme)
            if !window.resetText.isEmpty {
                Text(window.resetText)
                    .font(theme.mono(T.caption))
                    .foregroundStyle(theme.dim)
            }
        }
    }
}

/// Label, bar, tokens. Today is picked out in full foreground so the week
/// reads as a run-up to right now.
struct DayRowView: View {
    let day: DayUsage
    let theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            Text(day.label)
                .font(theme.mono(T.caption, day.isToday ? .bold : .regular))
                .foregroundStyle(day.isToday ? theme.fg : theme.dim)
                .fixedSize()
                .frame(width: T.dayLabelWidth, alignment: .leading)

            Meter(value: day.ratio, alarming: false, theme: theme,
                  fill: day.isToday ? theme.fg : theme.fg.opacity(0.55))
                .padding(.leading, T.lg)
                .padding(.trailing, T.xl)

            Text(day.tokens)
                .font(theme.mono(T.caption, .bold))
                .foregroundStyle(day.isToday ? theme.fg : theme.dim)
                .fixedSize()
                .frame(width: T.dayLabelWidth, alignment: .trailing)
        }
        .frame(height: T.controlHeight * 0.62)
    }
}

/// The share bar fills the row *behind* the label rather than stacking under
/// it, which is what keeps the whole dashboard on one screen.
struct ModelRowView: View {
    let model: ModelUsage
    let theme: Theme

    var body: some View {
        HStack(spacing: T.lg) {
            Text(model.name)
                .font(theme.mono(T.bodySmall))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: T.sm)
            Text(model.tokens)
                .font(theme.mono(T.bodySmall, .bold))
                .foregroundStyle(theme.dim)
        }
        .padding(.horizontal, T.lg)
        .padding(.vertical, T.md)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: theme.radius).fill(theme.fg.opacity(0.05))
                    RoundedRectangle(cornerRadius: theme.radius)
                        .fill(theme.fg.opacity(0.14))
                        .frame(width: geo.size.width * min(max(model.share, 0), 1))
                }
                .animation(.easeOut(duration: 0.16), value: model.share)
            }
        )
    }
}

/// The provider tabs. `selected` is the persistent choice; `hasCursor` is the
/// keyboard highlight, and on this panel they are the same thing.
struct TabButton: View {
    let title: String
    let selected: Bool
    let theme: Theme
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(theme.mono(T.bodySmall, selected ? .bold : .regular))
            .foregroundStyle(theme.fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, T.controlPaddingY)
            .background(
                RoundedRectangle(cornerRadius: theme.radius)
                    .fill(selected ? theme.fg.opacity(0.18)
                                   : (hovering ? theme.fg.opacity(0.08) : theme.fg.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: theme.radius)
                        .strokeBorder(selected ? theme.fg : theme.fg.opacity(0.4),
                                      lineWidth: 1))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            // No implicit animation on `selected`: switching provider replaces
            // the whole dashboard, and a tab that eases while the panel behind
            // it swaps instantly reads as lag rather than as feedback.
    }
}

// MARK: - panel

struct PanelView: View {
    @ObservedObject var store: AgentStore
    let theme: Theme
    let assets: String
    let onClose: () -> Void

    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Swapping providers replaces the whole dashboard, so it must not animate:
    /// the meters interpolate on value and the window resizes at the same time,
    /// which together looked like the bars dropping in from the top. Refreshes
    /// of the *same* provider still animate, which is where it belongs.
    private func selectProvider(_ i: Int) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { store.select(i) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.xxl) {
            header

            if store.providers.count > 1 {
                HStack(spacing: T.md) {
                    ForEach(Array(store.providers.enumerated()), id: \.element.id) { i, p in
                        TabButton(title: p.name, selected: i == store.selected,
                                  theme: theme) { selectProvider(i) }
                    }
                }
            }

            if let p = store.current {
                Group {
                if !p.available {
                    notice(p.statusText)
                } else {
                    if !p.limits.isEmpty {
                        Separator(theme: theme)
                        VStack(alignment: .leading, spacing: T.xl) {
                            SectionHeader(text: "LIMITS", theme: theme)
                            ForEach(p.limits) { LimitRowView(window: $0, theme: theme) }
                        }
                    }
                    if !p.days.isEmpty {
                        Separator(theme: theme)
                        VStack(alignment: .leading, spacing: T.md) {
                            SectionHeader(text: "TOKENS BY DAY", theme: theme)
                            ForEach(p.days) { DayRowView(day: $0, theme: theme) }
                        }
                    }
                    if !p.models.isEmpty {
                        Separator(theme: theme)
                        VStack(alignment: .leading, spacing: T.md) {
                            SectionHeader(text: "TOKENS BY MODEL", theme: theme)
                            ForEach(p.models) { ModelRowView(model: $0, theme: theme) }
                        }
                    }
                }
                }
                .id(p.id)
                .transaction { $0.animation = nil }
            } else {
                notice("No AI coding subscriptions found.\nAgents show up here once you've used them.")
            }
        }
        .padding(T.popupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg)
        .onAppear { store.load() }
        .onReceive(tick) { _ in store.load() }
        .background(KeyCatcher(onMove: move, onClose: onClose, onReload: store.load))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: T.xxl) {
            if let id = store.current?.id,
               let logo = Logo.image(id, in: assets, side: 26) {
                Image(nsImage: logo)
                    .resizable()
                    .frame(width: 26, height: 26)
            } else {
                Glyph(text: "󰚩", size: T.display, family: theme.font, color: theme.fg)
            }
            VStack(alignment: .leading, spacing: T.xxs) {
                Text(store.current?.name ?? "Agents")
                    .font(theme.mono(T.title, .bold))
                    .foregroundStyle(theme.fg)
                Text((store.current?.plan ?? "").uppercased())
                    .font(theme.mono(T.caption, .bold))
                    .kerning(1.2)
                    .foregroundStyle(theme.dim)
            }
            Spacer()
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(theme.mono(T.body))
            .foregroundStyle(theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, T.xl)
    }

    /// h/l and the arrows walk the tabs; there is nothing else to land on, so
    /// vertical movement is deliberately inert rather than wrapping.
    private func move(_ dx: Int) {
        guard dx != 0 else { return }
        store.select(min(max(store.selected + dx, 0), store.providers.count - 1))
    }
}

struct KeyCatcher: NSViewRepresentable {
    let onMove: (Int) -> Void
    let onClose: () -> Void
    let onReload: () -> Void

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
                case 53: o.onClose(); return nil                       // esc
                case 123: o.onMove(-1); return nil                     // left
                case 124: o.onMove(1); return nil                      // right
                case 48: o.onMove(1); return nil                       // tab
                default: break
                }
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "h": o.onMove(-1); return nil
                case "l": o.onMove(1); return nil
                case "r": o.onReload(); return nil
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

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let opts: Options
    private let store: AgentStore
    private var window: PanelWindow?
    private let previous = NSWorkspace.shared.frontmostApplication

    @MainActor init(opts: Options) {
        self.opts = opts
        self.store = AgentStore(opts: opts)
    }

    @MainActor func applicationDidFinishLaunching(_ n: Notification) {
        let theme = Theme(palette: opts.palette, font: opts.font, radius: opts.radius)
        let root = PanelView(store: store, theme: theme, assets: opts.assets) { NSApp.terminate(nil) }
            .frame(width: opts.width)

        // Sized by the hosting controller rather than measured once: the panel
        // is empty until the two usage scripts return, and the window has to
        // keep following SwiftUI's ideal height as the sections appear.
        let hc = NSHostingController(rootView: AnyView(root))
        hc.sizingOptions = [.preferredContentSize]

        let w = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: opts.width, height: 480),
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

        if let cv = w.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = opts.radius
            cv.layer?.masksToBounds = true
            cv.layer?.borderWidth = 1
            cv.layer?.borderColor = opts.palette.border.cgColor
        }

        position(w, size: w.frame.size)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    /// Anchored by its top edge, so every resize has to re-place it or the
    /// panel appears to crawl down the screen as sections arrive.
    func windowDidResize(_ n: Notification) {
        guard let w = window else { return }
        position(w, size: w.frame.size)
    }

    private func position(_ w: NSWindow, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let margin: CGFloat = 6
        let x = min(max(f.minX + margin, (opts.anchorX ?? f.maxX - margin) - size.width),
                    f.maxX - size.width - margin)
        let y = max(f.minY + margin, f.maxY - (opts.anchorY ?? 32) - size.height)
        w.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowDidResignKey(_ n: Notification) {
        guard opts.exitOnBlur else { return }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ n: Notification) {
        guard NSApp.isActive, let previous, previous != NSRunningApplication.current else { return }
        previous.activate()
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { Controller(opts: options) }
app.delegate = controller
app.run()
