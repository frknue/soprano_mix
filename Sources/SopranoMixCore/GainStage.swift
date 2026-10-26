import Foundation

/// The per-route gain of the IOProc: a click-free linear gain ramp and, for boosted
/// apps, a stereo-linked peak limiter (instant attack, exponential release) that keeps
/// every output sample at or below `ceiling`.
///
/// `process` is real-time safe: it touches only the buffers it is given and its own
/// stored scalars (no allocation, no locks, no runtime calls).
public struct GainStage: Sendable {
    /// −0.3 dBFS.
    public static let ceiling: Float = Float(pow(10.0, -0.3 / 20))

    public private(set) var currentGain: Float
    /// The limiter's own gain, 0...1 (1 = not limiting).
    private var limiterGain: Float = 1
    /// Per-sample factor by which the limiter's gain reduction decays.
    private let releaseCoefficient: Float

    public init(sampleRate: Double, gain: Float, releaseSeconds: Double = 0.08) {
        currentGain = gain.isFinite ? max(0, gain) : 0
        let samples = max(1, sampleRate.isFinite ? sampleRate : 48_000) * max(0.0001, releaseSeconds.isFinite ? releaseSeconds : 0.08)
        releaseCoefficient = Float(exp(-1 / samples))
    }

    /// In place on planar stereo; real-time safe (no allocation, no locks). Ramps
    /// linearly from `currentGain` to `targetGain` over the buffer. With `limiter`, a
    /// sample whose |x × g| would exceed `ceiling` pulls the limiter gain down at once;
    /// it recovers exponentially over `releaseSeconds`; output never exceeds `ceiling`.
    /// Returns the output peaks.
    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                                 frames: Int, targetGain: Float, limiter: Bool) -> StereoLevel {
        let target = targetGain.isFinite ? max(0, targetGain) : 0
        guard frames > 0 else {
            currentGain = target
            return .silent
        }
        let start = currentGain
        let delta = target - start
        let count = Float(frames)
        let ceiling = Self.ceiling
        let release = releaseCoefficient
        var reduction = limiter ? limiterGain : 1
        var peakLeft: Float = 0
        var peakRight: Float = 0

        for index in 0..<frames {
            // The last frame lands exactly on the target, so the next buffer starts there.
            let gain = index == frames - 1 ? target : start + delta * (Float(index + 1) / count)
            var outLeft = left[index] * gain
            var outRight = right[index] * gain
            if !outLeft.isFinite { outLeft = 0 }
            if !outRight.isFinite { outRight = 0 }

            if limiter {
                reduction = 1 - (1 - reduction) * release
                let peak = max(abs(outLeft), abs(outRight))
                if peak * reduction > ceiling {
                    reduction = ceiling / peak
                }
                outLeft *= reduction
                outRight *= reduction
                // Rounding in the division above may leave one ulp too much.
                if outLeft > ceiling { outLeft = ceiling } else if outLeft < -ceiling { outLeft = -ceiling }
                if outRight > ceiling { outRight = ceiling } else if outRight < -ceiling { outRight = -ceiling }
            }

            left[index] = outLeft
            right[index] = outRight
            let magnitudeLeft = abs(outLeft)
            let magnitudeRight = abs(outRight)
            if magnitudeLeft > peakLeft { peakLeft = magnitudeLeft }
            if magnitudeRight > peakRight { peakRight = magnitudeRight }
        }

        currentGain = target
        limiterGain = reduction
        return StereoLevel(left: peakLeft, right: peakRight)
    }

    /// The input peaks of a planar stereo buffer (for meters before gain).
    public static func peaks(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> StereoLevel {
        guard frames > 0 else { return .silent }
        var peakLeft: Float = 0
        var peakRight: Float = 0
        for index in 0..<frames {
            let magnitudeLeft = abs(left[index])
            let magnitudeRight = abs(right[index])
            if magnitudeLeft > peakLeft { peakLeft = magnitudeLeft }
            if magnitudeRight > peakRight { peakRight = magnitudeRight }
        }
        return StereoLevel(left: peakLeft, right: peakRight)
    }
}
