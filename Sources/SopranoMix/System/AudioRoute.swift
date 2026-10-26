import CoreAudio
import Foundation
import SopranoMixCore

// MARK: - Buffer layout (pure)

/// Where one channel sits in an IOProc's `AudioBufferList`: buffer index, channel offset
/// inside that buffer, and the buffer's channel count (the sample stride).
struct RouteChannel: Equatable, Sendable {
    var buffer: Int
    var offset: Int
    var stride: Int
}

/// Which input channels carry the tap and which output channels are the device's, worked
/// out once from the aggregate's stream configurations.
///
/// An aggregate's input buffers list the sub-device's own input streams first and the
/// tap's stream(s) last, so the tap's channels are the last `tapChannelCount` input
/// channels (one interleaved buffer or one buffer per channel, the stride says which).
/// The output buffers are the output device's streams in order.
struct RouteBufferLayout: Equatable, Sendable {
    /// Tap channel i (0 = left, 1 = right for a stereo tap).
    var tapChannels: [RouteChannel]
    /// Device output channel i.
    var outputChannels: [RouteChannel]

    /// nil when the tap has no channels or the input buffers hold fewer channels than the tap.
    init?(inputBufferChannels: [Int], outputBufferChannels: [Int], tapChannelCount: Int) {
        guard tapChannelCount > 0 else { return nil }
        let inputs = Self.flatten(inputBufferChannels)
        guard inputs.count >= tapChannelCount else { return nil }
        tapChannels = Array(inputs.suffix(tapChannelCount))
        outputChannels = Self.flatten(outputBufferChannels)
    }

    private static func flatten(_ bufferChannels: [Int]) -> [RouteChannel] {
        var channels: [RouteChannel] = []
        for (buffer, count) in bufferChannels.enumerated() where count > 0 {
            for offset in 0..<count {
                channels.append(RouteChannel(buffer: buffer, offset: offset, stride: count))
            }
        }
        return channels
    }
}

// MARK: - Route

enum AudioRouteKind: Equatable, Sendable {
    /// Mutes the app (`.mutedWhenTapped`) and plays it again through `GainStage`.
    case replace
    /// Reads the app for its meter (`.unmuted`); writes silence.
    case meter
    /// Every process on the output except the excluded ones (and Soprano Mix), muted and
    /// played again channel for channel at the gain.
    case master
}

/// What a route is built from. Two configurations that differ only in
/// `processObjectIDs` are the same route updated in place.
struct AudioRouteConfiguration: Equatable, Sendable {
    var kind: AudioRouteKind
    /// The tap's name: "Soprano Mix <key>".
    var name: String
    /// Tapped processes (app routes) or excluded processes (master; Soprano Mix's own
    /// process object is added by the route).
    var processObjectIDs: [AudioObjectID]
    var outputDeviceUID: String
    var bufferFrames: Int

    func isSameRoute(as other: AudioRouteConfiguration) -> Bool {
        kind == other.kind && outputDeviceUID == other.outputDeviceUID && bufferFrames == other.bufferFrames
    }
}

/// Timing of a running route, for `selftest`.
struct RouteDiagnostics: Equatable, Sendable {
    var sampleRate: Double
    var bufferFrames: Int
    /// The aggregate's output-scope `kAudioDevicePropertyLatency`.
    var outputLatencyFrames: Int
    /// The aggregate's output-scope `kAudioDevicePropertySafetyOffset`.
    var safetyOffsetFrames: Int

    /// Safety offset + one buffer + device latency.
    var addedLatencyFrames: Int { safetyOffsetFrames + bufferFrames + outputLatencyFrames }
    var outputLatencyMilliseconds: Double { milliseconds(outputLatencyFrames) }
    var safetyOffsetMilliseconds: Double { milliseconds(safetyOffsetFrames) }
    var bufferMilliseconds: Double { milliseconds(bufferFrames) }
    var addedLatencyMilliseconds: Double { milliseconds(addedLatencyFrames) }

    private func milliseconds(_ frames: Int) -> Double {
        sampleRate > 0 ? Double(frames) / sampleRate * 1000 : 0
    }
}

