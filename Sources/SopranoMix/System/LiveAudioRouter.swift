import CoreAudio
import Foundation
import SopranoMixCore

/// Keeps live taps, private aggregates and IOProcs equal to the last applied `RoutePlan`.
///
/// The main actor diffs plans and owns statuses and each route's `RouteParameters`
/// (gain and limiter changes apply without any HAL call). Building, updating the tap's
/// process list and destroying run on one private serial queue (`RouteWorker`); results
/// come back to the main actor in order. Only `stopAll` waits for that queue.
@MainActor
final class LiveAudioRouter: AudioRouting {
    private(set) var statuses: [AppKey: RouteStatus] = [:]
    private(set) var masterStatus: RouteStatus?
    var onStatusChange: (() -> Void)?

    private struct Entry {
        var configuration: AudioRouteConfiguration
        var parameters: RouteParameters
        /// Identifies one build; results of older builds are ignored.
        var generation: Int
        var status: RouteStatus
        var diagnostics: RouteDiagnostics?
    }

    private var entries: [RouteID: Entry] = [:]
    private var lastPlan: RoutePlan?
    private var nextGeneration = 0
    private let worker = RouteWorker()

    init() {
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

        var wanted: [(RouteID, AudioRouteConfiguration, RouteParameters.Values)] = plan.routes.map { spec in
            (
                .app(spec.key),
                AudioRouteConfiguration(
                    kind: spec.mode == .replace ? .replace : .meter,
                    name: "Soprano Mix \(spec.key.rawValue)",
                    processObjectIDs: spec.processObjectIDs,
                    outputDeviceUID: spec.outputDeviceUID,
                    bufferFrames: spec.bufferFrames
                ),
                RouteParameters.Values(gain: spec.gain, limiter: spec.limiter)
            )
        }
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

        let wantedIDs = Set(wanted.map(\.0))
        for id in entries.keys.sorted() where !wantedIDs.contains(id) {
            entries[id] = nil
            worker.remove(id)
        }

        for (id, configuration, values) in wanted {
            if var entry = entries[id], entry.configuration.isSameRoute(as: configuration), !entry.status.isFailed {
                entry.parameters.set(gain: values.gain, limiter: values.limiter)
                if entry.configuration.processObjectIDs != configuration.processObjectIDs {
                    worker.update(id, generation: entry.generation, configuration: configuration, parameters: entry.parameters)
                }
                entry.configuration = configuration
                entries[id] = entry
            } else {
                nextGeneration += 1
                let parameters = RouteParameters(gain: values.gain, limiter: values.limiter)
                entries[id] = Entry(configuration: configuration, parameters: parameters, generation: nextGeneration, status: .starting)
                worker.build(id, generation: nextGeneration, configuration: configuration, parameters: parameters)
            }
        }
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
/// `@unchecked Sendable`: `routes` is only read and written on `queue` (every method
/// hops there; `stopAll` synchronously), and `report` is set once in the router's
/// initializer before any work is queued.
private final class RouteWorker: @unchecked Sendable {
    enum Result: Sendable {
        case running(RouteDiagnostics)
        case failed(String)
    }

    private struct LiveRoute {
        var generation: Int
        /// Unique per build, so a late failure of a replaced route never hits its successor.
        var build: Int
        var route: AudioRoute
    }

    let queue = DispatchQueue(label: "com.soprano.mix.router", qos: .userInteractive)
    var report: (@Sendable (RouteID, Int, Result) -> Void)?
    private var routes: [RouteID: LiveRoute] = [:]
    private var buildCount = 0

    /// Tears down any route under `id`, then builds a new one.
    func build(_ id: RouteID, generation: Int, configuration: AudioRouteConfiguration, parameters: RouteParameters) {
        queue.async { [self] in
            rebuild(id, generation: generation, configuration: configuration, parameters: parameters)
        }
    }

    /// Changes the tap's process list in place; rebuilds when that fails or the route is
    /// not live.
    func update(_ id: RouteID, generation: Int, configuration: AudioRouteConfiguration, parameters: RouteParameters) {
        queue.async { [self] in
            if let live = routes[id], live.generation == generation,
               live.route.updateProcesses(configuration.processObjectIDs) {
                return
            }
            rebuild(id, generation: generation, configuration: configuration, parameters: parameters)
        }
    }

    func remove(_ id: RouteID) {
        queue.async { [self] in
            routes.removeValue(forKey: id)?.route.teardown()
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

    private func rebuild(_ id: RouteID, generation: Int, configuration: AudioRouteConfiguration, parameters: RouteParameters) {
        dispatchPrecondition(condition: .onQueue(queue))
        routes.removeValue(forKey: id)?.route.teardown()
        buildCount += 1
        let build = buildCount
        do {
            let route = try AudioRoute(
                configuration: configuration,
                parameters: parameters,
                queue: queue
            ) { [weak self] reason in
                // On `queue`, inside the HAL listener: leave the callback before tearing down.
                guard let self else { return }
                self.queue.async { [weak self] in
                    self?.fail(id, build: build, reason: reason)
                }
            }
            routes[id] = LiveRoute(generation: generation, build: build, route: route)
            report?(id, generation, .running(route.diagnostics))
        } catch {
            report?(id, generation, .failed(Self.reason(for: error)))
        }
    }

    private func fail(_ id: RouteID, build: Int, reason: String) {
        guard let live = routes[id], live.build == build else { return }
        live.route.teardown()
        routes[id] = nil
        report?(id, live.generation, .failed(reason))
    }

    private static func reason(for error: Error) -> String {
        if let error = error as? AudioRouteError { return error.description }
        if let error = error as? CoreAudioError { return "Core Audio error \(error)" }
        return String(describing: error)
    }
}
