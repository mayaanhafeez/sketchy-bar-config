// Wi-Fi panel: the network popup as a real window instead of a stack of
// sketchybar items.
//
// The Lua popup rendered in well under 10ms -- drawing was never the problem.
// What it could not do was scroll, take a keypress, or accept typed text, and
// getting close meant 32 permanent bar items, a slot recycler, a keyboard
// grabber, and an osascript dialog for passwords. That is what this replaces.
//
// Every reading and every action comes from macwifi, through the same helper
// scripts the popup used, so there is exactly one implementation of "what is
// the Wi-Fi doing" on this machine and scan improvements land here for free.
// An earlier revision read scans through CoreWLAN in-process, which was much
// faster but put the panel behind a Location Services prompt: macOS hides every
// SSID from a process without location access, so it needed to ship as a signed
// .app just to be grantable. Shelling out to macwifi sidesteps that -- macwifi
// carries its own grant, and this stays an ordinary binary.
//
//   wifi_panel [--anchor-x <px>] [--anchor-y <px>] [--width <px>] [...palette]
//
//   --anchor-x/--anchor-y  Top-right corner to hang the panel from, in screen
//                          coordinates with y measured from the top. Defaults
//                          to the top-right of the main screen under the bar.
//   --width                Panel width. Default 380.
//   --radius               Corner radius. Default 10.
//   --font                 Family for everything, including the Nerd Font
//                          glyphs. Default "JetBrainsMono Nerd Font".
//   --macwifi              Path to the macwifi binary.
//   --helpers              Directory holding wifi_status.sh, wifi_scan.sh,
//                          wifi_join.command, wifi_speedtest.sh and
//                          speedtest_overlay/bin. Required in practice.
//   --stay                 Keep running after the panel loses focus. Off by
//                          default: clicking away is how a popup is dismissed.
//                          Mainly here to make the thing inspectable, the same
//                          way popup_keys carries the flag.
//
// Colours are "#rrggbb" or "0xaarrggbb", the same argb form sketchybar uses,
// so the widget can pass the active theme straight through the way it already
// does for speedtest_overlay:
//
//   --foreground --background --accent --urgent --muted --border
//
// Joins go through helpers/wifi_join.command rather than calling `macwifi
// connect <ssid> <password>` directly, and the passphrase is set on the child
// process's environment rather than interpolated into a shell string -- so it
// never appears in this panel's argv, and never in a shell's history or
// process table on the way over. The helper also reports BUSY / NEEDPASS /
// FAILED, which is exactly the state machine the row UI needs.

import AppKit
import SwiftUI
import CoreImage
import CoreImage

// MARK: - palette

/// One colour per role, mirroring the handful of roles omarchy's Color
/// singleton actually exposes to a panel: text, surface, accent, alarm, the
/// dimmed variant used for secondary text, and the card edge.
struct Palette {
    var foreground = NSColor(calibratedWhite: 0.88, alpha: 1)
    var background = NSColor(calibratedRed: 0.14, green: 0.13, blue: 0.20, alpha: 1)
    var accent     = NSColor(calibratedRed: 0.77, green: 0.65, blue: 0.90, alpha: 1)
    var urgent     = NSColor(calibratedRed: 0.92, green: 0.44, blue: 0.57, alpha: 1)
    var muted      = NSColor(calibratedWhite: 0.55, alpha: 1)
    var border     = NSColor(calibratedWhite: 0.43, alpha: 1)
}

extension Palette {
    /// speedtest_overlay's own flag set, so the overlay a click raises here is
    /// tinted like the panel that raised it.
    var overlayFlags: [String] {
        func hex(_ c: NSColor) -> String {
            guard let d = c.usingColorSpace(.deviceRGB) else { return "0xffffffff" }
            return String(format: "0x%02x%02x%02x%02x",
                          Int(d.alphaComponent * 255), Int(d.redComponent * 255),
                          Int(d.greenComponent * 255), Int(d.blueComponent * 255))
        }
        return ["--accent-down", hex(accent), "--accent-up", hex(accent),
                "--value", hex(foreground), "--muted", hex(muted),
                "--title-color", hex(muted), "--fail", hex(urgent),
                "--dim", hex(background.withAlphaComponent(0.82))]
    }
}

struct Options {
    var anchorX: CGFloat? = nil
    var anchorY: CGFloat? = nil
    var width: CGFloat = 380
    var radius: CGFloat = 10
    var font = "JetBrainsMono Nerd Font"
    var macwifi = "/usr/local/bin/macwifi"
    var helpers = FileManager.default.currentDirectoryPath
    var exitOnBlur = true
    var palette = Palette()

    static func parse(_ argv: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            let next: String? = (i + 1 < argv.count) ? argv[i + 1] : nil
            switch arg {
            case "--anchor-x":   if let v = next, let d = Double(v) { o.anchorX = CGFloat(d); i += 1 }
            case "--anchor-y":   if let v = next, let d = Double(v) { o.anchorY = CGFloat(d); i += 1 }
            case "--width":      if let v = next, let d = Double(v) { o.width = CGFloat(d); i += 1 }
            case "--radius":     if let v = next, let d = Double(v) { o.radius = CGFloat(d); i += 1 }
            case "--font":       if let v = next { o.font = v; i += 1 }
            case "--macwifi":    if let v = next { o.macwifi = v; i += 1 }
            case "--helpers":    if let v = next { o.helpers = (v as NSString).expandingTildeInPath; i += 1 }
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
    // "#rrggbb", "rrggbb", "0xaarrggbb" -- the argb form sketchybar uses.
    convenience init?(hex: String) {
        var t = hex.lowercased()
        if t.hasPrefix("#") { t.removeFirst() }
        if t.hasPrefix("0x") { t.removeFirst(2) }
        guard let v = UInt32(t, radix: 16) else { return nil }
        let hasAlpha = t.count == 8
        let a = hasAlpha ? CGFloat((v >> 24) & 0xff) / 255 : 1
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        self.init(calibratedRed: r, green: g, blue: b, alpha: a)
    }

    /// omarchy leans on Qt.darker() for secondary text; this is the same idea
    /// with the same call sites, so the two panels read alike.
    func darker(_ factor: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.deviceRGB) else { return self }
        return NSColor(deviceRed: c.redComponent / factor,
                       green: c.greenComponent / factor,
                       blue: c.blueComponent / factor,
                       alpha: c.alphaComponent)
    }
}

// MARK: - design tokens
//
// A direct port of qs.Commons.Style at its default 12px root, so spacing and
// type here land on the same values the QML panel uses rather than on
// freshly-invented ones.

enum T {
    // typography
    static let caption: CGFloat   = 10
    static let bodySmall: CGFloat = 11
    static let body: CGFloat      = 12
    static let subtitle: CGFloat  = 13
    static let title: CGFloat     = 14
    static let display: CGFloat   = 24