enum AudioRouteError: Error, CustomStringConvertible {
    case deviceMissing
    case unsupportedTapFormat
    case noTapChannels
    case noOutputChannels
    /// Soprano Mix's own process object is unknown: a master tap would capture its own
    /// output (feedback).
    case ownProcessUnknown
    case coreAudio(CoreAudioError)

    /// The text a failed route shows.
    var description: String {
        switch self {
        case .deviceMissing: "The output device is gone."
        case .unsupportedTapFormat: "The tap delivers an unsupported audio format."
        case .noTapChannels: "The tap has no audio channels."
        case .noOutputChannels: "The output device has no output channels."
        case .ownProcessUnknown: "Core Audio does not list Soprano Mix's own process, so software volume cannot exclude it."
        case .coreAudio(let error): "Core Audio error \(error)"
        }
    }
}

/// What a live route reports to its owner (on the router's queue, at most once).
enum AudioRouteEvent: Sendable {
    /// The output device died: the route has failed.
    case deviceGone
    /// The aggregate's streams or the tap's format changed: the route must be rebuilt.
    case layoutChanged
}

/// One live route: a process tap, a private aggregate device around the output device and
/// the tap, and an IOProc on the aggregate. Built, updated and torn down on the router's
/// serial queue only (not thread-safe otherwise); the IO block runs on the HAL's IO thread
/// and touches nothing but the preallocated `RouteRenderer` memory, `RouteParameters` and
/// the route's `RouteGate`.
final class AudioRoute {
    let parameters: RouteParameters
    private(set) var diagnostics: RouteDiagnostics
    /// The tapped (or, for master, excluded) processes right now.
    private(set) var processObjectIDs: [AudioObjectID]

    private let baseConfiguration: AudioRouteConfiguration
    private let gate = RouteGate()
    private let tapUUID: UUID
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private var renderer: RouteRenderer?
    private var listeners: [CoreAudioListener] = []

    /// The configuration this route runs now (with in-place process updates).
    var configuration: AudioRouteConfiguration {
        var configuration = baseConfiguration
        configuration.processObjectIDs = processObjectIDs
        return configuration
    }

    /// Builds and starts the route. `onEvent` runs on `queue`, at most once.
    init(
        configuration: AudioRouteConfiguration,
        parameters: RouteParameters,
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (AudioRouteEvent) -> Void
    ) throws {
        baseConfiguration = configuration
        self.parameters = parameters
        tapUUID = UUID()
        processObjectIDs = configuration.processObjectIDs
        diagnostics = RouteDiagnostics(sampleRate: 0, bufferFrames: 0, outputLatencyFrames: 0, safetyOffsetFrames: 0)
        do {
            try build(queue: queue, onEvent: onEvent)
        } catch {
            teardown()
            throw error
        }
    }

    deinit {
        teardown()
    }

    /// Ramps this route's output to silence within one IO cycle (before a replacement
    /// starts). Irreversible.
    func silence() {
        gate.close()
    }

    /// Changes the tapped (or, for master, excluded) processes of the running tap. False
    /// when Core Audio refused or Soprano Mix's own process is unknown (master): the
    /// caller rebuilds the route.
    func updateProcesses(_ ids: [AudioObjectID]) -> Bool {
        guard tapID != kAudioObjectUnknown else { return false }
        guard ids != processObjectIDs else { return true }
        do {
            let description = try makeTapDescription(processes: ids)
            try CoreAudioProperties.setValue(description, on: tapID, CoreAudioProperties.address(kAudioTapPropertyDescription))
        } catch {
            return false
        }
        processObjectIDs = ids
        return true
    }

