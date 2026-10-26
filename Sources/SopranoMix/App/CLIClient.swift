import Foundation
import SopranoMixCore

/// `SopranoMix <command>`: sends one `CLIRequest` to the running app over its
/// `CFMessagePort` and prints the `CLIResponse`.
enum CLIClient {
    /// First arguments that select the CLI instead of the GUI.
    static let commands: Set<String> = [
        "list", "devices", "set", "mute", "unmute", "output", "show", "hide", "help", "--help",
    ]

    static let usage = """
    Usage: SopranoMix <command>

      list                              List the apps in the mixer: volume, mute, output, playing
      devices                           List the audio devices
      set <app> <0-400>                 Set an app's volume in percent (100 = unchanged)
      mute <app>                        Mute an app
      unmute <app>                      Unmute an app
      output <app> <device|default>     Play an app on an output (UID or name), or on the system output
      show                              Open the panel
      hide                              Close the panel
      scan [--all]                      Print every audio process and how it is grouped (no app needed)
      selftest [--gain <x>] [--seconds <n>] [--silent]
                                        Route a test tone through the live pipeline and report JSON
      snapshot --out <png> [options]    Render the panel offscreen on fixtures (development)
      help                              Show this help

    <app> is a name (case-insensitive; a unique prefix is enough) or a settings key such as
    com.spotify.client or "wine:TEKKEN 8". Names with spaces work quoted or unquoted
    (set TEKKEN 8 35). Quote device names with spaces: output Discord "AirPods Pro".

    """

    /// The request for command-line arguments (without the executable); nil for `help`
    /// and anything malformed. An app name may span several arguments: everything between
    /// the command and the last argument (`set`, `output`) or the end (`mute`, `unmute`).
    static func request(from arguments: [String]) -> CLIRequest? {
        guard let command = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "list" where rest.isEmpty:
            return .list
        case "devices" where rest.isEmpty:
            return .devices
        case "show" where rest.isEmpty:
            return .show
        case "hide" where rest.isEmpty:
            return .hide
        case "set":
            guard let last = rest.last, let app = appName(rest.dropLast()), let percent = percent(last) else { return nil }
            return .setVolume(app: app, percent: percent)
        case "mute", "unmute":
            guard let app = appName(rest[...]) else { return nil }
            return .setMuted(app: app, muted: command == "mute")
        case "output":
            guard let last = rest.last, let app = appName(rest.dropLast()) else { return nil }
            let device = last.trimmingCharacters(in: .whitespaces)
            guard !device.isEmpty else { return nil }
            return .setOutput(app: app, device: device.caseInsensitiveCompare("default") == .orderedSame ? nil : device)
        default:
            return nil
        }
    }

    /// Runs the command: 0 with the response JSON on stdout (or the usage for `help`); 1
    /// with the error on stderr; 2 with the usage on stderr for malformed arguments.
    static func run(arguments: [String]) -> Int32 {
        if let command = arguments.first, command == "help" || command == "--help" {
            print(usage, terminator: "")
            return 0
        }
        guard let request = request(from: arguments) else {
            writeError(usage)
            return 2
        }
        let response: CLIResponse
        do {
            response = try send(request)
        } catch {
            writeError("\(error.message)\n")
            return 1
        }
        guard response.ok else {
            writeError("\(response.error ?? "The request failed.")\n")
            return 1
        }
        guard let text = output(for: response) else {
            writeError("Could not encode the response.\n")
            return 1
        }
        print(text)
        return 0
    }

    /// The response as printed: pretty JSON with sorted keys.
    static func output(for response: CLIResponse) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(response) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    /// Sends one request to the app listening on `portName` and waits up to `timeout`
    /// seconds for its answer.
    static func send(
        _ request: CLIRequest,
        portName: String = CLIServer.defaultPortName,
        timeout: CFTimeInterval = 2
    ) throws(Failure) -> CLIResponse {
        guard let port = CFMessagePortCreateRemote(nil, portName as CFString) else {
            throw Failure(message: "Soprano Mix is not running.")
        }
        defer { CFMessagePortInvalidate(port) }
        guard let body = try? JSONEncoder().encode(request) else {
            throw Failure(message: "Could not encode the request.")
        }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            port,
            0,
            body as CFData,
            timeout,
            timeout,
            CFRunLoopMode.defaultMode.rawValue,
            &reply
        )
        let replyData = reply?.takeRetainedValue()
        guard status == kCFMessagePortSuccess, let replyData else {
            throw Failure(message: status == kCFMessagePortReceiveTimeout || status == kCFMessagePortSendTimeout
                ? "Soprano Mix did not answer."
                : "Soprano Mix is not running.")
        }
        guard let response = try? JSONDecoder().decode(CLIResponse.self, from: replyData as Data) else {
            throw Failure(message: "Soprano Mix sent an unreadable response.")
        }
        return response
    }

    /// The words joined with single spaces; nil when nothing but whitespace is left.
    private static func appName(_ words: ArraySlice<String>) -> String? {
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// "35" or "35%", within `VolumeLaw.appRange`.
    private static func percent(_ text: String) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("%") {
            text.removeLast()
        }
        guard let value = Double(text), value.isFinite, VolumeLaw.appRange.contains(value) else { return nil }
        return value
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