    // spacing
    static let xxs: CGFloat = 2
    static let xs: CGFloat  = 3
    static let sm: CGFloat  = 4
    static let md: CGFloat  = 6
    static let lg: CGFloat  = 8
    static let xl: CGFloat  = 10
    static let xxl: CGFloat = 12
    static let xxxl: CGFloat = 14

    static let labelGap: CGFloat      = 4
    static let rowGap: CGFloat        = 8
    static let rowPaddingX: CGFloat   = 12
    static let popupPadding: CGFloat  = 14
    static let controlHeight: CGFloat = 28

    // state alphas
    static let normalFillAlpha: CGFloat   = 0.04
    static let hoverFillAlpha: CGFloat    = 0.08
    static let selectedFillAlpha: CGFloat = 0.18
    static let normalBorderAlpha: CGFloat = 0.40
    static let hoverBorderAlpha: CGFloat  = 0.25

    static let listMaxHeight: CGFloat = 240
}

// MARK: - model

enum Security {
    case open, owe, wep, personal, enterprise

    /// macwifi prints the column straight from CoreWLAN's own naming, so this
    /// matches on the substrings that survive every variant it can emit
    /// (WPA2, WPA2/WPA3, WPA3-Enterprise, and so on).
    static func parse(_ raw: String) -> Security {
        let t = raw.uppercased()
        if t.isEmpty || t == "OPEN" || t == "NONE" { return .open }
        if t.contains("OWE") { return .owe }
        if t.contains("ENTERPRISE") || t.contains("EAP") || t.contains("802.1X") { return .enterprise }
        if t.contains("WEP") { return .wep }
        return .personal
    }

    /// OWE encrypts without authenticating, so like open it has no credentials
    /// to collect and must not show the lock or open the prompt.
    var requiresCredentials: Bool {
        switch self {
        case .open, .owe: return false
        default: return true
        }
    }
}

struct WifiNetwork: Identifiable, Equatable {
    var ssid: String
    var rssi: Int
    var band: String        // "2.4" | "5" | "6" | ""
    var security: Security
    var known: Bool
    var connected: Bool

    var id: String { ssid }

    /// macwifi reports dBm; the glyph ramp and every comparison below want a
    /// 0-100 quality the way NetworkManager already hands omarchy.
    var quality: Int { max(0, min(100, 2 * (rssi + 100))) }

    static func == (a: WifiNetwork, b: WifiNetwork) -> Bool {
        a.ssid == b.ssid && a.rssi == b.rssi && a.known == b.known
            && a.connected == b.connected && a.band == b.band
    }
}

enum ActionKind: String {
    case connect, disconnect, forget

    var progressText: String {
        switch self {
        case .connect: return "Connecting…"
        case .disconnect: return "Disconnecting…"
        case .forget: return "Forgetting…"
        }
    }
}

struct LinkInfo {
    var iface = ""
    var ip = ""
    var gateway = ""
    var rxBytes: Double = 0
    var txBytes: Double = 0
    var hasCounters = false
}

// MARK: - formatting
//
// Ported from network/Model.js so the two panels round and abbreviate
// identically.

enum Fmt {
    static let signalGlyphs = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]

    static func wifiGlyph(_ quality: Int) -> String {
        let i = max(0, min(4, Int(ceil(Double(quality) / 20.0)) - 1))
        return signalGlyphs[i]
    }

    static func bytes(_ n: Double) -> String {
        let v = n.isFinite && n > 0 ? n : 0
        if v < 1024 { return "\(Int(v.rounded())) B" }
        if v < 1024 * 1024 { return String(format: "%.1f KB", v / 1024) }
        if v < 1024 * 1024 * 1024 { return String(format: "%.1f MB", v / (1024 * 1024)) }
        return String(format: "%.2f GB", v / (1024 * 1024 * 1024))
    }

    static func rate(_ bytesPerSec: Double) -> String { bytes(bytesPerSec) + "/s" }

    static func ping(_ ms: Double, hasSamples: Bool) -> String {
        if !hasSamples { return "--" }
        if !ms.isFinite || ms < 0 { return "Timeout" }
        return String(format: ms > 0 && ms < 10 ? "%.1f ms" : "%.0f ms", ms)
    }

    static func packetLoss(_ pct: Int, hasSamples: Bool) -> String {
        if !hasSamples { return "--" }
        return pct <= 0 ? "0%" : "\(pct)%"
    }

    static func bandLabel(_ band: String) -> String { band.isEmpty ? "" : band + "ghz" }
}