    /// Stop, destroy the IOProc, destroy the aggregate, destroy the tap. Idempotent;
    /// errors are ignored (the objects may already be gone with the device).
    func teardown() {
        for listener in listeners {
            listener.remove()
        }
        listeners = []
        if let ioProcID {
            if isStarted {
                AudioDeviceStop(aggregateID, ioProcID)
                isStarted = false
            }
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        // Only after the IOProc is destroyed: the IO block never runs again.
        renderer?.deallocate()
        renderer = nil
    }

    // MARK: Building

    private func build(queue: DispatchQueue, onEvent: @escaping @Sendable (AudioRouteEvent) -> Void) throws {
        guard let outputDevice = CoreAudioProperties.device(forUID: baseConfiguration.outputDeviceUID) else {
            throw AudioRouteError.deviceMissing
        }

        // 1. The tap.
        let description = try makeTapDescription(processes: baseConfiguration.processObjectIDs)
        var newTap = kAudioObjectUnknown
        try check(AudioHardwareCreateProcessTap(description, &newTap), "Create process tap")
        tapID = newTap
        let tapFormat: AudioStreamBasicDescription = try coreAudio {
            try CoreAudioProperties.value(tapID, CoreAudioProperties.address(kAudioTapPropertyFormat))
        }
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32 else {
            throw AudioRouteError.unsupportedTapFormat
        }
        let tapUID = (try? CoreAudioProperties.string(tapID, CoreAudioProperties.address(kAudioTapPropertyUID)))
            .flatMap { $0.isEmpty ? nil : $0 } ?? tapUUID.uuidString

        // 2. The private aggregate: the output device as main and only sub-device, the tap.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: baseConfiguration.name,
            kAudioAggregateDeviceUIDKey: "com.soprano.mix.route.\(tapUUID.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: baseConfiguration.outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: baseConfiguration.outputDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var newAggregate = kAudioObjectUnknown
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate), "Create aggregate device")
        aggregateID = newAggregate

        // 3. IO buffer size, clamped to what the aggregate allows.
        let bufferFrames = setBufferFrames(baseConfiguration.bufferFrames)

