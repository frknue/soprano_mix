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
    case coreAudio(CoreAudioError)

    /// The text a failed route shows.
    var description: String {
        switch self {
        case .deviceMissing: "The output device is gone."
        case .unsupportedTapFormat: "The tap delivers an unsupported audio format."
        case .noTapChannels: "The tap has no audio channels."
        case .noOutputChannels: "The output device has no output channels."
        case .coreAudio(let error): "Core Audio error \(error)"
        }
    }
}

/// One live route: a process tap, a private aggregate device around the output device and
/// the tap, and an IOProc on the aggregate. Built, updated and torn down on the router's
/// serial queue only (not thread-safe otherwise); the IO block runs on the HAL's IO thread
/// and touches nothing but the preallocated `RouteRenderer` memory and `RouteParameters`.
final class AudioRoute {
    let configuration: AudioRouteConfiguration
    let parameters: RouteParameters
    private(set) var diagnostics: RouteDiagnostics

    private let tapUUID: UUID
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private var renderer: RouteRenderer?
    private var aliveListener: CoreAudioListener?
    private var processObjectIDs: [AudioObjectID]

    /// Builds and starts the route. `onFailure` runs on `queue` when the output device
    /// dies (at most once).
    init(
        configuration: AudioRouteConfiguration,
        parameters: RouteParameters,
        queue: DispatchQueue,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        self.configuration = configuration
        self.parameters = parameters
        tapUUID = UUID()
        processObjectIDs = configuration.processObjectIDs
        diagnostics = RouteDiagnostics(sampleRate: 0, bufferFrames: 0, outputLatencyFrames: 0, safetyOffsetFrames: 0)
        do {
            try build(queue: queue, onFailure: onFailure)
        } catch {
            teardown()
            throw error
        }
    }

    deinit {
        teardown()
    }

