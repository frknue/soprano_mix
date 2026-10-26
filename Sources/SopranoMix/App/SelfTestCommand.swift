import CoreAudio
import Foundation
import SopranoMixCore

/// `SopranoMix selftest [--gain <x>] [--seconds <n>] [--silent]`: the live pipeline check.
///
/// Writes a 440 Hz −12 dBFS tone to a temporary WAV, plays it with `/usr/bin/afplay`,
/// routes that afplay process (and nothing else) through `LiveAudioRouter` on the default
/// output at the gain, samples the route's peaks every 100 ms and reports JSON: capture
/// status, input and output peaks, the expected output peak, the route's added latency,
/// pass or fail. Exit 0 on pass, 1 otherwise. Plays sound unless `--silent` (gain 0).
@MainActor
enum SelfTestCommand {
    struct Options: Equatable {
        var gain: Float = 0.5
        var seconds: Double = 3
        var silent = false
    }

    enum ParseResult: Equatable {
        case run(Options)
        case help
        case failure(String)
    }

    static let usage = """
    usage: SopranoMix selftest [--gain <x>] [--seconds <n>] [--silent]

      --gain <x>      linear route gain, 0–10 (default 0.5)
      --seconds <n>   how long to measure, 0.5–60 (default 3)
      --silent        gain 0: the tone is muted by the route
      --help          this text

    Plays a 440 Hz tone with /usr/bin/afplay, routes it through Soprano Mix's live
    pipeline on the default output and checks the output peak against input × gain.
    Triggers the System Audio Recording prompt for the app that runs it.
    """

    /// Linear amplitude of −12 dBFS.
    static let toneAmplitude = Float(pow(10.0, -12.0 / 20))
    static let tolerance: Float = 0.02

    static func run(arguments: [String]) -> Int32 {
        var arguments = arguments
        if arguments.first == "selftest" { arguments.removeFirst() }
        switch parse(arguments) {
        case .help:
            print(usage)
            return 0
        case .failure(let message):
            FileHandle.standardError.write(Data("selftest: \(message)\n\(usage)\n".utf8))
            return 1
        case .run(let options):
            return execute(options)
        }
    }