        // 4. Where the tap and the output channels sit in the IOProc's buffers (one
        //    buffer per stream; disabled streams stay in the list with NULL data).
        let inputBuffers = try coreAudio { try CoreAudioProperties.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeInput) }
        let outputBuffers = try coreAudio { try CoreAudioProperties.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeOutput) }
        guard let layout = RouteBufferLayout(
            inputBufferChannels: inputBuffers,
            outputBufferChannels: outputBuffers,
            tapChannelCount: Int(tapFormat.mChannelsPerFrame)
        ) else {
            throw AudioRouteError.noTapChannels
        }
        if baseConfiguration.kind != .meter, layout.outputChannels.isEmpty {
            throw AudioRouteError.noOutputChannels
        }

        let nominalRate = try? CoreAudioProperties.value(aggregateID, CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
        let sampleRate = nominalRate.flatMap { $0 > 0 ? $0 : nil } ?? (tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 48_000)

        // 5. The IOProc. The block captures only `RouteRenderer`, a struct of raw pointers.
        let renderer = RouteRenderer(
            kind: baseConfiguration.kind,
            layout: layout,
            inputBufferCount: inputBuffers.count,
            outputBufferCount: outputBuffers.count,
            sampleRate: sampleRate,
            parameters: parameters,
            gate: gate
        )
        self.renderer = renderer
        var newProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil) { _, inputData, _, outputData, _ in
                renderer.render(input: inputData, output: outputData)
            },
            "Create IOProc"
        )
        ioProcID = newProcID
        guard let newProcID else { throw AudioRouteError.coreAudio(CoreAudioError(status: OSStatus(kAudioHardwareUnspecifiedError), operation: "Create IOProc")) }

        // 6. Only the tap's input streams: the output device's own inputs (a headset
        //    microphone) are never opened.
        let tapStreams = Set(layout.tapChannels.map(\.buffer))
        do {
            try setInputStreamUsage(newProcID, streamCount: inputBuffers.count, enabled: tapStreams)
        } catch let error as CoreAudioError {
            let opensOtherInputs = inputBuffers.indices.contains { !tapStreams.contains($0) && inputBuffers[$0] > 0 }
            if opensOtherInputs { throw AudioRouteError.coreAudio(error) }
        }

        // 7. Watch the output device, the aggregate's streams and the tap's format.
        let watch = RouteWatch(
            outputDevice: outputDevice,
            aggregateID: aggregateID,
            tapID: tapID,
            inputBuffers: inputBuffers,
            outputBuffers: outputBuffers,
            tapFormat: tapFormat,
            onEvent: onEvent
        )
        let watched: [(AudioObjectID, AudioObjectPropertyAddress, @Sendable () -> Void)] = [
            (outputDevice, CoreAudioProperties.address(kAudioDevicePropertyDeviceIsAlive), { watch.checkAlive() }),
            (aggregateID, CoreAudioProperties.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput), { watch.checkLayout() }),
            (aggregateID, CoreAudioProperties.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput), { watch.checkLayout() }),
            (tapID, CoreAudioProperties.address(kAudioTapPropertyFormat), { watch.checkLayout() }),
        ]
        for (object, address, handler) in watched {
            if let listener = CoreAudioProperties.addListener(object, address, queue: queue, { _, _ in handler() }) {
                listeners.append(listener)
            }
        }

        // The baselines above were read before the listeners existed: catch a change
        // that slipped in between (reported through `onEvent` like any later one).
        watch.checkAlive()
        watch.checkLayout()

        // 8. Start.
        try check(AudioDeviceStart(aggregateID, newProcID), "Start aggregate device")
        isStarted = true

        diagnostics = RouteDiagnostics(
            sampleRate: sampleRate,
            bufferFrames: bufferFrames,
            outputLatencyFrames: frames(kAudioDevicePropertyLatency),
            safetyOffsetFrames: frames(kAudioDevicePropertySafetyOffset)
        )
    }

    private func makeTapDescription(processes: [AudioObjectID]) throws -> CATapDescription {
        let description: CATapDescription
        switch baseConfiguration.kind {
        case .replace, .meter:
            description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.muteBehavior = baseConfiguration.kind == .replace ? .mutedWhenTapped : .unmuted
        case .master:
            // `excludingProcesses:deviceUID:stream:` taps exactly what the other processes
            // send to this output's first stream, in that stream's own format (every
            // channel, not a stereo mixdown), so the IOProc can copy channel i to channel
            // i. A global stereo tap would also capture audio headed for other devices and
            // fold surround layouts to stereo. Without our own process object the tap
            // would capture our replayed output: refuse.
            guard let own = CoreAudioProperties.processObject(forPID: getpid()) else {
                throw AudioRouteError.ownProcessUnknown
            }
            let excluded = Set(processes).union([own]).sorted()
            description = CATapDescription(excludingProcesses: excluded, deviceUID: baseConfiguration.outputDeviceUID, stream: 0)
            description.muteBehavior = .mutedWhenTapped
        }
        description.uuid = tapUUID
        description.name = baseConfiguration.name
        description.isPrivate = true
        return description
    }

    /// `kAudioDevicePropertyIOProcStreamUsage` (input scope) for `procID`: only the
    /// `enabled` stream indices are on.
    private func setInputStreamUsage(_ procID: AudioDeviceIOProcID, streamCount: Int, enabled: Set<Int>) throws {
        guard streamCount > 0 else { return }
        let numberOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams) ?? 8
        let arrayOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let byteCount = max(MemoryLayout<AudioHardwareIOProcStreamUsage>.size, arrayOffset + streamCount * MemoryLayout<UInt32>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(streamCount), toByteOffset: numberOffset, as: UInt32.self)
        for stream in 0..<streamCount {
            raw.storeBytes(of: enabled.contains(stream) ? 1 : 0, toByteOffset: arrayOffset + stream * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        try CoreAudioProperties.setBytes(
            UnsafeRawBufferPointer(start: raw, count: byteCount),
            on: aggregateID,
            CoreAudioProperties.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        )
    }

    private func setBufferFrames(_ requested: Int) -> Int {
        let address = CoreAudioProperties.address(kAudioDevicePropertyBufferFrameSize)
        var frames = requested
        if let range = try? CoreAudioProperties.value(aggregateID, CoreAudioProperties.address(kAudioDevicePropertyBufferFrameSizeRange), as: AudioValueRange.self),
           range.mMinimum > 0, range.mMaximum >= range.mMinimum {
            frames = min(max(requested, Int(range.mMinimum)), Int(range.mMaximum))
        }
        try? CoreAudioProperties.setValue(UInt32(frames), on: aggregateID, address)
        let actual = (try? CoreAudioProperties.value(aggregateID, address, as: UInt32.self)).map(Int.init)
        return actual ?? frames
    }

    private func frames(_ selector: AudioObjectPropertySelector) -> Int {
        let value = try? CoreAudioProperties.value(
            aggregateID,
            CoreAudioProperties.address(selector, kAudioObjectPropertyScopeOutput),
            as: UInt32.self
        )
        return Int(value ?? 0)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioRouteError.coreAudio(CoreAudioError(status: status, operation: operation)) }
    }

    private func coreAudio<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CoreAudioError {
            throw AudioRouteError.coreAudio(error)
        }
    }
}