    /// Changes the tapped (or, for master, excluded) processes of the running tap. False
    /// when Core Audio refused: the caller rebuilds the route.
    func updateProcesses(_ ids: [AudioObjectID]) -> Bool {
        guard tapID != kAudioObjectUnknown else { return false }
        guard ids != processObjectIDs else { return true }
        let description = makeTapDescription(processes: ids)
        do {
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
        aliveListener?.remove()
        aliveListener = nil
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

    private func build(queue: DispatchQueue, onFailure: @escaping @Sendable (String) -> Void) throws {
        guard let outputDevice = CoreAudioProperties.device(forUID: configuration.outputDeviceUID) else {
            throw AudioRouteError.deviceMissing
        }

        // 1. The tap.
        let description = makeTapDescription(processes: configuration.processObjectIDs)
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
            kAudioAggregateDeviceNameKey: configuration.name,
            kAudioAggregateDeviceUIDKey: "com.soprano.mix.route.\(tapUUID.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: configuration.outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: configuration.outputDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var newAggregate = kAudioObjectUnknown
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate), "Create aggregate device")
        aggregateID = newAggregate

        // 3. IO buffer size, clamped to what the aggregate allows.
        let bufferFrames = setBufferFrames(configuration.bufferFrames)

        // 4. Where the tap and the output channels sit in the IOProc's buffers.
        let inputBuffers = try coreAudio { try CoreAudioProperties.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeInput) }
        let outputBuffers = try coreAudio { try CoreAudioProperties.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeOutput) }
        guard let layout = RouteBufferLayout(
            inputBufferChannels: inputBuffers,
            outputBufferChannels: outputBuffers,
            tapChannelCount: Int(tapFormat.mChannelsPerFrame)
        ) else {
            throw AudioRouteError.noTapChannels
        }
        if configuration.kind != .meter, layout.outputChannels.isEmpty {
            throw AudioRouteError.noOutputChannels
        }

        let nominalRate = try? CoreAudioProperties.value(aggregateID, CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
        let sampleRate = nominalRate.flatMap { $0 > 0 ? $0 : nil } ?? (tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 48_000)

        // 5. The IOProc. The block captures only `RouteRenderer`, a struct of raw pointers.
        let renderer = RouteRenderer(
            kind: configuration.kind,
            layout: layout,
            sampleRate: sampleRate,
            initialGain: parameters.values.gain,
            parameters: parameters.realtime
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

        // 6. Watch the output device, then start.
        let failureLatch = FailureLatch(onFailure)
        aliveListener = CoreAudioProperties.addListener(
            outputDevice,
            CoreAudioProperties.address(kAudioDevicePropertyDeviceIsAlive),
            queue: queue
        ) { _, _ in
            let alive = (try? CoreAudioProperties.value(outputDevice, CoreAudioProperties.address(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self)) ?? 0
            if alive == 0 { failureLatch.fire(AudioRouteError.deviceMissing.description) }
        }
        try check(AudioDeviceStart(aggregateID, newProcID), "Start aggregate device")
        isStarted = true

        diagnostics = RouteDiagnostics(
            sampleRate: sampleRate,
            bufferFrames: bufferFrames,
            outputLatencyFrames: frames(kAudioDevicePropertyLatency),
            safetyOffsetFrames: frames(kAudioDevicePropertySafetyOffset)
        )
    }

    private func makeTapDescription(processes: [AudioObjectID]) -> CATapDescription {
        let description: CATapDescription
        switch configuration.kind {
        case .replace, .meter:
            description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.muteBehavior = configuration.kind == .replace ? .mutedWhenTapped : .unmuted
        case .master:
            // `excludingProcesses:deviceUID:stream:` taps exactly what the other processes
            // send to this output's first stream, in that stream's own format (every
            // channel, not a stereo mixdown), so the IOProc can copy channel i to channel
            // i. A global stereo tap would also capture audio headed for other devices and
            // fold surround layouts to stereo.
            var excluded = processes
            if let own = CoreAudioProperties.processObject(forPID: getpid()), !excluded.contains(own) {
                excluded.append(own)
            }
            description = CATapDescription(excludingProcesses: excluded.sorted(), deviceUID: configuration.outputDeviceUID, stream: 0)
            description.muteBehavior = .mutedWhenTapped
        }
        description.uuid = tapUUID
        description.name = configuration.name
        description.isPrivate = true
        return description
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

/// Reports a route failure once.
private final class FailureLatch: @unchecked Sendable {
    // @unchecked: `fired` is only touched under `lock`.
    private let lock = NSLock()
    private var fired = false
    private let onFailure: @Sendable (String) -> Void

    init(_ onFailure: @escaping @Sendable (String) -> Void) {
        self.onFailure = onFailure
    }

    func fire(_ reason: String) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { onFailure(reason) }
    }
}

// MARK: - IO

/// Everything the IO block touches, allocated once at build time.
///
/// Real-time safety: the struct holds only raw pointers and plain values (no class
/// references, so capturing and calling it never retains or releases); `render` uses
/// pointer arithmetic, `memset`, `GainStage` (allocation- and lock-free by contract) on
/// a pointer-held instance (no exclusivity bookkeeping) and `RouteParameters.Realtime`
/// (`os_unfair_lock_trylock` only). No Swift arrays, no Objective-C, no logging.
struct RouteRenderer: @unchecked Sendable {
    // @unchecked: owned by one `AudioRoute`; after build only the IO thread touches the
    // pointees, and `deallocate` runs after the IOProc is destroyed.
    /// Planar scratch frames per channel; larger IO buffers are processed in chunks.
    static let scratchFrames = 4096

    let kind: AudioRouteKind
    let parameters: RouteParameters.Realtime
    private let tapChannels: UnsafeMutablePointer<RouteChannel>
    private let tapCount: Int
    private let outputChannels: UnsafeMutablePointer<RouteChannel>
    private let outputCount: Int
    private let scratch: UnsafeMutablePointer<Float>
    private let gainStage: UnsafeMutablePointer<GainStage>
    /// The master route's current (ramped) gain.
    private let masterGain: UnsafeMutablePointer<Float>

    init(kind: AudioRouteKind, layout: RouteBufferLayout, sampleRate: Double, initialGain: Float, parameters: RouteParameters.Realtime) {
        self.kind = kind
        self.parameters = parameters
        tapCount = layout.tapChannels.count
        tapChannels = .allocate(capacity: max(tapCount, 1))
        tapChannels.initialize(from: layout.tapChannels, count: tapCount)
        outputCount = layout.outputChannels.count
        outputChannels = .allocate(capacity: max(outputCount, 1))
        outputChannels.initialize(from: layout.outputChannels, count: outputCount)
        scratch = .allocate(capacity: 2 * Self.scratchFrames)
        scratch.initialize(repeating: 0, count: 2 * Self.scratchFrames)
        gainStage = .allocate(capacity: 1)
        gainStage.initialize(to: GainStage(sampleRate: sampleRate, gain: initialGain))
        masterGain = .allocate(capacity: 1)
        masterGain.initialize(to: initialGain)
    }

    func deallocate() {
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

        let values = parameters.current()
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

    /// The frames every listed channel's buffer holds (0 when one is missing).
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