/// QR rendering. CoreImage's generator emits one pixel per module, so it has
/// to be scaled up with a nearest-neighbour transform -- any smoothing here
/// blurs the module edges and scanners start missing it.
enum QR {
    static func render(_ payload: String, side: CGFloat) -> NSImage? {
        guard let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // Medium correction: enough redundancy for a phone held at an angle
        // without inflating the module count on a long passphrase.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - store

@MainActor
final class WifiStore: ObservableObject {
    @Published var networks: [WifiNetwork] = []
    @Published var connectedSsid = ""
    @Published var powered = true
    @Published var scanning = false
    @Published var connectedChannel = 0
    @Published var connectedRssi = 0
    @Published var info = LinkInfo()

    @Published var downloadRate: Double = 0
    @Published var uploadRate: Double = 0
    @Published var pingMs: Double = -1
    @Published var packetLoss = 0
    @Published var hasPing = false

    @Published var actionSsid = ""
    @Published var actionKind: ActionKind? = nil
    @Published var failureSsid = ""
    @Published var failureReason = ""

    /// The share sheet's contents. nil means the sheet is shut; `qrError`
    /// carries the reason when a payload could not be built.
    @Published var qrPayload: String? = nil
    @Published var qrError = ""

    var busy: Bool { actionKind != nil }

    var connectedNetwork: WifiNetwork? { networks.first { $0.ssid == connectedSsid } }

    /// Sharing belongs to the connected network, and an enterprise login has no
    /// passphrase to put in a QR in the first place.
    var canShare: Bool {
        guard let net = connectedNetwork else { return false }
        return net.security != .enterprise
    }

    /// The speed test needs an interface to test, so its action only appears
    /// once there is one.
    var canSpeedTest: Bool { !info.iface.isEmpty }

    private let opts: Options

    private var prevRx: Double = 0
    private var prevTx: Double = 0
    private var prevSample: Date? = nil
    private var prevIface = ""
    private var pingSamples: [Double] = []

    private let work = DispatchQueue(label: "wifi_panel.scan", qos: .userInitiated)

    init(opts: Options) { self.opts = opts }

    private func helper(_ name: String) -> String {
        (opts.helpers as NSString).appendingPathComponent(name)
    }

    private var scriptEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["MACWIFI_BIN"] = opts.macwifi
        return env
    }

    // ---------------------------------------------------------------- reads

    /// Radio state and the current association. Cheap -- `macwifi status` is a
    /// couple of milliseconds -- so this runs on every tick, unlike the scan.
    func loadStatus() {
        let script = helper("wifi_status.sh")
        let env = scriptEnv
        work.async { [weak self] in
            let out = Self.shell(script, [], env: env) ?? ""
            let kv = Self.keyValues(out)
            Task { @MainActor in
                guard let self, kv["ok"] == "1" else { return }
                self.powered = kv["powered"] == "1"
                let ssid = kv["ssid"] ?? ""
                self.connectedSsid = (ssid == "-" ) ? "" : ssid
                self.connectedChannel = Int(kv["channel"] ?? "") ?? 0
                // The connected row's own signal comes from here rather than
                // from the scan: it is current, where a scan row can be a
                // minute old, and it is the number the hero glyph reads.
                self.connectedRssi = Int(kv["rssi"] ?? "") ?? 0
                self.retagConnected()
            }
        }
    }

    /// The slow one. `macwifi scan` is a full sweep and takes seconds, so it
    /// runs off the main queue and the list it replaces stays on screen until
    /// it lands -- nothing here is ever blocked on it.
    func rescan() {
        guard !scanning else { return }
        scanning = true
        let script = helper("wifi_scan.sh")
        let env = scriptEnv
        work.async { [weak self] in
            let out = Self.shell(script, [], env: env) ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.scanning = false
                self.applyScan(out)
            }
        }
    }

