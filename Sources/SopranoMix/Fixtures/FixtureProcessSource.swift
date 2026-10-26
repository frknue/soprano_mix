import Foundation
import SopranoMixCore

/// The processes of a fixture scenario as an `AudioProcessSource`; tests and the harness
/// change `processes` to simulate apps starting, stopping and starting to play.
@MainActor
final class FixtureProcessSource: AudioProcessSource {
    var processes: [AudioProcessFacts] {
        didSet { onChange?() }
    }

    var onChange: (() -> Void)?

    init(scenario: FixtureScenario) {
        processes = scenario.processes()
    }

    /// The fixture list is complete from the start; there is nothing to listen to.
    func start() {}
}
