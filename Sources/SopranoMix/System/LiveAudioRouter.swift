import CoreAudio
import Foundation
import SopranoMixCore

/// Keeps live taps, private aggregates and IOProcs equal to the last applied `RoutePlan`.
///
/// The main actor diffs plans and owns statuses and each route's `RouteParameters`
/// (gain and limiter changes apply without any HAL call). Building, updating the tap's
/// process list and destroying run on one private serial queue (`RouteWorker`), one plan
/// per queue turn; results come back to the main actor in order. Only `stopAll` waits
/// for that queue.
@MainActor
final class LiveAudioRouter: AudioRouting {
    private(set) var statuses: [AppKey: RouteStatus] = [:]
    private(set) var masterStatus: RouteStatus?
    var onStatusChange: (() -> Void)?

    private struct Entry {
        var configuration: AudioRouteConfiguration
        var parameters: RouteParameters
        /// Identifies one build request; results of older ones are ignored.
        var generation: Int
        var status: RouteStatus
        var diagnostics: RouteDiagnostics?
        /// `now()` of the last build (or worker rebuild) of this route.
        var lastAttempt: TimeInterval
    }

    /// A failed route with an unchanged configuration is retried on a plan change only
    /// this long after its last build attempt.
    static let retryInterval: TimeInterval = 2

    private var entries: [RouteID: Entry] = [:]
    private var lastPlan: RoutePlan?
    private var nextGeneration = 0
    private let worker = RouteWorker()
    private let now: () -> TimeInterval

    /// `now` is a monotonic clock in seconds (injectable for tests).
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        worker.report = { [weak self] id, generation, result in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.receive(id: id, generation: generation, result: result)
                }
            }
        }
    }

    func apply(_ plan: RoutePlan) {
        guard plan != lastPlan else { return }
        lastPlan = plan

        var wanted: [(RouteID, AudioRouteConfiguration, RouteParameters.Values)] = []
        if let master = plan.master {
            wanted.append((
                .master,
                AudioRouteConfiguration(
                    kind: .master,
                    name: "Soprano Mix master",
                    processObjectIDs: master.excludedProcessObjectIDs,
                    outputDeviceUID: master.outputDeviceUID,
                    bufferFrames: master.bufferFrames
                ),
                RouteParameters.Values(gain: master.gain, limiter: false)
            ))
        }
        for spec in plan.routes {
            wanted.append((
                .app(spec.key),
                AudioRouteConfiguration(
                    kind: spec.mode == .replace ? .replace : .meter,
                    name: "Soprano Mix \(spec.key.rawValue)",
                    processObjectIDs: spec.processObjectIDs,
                    outputDeviceUID: spec.outputDeviceUID,
                    bufferFrames: spec.bufferFrames
                ),
                RouteParameters.Values(gain: spec.gain, limiter: spec.limiter)
            ))
        }

        // One queue turn, in this order: master builds and exclusion shrinks (processes
        // whose app route goes away fall back to the master before their taps are
        // destroyed), removals, app builds and updates, master exclusion growth (new app
        // routes exist before the master stops covering their processes).
        var masterFirst: [RouteWorker.Operation] = []
        var removals: [RouteWorker.Operation] = []
        var appOperations: [RouteWorker.Operation] = []
        var masterLast: [RouteWorker.Operation] = []

        let wantedIDs = Set(wanted.map(\.0))
        for id in entries.keys.sorted() where !wantedIDs.contains(id) {
            entries[id] = nil
            removals.append(.remove(id))
        }

        let time = now()
        for (id, configuration, values) in wanted {
            if var entry = entries[id], entry.configuration.isSameRoute(as: configuration),
               !entry.status.isFailed
               || (entry.configuration == configuration && time - entry.lastAttempt < Self.retryInterval) {
                // Same route: new gain and limiter at once. A failed route stays failed
                // until its configuration changes or the retry interval has passed.
                entry.parameters.set(gain: values.gain, limiter: values.limiter)
                if !entry.status.isFailed, entry.configuration.processObjectIDs != configuration.processObjectIDs {
                    let update = { (processes: [AudioObjectID]) -> RouteWorker.Operation in
                        var step = configuration
                        step.processObjectIDs = processes
                        return .update(id, generation: entry.generation, configuration: step, parameters: entry.parameters)
                    }
                    if id == .master {
                        let old = Set(entry.configuration.processObjectIDs)
                        let new = Set(configuration.processObjectIDs)
                        let kept = old.intersection(new)
                        let shrinks = kept != old
                        let grows = kept != new
                        if shrinks, grows {
                            masterFirst.append(update(kept.sorted()))
                            masterLast.append(update(configuration.processObjectIDs))
                        } else if grows {
                            masterLast.append(update(configuration.processObjectIDs))
                        } else {
                            masterFirst.append(update(configuration.processObjectIDs))
                        }
                    } else {
                        appOperations.append(update(configuration.processObjectIDs))
                    }
                }
                entry.configuration = configuration
                entries[id] = entry
            } else {
                nextGeneration += 1
                let parameters = RouteParameters(gain: values.gain, limiter: values.limiter)
                entries[id] = Entry(
                    configuration: configuration,
                    parameters: parameters,
                    generation: nextGeneration,
                    status: .starting,
                    lastAttempt: time
                )
                let build = RouteWorker.Operation.build(id, generation: nextGeneration, configuration: configuration, parameters: parameters)
                if id == .master {
                    masterFirst.append(build)
                } else {
                    appOperations.append(build)
                }
            }
        }

        worker.perform(masterFirst + removals + appOperations + masterLast)
        publish()
    }

    func takeLevels() -> [AppKey: RouteLevels] {
        var levels: [AppKey: RouteLevels] = [:]
        for (id, entry) in entries {
            if case .app(let key) = id {
                levels[key] = entry.parameters.takeLevels()
            }
        }
        return levels
    }

    func stopAll() {
        entries = [:]
        lastPlan = nil
        worker.stopAll()
        publish()
    }

    /// Timing of a running app route (for `selftest`); nil until it runs.
    func diagnostics(for key: AppKey) -> RouteDiagnostics? {
        entries[.app(key)]?.diagnostics
    }

    private func receive(id: RouteID, generation: Int, result: RouteWorker.Result) {
        guard var entry = entries[id], entry.generation == generation else { return }
        switch result {
        case .starting:
            entry.status = .starting
            entry.diagnostics = nil
            entry.lastAttempt = now()
        case .running(let diagnostics):
            entry.status = .running
            entry.diagnostics = diagnostics
        case .failed(let reason):
            entry.status = .failed(reason)
            entry.diagnostics = nil
        }
        entries[id] = entry
        publish()
    }

    private func publish() {
        var newStatuses: [AppKey: RouteStatus] = [:]
        var newMaster: RouteStatus?
        for (id, entry) in entries {
            switch id {
            case .app(let key): newStatuses[key] = entry.status
            case .master: newMaster = entry.status
            }
        }
        guard newStatuses != statuses || newMaster != masterStatus else { return }
        statuses = newStatuses
        masterStatus = newMaster
        onStatusChange?()
    }
}