    /// Rows are `ssid\trssi\tchannel\tsecurity\tbssid\tknown`, one per line,
    /// after an `ok=1` header. macwifi scans per BSSID, so a mesh or dual-band
    /// AP arrives once per radio and every AP withholding its name arrives
    /// nameless -- duplicates collapse to the strongest sighting, and the
    /// nameless ones are dropped since they cannot be joined by name anyway.
    private func applyScan(_ raw: String) {
        var best: [String: WifiNetwork] = [:]
        for line in raw.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 6 else { continue }
            let ssid = f[0]
            guard !ssid.isEmpty, let rssi = Int(f[1]) else { continue }
            let net = WifiNetwork(
                ssid: ssid,
                rssi: rssi,
                band: Self.band(forChannel: Int(f[2]) ?? 0),
                security: Security.parse(f[3]),
                known: f[5] == "1",
                connected: ssid == connectedSsid)
            if let existing = best[ssid], existing.rssi >= rssi { continue }
            best[ssid] = net
        }
        networks = sorted(Array(best.values))
    }

    /// A scan can land while the association is changing under it, so the
    /// connected flag is re-applied from status rather than trusted from the
    /// scan row that produced it.
    private func retagConnected() {
        guard !networks.isEmpty else { return }
        var updated = networks
        for i in updated.indices {
            updated[i].connected = updated[i].ssid == connectedSsid
            if updated[i].connected, connectedRssi != 0 { updated[i].rssi = connectedRssi }
        }
        networks = sorted(updated)
    }

    /// Connected first, then saved, then by signal. Signal is bucketed in 5%
    /// steps and ties break on SSID: raw RSSI wanders a few dB between scans,
    /// and sorting on it directly had rows swapping places under the pointer.
    private func sorted(_ nets: [WifiNetwork]) -> [WifiNetwork] {
        nets.sorted { a, b in
            if a.connected != b.connected { return a.connected }
            if a.known != b.known { return a.known }
            let qa = a.quality / 5, qb = b.quality / 5
            if qa != qb { return qa > qb }
            return a.ssid < b.ssid
        }
    }

    /// Channel numbering, matching the popup's own fmt_band so both agree.
    nonisolated private static func band(forChannel ch: Int) -> String {
        if ch <= 0 { return "" }
        if ch <= 14 { return "2.4" }
        if ch <= 165 { return "5" }
        return "6"
    }

    nonisolated private static func keyValues(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    /// Section label for the row at `index`, matching Model.wifiSectionTitle:
    /// a header only where the known/other boundary actually falls.
    func sectionTitle(at index: Int) -> String? {
        guard networks.indices.contains(index) else { return nil }
        let net = networks[index]
        if net.known && index == 0 { return "KNOWN NETWORKS" }
        if !net.known && (index == 0 || networks[index - 1].known) { return "OTHER NETWORKS" }
        return nil
    }

    func canForget(_ net: WifiNetwork) -> Bool { net.known && !net.connected }

    // --------------------------------------------------------------- writes

    /// Joins through helpers/wifi_join.command, which is macwifi's own path in
    /// and out. The passphrase is handed over on the child's environment, never
    /// in argv -- macwifi puts it in its own argv at the last step, which is as
    /// far as this side can control.
    ///
    /// `needsPassword` fires when the helper reports NEEDPASS: macwifi tried a
    /// cached credential and it no longer associates, which is the one case
    /// where a known network still has to ask.
    func connect(_ net: WifiNetwork, password: String? = nil,
                 needsPassword: (() -> Void)? = nil) {
        guard !busy else { return }
        begin(.connect, net.ssid)
        let ssid = net.ssid
        let join = (opts.helpers as NSString).appendingPathComponent("wifi_join.command")
        var env = ProcessInfo.processInfo.environment
        if let password { env["PASS"] = password }
        env["MACWIFI_BIN"] = opts.macwifi
        run(join, [ssid], env: env) { [weak self] out in
            let result = out.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case "NEEDPASS":
                    self.actionKind = nil
                    self.actionSsid = ""
                    needsPassword?()
                case "BUSY":
                    self.fail(ssid, "Radio busy")
                case "FAILED":
                    self.fail(ssid, password == nil ? "Failed" : "Wrong password")
                default:
                    self.finish(ssid)
                }
            }
        }
    }

    func disconnect() {
        guard !busy else { return }
        begin(.disconnect, connectedSsid)
        let ssid = connectedSsid
        run(opts.macwifi, ["disconnect"]) { [weak self] _ in
            Task { @MainActor in self?.finish(ssid) }
        }
    }

    func forget(_ net: WifiNetwork) {
        guard !busy else { return }
        begin(.forget, net.ssid)
        let ssid = net.ssid
        run(opts.macwifi, ["forget", ssid]) { [weak self] _ in
            Task { @MainActor in self?.finish(ssid) }
        }
    }

    func togglePower() {
        let target = !powered
        powered = target                       // answer the click now, not after the radio settles
        run(opts.macwifi, ["power", target ? "on" : "off"]) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // ------------------------------------------------------ speed test / share

    /// Hands the run to the same backend the sketchybar popup uses and raises
    /// speedtest_overlay over it. Neither owns the other: the script detaches
    /// `macwifi speedtest` and the overlay tails the JSONL it writes.
    ///
    /// This runs *synchronously* and detaches through a shell, because the
    /// caller terminates the panel the moment it returns -- the overlay is
    /// full-screen, so the panel gets out of its way. An earlier version
    /// dispatched onto the work queue and the process died before the queue
    /// ever ran, which is why nothing happened when the button was clicked.
    func runSpeedTest() {
        let script = helper("wifi_speedtest.sh")
        let overlay = (opts.helpers as NSString)
            .appendingPathComponent("speedtest_overlay/bin/speedtest_overlay")
        func q(_ v: String) -> String { "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'" }

        var command = "\(q(script)) start >/dev/null 2>&1 & "
        command += "pkill -x speedtest_overlay >/dev/null 2>&1; "
        command += ([q(overlay)] + opts.palette.overlayFlags.map(q)
                    + (connectedSsid.isEmpty ? [] : ["--title", q(connectedSsid)])).joined(separator: " ")
        command += " >/dev/null 2>&1 &"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.environment = scriptEnv
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        // Everything in the command backgrounds itself, so this returns at once
        // and the children outlive us.
        p.waitUntilExit()
    }

    /// `macwifi share <ssid>` hands back the whole WIFI: URI, passphrase and
    /// all, so there is nothing to assemble or escape here -- and no reason for
    /// this process to go near the keychain itself.
    func share() {
        guard let net = connectedNetwork else { return }
        let ssid = net.ssid
        let security: String
        switch net.security {
        case .open, .owe: security = "open"
        case .wep: security = "wep"
        default: security = "wpa"
        }
        let bin = opts.macwifi
        work.async { [weak self] in
            let out = Self.shell(bin, ["share", ssid, "--security", security]) ?? ""
            let uri = out.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                if uri.hasPrefix("WIFI:") {
                    self?.qrError = ""
                    self?.qrPayload = uri
                } else {
                    self?.qrPayload = nil
                    self?.qrError = uri.isEmpty ? "macwifi share returned nothing." : uri
                }
            }
        }
    }

    func dismissShare() {
        qrPayload = nil
        qrError = ""
    }

    private func begin(_ kind: ActionKind, _ ssid: String) {
        actionKind = kind
        actionSsid = ssid
        failureSsid = ""
        failureReason = ""
    }

    private func finish(_ ssid: String) {
        actionKind = nil
        actionSsid = ""
        refresh()
    }

    private func fail(_ ssid: String, _ reason: String) {
        actionKind = nil
        actionSsid = ""
        failureSsid = ssid
        failureReason = reason
        refresh()
    }

    private func run(_ path: String, _ args: [String],
                     env: [String: String]? = nil,
                     _ done: @escaping (String) -> Void) {
        work.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if let env { p.environment = env }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { done(""); return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            done(String(data: data, encoding: .utf8) ?? "")
        }
    }

    // ---------------------------------------------------------------- stats

    func refresh() {
        loadStatus()
        refreshLink()
    }

    /// IP comes from getifaddrs in-process; the gateway and byte counters come
    /// from two short-lived tools that answer in single-digit milliseconds, so
    /// none of this is worth a daemon.
    func refreshLink() {
        let name = info.iface.isEmpty ? "en0" : info.iface
        work.async { [weak self] in
            var next = LinkInfo()
            next.iface = name
            next.ip = Self.ipv4(for: name) ?? ""
            next.gateway = Self.defaultGateway() ?? ""
            if let (rx, tx) = Self.counters(for: name) {
                next.rxBytes = rx
                next.txBytes = tx
                next.hasCounters = true
            }
            Task { @MainActor in self?.applyLink(next) }
        }
    }

    /// Rates are deltas between successive samples. The first sample after
    /// open, or after the interface changes under us, seeds the baseline
    /// instead of manufacturing a spike out of a lifetime byte count.
    private func applyLink(_ next: LinkInfo) {
        info = next
        let now = Date()
        defer {
            prevRx = next.rxBytes
            prevTx = next.txBytes
            prevSample = now
            prevIface = next.iface
        }
        guard next.hasCounters, next.iface == prevIface, let last = prevSample else {
            downloadRate = 0
            uploadRate = 0
            return
        }
        let dt = now.timeIntervalSince(last)
        guard dt > 0 else { return }
        downloadRate = max(0, (next.rxBytes - prevRx) / dt)
        uploadRate = max(0, (next.txBytes - prevTx) / dt)
    }

    func ping() {
        work.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/ping")
            p.arguments = ["-c", "1", "-t", "2", "-n", "1.1.1.1"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            var ms = -1.0
            if let r = out.range(of: "time="), let end = out[r.upperBound...].firstIndex(of: " ") {
                ms = Double(out[r.upperBound..<end]) ?? -1
            }
            Task { @MainActor in self?.applyPing(ms) }
        }
    }

    /// A rolling window, so one slow reply does not make the readout jump. The
    /// loss figure is just how much of that window timed out.
    private func applyPing(_ ms: Double) {
        pingSamples.append(ms)
        if pingSamples.count > 5 { pingSamples.removeFirst() }
        hasPing = true
        let good = pingSamples.filter { $0 >= 0 }
        pingMs = good.isEmpty ? -1 : good.reduce(0, +) / Double(good.count)
        packetLoss = Int((Double(pingSamples.count - good.count) / Double(pingSamples.count) * 100).rounded())
    }

    // -------------------------------------------------------- system probes

    nonisolated private static func ipv4(for name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let ptr = cursor {
            let ifa = ptr.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == name {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                               socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            cursor = ifa.ifa_next
        }
        return nil
    }

    nonisolated private static func defaultGateway() -> String? {
        guard let out = shell("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// `netstat -ibn` repeats an interface once per address family; the row
    /// with a Link-level address carries the byte counters, so take the first
    /// match with enough columns and stop.
    nonisolated private static func counters(for name: String) -> (Double, Double)? {
        guard let out = shell("/usr/sbin/netstat", ["-ibn"]) else { return nil }
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 10, f[0] == name, f[2].hasPrefix("<Link") else { continue }
            guard let rx = Double(f[6]), let tx = Double(f[9]) else { continue }
            return (rx, tx)
        }
        return nil
    }

    nonisolated private static func shell(_ path: String, _ args: [String],
                                          env: [String: String]? = nil) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - shared chrome

/// The panel's cursor model, ported from PanelKeyCatcher's contract: exactly
/// one highlight on screen, driven by keyboard and mouse alike. Rows must
/// never colour themselves from hover directly -- hover moves the cursor, and
/// the cursor draws.
enum Section: Equatable {
    case header(Int) // an index into the hero's action row
    case list(Int)   // a network row
}

/// The hero's actions, in omarchy's order. Which of them exist depends on the
/// connection, so the cursor walks the live list rather than fixed indices.
enum HeaderAction: Equatable {
    case qr, speed, power

    var glyph: String {
        switch self {
        case .qr: return "󰐲"
        case .speed: return "󰓅"
        case .power: return ""
        }
    }

    var tooltip: String {
        switch self {
        case .qr: return "Show QR code"
        case .speed: return "Run a speed test"
        case .power: return "Toggle Wi-Fi"
        }
    }
}

struct Theme {
    let palette: Palette
    let font: String
    let radius: CGFloat

    var fg: Color { Color(palette.foreground) }
    var bg: Color { Color(palette.background) }
    var accent: Color { Color(palette.accent) }
    var urgent: Color { Color(palette.urgent) }
    var border: Color { Color(palette.border) }
    var dim: Color { Color(palette.foreground.darker(1.4)) }
    var dimmer: Color { Color(palette.foreground.darker(1.5)) }

    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(font, size: size).weight(weight)
    }

    var normalFill: Color { fg.opacity(T.normalFillAlpha) }
    var hoverFill: Color { fg.opacity(T.hoverFillAlpha) }
    var selectedFill: Color { fg.opacity(T.selectedFillAlpha) }
    var normalBorder: Color { fg.opacity(T.normalBorderAlpha) }
    var hoverBorder: Color { fg.opacity(T.hoverBorderAlpha) }
}

/// PanelSectionHeader: the small-caps label that introduces a section.
struct SectionHeader: View {
    let text: String
    let theme: Theme

    var body: some View {
        Text(text)
            .font(theme.mono(T.caption, .bold))
            .kerning(1.2)
            .foregroundStyle(theme.dim)
            // Nerd Font outlines run past the ascent Text reserves; without
            // this a header at the top of a clipping list renders beheaded.
            .padding(.top, ceil(T.caption * 0.15))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// PanelSeparator: the 1px rule between sections.
struct Separator: View {
    let theme: Theme
    var body: some View {
        Rectangle()
            .fill(theme.fg.opacity(0.12))
            .frame(height: 1)
    }
}

/// ToggleSwitch: track, sliding knob, and a cursor ring drawn *outside* the
/// track. The ring is deliberate -- normal chrome carries a stronger border
/// than hover-cursor, so lighting the track itself would make a bordered
/// control go fainter under the cursor rather than brighter.
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
                    .overlay(Capsule().strokeBorder(
                        checked ? theme.fg : theme.normalBorder, lineWidth: 1))
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

/// omarchy's Button in its icon-only form: no fill at rest, hover-cursor fill
/// and border when hot. Hover moves the panel's cursor rather than colouring
/// the button directly, so only one thing is ever highlighted.
struct IconButton: View {
    let glyph: String
    let tooltip: String
    let hasCursor: Bool
    let theme: Theme
    let onHover: () -> Void
    let action: () -> Void

    @State private var hovering = false
    private var hot: Bool { hasCursor || hovering }

    var body: some View {
        Glyph(text: glyph, size: T.subtitle * 1.5, family: theme.font, color: theme.fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: theme.radius)
                    .fill(hot ? theme.hoverFill : .clear)
                    .overlay(RoundedRectangle(cornerRadius: theme.radius)
                        .strokeBorder(hot ? theme.hoverBorder : .clear, lineWidth: 1)))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { onHover() }
            }
            .onTapGesture(perform: action)
            .help(tooltip)
    }
}

/// A Nerd Font icon.
///
/// These glyphs paint wider than the cell they advance: in JetBrainsMono Nerd
/// Font at 14pt the wifi marks lay down 13.58pt of ink into an 8.40pt advance.
/// SwiftUI sizes a Text from the advance, so the surrounding layout sheared a
/// third off the right of every icon -- and .fixedSize() does not help, because
/// the "ideal" size it asks for is that same advance. Measuring the real ink box
/// and reserving that is the only fix that holds for an arbitrary --font.
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

// MARK: - hero

struct HeroView: View {
    @ObservedObject var store: WifiStore
    let theme: Theme
    let phrase: String
    let actions: [HeaderAction]
    let cursorIndex: Int?
    let onHover: (Int) -> Void
    let onActivate: (HeaderAction) -> Void

    private var title: String {
        if !store.connectedSsid.isEmpty { return store.connectedSsid }
        return store.powered ? "Wi-Fi" : "Wi-Fi off"
    }

    /// Band rides inline after the name -- "Home (5ghz)" -- rather than in a
    /// pill, which crowded the actions. This is read-only where omarchy has a
    /// selector: macOS exposes no band-pinning API, and macwifi has no
    /// subcommand for it either, so there is nothing honest to click.
    private var detail: String {
        guard let net = store.networks.first(where: { $0.ssid == store.connectedSsid })
        else { return "" }
        return Fmt.bandLabel(net.band)
    }

    private var meta: String {
        if !store.connectedSsid.isEmpty { return phrase.uppercased() }
        return store.powered ? "NOT CONNECTED" : "RADIO OFF"
    }

    private var glyph: String {
        guard store.powered else { return "󰤮" }
        guard let net = store.networks.first(where: { $0.ssid == store.connectedSsid })
        else { return "󰤯" }
        return Fmt.wifiGlyph(net.quality)
    }

    var body: some View {
        HStack(alignment: .center, spacing: T.xxxl) {
            Glyph(text: glyph, size: T.display, family: theme.font, color: theme.fg)
                .opacity(store.powered ? 1 : 0.5)

            VStack(alignment: .leading, spacing: T.xxs) {
                Text(detail.isEmpty ? title : "\(title) (\(detail))")
                    .font(theme.mono(T.title, .bold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(meta)
                    .font(theme.mono(T.caption, .bold))
                    .kerning(1.2)
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Sharing and the speed test belong to the connected network, so
            // they ride the hero beside the radio switch rather than sitting on
            // a scan-result row.
            HStack(spacing: T.lg) {
                ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
                    switch action {
                    case .power:
                        ToggleSwitchView(checked: store.powered,
                                         hasCursor: cursorIndex == i,
                                         theme: theme) { onActivate(.power) }
                            .onHover { if $0 { onHover(i) } }
                    default:
                        IconButton(glyph: action.glyph, tooltip: action.tooltip,
                                   hasCursor: cursorIndex == i, theme: theme,
                                   onHover: { onHover(i) }) { onActivate(action) }
                    }
                }
            }
        }
    }
}

// MARK: - stats

struct StatsGrid: View {
    @ObservedObject var store: WifiStore
    let theme: Theme

    private var lossColor: Color { store.packetLoss > 0 ? theme.urgent : theme.fg }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: T.labelGap) {
            GridRow {
                label("Ping")
                value(Fmt.ping(store.pingMs, hasSamples: store.hasPing), lossColor)
                label("Packet Loss")
                value(Fmt.packetLoss(store.packetLoss, hasSamples: store.hasPing), lossColor)
            }
            GridRow {
                label("Receiving")
                value(store.info.hasCounters ? Fmt.rate(store.downloadRate) : "--")
                label("Sending")
                value(store.info.hasCounters ? Fmt.rate(store.uploadRate) : "--")
            }
            GridRow {
                label("Downloaded")
                value(store.info.hasCounters ? Fmt.bytes(store.info.rxBytes) : "--")
                label("Uploaded")
                value(store.info.hasCounters ? Fmt.bytes(store.info.txBytes) : "--")
            }
            GridRow {
                label("IP Address")
                copyable(store.info.ip)
                label("Gateway")
                copyable(store.info.gateway)
            }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t)
            .font(theme.mono(T.bodySmall))
            .foregroundStyle(theme.fg.opacity(0.6))
    }

    private func value(_ t: String, _ color: Color? = nil) -> some View {
        Text(t)
            .font(theme.mono(T.bodySmall))
            .foregroundStyle(color ?? theme.fg)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .lineLimit(1)
    }

    /// IP and gateway are the two values people actually want out of a panel
    /// like this, so clicking copies rather than making them retype it.
    private func copyable(_ t: String) -> some View {
        value(t.isEmpty ? "--" : t)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !t.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
            .help(t.isEmpty ? "" : "Copy")
    }
}

// MARK: - network row

struct NetworkRowView: View {
    let net: WifiNetwork
    let index: Int
    @ObservedObject var store: WifiStore
    let theme: Theme
    let hasCursor: Bool
    let passwordOpen: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onForget: () -> Void

    @Binding var password: String
    @FocusState private var pwFocused: Bool
    @State private var hoveringForget = false

    private var isBusy: Bool { store.actionKind != nil && store.actionSsid == net.ssid }
    private var isFailed: Bool { !store.failureReason.isEmpty && store.failureSsid == net.ssid }
    private var canForget: Bool { store.canForget(net) }

    private var statusText: String {
        if passwordOpen { return "" }
        if isBusy, let k = store.actionKind { return k.progressText }
        if isFailed { return store.failureReason }
        if net.connected { return "Connected" }
        return ""
    }

    private var statusColor: Color {
        if isFailed { return theme.urgent }
        if isBusy || net.connected { return theme.fg }
        return theme.dimmer
    }

    /// The lock is a credentials-required affordance; Forget replaces it on
    /// hover for saved networks, rather than reserving a second invisible
    /// target on every row.
    private var showForget: Bool { canForget && (!net.security.requiresCredentials || hoveringForget) }

    var body: some View {
        VStack(alignment: .leading, spacing: T.sm) {
            HStack(spacing: T.xl) {
                Glyph(text: Fmt.wifiGlyph(net.quality), size: T.title,
                      family: theme.font, color: statusColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text(net.ssid)
                        .font(theme.mono(T.body))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(theme.mono(T.caption))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if net.security.requiresCredentials || canForget {
                    Glyph(text: showForget ? "󰅙" : "󰌾", size: T.subtitle,
                          family: theme.font,
                          color: showForget ? theme.urgent : theme.dim)
                        .contentShape(Rectangle())
                        .onHover { hoveringForget = $0 && canForget }
                        .onTapGesture { if canForget { onForget() } }
                        .help(showForget ? "Forget network" : "")
                }
            }
            .padding(.horizontal, T.xl)
            .padding(.vertical, T.md)
            .contentShape(Rectangle())
            .onHover { if $0 { onSelect() } }
            .onTapGesture(perform: onActivate)

            if passwordOpen {
                passwordPrompt
            }
        }
        .background(
            RoundedRectangle(cornerRadius: theme.radius)
                .fill(hasCursor ? theme.hoverFill : (net.connected ? theme.selectedFill : .clear))
                .overlay(RoundedRectangle(cornerRadius: theme.radius)
                    .strokeBorder(hasCursor ? theme.hoverBorder : .clear, lineWidth: 1))
        )
        .animation(.easeOut(duration: 0.06), value: hasCursor)
    }

    /// Inline passphrase entry, expanding under the row it belongs to rather
    /// than in a separate dialog. This is the piece the sketchybar popup could
    /// not do at all -- it shelled out to `osascript display dialog`.
    private var passwordPrompt: some View {
        HStack(spacing: T.md) {
            if isBusy || isFailed {
                Text(isFailed ? store.failureReason : "Connecting…")
                    .font(theme.mono(T.bodySmall))
                    .foregroundStyle(isFailed ? theme.urgent : theme.fg)
                    .frame(maxWidth: .infinity, minHeight: T.controlHeight)
                    .background(RoundedRectangle(cornerRadius: theme.radius).fill(theme.normalFill))
            } else {
                SecureField("Passphrase", text: $password)
                    .textFieldStyle(.plain)
                    .font(theme.mono(T.body))
                    .foregroundStyle(theme.fg)
                    .focused($pwFocused)
                    .onSubmit(onActivate)
                    .padding(.horizontal, T.lg)
                    .frame(height: T.controlHeight)
                    .background(RoundedRectangle(cornerRadius: theme.radius)
                        .fill(theme.normalFill)
                        .overlay(RoundedRectangle(cornerRadius: theme.radius)
                            .strokeBorder(theme.normalBorder, lineWidth: 1)))

                Glyph(text: "󰄬", size: T.subtitle, family: theme.font,
                      color: password.isEmpty ? theme.dim : theme.fg)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { if !password.isEmpty { onActivate() } }
                    .help("Connect")
            }
        }
        .padding(.horizontal, T.xl)
        .padding(.bottom, T.lg)
        .onAppear { pwFocused = true }
    }
}

// MARK: - panel

struct PanelView: View {
    @ObservedObject var store: WifiStore
    let theme: Theme
    let onClose: () -> Void

    @State private var cursor: Section = .header(0)
    @State private var cursorActive = false
    @State private var passwordSsid = ""
    @State private var password = ""
    @State private var phraseIndex = 0

    /// Straight from omarchy: the hero's second line is a rotating bit of
    /// nonsense rather than a static "CONNECTED", which makes it read as a
    /// live connection rather than a stale label.
    private let phrases = ["Wiring bits", "Handling packets", "Sorting frames",
                           "Hauling bytes", "Routing crumbs", "Counting collisions",
                           "Bending light"]

    /// Availability shifts as the connection changes, so the cursor walks this
    /// list rather than fixed indices -- the same reason omarchy recomputes its
    /// header indices instead of hard-coding them.
    private var headerActions: [HeaderAction] {
        var out: [HeaderAction] = []
        if store.canShare { out.append(.qr) }
        if store.canSpeedTest { out.append(.speed) }
        out.append(.power)
        return out
    }

    private func activateHeader(_ action: HeaderAction) {
        switch action {
        case .qr: store.share()
        case .speed:
            // The overlay is full-screen and sketchybar draws above it, so the
            // panel gets out of the way rather than sitting on top of the dials.
            store.runSpeedTest()
            onClose()
        case .power: store.togglePower()
        }
    }

    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private let slowTick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: T.xxl) {
            HeroView(store: store, theme: theme,
                     phrase: phrases[phraseIndex % phrases.count],
                     actions: headerActions,
                     cursorIndex: {
                         if case .header(let i) = cursor, cursorActive { return i }
                         return nil
                     }(),
                     onHover: { i in cursorActive = true; cursor = .header(i) },
                     onActivate: activateHeader)

            if !store.info.iface.isEmpty {
                StatsGrid(store: store, theme: theme)
            }

            Separator(theme: theme)

            if store.scanning {
                SectionHeader(text: "SCANNING WI-FI…", theme: theme)
            }
            networkList
        }
        .padding(T.popupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg)
        .overlay { if store.qrPayload != nil || !store.qrError.isEmpty { shareSheet } }
        .onReceive(tick) { _ in
            store.refreshLink()
            if !store.connectedSsid.isEmpty { phraseIndex += 1 }
        }
        .onReceive(slowTick) { _ in
            store.ping()
            store.rescan()
        }
        .onAppear {
            store.refresh()
            store.rescan()
            store.ping()
        }
        .background(KeyCatcher(
            onMove: move, onActivate: activate,
            onClose: {
                // Esc backs out of the share sheet first; it is a layer over
                // the panel, not a separate window.
                if store.qrPayload != nil || !store.qrError.isEmpty {
                    store.dismissShare()
                } else {
                    onClose()
                }
            },
            onText: { key in
                if key == "r" { store.rescan() }
                if key == "w" { store.togglePower() }
            },
            blocked: !passwordSsid.isEmpty))
    }

    /// The share card, drawn over the panel rather than as a second window --
    /// omarchy summons a separate centred card, but that only makes sense when
    /// something else can summon it too. Here it is only ever this panel.
    private var shareSheet: some View {
        ZStack {
            theme.bg.opacity(0.97)
            VStack(spacing: T.xxl) {
                Text(store.connectedSsid)
                    .font(theme.mono(T.title, .bold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let payload = store.qrPayload, let image = QR.render(payload, side: 190) {
                    Image(nsImage: image)
                        .interpolation(.none)          // keep the modules crisp
                        .resizable()
                        .frame(width: 190, height: 190)
                        .padding(T.xl)
                        .background(RoundedRectangle(cornerRadius: theme.radius).fill(.white))
                    Text("Scan to join this network")
                        .font(theme.mono(T.caption))
                        .foregroundStyle(theme.dim)
                } else {
                    Text(store.qrError.isEmpty ? "Could not build a share code." : store.qrError)
                        .font(theme.mono(T.bodySmall))
                        .foregroundStyle(theme.dim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, T.xl)
                }

                Text("Close")
                    .font(theme.mono(T.bodySmall))
                    .foregroundStyle(theme.fg)
                    .padding(.horizontal, T.xl)
                    .padding(.vertical, T.md)
                    .background(RoundedRectangle(cornerRadius: theme.radius)
                        .fill(theme.normalFill)
                        .overlay(RoundedRectangle(cornerRadius: theme.radius)
                            .strokeBorder(theme.normalBorder, lineWidth: 1)))
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissShare() }
            }
            .padding(T.popupPadding)
        }
    }

    private var networkList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: T.sm) {
                    ForEach(Array(store.networks.enumerated()), id: \.element.id) { index, net in
                        if let title = store.sectionTitle(at: index) {
                            SectionHeader(text: title, theme: theme)
                                .padding(.top, index == 0 ? 0 : T.md)
                        }
                        NetworkRowView(
                            net: net, index: index, store: store, theme: theme,
                            hasCursor: cursorActive && cursor == .list(index),
                            passwordOpen: passwordSsid == net.ssid,
                            onSelect: { cursorActive = true; cursor = .list(index) },
                            onActivate: { activateRow(net) },
                            onForget: { store.forget(net) },
                            password: $password)
                        .id(net.id)
                    }
                }
            }
            .frame(maxHeight: T.listMaxHeight)
            .onChange(of: cursor) { _, new in
                if case .list(let i) = new, store.networks.indices.contains(i) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(store.networks[i].id, anchor: .center)
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------- keyboard

    private func move(_ dx: Int, _ dy: Int) {
        guard passwordSsid.isEmpty else { return }
        if !cursorActive {
            cursorActive = true
            if dy >= 0 { return }
        }
        // h/l walk the hero's actions; j/k cross between the hero and the list.
        if dx != 0, case .header(let i) = cursor {
            cursor = .header(min(max(i + dx, 0), headerActions.count - 1))
            return
        }
        guard dy != 0 else { return }
        switch cursor {
        case .header:
            if dy > 0, !store.networks.isEmpty { cursor = .list(0) }
        case .list(let i):
            let next = i + dy
            // Escaping upward off the top row goes back to the switch rather
            // than wrapping to the bottom of a long list.
            if next < 0 { cursor = .header(headerActions.count - 1) }
            else if next < store.networks.count { cursor = .list(next) }
        }
    }

    private func activate() {
        guard cursorActive else { return }
        switch cursor {
        case .header(let i):
            guard headerActions.indices.contains(i) else { return }
            activateHeader(headerActions[i])
        case .list(let i):
            guard store.networks.indices.contains(i) else { return }
            activateRow(store.networks[i])
        }
    }

    private func activateRow(_ net: WifiNetwork) {
        if passwordSsid == net.ssid {
            guard !password.isEmpty else { return }
            store.connect(net, password: password)
            passwordSsid = ""
            password = ""
            return
        }
        if net.connected { store.disconnect(); return }
        if net.security.requiresCredentials && !net.known {
            passwordSsid = net.ssid
            password = ""
            return
        }
        store.connect(net)
    }
}