/// The listeners' side of a route: compares what Core Audio reports now with what the
/// route was built for and reports the first difference once. Holds no reference to the
/// route (no retain cycle through the listener blocks).
private final class RouteWatch: @unchecked Sendable {
    // @unchecked: immutable except `fired`, which is only touched under `lock`.
    private let outputDevice: AudioObjectID
    private let aggregateID: AudioObjectID
    private let tapID: AudioObjectID
    private let inputBuffers: [Int]
    private let outputBuffers: [Int]
    private let tapFormat: AudioStreamBasicDescription
    private let onEvent: @Sendable (AudioRouteEvent) -> Void
    private let lock = NSLock()
    private var fired = false

    init(
        outputDevice: AudioObjectID,
        aggregateID: AudioObjectID,
        tapID: AudioObjectID,
        inputBuffers: [Int],
        outputBuffers: [Int],
        tapFormat: AudioStreamBasicDescription,
        onEvent: @escaping @Sendable (AudioRouteEvent) -> Void
    ) {
        self.outputDevice = outputDevice
        self.aggregateID = aggregateID
        self.tapID = tapID
        self.inputBuffers = inputBuffers
        self.outputBuffers = outputBuffers
        self.tapFormat = tapFormat
        self.onEvent = onEvent
    }

    func checkAlive() {
        let alive = try? CoreAudioProperties.value(outputDevice, CoreAudioProperties.address(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self)
        if (alive ?? 0) == 0 { fire(.deviceGone) }
    }

    /// Fires `.layoutChanged` when the stream channel counts or the tap format differ
    /// from the built ones (notifications for unrelated changes, like the buffer size,
    /// are ignored). A read that fails proves nothing and fires nothing: a device on its
    /// way out is the alive check's job, and treating failures as changes would rebuild
    /// the route in a loop.
    func checkLayout() {
        guard let inputs = try? CoreAudioProperties.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeInput),
              let outputs = try? CoreAudioProperties.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeOutput),
              let format = try? CoreAudioProperties.value(tapID, CoreAudioProperties.address(kAudioTapPropertyFormat), as: AudioStreamBasicDescription.self)
        else { return }
        if inputs != inputBuffers || outputs != outputBuffers || !Self.same(format, tapFormat) {
            fire(.layoutChanged)
        }
    }

    private func fire(_ event: AudioRouteEvent) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { onEvent(event) }
    }

    private static func same(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate && lhs.mFormatID == rhs.mFormatID && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}

// MARK: - IO

/// Everything the IO block touches, allocated once at build time.
///
/// Real-time safety: the struct holds only raw pointers and plain values (no class
/// references, so capturing and calling it never retains or releases); `render` uses
/// pointer arithmetic, `memset`, `GainStage` (allocation- and lock-free by contract) on
/// a pointer-held instance (no exclusivity bookkeeping), `RouteParameters.Realtime` and
/// `RouteGate.Realtime` (`os_unfair_lock_trylock` only). No Swift arrays, no
/// Objective-C, no logging.
struct RouteRenderer: @unchecked Sendable {
    // @unchecked: owned by one `AudioRoute`; after build only the IO thread touches the
    // pointees, and `deallocate` runs after the IOProc is destroyed.
    /// Planar scratch frames per channel; larger IO buffers are processed in chunks.
    static let scratchFrames = 4096

    let kind: AudioRouteKind
    private let parameters: RouteParameters.Realtime
    private let gate: RouteGate.Realtime
    private let ioState: UnsafeMutablePointer<RouteParameters.IOState>
    /// The buffer counts the layout was computed for; any other shape renders silence.
    private let inputBufferCount: Int
    private let outputBufferCount: Int
    private let tapChannels: UnsafeMutablePointer<RouteChannel>
    private let tapCount: Int
    private let outputChannels: UnsafeMutablePointer<RouteChannel>
    private let outputCount: Int
    private let scratch: UnsafeMutablePointer<Float>
    private let gainStage: UnsafeMutablePointer<GainStage>
    /// The master route's current (ramped) gain.
    private let masterGain: UnsafeMutablePointer<Float>

