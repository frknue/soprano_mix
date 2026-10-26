import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

struct RouteParametersTests {
    @Test func theIOThreadStartsWithTheInitialGainAndLimiter() {
        let parameters = RouteParameters(gain: 0.25, limiter: true)
        #expect(parameters.realtime.current() == RouteParameters.Values(gain: 0.25, limiter: true))
    }

    @Test func aNewGainReachesTheNextIOCycle() {
        let parameters = RouteParameters(gain: 1, limiter: false)
        parameters.set(gain: 2.5, limiter: true)
        #expect(parameters.values == RouteParameters.Values(gain: 2.5, limiter: true))
        #expect(parameters.realtime.current() == RouteParameters.Values(gain: 2.5, limiter: true))
    }

    @Test func peaksMergeChannelByChannelUntilRead() {
        let parameters = RouteParameters(gain: 1, limiter: false)
        let realtime = parameters.realtime
        realtime.record(input: StereoLevel(left: 0.2, right: 0.6), output: StereoLevel(left: 0.1, right: 0.3))
        realtime.record(input: StereoLevel(left: 0.5, right: 0.1), output: StereoLevel(left: 0.4, right: 0.05))
        #expect(parameters.takeLevels() == RouteLevels(
            input: StereoLevel(left: 0.5, right: 0.6),
            output: StereoLevel(left: 0.4, right: 0.3)
        ))
    }

    @Test func readingLevelsResetsThemToSilence() {
        let parameters = RouteParameters(gain: 1, limiter: false)
        parameters.realtime.record(input: StereoLevel(left: 0.7, right: 0.7), output: StereoLevel(left: 0.35, right: 0.35))
        _ = parameters.takeLevels()
        #expect(parameters.takeLevels() == .silent)
    }

    @Test func theIOThreadKeepsTheLastParametersItSawWhileTheLockIsBusy() {
        let parameters = RouteParameters(gain: 1, limiter: false)
        let realtime = parameters.realtime
        _ = realtime.current()
        parameters.set(gain: 0.5, limiter: true)
        let whileBusy = parameters.withLock { realtime.current() }
        #expect(whileBusy == RouteParameters.Values(gain: 1, limiter: false))
        #expect(realtime.current() == RouteParameters.Values(gain: 0.5, limiter: true))
    }

    @Test func peaksRecordedWhileTheLockIsBusyArePublishedWithTheNextCycle() {
        let parameters = RouteParameters(gain: 1, limiter: false)
        let realtime = parameters.realtime
        parameters.withLock {
            realtime.record(input: StereoLevel(left: 0.9, right: 0.8), output: StereoLevel(left: 0.45, right: 0.4))
        }
        #expect(parameters.takeLevels() == .silent)

        realtime.record(input: StereoLevel(left: 0.1, right: 0.1), output: StereoLevel(left: 0.05, right: 0.05))
        #expect(parameters.takeLevels() == RouteLevels(
            input: StereoLevel(left: 0.9, right: 0.8),
            output: StereoLevel(left: 0.45, right: 0.4)
        ))
        #expect(parameters.takeLevels() == .silent)
    }
}