// MARK: - key catcher
//
// PanelKeyCatcher's job: swallow every key the focused subtree ignored and
// turn it into cursor movement. `blocked` hands input back to the passphrase
// field, which owns the keyboard until Esc or Enter.

struct KeyCatcher: NSViewRepresentable {
    let onMove: (Int, Int) -> Void
    let onActivate: () -> Void
    let onClose: () -> Void
    let onText: (String) -> Void
    let blocked: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.install(self)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.owner = self
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var owner: KeyCatcher?
        private var monitor: Any?

        func install(_ owner: KeyCatcher) {
            self.owner = owner
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let o = self?.owner else { return e }
                // Esc always closes, even mid-passphrase; that is the one key
                // the prompt is not allowed to swallow.
                if e.keyCode == 53 { o.onClose(); return nil }
                if o.blocked { return e }
                switch e.keyCode {
                case 126: o.onMove(0, -1); return nil   // up
                case 125: o.onMove(0, 1); return nil    // down
                case 123: o.onMove(-1, 0); return nil   // left
                case 124: o.onMove(1, 0); return nil    // right
                case 36, 76: o.onActivate(); return nil // return / keypad enter
                default: break
                }
                if let c = e.charactersIgnoringModifiers?.lowercased() {
                    switch c {
                    case "k": o.onMove(0, -1); return nil
                    case "j": o.onMove(0, 1); return nil
                    case "h": o.onMove(-1, 0); return nil
                    case "l": o.onMove(1, 0); return nil
                    case "r", "w": o.onText(c); return nil
                    default: break
                    }
                }
                return e
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - window

/// Borderless panels are not key-eligible by default, and this one has a
/// passphrase field in it -- so, unlike popup_keys' invisible grabber, it must
/// genuinely take focus.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let opts: Options
    private let store: WifiStore
    private var window: PanelWindow?
    private let previous = NSWorkspace.shared.frontmostApplication

    @MainActor init(opts: Options) {
        self.opts = opts
        self.store = WifiStore(opts: opts)
    }

    @MainActor func applicationDidFinishLaunching(_ n: Notification) {
        let theme = Theme(palette: opts.palette, font: opts.font, radius: opts.radius)
        let root = PanelView(store: store, theme: theme) { NSApp.terminate(nil) }
            .frame(width: opts.width)

        // A hosting *controller* with .preferredContentSize, rather than a bare
        // hosting view: the panel is empty on the first frame and only gets its
        // real height once the cached scan lands a few milliseconds later, so
        // the window has to keep following SwiftUI's ideal size instead of
        // measuring once at launch and freezing at 122pt.
        let hc = NSHostingController(rootView: AnyView(root))
        hc.sizingOptions = [.preferredContentSize]

        let w = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: opts.width, height: 480),
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

        // Round the card and paint its edge on the window's own content view so
        // the shadow follows the same silhouette as the corners.
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

    /// The window grows as the list fills in, and it is anchored by its top
    /// edge -- so every resize has to re-place it or the panel would appear to
    /// crawl down the screen as content arrives.
    func windowDidResize(_ n: Notification) {
        guard let w = window else { return }
        position(w, size: w.frame.size)
    }

    /// Hang from the anchor's top-right, flipping to stay on screen. y arrives
    /// measured from the top the way sketchybar reports it; AppKit wants it
    /// from the bottom.
    private func position(_ w: NSWindow, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let margin: CGFloat = 6
        let x = min(max(f.minX + margin, (opts.anchorX ?? f.maxX - margin) - size.width),
                    f.maxX - size.width - margin)
        let topY = opts.anchorY ?? 32
        let y = max(f.minY + margin, f.maxY - topY - size.height)
        w.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // Clicking away is the popup's own dismissal, same as HyprlandFocusGrab.
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
