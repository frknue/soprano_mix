import CoreAudio
import Foundation

/// A failed Core Audio call: the `OSStatus` and what was attempted.
struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    /// "<operation>: '<fourcc>' (<status>)"; statuses that are not four printable
    /// characters show their number in the quotes.
    var description: String {
        "\(operation): '\(Self.fourCC(status))' (\(status))"
    }

    /// "nope" for 'nope'; the decimal value when any byte is not printable ASCII.
    static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(status) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Typed access to Core Audio object properties. The only place that calls
/// `AudioObjectGetPropertyData` and friends directly.
enum CoreAudioProperties {
    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// Fixed-size POD values (UInt32, Int32, Float32, Float64, AudioObjectID, pid_t,
    /// AudioStreamBasicDescription, AudioValueRange …).
    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type = T.self) throws -> T {
        try read(object, address, qualifierSize: 0, qualifier: nil, as: type)
    }

    static func value<T, Q>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, qualifier: Q, as type: T.Type = T.self) throws -> T {
        try withUnsafePointer(to: qualifier) { qualifierPointer in
            try read(object, address, qualifierSize: UInt32(MemoryLayout<Q>.size), qualifier: UnsafeRawPointer(qualifierPointer), as: type)
        }
    }

    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of type: T.Type = T.self) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get size of '\(CoreAudioError.fourCC(OSStatus(bitPattern: address.mSelector)))'") }
        let stride = MemoryLayout<T>.stride
        guard size > 0, stride > 0 else { return [] }
        let capacity = Int(size) / stride
        guard capacity > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity * stride, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity * stride)
        size = UInt32(capacity * stride)
        status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get '\(CoreAudioError.fourCC(OSStatus(bitPattern: address.mSelector)))'") }
        let count = min(capacity, Int(size) / stride)
        return (0..<count).map { raw.load(fromByteOffset: $0 * stride, as: T.self) }
    }

    /// CFString properties (names, UIDs, bundle ids); "" stays "".
    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get '\(CoreAudioError.fourCC(OSStatus(bitPattern: address.mSelector)))'") }
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    static func setValue<T>(_ value: T, on object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws {
        var address = address
        let status = withUnsafePointer(to: value) { pointer in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer)
        }
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Set '\(CoreAudioError.fourCC(OSStatus(bitPattern: address.mSelector)))'") }
    }

    /// Channel count per scope from kAudioDevicePropertyStreamConfiguration (sum of
    /// mNumberChannels).
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        ((try? bufferChannelCounts(device, scope: scope)) ?? []).reduce(0, +)
    }

    /// The channel count of every buffer of `kAudioDevicePropertyStreamConfiguration`, in
    /// buffer order (what an IOProc's `AudioBufferList` holds in that scope).
    static func bufferChannelCounts(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get size of 'slay'") }
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get 'slay'") }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// kAudioHardwarePropertyTranslatePIDToProcessObject; nil for kAudioObjectUnknown.
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        let object = try? value(
            AudioObjectID(kAudioObjectSystemObject),
            address(kAudioHardwarePropertyTranslatePIDToProcessObject),
            qualifier: pid,
            as: AudioObjectID.self
        )
        guard let object, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// kAudioHardwarePropertyTranslateUIDToDevice; nil for kAudioObjectUnknown.
    static func device(forUID uid: String) -> AudioObjectID? {
        let object = try? value(
            AudioObjectID(kAudioObjectSystemObject),
            address(kAudioHardwarePropertyTranslateUIDToDevice),
            qualifier: uid as CFString,
            as: AudioObjectID.self
        )
        guard let object, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// AudioObjectAddPropertyListenerBlock on `queue`; the returned token removes it on
    /// `remove()` or deinit.
    static func addListener(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> CoreAudioListener? {
        var mutableAddress = address
        guard AudioObjectAddPropertyListenerBlock(object, &mutableAddress, queue, block) == noErr else { return nil }
        return CoreAudioListener(object: object, address: address, queue: queue, block: block)
    }

    private static func read<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        qualifierSize: UInt32,
        qualifier: UnsafeRawPointer?,
        as type: T.Type
    ) throws -> T {
        var address = address
        let byteCount = max(MemoryLayout<T>.size, 1)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, raw)
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "Get '\(CoreAudioError.fourCC(OSStatus(bitPattern: address.mSelector)))'")
        }
        guard size == UInt32(MemoryLayout<T>.size) else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareBadPropertySizeError), operation: "Get '\(CoreAudioError.fourCC(OSStatus(bitPattern: address.mSelector)))'")
        }
        return raw.load(as: T.self)
    }
}

/// One installed property listener. `remove()` (or deinit) unregisters the very block
/// that was added, so the HAL can match it.
final class CoreAudioListener: @unchecked Sendable {
    // @unchecked: every stored property is immutable except `isRemoved`, which is only
    // read and written under `lock`.
    private let object: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var isRemoved = false

    fileprivate init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
    }

    deinit {
        remove()
    }

    func remove() {
        lock.lock()
        let shouldRemove = !isRemoved
        isRemoved = true
        lock.unlock()
        guard shouldRemove else { return }
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
