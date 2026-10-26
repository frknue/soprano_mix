import Foundation

/// Amplitude → meter position: linear in decibels between the floor and 0 dBFS.
public enum MeterScale {
    public static let floorDecibels: Double = -60

    /// 0 at or below the floor, 1 at 0 dBFS and above, linear in dB between.
    public static func position(forAmplitude amplitude: Float) -> Double {
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        let decibels = 20 * log10(Double(amplitude))
        let position = (decibels - floorDecibels) / -floorDecibels
        return min(max(position, 0), 1)
    }
}

/// Peak-meter motion: jumps up to a louder peak at once, falls at a fixed dB rate.
public struct MeterBallistics: Sendable {
    /// The fall rate in meter positions per second.
    private let fallPerSecond: Double
    private var position: Double = 0

    public init(fallDecibelsPerSecond: Double = 24) {
        let rate = fallDecibelsPerSecond.isFinite ? max(0, fallDecibelsPerSecond) : 24
        fallPerSecond = rate / -MeterScale.floorDecibels
    }

    /// Rises at once to a higher peak, falls at the given rate; returns a `MeterScale` position.
    public mutating func update(peak: Float, elapsed: TimeInterval) -> Double {
        let target = MeterScale.position(forAmplitude: peak)
        let seconds = elapsed.isFinite ? max(0, elapsed) : 0
        let fallen = max(0, position - fallPerSecond * seconds)
        position = max(target, fallen)
        return position
    }
}
