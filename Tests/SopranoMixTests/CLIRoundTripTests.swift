import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct CLIRoundTripTests {
    /// The requests a stub server received.
    @MainActor
    private final class RequestLog {
        var requests: [CLIRequest] = []
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    /// A port name no running app uses.
    private func uniquePortName() -> String {
        "com.soprano.mix.tests.\(UUID().uuidString).cli"
    }

    private let tekken = CLIApp(
        key: "wine:TEKKEN 8", name: "TEKKEN 8", kind: "wine", volume: 35, muted: false, output: nil,
        outputName: "Odyssey G91F", playing: true, routed: true, pids: [4242]
    )

    @Test("every request survives encoding and decoding")
    func requestsRoundTrip() throws {
        let requests: [CLIRequest] = [
            .list,
            .devices,
            .setVolume(app: "TEKKEN 8", percent: 35),
            .setMuted(app: "Spotify", muted: true),
            .setMuted(app: "Spotify", muted: nil),
            .setOutput(app: "Discord", device: "AirPods Pro"),
            .setOutput(app: "Discord", device: nil),
            .show,
            .hide,
        ]
        for request in requests {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test("command-line arguments map to requests")
    func argumentsMapToRequests() {
        #expect(CLIClient.request(from: ["list"]) == .list)
        #expect(CLIClient.request(from: ["devices"]) == .devices)
        #expect(CLIClient.request(from: ["show"]) == .show)
        #expect(CLIClient.request(from: ["hide"]) == .hide)
        #expect(CLIClient.request(from: ["set", "Spotify", "60"]) == .setVolume(app: "Spotify", percent: 60))
        #expect(CLIClient.request(from: ["set", "Spotify", "250%"]) == .setVolume(app: "Spotify", percent: 250))
        #expect(CLIClient.request(from: ["set", "com.spotify.client", "0"]) == .setVolume(app: "com.spotify.client", percent: 0))
        #expect(CLIClient.request(from: ["set", "Spotify", "400"]) == .setVolume(app: "Spotify", percent: 400))
        #expect(CLIClient.request(from: ["mute", "Music"]) == .setMuted(app: "Music", muted: true))
        #expect(CLIClient.request(from: ["unmute", "Music"]) == .setMuted(app: "Music", muted: false))
        #expect(CLIClient.request(from: ["output", "Discord", "AirPods Pro"]) == .setOutput(app: "Discord", device: "AirPods Pro"))
        #expect(CLIClient.request(from: ["output", "Discord", "default"]) == .setOutput(app: "Discord", device: nil))
        #expect(CLIClient.request(from: ["output", "Discord", "Default"]) == .setOutput(app: "Discord", device: nil))
    }

    @Test("app names with spaces work quoted as one argument and unquoted as several")
    func appNamesWithSpaces() {
        let quoted = CLIClient.request(from: ["set", "TEKKEN 8", "35"])
        let unquoted = CLIClient.request(from: ["set", "TEKKEN", "8", "35"])
        #expect(quoted == .setVolume(app: "TEKKEN 8", percent: 35))
        #expect(unquoted == quoted)
        #expect(CLIClient.request(from: ["mute", "TEKKEN", "8"]) == .setMuted(app: "TEKKEN 8", muted: true))
        #expect(CLIClient.request(from: ["unmute", "wine:TEKKEN 8"]) == .setMuted(app: "wine:TEKKEN 8", muted: false))
        #expect(CLIClient.request(from: ["output", "TEKKEN", "8", "Odyssey G91F"]) == .setOutput(app: "TEKKEN 8", device: "Odyssey G91F"))
    }

    @Test("help and malformed arguments give no request")
    func malformedArgumentsAreRejected() {
        #expect(CLIClient.request(from: []) == nil)
        #expect(CLIClient.request(from: ["help"]) == nil)
        #expect(CLIClient.request(from: ["--help"]) == nil)
        #expect(CLIClient.request(from: ["list", "--all"]) == nil)
        #expect(CLIClient.request(from: ["hide", "now"]) == nil)
        #expect(CLIClient.request(from: ["set", "Spotify"]) == nil)
        #expect(CLIClient.request(from: ["set", "60"]) == nil)
        #expect(CLIClient.request(from: ["set", "Spotify", "401"]) == nil)
        #expect(CLIClient.request(from: ["set", "Spotify", "-1"]) == nil)
        #expect(CLIClient.request(from: ["set", "Spotify", "loud"]) == nil)
        #expect(CLIClient.request(from: ["set", "Spotify", "nan"]) == nil)
        #expect(CLIClient.request(from: ["mute"]) == nil)
        #expect(CLIClient.request(from: ["mute", " "]) == nil)
        #expect(CLIClient.request(from: ["output", "Discord"]) == nil)
        #expect(CLIClient.request(from: ["focus", "Spotify"]) == nil)
    }

    @Test("every CLI command and help select the client, the subcommands and the GUI do not")
    func commandSelection() {
        for command in ["list", "devices", "set", "mute", "unmute", "output", "show", "hide", "help", "--help"] {
            #expect(CLIClient.commands.contains(command))
        }
        for command in ["snapshot", "scan", "selftest", "-psn_0_12345"] {
            #expect(!CLIClient.commands.contains(command))
        }
        for command in ["snapshot", "scan", "selftest"] {
            #expect(CLIClient.usage.contains(command))
        }
    }

    @Test("a request travels over a real message port to the handler and its response comes back")
    func requestTravelsOverMessagePort() throws {
        let portName = uniquePortName()
        let log = RequestLog()
        let tekken = tekken
        let server = CLIServer(portName: portName) { request in
            log.requests.append(request)
            return CLIResponse(ok: true, app: tekken)
        }
        #expect(server.start())
        defer { server.stop() }

        let response = try CLIClient.send(.setVolume(app: "TEKKEN 8", percent: 35), portName: portName)

        #expect(log.requests == [.setVolume(app: "TEKKEN 8", percent: 35)])
        #expect(response == CLIResponse(ok: true, app: tekken))
    }

    @Test("a failure from the handler reaches the client unchanged")
    func failureTravelsOverMessagePort() throws {
        let portName = uniquePortName()
        let server = CLIServer(portName: portName) { request in
            guard case .setMuted(let app, _) = request else { return .failure("Unexpected request.") }
            return .failure("No app matches '\(app)'.")
        }
        #expect(server.start())
        defer { server.stop() }

        let response = try CLIClient.send(.setMuted(app: "Winamp", muted: true), portName: portName)

        #expect(response == .failure("No app matches 'Winamp'."))
    }

    @Test("without a listening app the client reports that Soprano Mix is not running")
    func missingPortIsNotRunning() {
        let portName = uniquePortName()
        #expect(throws: CLIClient.Failure(message: "Soprano Mix is not running.")) {
            try CLIClient.send(.list, portName: portName)
        }
    }

    @Test("an undecodable request is answered with a bad-request failure")
    func undecodableRequestIsBadRequest() throws {
        let log = RequestLog()
        let server = CLIServer(portName: uniquePortName()) { request in
            log.requests.append(request)
            return CLIResponse(ok: true)
        }

        let reply = server.reply(to: Data("not json".utf8))

        #expect(try JSONDecoder().decode(CLIResponse.self, from: reply) == .failure("Bad request."))
        #expect(log.requests.isEmpty)
    }

    @Test("printed output is pretty JSON with sorted keys that decodes to the response")
    func outputIsPrettySortedJSON() throws {
        let response = CLIResponse(ok: true, apps: [tekken])

        let text = try #require(CLIClient.output(for: response))

        #expect(text.contains("\n"))
        let key = try #require(text.range(of: "\"key\""))
        let name = try #require(text.range(of: "\"name\""))
        #expect(key.lowerBound < name.lowerBound)
        #expect(try JSONDecoder().decode(CLIResponse.self, from: Data(text.utf8)) == response)
    }
}
