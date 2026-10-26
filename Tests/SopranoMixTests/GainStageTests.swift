import AppKit
import Testing
@testable import SopranoMixCore

struct GainStageTests {
    private let sampleRate = 48_000.0

    /// Runs `stage` over planar copies of `left`/`right`; returns the processed buffers and peaks.
    private func run(
        _ stage: inout GainStage,
        left: [Float],
        right: [Float]? = nil,
        target: Float,
        limiter: Bool
    ) -> (left: [Float], right: [Float], level: StereoLevel) {
        var outLeft = left
        var outRight = right ?? left
        let frames = outLeft.count
        let level = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                stage.process(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!,
                              frames: frames, targetGain: target, limiter: limiter)
            }
        }
        return (outLeft, outRight, level)
    }

    private func sine(frames: Int, amplitude: Float, frequency: Double = 440, offset: Int = 0) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0 + offset) / sampleRate)) }
    }

    @Test("the ramp starts near the current gain and ends exactly on the target")
    func rampEndpoints() {
        var stage = GainStage(sampleRate: sampleRate, gain: 0)
        let ones = [Float](repeating: 1, count: 256)
        let result = run(&stage, left: ones, target: 1, limiter: false)
        #expect(result.left.first.map { $0 > 0 && $0 <= 1.0 / 256 + 1e-6 } == true)
        #expect(result.left.last == 1)
        #expect(zip(result.left, result.left.dropFirst()).allSatisfy { $0 < $1 })
        #expect(stage.currentGain == 1)

        // The next buffer continues at the target, flat.
        let steady = run(&stage, left: [Float](repeating: 0.5, count: 64), target: 1, limiter: false)
        #expect(steady.left.allSatisfy { $0 == 0.5 })
        #expect(steady.level == StereoLevel(left: 0.5, right: 0.5))
    }

    @Test("zero gain produces silence")
    func zeroGainSilence() {
        var stage = GainStage(sampleRate: sampleRate, gain: 0)
        let result = run(&stage, left: sine(frames: 512, amplitude: 1), target: 0, limiter: true)
        #expect(result.left.allSatisfy { $0 == 0 })
        #expect(result.right.allSatisfy { $0 == 0 })
        #expect(result.level == .silent)
    }

    @Test("a 4x boost of a full-scale sine never exceeds the ceiling with the limiter")
    func limiterCeiling() {
        var stage = GainStage(sampleRate: sampleRate, gain: 4)
        var peak: Float = 0
        for block in 0..<20 {
            let input = sine(frames: 256, amplitude: 1, offset: block * 256)
            let result = run(&stage, left: input, right: input.map { -$0 }, target: 4, limiter: true)
            #expect(result.left.allSatisfy { abs($0) <= GainStage.ceiling })
            #expect(result.right.allSatisfy { abs($0) <= GainStage.ceiling })
            peak = max(peak, result.level.peak)
        }
        #expect(peak <= GainStage.ceiling)
        #expect(peak > GainStage.ceiling * 0.9)
        #expect(abs(GainStage.ceiling - 0.966_05) < 1e-4)
    }

    @Test("without the limiter a boost passes through unlimited")
    func noLimiter() {
        var stage = GainStage(sampleRate: sampleRate, gain: 4)
        let result = run(&stage, left: [Float](repeating: 0.5, count: 32), target: 4, limiter: false)
        #expect(result.left.allSatisfy { $0 == 2 })
    }

    @Test("the limiter releases back to unity gain after a loud burst")
    func releaseRecovery() {
        var stage = GainStage(sampleRate: sampleRate, gain: 1, releaseSeconds: 0.08)
        _ = run(&stage, left: [Float](repeating: 4, count: 64), target: 1, limiter: true)

        let quiet = [Float](repeating: 0.1, count: 256)
        let first = run(&stage, left: quiet, target: 1, limiter: true)
        #expect(first.left[0] < 0.05)

        var last = first
        for _ in 0..<(48_000 / 256) { // one second
            last = run(&stage, left: quiet, target: 1, limiter: true)
        }
        #expect(abs(last.left[255] - 0.1) < 1e-4)
        #expect(last.left[255] > first.left[255])
    }

    @Test("input peaks are the loudest magnitude per channel")
    func inputPeaks() {
        let left: [Float] = [0.1, -0.7, 0.3]
        let right: [Float] = [0.2, 0.25, -0.05]
        let level = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                GainStage.peaks(left: l.baseAddress!, right: r.baseAddress!, frames: 3)
            }
        }
        #expect(level == StereoLevel(left: 0.7, right: 0.25))
    }
}
