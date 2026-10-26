import Foundation
import os

/// The sound-effects (alert) volume, 0...100, through Standard Additions' `volume
/// settings`: macOS has no public API for it. Failures read as nil and are logged.
enum AlertVolume {
    private static let logger = Logger(subsystem: "com.soprano.mix", category: "alert-volume")

    static func get() -> Double? {
        guard let result = run("alert volume of (get volume settings)"),
              let text = result.stringValue,
              let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return min(max(value, 0), 100)
    }

    static func set(_ percent: Double) {
        guard percent.isFinite else { return }
        let value = Int(min(max(percent, 0), 100).rounded())
        _ = run("set volume alert volume \(value)")
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else {
            logger.error("could not compile \(source, privacy: .public)")
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            logger.error("\(source, privacy: .public) failed: \(error.description, privacy: .public)")
            return nil
        }
        return result
    }
}
