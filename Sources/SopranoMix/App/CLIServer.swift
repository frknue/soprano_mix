import AppKit
import OSLog
import SopranoMixCore

private let cliLog = Logger(subsystem: "com.soprano.mix", category: "cli")

/// Answers `SopranoMix <command>` from the running app (Soprano Tab's transport): a local
/// `CFMessagePort` named `<bundle id>.cli` on the main run loop, JSON `CLIRequest` in,
/// JSON `CLIResponse` out. The mixer controller answers every request.
@MainActor
final class CLIServer {
    /// The port the app and `CLIClient` use.
    nonisolated static var defaultPortName: String {
        "\(Bundle.main.bundleIdentifier ?? "com.soprano.mix").cli"
    }

    let portName: String
    private let handler: @MainActor (CLIRequest) -> CLIResponse
    private var port: CFMessagePort?
    private var runLoopSource: CFRunLoopSource?

    /// Tests pass their own port name and handler.
    init(portName: String = CLIServer.defaultPortName, handler: @escaping @MainActor (CLIRequest) -> CLIResponse) {
        self.portName = portName
        self.handler = handler
    }

    convenience init(controller: MixerController) {
        self.init { request in controller.handle(request) }
    }

    /// Opens the port; false (logged) when the name is taken, e.g. by another instance.
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        var shouldFreeInfo: DarwinBoolean = false
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info else { return nil }
            let request = data.map { $0 as Data }
            // Safe: the port's run loop source is on the main run loop, so assumeIsolated
            // holds and the pointer never crosses an isolation boundary.
            nonisolated(unsafe) let serverPointer = info
            let reply = MainActor.assumeIsolated {
                Unmanaged<CLIServer>.fromOpaque(serverPointer).takeUnretainedValue().reply(to: request)
            }
            return Unmanaged.passRetained(reply as CFData)
        }
        guard let port = CFMessagePortCreateLocal(nil, portName as CFString, callback, &context, &shouldFreeInfo) else {
            cliLog.error("Could not open the CLI port \(self.portName, privacy: .public)")
            return false
        }
        let runLoopSource = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        self.port = port
        self.runLoopSource = runLoopSource
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let port {
            CFMessagePortInvalidate(port)
        }
        runLoopSource = nil
        port = nil
    }

    /// The encoded response to one encoded request; undecodable input is "Bad request.".
    func reply(to data: Data?) -> Data {
        let response: CLIResponse
        if let data, let request = try? JSONDecoder().decode(CLIRequest.self, from: data) {
            response = handler(request)
        } else {
            response = .failure("Bad request.")
        }
        return (try? Self.encoder.encode(response)) ?? Data()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