    init(
        kind: AudioRouteKind,
        layout: RouteBufferLayout,
        inputBufferCount: Int,
        outputBufferCount: Int,
        sampleRate: Double,
        parameters: RouteParameters,
        gate: RouteGate
    ) {
        self.kind = kind
        let initial = parameters.values
        let ioState = UnsafeMutablePointer<RouteParameters.IOState>.allocate(capacity: 1)
        ioState.initialize(to: RouteParameters.IOState(values: initial))
        self.ioState = ioState
        self.parameters = parameters.realtime(state: ioState)
        self.gate = gate.realtime
        self.inputBufferCount = inputBufferCount
        self.outputBufferCount = outputBufferCount
        tapCount = layout.tapChannels.count
        tapChannels = .allocate(capacity: max(tapCount, 1))
        tapChannels.initialize(from: layout.tapChannels, count: tapCount)
        outputCount = layout.outputChannels.count
        outputChannels = .allocate(capacity: max(outputCount, 1))
        outputChannels.initialize(from: layout.outputChannels, count: outputCount)
        scratch = .allocate(capacity: 2 * Self.scratchFrames)
        scratch.initialize(repeating: 0, count: 2 * Self.scratchFrames)
        gainStage = .allocate(capacity: 1)
        gainStage.initialize(to: GainStage(sampleRate: sampleRate, gain: initial.gain))
        masterGain = .allocate(capacity: 1)
        masterGain.initialize(to: initial.gain)
    }

    func deallocate() {
        ioState.deinitialize(count: 1)
        ioState.deallocate()
        tapChannels.deinitialize(count: tapCount)
        tapChannels.deallocate()
        outputChannels.deinitialize(count: outputCount)
        outputChannels.deallocate()
        scratch.deinitialize(count: 2 * Self.scratchFrames)
        scratch.deallocate()
        gainStage.deinitialize(count: 1)
        gainStage.deallocate()
        masterGain.deinitialize(count: 1)
        masterGain.deallocate()
    }

    /// One IO cycle. Called on the HAL IO thread.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // Silence first: meter mode writes nothing, and channels beyond L/R stay zero.
        for index in 0..<outputs.count {
            if let data = outputs[index].mData {
                memset(data, 0, Int(outputs[index].mDataByteSize))
            }
        }

        // A changed stream layout (rebuild pending) must never route a non-tap input.
        guard inputs.count == inputBufferCount, outputs.count == outputBufferCount else {
            parameters.record(input: .silent, output: .silent)
            return
        }

        var values = parameters.current()
        if !gate.isOpen() { values.gain = 0 }
        let tapFrames = frameCount(inputs, tapChannels, tapCount)
        guard tapFrames > 0 else {
            parameters.record(input: .silent, output: .silent)
            return
        }