    static func parse(_ arguments: [String]) -> ParseResult {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                return .help
            case "--silent":
                options.silent = true
            case "--gain", "--seconds":
                guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value.isFinite else {
                    return .failure("\(argument) needs a number")
                }
                if argument == "--gain" {
                    guard (0...10).contains(value) else { return .failure("--gain must be 0–10") }
                    options.gain = Float(value)
                } else {
                    guard (0.5...60).contains(value) else { return .failure("--seconds must be 0.5–60") }
                    options.seconds = value
                }
                index += 1
            default:
                return .failure("unknown argument '\(argument)'")
            }
            index += 1
        }
        if options.silent { options.gain = 0 }
        return .run(options)
    }

    // MARK: - Report

    struct Latency: Encodable {
        var sampleRate: Double
        var bufferFrames: Int
        var safetyOffsetMs: Double
        var bufferMs: Double
        var deviceLatencyMs: Double
        var totalMs: Double
    }

    struct Report: Encodable {
        var capture: String
        var outputDevice: String?
        var gain: Float
        var seconds: Double
        var silent: Bool
        var inputPeak: Float?
        var outputPeak: Float?
        var expectedOutputPeak: Float?
        var tolerance: Float
        var latency: Latency?
        var pass: Bool
        var error: String?
    }

    // MARK: - Run

    private static func execute(_ options: Options) -> Int32 {
        var report = Report(
            capture: CaptureStatus.unknown.rawValue,
            gain: options.gain,
            seconds: options.seconds,
            silent: options.silent,
            tolerance: tolerance,
            pass: false
        )
        func finish(_ error: String?) -> Int32 {
            report.error = error
            emit(report)
            return report.pass ? 0 : 1
        }

        var capture = PrivateAPIs.audioCapturePreflight()
        if capture == .notDetermined {
            capture = requestCapture()
        }
        report.capture = capture.rawValue
        guard capture != .denied else {
            return finish("System Audio Recording is denied for the app running selftest; allow it in System Settings → Privacy & Security.")
        }

        guard let output = defaultOutput() else {
            return finish("There is no default output device.")
        }
        report.outputDevice = output.name

        // Long enough for process discovery, route start-up and the measurement.
        let toneSeconds = options.seconds + 8
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-mix-selftest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        do {
            try toneWAV(seconds: toneSeconds, amplitude: toneAmplitude).write(to: wavURL)
        } catch {
            return finish("Could not write the test tone: \(error.localizedDescription)")
        }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wavURL.path]
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        do {
            try player.run()
        } catch {
            return finish("Could not start afplay: \(error.localizedDescription)")
        }
        let router = LiveAudioRouter()
        defer {
            // afplay first: tearing the route down while it still plays would let the
            // tone through unmuted (audible with `--silent`).
            if player.isRunning {
                player.terminate()
                player.waitUntilExit()
            }
            router.stopAll()
        }

        // afplay's own process object; routed as soon as it exists so `--silent` mutes
        // the tone from its first buffers on.
        let discoveryDeadline = Date().addingTimeInterval(3)
        var processObject: AudioObjectID?
        pump(until: discoveryDeadline) {
            processObject = CoreAudioProperties.processObject(forPID: player.processIdentifier)
            return processObject != nil || !player.isRunning
        }
        guard let processObject else {
            return finish("afplay never connected to Core Audio.")
        }

        let key = AppKey.executable("afplay")
        router.apply(RoutePlan(routes: [
            RouteSpec(
                key: key,
                processObjectIDs: [processObject],
                outputDeviceUID: output.uid,
                gain: options.gain,
                mode: .replace,
                limiter: options.gain > 1,
                bufferFrames: AudioEngineSettings().bufferFrames
            ),
        ]))

        var isPlaying = false
        pump(until: discoveryDeadline) {
            isPlaying = isRunningOutput(processObject)
            return isPlaying || !player.isRunning
        }
        guard isPlaying else {
            return finish("afplay's process object never ran output.")
        }

        pump(until: Date().addingTimeInterval(3)) { router.statuses[key] != .starting }
        switch router.statuses[key] {
        case .running:
            break
        case .failed(let reason):
            return finish("The route failed: \(reason)")
        case .starting, nil:
            return finish("The route did not start within 3 s.")
        }
        if let diagnostics = router.diagnostics(for: key) {
            report.latency = Latency(
                sampleRate: diagnostics.sampleRate,
                bufferFrames: diagnostics.bufferFrames,
                safetyOffsetMs: rounded(diagnostics.safetyOffsetMilliseconds),
                bufferMs: rounded(diagnostics.bufferMilliseconds),
                deviceLatencyMs: rounded(diagnostics.outputLatencyMilliseconds),
                totalMs: rounded(diagnostics.addedLatencyMilliseconds)
            )
        }

        // Let the first cycles pass, then measure.
        pump(until: Date().addingTimeInterval(0.2)) { false }
        _ = router.takeLevels()
        var levels = RouteLevels.silent
        let measureEnd = Date().addingTimeInterval(options.seconds)
        while Date() < measureEnd {
            pump(until: min(measureEnd, Date().addingTimeInterval(0.1))) { false }
            if let sample = router.takeLevels()[key] {
                levels = RouteLevels(input: levels.input.merged(with: sample.input), output: levels.output.merged(with: sample.output))
            }
            if case .failed(let reason) = router.statuses[key] {
                return finish("The route failed while measuring: \(reason)")
            }
            guard player.isRunning else {
                return finish("afplay stopped before the measurement ended.")
            }
        }

        let inputPeak = levels.input.peak
        let outputPeak = levels.output.peak
        let expected = options.gain == 0 ? 0 : min(inputPeak * options.gain, GainStage.ceiling)
        report.inputPeak = rounded(inputPeak)
        report.outputPeak = rounded(outputPeak)
        report.expectedOutputPeak = rounded(expected)
        guard inputPeak > tolerance else {
            return finish("The tap delivered silence (is System Audio Recording allowed?).")
        }
        report.pass = abs(outputPeak - expected) <= tolerance
        return finish(report.pass ? nil : "The output peak differs from the expected peak by more than \(tolerance).")
    }

    // MARK: - Helpers

    /// Runs the main run loop until `done` returns true or `deadline` passes, checking
    /// every 10 ms.
    private static func pump(until deadline: Date, _ done: () -> Bool) {
        while !done() {
            let now = Date()
            guard now < deadline else { return }
            _ = RunLoop.main.run(mode: .default, before: min(deadline, now.addingTimeInterval(0.01)))
        }
    }

    /// Shows the System Audio Recording prompt and waits up to 60 s for the answer.
    private static func requestCapture() -> CaptureStatus {
        let answer = CaptureAnswer()
        guard PrivateAPIs.requestAudioCapture({ granted in answer.set(granted) }) else {
            return PrivateAPIs.audioCapturePreflight()
        }
        pump(until: Date().addingTimeInterval(60)) { answer.value != nil }
        switch answer.value {
        case true?: return .granted
        case false?: return .denied
        case nil: return PrivateAPIs.audioCapturePreflight()
        }
    }

    private static func defaultOutput() -> (uid: String, name: String)? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device = try? CoreAudioProperties.value(
            system,
            CoreAudioProperties.address(kAudioHardwarePropertyDefaultOutputDevice),
            as: AudioObjectID.self
        ), device != kAudioObjectUnknown,
            let uid = try? CoreAudioProperties.string(device, CoreAudioProperties.address(kAudioDevicePropertyDeviceUID)),
            !uid.isEmpty
        else { return nil }
        let name = (try? CoreAudioProperties.string(device, CoreAudioProperties.address(kAudioObjectPropertyName))) ?? uid
        return (uid, name)
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        let running = try? CoreAudioProperties.value(
            object,
            CoreAudioProperties.address(kAudioProcessPropertyIsRunningOutput),
            as: UInt32.self
        )
        return (running ?? 0) != 0
    }

    /// 16-bit PCM, 48 kHz, stereo: a sine at `amplitude` (linear) on both channels.
    static func toneWAV(seconds: Double, amplitude: Float, frequency: Double = 440, sampleRate: Int = 48_000) -> Data {
        let channels = 2
        let bytesPerSample = 2
        let frames = Int(seconds * Double(sampleRate))
        let dataSize = frames * channels * bytesPerSample
        var data = Data(capacity: 44 + dataSize)
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)                                                    // PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * channels * bytesPerSample))       // byte rate
        append16(UInt16(channels * bytesPerSample))                    // block align
        append16(UInt16(bytesPerSample * 8))
        append("data")
        append32(UInt32(dataSize))

        var samples = [Int16](repeating: 0, count: frames * channels)
        let step = 2 * Double.pi * frequency / Double(sampleRate)
        let scale = Double(amplitude) * Double(Int16.max)
        for frame in 0..<frames {
            let value = Int16((sin(step * Double(frame)) * scale).rounded())
            samples[frame * 2] = value.littleEndian
            samples[frame * 2 + 1] = value.littleEndian
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func rounded(_ value: Float) -> Float {
        (value * 10_000).rounded() / 10_000
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}

/// The prompt's answer, set on a TCC queue and read on the main thread.
private final class CaptureAnswer: @unchecked Sendable {
    // @unchecked: `stored` is only touched under `lock`.
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ granted: Bool) {
        lock.lock()
        stored = granted
        lock.unlock()
    }
}
