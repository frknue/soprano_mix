import Foundation
import SopranoMixCore

/// A router that builds nothing: it records every applied plan, reports every planned
/// route (and the master) as running at once, and hands out `levels` as the peaks.
@MainActor
final class RecordingRouter: AudioRouting {
    /// Every plan `apply` got, in order.
    private(set) var applied: [RoutePlan] = []
    /// What `takeLevels` returns (the harness's `--levels`, the tests' meters).
    var levels: [AppKey: RouteLevels] = [:]
    private(set) var statuses: [AppKey: RouteStatus] = [:]
    private(set) var masterStatus: RouteStatus?
    var onStatusChange: (() -> Void)?
    private(set) var stopAllCount = 0

    init() {}

    func apply(_ plan: RoutePlan) {
        applied.append(plan)
        let nextStatuses = Dictionary(uniqueKeysWithValues: plan.routes.map { ($0.key, RouteStatus.running) })
        let nextMaster: RouteStatus? = plan.master == nil ? nil : .running
        guard nextStatuses != statuses || nextMaster != masterStatus else { return }
        statuses = nextStatuses
        masterStatus = nextMaster
        onStatusChange?()
    }

    func takeLevels() -> [AppKey: RouteLevels] {
        levels
    }

    func stopAll() {
        stopAllCount += 1
        guard !statuses.isEmpty || masterStatus != nil else { return }
        statuses = [:]
        masterStatus = nil
        onStatusChange?()
    }
}