        switch kind {
        case .master:
            renderMaster(inputs: inputs, outputs: outputs, frames: tapFrames, target: values.gain)
        case .replace, .meter:
            renderStereo(inputs: inputs, outputs: outputs, frames: tapFrames, values: values)
        }
    }

    private func renderStereo(
        inputs: UnsafeMutableAudioBufferListPointer,
        outputs: UnsafeMutableAudioBufferListPointer,
        frames tapFrames: Int,
        values: RouteParameters.Values
    ) {
        let writes = kind == .replace && outputCount > 0
        let outputFrames = writes ? frameCount(outputs, outputChannels, outputCount) : 0
        let frames = writes ? min(tapFrames, outputFrames) : tapFrames
        let left = scratch
        let right = scratch + Self.scratchFrames
        let leftSource = tapChannels[0]
        let rightSource = tapCount > 1 ? tapChannels[1] : tapChannels[0]
        guard let leftData = inputs[leftSource.buffer].mData?.assumingMemoryBound(to: Float.self),
              let rightData = inputs[rightSource.buffer].mData?.assumingMemoryBound(to: Float.self) else {
            parameters.record(input: .silent, output: .silent)
            return
        }

        var inputPeak = StereoLevel.silent
        var outputPeak = StereoLevel.silent
        var done = 0
        while done < frames {
            let count = min(Self.scratchFrames, frames - done)
            for frame in 0..<count {
                let source = done + frame
                left[frame] = leftData[source * leftSource.stride + leftSource.offset]
                right[frame] = rightData[source * rightSource.stride + rightSource.offset]
            }
            let peaks = GainStage.peaks(left: left, right: right, frames: count)
            inputPeak = inputPeak.merged(with: peaks)
            if writes {
                let processed = gainStage.pointee.process(
                    left: left, right: right, frames: count, targetGain: values.gain, limiter: values.limiter
                )
                outputPeak = outputPeak.merged(with: processed)
                write(left: left, right: right, outputs: outputs, at: done, frames: count)
            } else {
                // Meter: the app plays unchanged, so what reaches the device is the input.
                outputPeak = outputPeak.merged(with: peaks)
            }
            done += count
        }
        parameters.record(input: inputPeak, output: outputPeak)
    }

    private func write(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        outputs: UnsafeMutableAudioBufferListPointer,
        at start: Int,
        frames: Int
    ) {
        if outputCount == 1 {
            let channel = outputChannels[0]
            guard let data = outputs[channel.buffer].mData?.assumingMemoryBound(to: Float.self) else { return }
            for frame in 0..<frames {
                data[(start + frame) * channel.stride + channel.offset] = (left[frame] + right[frame]) * 0.5
            }
            return
        }
        let leftChannel = outputChannels[0]
        let rightChannel = outputChannels[1]
        guard let leftData = outputs[leftChannel.buffer].mData?.assumingMemoryBound(to: Float.self),
              let rightData = outputs[rightChannel.buffer].mData?.assumingMemoryBound(to: Float.self) else { return }
        for frame in 0..<frames {
            leftData[(start + frame) * leftChannel.stride + leftChannel.offset] = left[frame]
            rightData[(start + frame) * rightChannel.stride + rightChannel.offset] = right[frame]
        }
    }

    /// Channel i → channel i with a gain ramped linearly from the last cycle's gain.
    private func renderMaster(
        inputs: UnsafeMutableAudioBufferListPointer,
        outputs: UnsafeMutableAudioBufferListPointer,
        frames tapFrames: Int,
        target: Float
    ) {
        let outputFrames = frameCount(outputs, outputChannels, outputCount)
        let frames = min(tapFrames, outputFrames)
        let channels = min(tapCount, outputCount)
        let start = masterGain.pointee
        var inputPeak = StereoLevel.silent
        var outputPeak = StereoLevel.silent
        if frames > 0 {
            let step = (target - start) / Float(frames)
            for index in 0..<channels {
                let source = tapChannels[index]
                let destination = outputChannels[index]
                guard let sourceData = inputs[source.buffer].mData?.assumingMemoryBound(to: Float.self),
                      let destinationData = outputs[destination.buffer].mData?.assumingMemoryBound(to: Float.self) else { continue }
                var inPeak: Float = 0
                var outPeak: Float = 0
                for frame in 0..<frames {
                    let sample = sourceData[frame * source.stride + source.offset]
                    let gain = frame == frames - 1 ? target : start + step * Float(frame + 1)
                    let processed = sample * gain
                    destinationData[frame * destination.stride + destination.offset] = processed
                    inPeak = max(inPeak, abs(sample))
                    outPeak = max(outPeak, abs(processed))
                }
                // Meters show the first two channels (a mono output fills both sides).
                if index == 0 {
                    inputPeak.left = inPeak
                    outputPeak.left = outPeak
                    if channels == 1 {
                        inputPeak.right = inPeak
                        outputPeak.right = outPeak
                    }
                } else if index == 1 {
                    inputPeak.right = inPeak
                    outputPeak.right = outPeak
                }
            }
            masterGain.pointee = target
        }
        parameters.record(input: inputPeak, output: outputPeak)
    }

    /// The frames every listed channel's buffer holds (0 when one is missing, disabled
    /// — NULL data — or shaped differently from the layout).
    private func frameCount(
        _ list: UnsafeMutableAudioBufferListPointer,
        _ channels: UnsafeMutablePointer<RouteChannel>,
        _ count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        var frames = Int.max
        for index in 0..<count {
            let channel = channels[index]
            guard channel.buffer < list.count, channel.stride > 0 else { return 0 }
            let buffer = list[channel.buffer]
            guard buffer.mData != nil, Int(buffer.mNumberChannels) == channel.stride else { return 0 }
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channel.stride))
        }
        return frames
    }
}
