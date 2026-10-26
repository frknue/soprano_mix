import AppKit
import Testing
@testable import SopranoMixCore

struct MeterBallisticsTests {
    @Test("the scale is 0 at the floor, 1 at full scale and linear in dB between")
    func scale() {
        #expect(MeterScale.floorDecibels == -60)
        #expect(MeterScale.position(forAmplitude: 0) == 0)
        #expect(MeterScale.position(forAmplitude: 0.0001) == 0)
        #expect(MeterScale.position(forAmplitude: 1) == 1)
        #expect(MeterScale.position(forAmplitude: 2) == 1)
        #expect(abs(MeterScale.position(forAmplitude: 0.001) - 0) < 1e-6)
        #expect(abs(MeterScale.position(forAmplitude: 0.031_622_78) - 0.5) < 1e-4)
        #expect(MeterScale.position(forAmplitude: .nan) == 0)
    }

    @Test("a louder peak shows at once")
    func risesInstantly() {
        var meter = MeterBallistics()
        #expect(meter.update(peak: 1, elapsed: 0.033) == 1)
    }

    @Test("a quieter peak falls at the configured rate until it meets the signal")
    func fallsAtRate() {
        var meter = MeterBallistics(fallDecibelsPerSecond: 24)
        _ = meter.update(peak: 1, elapsed: 0)
        // 24 dB/s over 0.5 s is 12 dB of a 60 dB scale.
        #expect(abs(meter.update(peak: 0, elapsed: 0.5) - 0.8) < 1e-9)
        #expect(abs(meter.update(peak: 0, elapsed: 0.5) - 0.6) < 1e-9)
        // A peak at -30 dBFS (0.5) holds the meter there.
        #expect(abs(meter.update(peak: 0.031_622_78, elapsed: 1) - 0.5) < 1e-4)
        #expect(meter.update(peak: 0, elapsed: 10) == 0)
    }
}
