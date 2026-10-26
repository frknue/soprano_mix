import Foundation
import os
import SopranoMixCore

/// What a route's IO block reads every cycle (target gain, limiter) and what it reports
/// back (input and output peaks, max-merged until `takeLevels`), shared between the main
/// actor and the HAL's real-time IO thread.
///
/// `@unchecked Sendable`: all mutable state lives in manually allocated memory. The
/// shared part (`shared`) is only touched while holding the `os_unfair_lock` at `lock`.
/// Each IOProc keeps its own `IOState` (allocated by its renderer, touched only by that
/// IO thread), so two renderers of the same route never share unsynchronized state.
/// Non-IO callers take the lock with `os_unfair_lock_lock`; the IO thread only ever calls
/// `os_unfair_lock_trylock`, so it never waits: when the lock is busy it keeps the last
/// parameters it saw and keeps its peaks in its `IOState` until a later cycle gets the
/// lock.
final class RouteParameters: @unchecked Sendable {
    struct Values: Equatable, Sendable {
        var gain: Float
        var limiter: Bool
    }

    fileprivate struct Shared {
        var values: Values
        var input: StereoLevel
        var output: StereoLevel
    }

    /// One IO thread's private state: the parameters it saw last and peaks not yet
    /// published.
    struct IOState {
        fileprivate var values: Values
        fileprivate var pendingInput = StereoLevel.silent
        fileprivate var pendingOutput = StereoLevel.silent

        init(values: Values) {
            self.values = values
        }
    }

    /// The IO thread's view: plain pointers, no reference counting, no allocation, no
    /// blocking. Valid while the `RouteParameters` and the `IOState` are alive.
    struct Realtime: @unchecked Sendable {
        // @unchecked: raw pointers into the owner's storage and one renderer's IOState;
        // see `RouteParameters`.
        fileprivate let lock: os_unfair_lock_t
        fileprivate let shared: UnsafeMutablePointer<Shared>
        fileprivate let state: UnsafeMutablePointer<IOState>

        /// The current parameters, or the last ones this thread saw when the lock is busy.
        func current() -> Values {
            if os_unfair_lock_trylock(lock) {
                state.pointee.values = shared.pointee.values
                os_unfair_lock_unlock(lock)
            }
            return state.pointee.values
        }

        /// Merges one cycle's peaks into the shared accumulators, or keeps them (merged)
        /// when the lock is busy and publishes them with a later cycle.
        func record(input: StereoLevel, output: StereoLevel) {
            state.pointee.pendingInput = state.pointee.pendingInput.merged(with: input)
            state.pointee.pendingOutput = state.pointee.pendingOutput.merged(with: output)
            guard os_unfair_lock_trylock(lock) else { return }
            shared.pointee.input = shared.pointee.input.merged(with: state.pointee.pendingInput)
            shared.pointee.output = shared.pointee.output.merged(with: state.pointee.pendingOutput)
            os_unfair_lock_unlock(lock)
            state.pointee.pendingInput = .silent
            state.pointee.pendingOutput = .silent
        }
    }

    private let lock: os_unfair_lock_t
    private let shared: UnsafeMutablePointer<Shared>

    init(gain: Float, limiter: Bool) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        shared = .allocate(capacity: 1)
        shared.initialize(to: Shared(values: Values(gain: gain, limiter: limiter), input: .silent, output: .silent))
    }

    deinit {
        shared.deinitialize(count: 1)
        shared.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// The IO view over `state` (one per IOProc, owned by the caller).
    func realtime(state: UnsafeMutablePointer<IOState>) -> Realtime {
        Realtime(lock: lock, shared: shared, state: state)
    }

    /// The parameters the next IO cycle picks up.
    var values: Values {
        withLock { shared.pointee.values }
    }

    func set(gain: Float, limiter: Bool) {
        withLock { shared.pointee.values = Values(gain: gain, limiter: limiter) }
    }

    /// Peaks published since the last call, then reset to silence.
    func takeLevels() -> RouteLevels {
        withLock {
            let levels = RouteLevels(input: shared.pointee.input, output: shared.pointee.output)
            shared.pointee.input = .silent
            shared.pointee.output = .silent
            return levels
        }
    }

    /// Runs `body` holding the lock (blocking). Never call from the IO thread.
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try body()
    }
}

/// Silences one route instance (its IO ramps to gain 0) while a replacement is built.
/// One gate per IOProc.
///
/// `@unchecked Sendable`: `open` is only touched under the `os_unfair_lock` at `lock`;
/// `lastSeen` only by the one IO thread, which only ever uses `os_unfair_lock_trylock`
/// (busy lock: it keeps what it saw last).
final class RouteGate: @unchecked Sendable {
    struct Realtime: @unchecked Sendable {
        // @unchecked: raw pointers into the gate; see `RouteGate`.
        fileprivate let lock: os_unfair_lock_t
        fileprivate let open: UnsafeMutablePointer<Bool>
        fileprivate let lastSeen: UnsafeMutablePointer<Bool>

        func isOpen() -> Bool {
            if os_unfair_lock_trylock(lock) {
                lastSeen.pointee = open.pointee
                os_unfair_lock_unlock(lock)
            }
            return lastSeen.pointee
        }
    }

    private let lock: os_unfair_lock_t
    private let open: UnsafeMutablePointer<Bool>
    private let lastSeen: UnsafeMutablePointer<Bool>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        open = .allocate(capacity: 1)
        open.initialize(to: true)
        lastSeen = .allocate(capacity: 1)
        lastSeen.initialize(to: true)
    }

    deinit {
        lastSeen.deinitialize(count: 1)
        lastSeen.deallocate()
        open.deinitialize(count: 1)
        open.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// For the one IO block of this gate.
    var realtime: Realtime { Realtime(lock: lock, open: open, lastSeen: lastSeen) }

    func close() {
        os_unfair_lock_lock(lock)
        open.pointee = false
        os_unfair_lock_unlock(lock)
    }
}
