import Foundation
import os
import SopranoMixCore

/// What one route's IO block reads every cycle (target gain, limiter) and what it reports
/// back (input and output peaks, max-merged until `takeLevels`), shared between the main
/// actor and the HAL's real-time IO thread.
///
/// `@unchecked Sendable`: all mutable state lives in manually allocated memory. The
/// shared part (`shared`) is only touched while holding the `os_unfair_lock` at `lock`;
/// the IO thread's private part (`local`) is only touched by the IO thread through
/// `realtime`, never by anyone else. Non-IO callers take the lock with
/// `os_unfair_lock_lock`; the IO thread only ever calls `os_unfair_lock_trylock`, so it
/// never waits: when the lock is busy it keeps the last parameters it saw and keeps its
/// peaks locally until a later cycle gets the lock.
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

    fileprivate struct Local {
        var values: Values
        var pendingInput: StereoLevel
        var pendingOutput: StereoLevel
    }

    /// The IO thread's view: plain pointers, no reference counting, no allocation, no
    /// blocking. Valid while the `RouteParameters` it came from is alive.
    struct Realtime: @unchecked Sendable {
        // @unchecked: raw pointers into the owner's storage; see `RouteParameters`.
        fileprivate let lock: os_unfair_lock_t
        fileprivate let shared: UnsafeMutablePointer<Shared>
        fileprivate let local: UnsafeMutablePointer<Local>

        /// The current parameters, or the last ones this thread saw when the lock is busy.
        func current() -> Values {
            if os_unfair_lock_trylock(lock) {
                local.pointee.values = shared.pointee.values
                os_unfair_lock_unlock(lock)
            }
            return local.pointee.values
        }

        /// Merges one cycle's peaks into the shared accumulators, or keeps them locally
        /// (merged) when the lock is busy and publishes them with a later cycle.
        func record(input: StereoLevel, output: StereoLevel) {
            local.pointee.pendingInput = local.pointee.pendingInput.merged(with: input)
            local.pointee.pendingOutput = local.pointee.pendingOutput.merged(with: output)
            guard os_unfair_lock_trylock(lock) else { return }
            shared.pointee.input = shared.pointee.input.merged(with: local.pointee.pendingInput)
            shared.pointee.output = shared.pointee.output.merged(with: local.pointee.pendingOutput)
            os_unfair_lock_unlock(lock)
            local.pointee.pendingInput = .silent
            local.pointee.pendingOutput = .silent
        }
    }

    private let lock: os_unfair_lock_t
    private let shared: UnsafeMutablePointer<Shared>
    private let local: UnsafeMutablePointer<Local>

    init(gain: Float, limiter: Bool) {
        let values = Values(gain: gain, limiter: limiter)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        shared = .allocate(capacity: 1)
        shared.initialize(to: Shared(values: values, input: .silent, output: .silent))
        local = .allocate(capacity: 1)
        local.initialize(to: Local(values: values, pendingInput: .silent, pendingOutput: .silent))
    }

    deinit {
        local.deinitialize(count: 1)
        local.deallocate()
        shared.deinitialize(count: 1)
        shared.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// For the IO block only.
    var realtime: Realtime { Realtime(lock: lock, shared: shared, local: local) }

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
