import Darwin
import Foundation

/// What the kernel tells about another process: its executable, its argv and
/// environment. Wine (CrossOver, Whisky, plain Wine) puts the Windows path of the program
/// it runs (`C:\…\Game.exe`) in argv[0], which is how a game is told apart from the Wine
/// loader inside `CrossOver.app`.
enum ProcessInspector {
    /// `proc_pidpath`; nil when the process is gone or unreadable.
    static func executablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 × MAXPATHLEN).
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        let capacity = UInt32(buffer.count)
        let length = proc_pidpath(pid, &buffer, capacity)
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// argv and environment through `sysctl(KERN_PROCARGS2)`; nil when the kernel refuses
    /// (other users' processes, processes that already exited) or the data is malformed.
    static func arguments(pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        let argmaxCount = UInt32(argmaxMIB.count)
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argmaxMIB, argmaxCount, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else {
            return nil
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let mibCount = UInt32(mib.count)
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = buffer.count
        guard sysctl(&mib, mibCount, &buffer, &size, nil, 0) == 0, size > 0 else { return nil }
        return parseProcArgs(Data(buffer.prefix(min(size, buffer.count))))
    }

    /// Parses a `KERN_PROCARGS2` buffer: argc (Int32, host order), the executable path
    /// (NUL-terminated), NUL padding, argc NUL-terminated argv strings, then `KEY=VALUE`
    /// environment strings up to an empty string or the end. nil when the header, the
    /// executable path or argv is cut off; an environment string cut off at the end is
    /// dropped. Strings that are not `KEY=VALUE` are skipped.
    static func parseProcArgs(_ data: Data) -> (arguments: [String], environment: [String: String])? {
        let bytes = [UInt8](data)
        let headerSize = MemoryLayout<Int32>.size
        guard bytes.count >= headerSize else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var index = headerSize
        // The executable path.
        guard let pathEnd = bytes[index...].firstIndex(of: 0) else { return nil }
        index = pathEnd
        // NUL padding (the terminator included) up to argv[0].
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }

        /// The next NUL-terminated string; nil when unterminated or at the end.
        func nextString() -> String? {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0) else { return nil }
            let string = String(decoding: bytes[index ..< end], as: UTF8.self)
            index = end + 1
            return string
        }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(min(argc, 4096)))
        for _ in 0 ..< argc {
            guard let argument = nextString() else { return nil }
            arguments.append(argument)
        }

        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            let key = String(entry[..<equals])
            let value = String(entry[entry.index(after: equals)...])
            if environment[key] == nil {
                environment[key] = value
            }
        }
        return (arguments, environment)
    }

    /// The outermost `.app` bundle on `path` (the `.app` component closest to "/"):
    /// "/Applications/Steam.app/Contents/MacOS/x/Helper.app/Contents/MacOS/Helper" →
    /// "/Applications/Steam.app". nil when no component is an app bundle.
    static func outermostAppBundle(containing path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { component in
            component.count > 4 && component.lowercased().hasSuffix(".app")
        }) else { return nil }
        let bundle = components[...index].joined(separator: "/")
        return bundle.isEmpty ? nil : bundle
    }
}
