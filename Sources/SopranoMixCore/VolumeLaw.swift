import Foundation

/// Percent ↔ gain for app and output volumes, and the volume-key grid.
public enum VolumeLaw {
    /// App volumes in percent; 100 leaves the app unchanged, above boosts.
    public static let appRange: ClosedRange<Double> = 0...400
    /// Software output volumes in percent.
    public static let outputRange: ClosedRange<Double> = 0...100

    /// log2(10) / 2: doubling the percent adds 10 dB.
    private static let exponent = log2(10.0) / 2

    /// Volume-key steps across `outputRange`, like macOS (quarter steps with `fine`).
    private static let coarseSteps = 16.0
    private static let fineSteps = 64.0

    /// Loudness-proportional: 50 % sounds half as loud (−10 dB), 200 % twice (+10 dB),
    /// 400 % +20 dB. gain = (percent / 100) ^ (log2(10) / 2); 0 → 0.
    public static func gain(percent: Double) -> Float {
        guard percent.isFinite, percent > 0 else { return 0 }
        return Float(pow(percent / 100, exponent))
    }

    /// nil at 0.
    public static func decibels(percent: Double) -> Double? {
        guard percent.isFinite, percent > 0 else { return nil }
        return 20 * exponent * log10(percent / 100)
    }

    /// "60 %", "0 %", "250 %" (rounded).
    public static func text(percent: Double) -> String {
        let value = percent.isFinite ? percent.rounded() : 0
        return "\(Int(value)) %"
    }

    /// One volume-key step on the 16-step grid (64 with `fine`), snapping to the grid
    /// first, clamped to `outputRange`.
    public static func step(_ percent: Double, up: Bool, fine: Bool) -> Double {
        let span = outputRange.upperBound - outputRange.lowerBound
        let size = span / (fine ? fineSteps : coarseSteps)
        let current = percent.isFinite ? percent : outputRange.lowerBound
        let snapped = ((current - outputRange.lowerBound) / size).rounded() * size + outputRange.lowerBound
        let moved = snapped + (up ? size : -size)
        return min(max(moved, outputRange.lowerBound), outputRange.upperBound)
    }
}
