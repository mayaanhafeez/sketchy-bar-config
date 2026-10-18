import Foundation
import CoreFoundation

enum PanelCommand: Int32 {
    case toggle = 1, hide, prepare
}

/// A tiny client forwards to the already-built window without initializing
/// NSApplication/SwiftUI. The per-user Mach port also prevents duplicate hosts.
final class PanelIPC {
    private static var name: CFString { "dev.sketchybar.volume-panel.\(getuid())" as CFString }
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private let receive: (PanelCommand, [String]) -> Void

    static func send(_ command: PanelCommand, arguments: [String]) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, name),
              let data = try? JSONSerialization.data(withJSONObject: arguments) else { return false }
        return CFMessagePortSendRequest(remote, command.rawValue, data as CFData,
                                        0.2, 0, nil, nil) == kCFMessagePortSuccess
    }

    init?(receive: @escaping (PanelCommand, [String]) -> Void) {
        self.receive = receive
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        var shouldFree: DarwinBoolean = false
        port = CFMessagePortCreateLocal(nil, Self.name, { _, raw, data, info in
            guard let info, let command = PanelCommand(rawValue: raw) else { return nil }
            let server = Unmanaged<PanelIPC>.fromOpaque(info).takeUnretainedValue()
            let arguments = data.flatMap { try? JSONSerialization.jsonObject(with: $0 as Data) as? [String] } ?? []
            server.receive(command, arguments)
            return nil
        }, &context, &shouldFree)
        guard let port, !shouldFree.boolValue,
              let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else { return nil }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
    }
}
