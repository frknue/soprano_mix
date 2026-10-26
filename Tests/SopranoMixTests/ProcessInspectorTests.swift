import AppKit
import Testing
@testable import SopranoMix

struct ProcessInspectorTests {
    /// A synthetic `KERN_PROCARGS2` buffer: argc, the executable path, NUL padding to an
    /// 8-byte boundary, argv, environment, and an optional raw tail.
    private func procArgs(
        executable: String,
        arguments: [String],
        argc: Int32? = nil,
        environment: [String] = [],
        terminateEnvironment: Bool = true
    ) -> Data {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: argc ?? Int32(arguments.count)) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(executable.utf8))
        bytes.append(0)
        while bytes.count % 8 != 0 { bytes.append(0) }
        bytes.append(contentsOf: [0, 0, 0, 0])
        for argument in arguments {
            bytes.append(contentsOf: Array(argument.utf8))
            bytes.append(0)
        }
        for entry in environment {
            bytes.append(contentsOf: Array(entry.utf8))
            bytes.append(0)
        }
        if terminateEnvironment { bytes.append(0) }
        return Data(bytes)
    }

    @Test("a Wine process yields its Windows argv0 and its WINEPREFIX")
    func wineProcess() throws {
        let gamePath = #"C:\Program Files (x86)\Steam\steamapps\common\TEKKEN 8\Polaris\Binaries\Win64\Polaris-Win64-Shipping.exe"#
        let prefix = "/Users/me/Library/Application Support/CrossOver/Bottles/Steam"
        let data = procArgs(
            executable: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine",
            arguments: [gamePath, "-dx12"],
            environment: ["WINEPREFIX=\(prefix)", "CX_BOTTLE=Steam", "PATH=/usr/bin:/bin"]
        )
        let parsed = try #require(ProcessInspector.parseProcArgs(data))
        #expect(parsed.arguments == [gamePath, "-dx12"])
        #expect(parsed.environment["WINEPREFIX"] == prefix)
        #expect(parsed.environment["CX_BOTTLE"] == "Steam")
        #expect(parsed.environment["PATH"] == "/usr/bin:/bin")
    }

    @Test("an environment value keeps every equals sign after the first")
    func valueWithEquals() throws {
        let data = procArgs(executable: "/bin/x", arguments: ["x"], environment: ["OPTS=a=b=c"])
        let parsed = try #require(ProcessInspector.parseProcArgs(data))
        #expect(parsed.environment["OPTS"] == "a=b=c")
    }

    @Test("a process without environment gives its arguments and an empty environment")
    func noEnvironment() throws {
        let data = procArgs(executable: "/usr/bin/afplay", arguments: ["afplay", "/tmp/tone.wav"], terminateEnvironment: false)
        let parsed = try #require(ProcessInspector.parseProcArgs(data))
        #expect(parsed.arguments == ["afplay", "/tmp/tone.wav"])
        #expect(parsed.environment.isEmpty)
    }

    @Test("the environment stops at the first empty string")
    func environmentEndsAtEmptyString() throws {
        var data = procArgs(executable: "/bin/x", arguments: ["x"], environment: ["A=1"])
        data.append(contentsOf: Array("executable_path=/bin/x".utf8) + [0])
        let parsed = try #require(ProcessInspector.parseProcArgs(data))
        #expect(parsed.environment == ["A": "1"])
    }

    @Test("an environment string cut off at the end is dropped")
    func truncatedEnvironment() throws {
        var data = procArgs(executable: "/bin/x", arguments: ["x"], environment: ["A=1"], terminateEnvironment: false)
        data.append(contentsOf: Array("WINEPREFIX=/Users/me/.wi".utf8))
        let parsed = try #require(ProcessInspector.parseProcArgs(data))
        #expect(parsed.arguments == ["x"])
        #expect(parsed.environment == ["A": "1"])
    }

    @Test("argv cut off before argc strings gives nil")
    func truncatedArguments() {
        let data = procArgs(executable: "/bin/x", arguments: ["x"], argc: 3, terminateEnvironment: false)
        #expect(ProcessInspector.parseProcArgs(data) == nil)
    }

    @Test("a buffer shorter than the argc header or without a terminated path gives nil")
    func truncatedHeader() {
        #expect(ProcessInspector.parseProcArgs(Data([1, 0])) == nil)
        var unterminated = Data()
        withUnsafeBytes(of: Int32(1)) { unterminated.append(contentsOf: $0) }
        unterminated.append(contentsOf: Array("/Applications/CrossOver.app/Cont".utf8))
        #expect(ProcessInspector.parseProcArgs(unterminated) == nil)
    }

    @Test("a negative argc gives nil")
    func negativeArgc() {
        let data = procArgs(executable: "/bin/x", arguments: ["x"], argc: -1)
        #expect(ProcessInspector.parseProcArgs(data) == nil)
    }

    @Test("the outermost app bundle is the .app closest to the root")
    func outermostAppBundle() {
        #expect(
            ProcessInspector.outermostAppBundle(
                containing: "/Applications/Steam.app/Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/Steam Helper"
            ) == "/Applications/Steam.app"
        )
        #expect(ProcessInspector.outermostAppBundle(containing: "/Applications/Safari.app") == "/Applications/Safari.app")
        #expect(
            ProcessInspector.outermostAppBundle(containing: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU")
                == nil
        )
        #expect(ProcessInspector.outermostAppBundle(containing: "/usr/bin/afplay") == nil)
        #expect(ProcessInspector.outermostAppBundle(containing: "/opt/.app/bin/tool") == nil)
    }
}