/// One live route's identity in the router.
enum RouteID: Hashable, Comparable, Sendable {
    case app(AppKey)
    case master

    static func < (lhs: RouteID, rhs: RouteID) -> Bool {
        switch (lhs, rhs) {
        case let (.app(left), .app(right)): left < right
        case (.app, .master): true
        case (.master, _): false
        }
    }
}

private extension RouteStatus {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The router's serial queue and the routes living on it.
///
/// `@unchecked Sendable`: `routes` and `buildCount` are only read and written on `queue`
/// (every method hops there; `stopAll` synchronously), and `report` is set once in the
/// router's initializer before any work is queued.
private final class RouteWorker: @unchecked Sendable {
    enum Result: Sendable {
        /// A live route is being rebuilt (its streams changed or an in-place update failed).
        case starting
        case running(RouteDiagnostics)
        case failed(String)
    }

    enum Operation: Sendable {
        /// Replaces any route under the id with a new one.
        case build(RouteID, generation: Int, configuration: AudioRouteConfiguration, parameters: RouteParameters)
        /// Changes the tap's process list in place; rebuilds when that fails.
        case update(RouteID, generation: Int, configuration: AudioRouteConfiguration, parameters: RouteParameters)
        case remove(RouteID)
    }

    private struct LiveRoute {
        var generation: Int
        /// Unique per build, so a late event of a replaced route never hits its successor.
        var build: Int
        var route: AudioRoute
    }

    let queue = DispatchQueue(label: "com.soprano.mix.router", qos: .userInteractive)
    var report: (@Sendable (RouteID, Int, Result) -> Void)?
    private var routes: [RouteID: LiveRoute] = [:]
    private var buildCount = 0

    /// Runs `operations` in order, in one queue turn.
    func perform(_ operations: [Operation]) {
        guard !operations.isEmpty else { return }
        queue.async { [self] in
            for operation in operations {
                switch operation {
                case let .build(id, generation, configuration, parameters):
                    replace(id, generation: generation, configuration: configuration, parameters: parameters)
                case let .update(id, generation, configuration, parameters):
                    if let live = routes[id], live.generation == generation,
                       live.route.updateProcesses(configuration.processObjectIDs) {
                        continue
                    }
                    report?(id, generation, .starting)
                    replace(id, generation: generation, configuration: configuration, parameters: parameters)
                case let .remove(id):
                    routes.removeValue(forKey: id)?.route.teardown()
                }
            }
        }
    }

    /// Waits for queued work, then tears down every route.
    func stopAll() {
        queue.sync {
            for id in routes.keys.sorted() {
                routes[id]?.route.teardown()
            }
            routes = [:]
        }
    }

    /// Silences the live route under `id` (if any), builds and starts the new one, then
    /// tears the old one down: the app is never heard unprocessed in between.
    private func replace(_ id: RouteID, generation: Int, configuration: AudioRouteConfiguration, parameters: RouteParameters) {
        dispatchPrecondition(condition: .onQueue(queue))
        let old = routes.removeValue(forKey: id)
        old?.route.silence()
        buildCount += 1
        let build = buildCount
        do {
            let route = try AudioRoute(
                configuration: configuration,
                parameters: parameters,
                queue: queue
            ) { [weak self] event in
                // On `queue`, inside the HAL listener: leave the callback first.
                guard let self else { return }
                self.queue.async { [weak self] in
                    self?.handle(event, id: id, build: build)
                }
            }
            routes[id] = LiveRoute(generation: generation, build: build, route: route)
            old?.route.teardown()
            report?(id, generation, .running(route.diagnostics))
        } catch {
            old?.route.teardown()
            report?(id, generation, .failed(Self.reason(for: error)))
        }
    }

    private func handle(_ event: AudioRouteEvent, id: RouteID, build: Int) {
        guard let live = routes[id], live.build == build else { return }
        switch event {
        case .deviceGone:
            live.route.teardown()
            routes[id] = nil
            report?(id, live.generation, .failed(AudioRouteError.deviceMissing.description))
        case .layoutChanged:
            report?(id, live.generation, .starting)
            replace(id, generation: live.generation, configuration: live.route.configuration, parameters: live.route.parameters)
        }
    }

    private static func reason(for error: Error) -> String {
        if let error = error as? AudioRouteError { return error.description }
        if let error = error as? CoreAudioError { return "Core Audio error \(error)" }
        return String(describing: error)
    }
}
