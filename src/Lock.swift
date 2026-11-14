// A lock, and running work on every core, with nothing beyond the system and
// Dispatch.

import Dispatch
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// A lock for state that several threads share.
final class Lock: @unchecked Sendable {
    #if os(Windows)
    private let lock = UnsafeMutablePointer<SRWLOCK>.allocate(capacity: 1)
    #else
    private let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    #endif

    init() {
        #if os(Windows)
        InitializeSRWLock(lock)
        #else
        let status = pthread_mutex_init(lock, nil)
        precondition(status == 0, "pthread_mutex_init gave \(status)")
        #endif
    }

    deinit {
        #if !os(Windows)
        pthread_mutex_destroy(lock)
        #endif
        lock.deallocate()
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        #if os(Windows)
        AcquireSRWLockExclusive(lock)
        defer { ReleaseSRWLockExclusive(lock) }
        #else
        pthread_mutex_lock(lock)
        defer { pthread_mutex_unlock(lock) }
        #endif
        return try body()
    }
}

/// State that several threads share, behind a lock.
final class Shared<State>: @unchecked Sendable {
    private let lock = Lock()
    private var state: State

    init(_ state: State) {
        self.state = state
    }

    func with<T>(_ body: (inout State) throws -> T) rethrows -> T {
        try lock.withLock { try body(&state) }
    }
}

/// How many processors this program may run on at once.
func processorCount() -> Int {
    #if os(Windows)
    // Every processor group, not only the one this thread is in.
    return max(1, Int(GetActiveProcessorCount(WORD(0xFFFF))))
    #else
    return max(1, sysconf(CInt(_SC_NPROCESSORS_ONLN)))
    #endif
}

/// How many workers to use for `asked`, where zero is one for each processor,
/// and never more than there is work for.
func workerCount(_ asked: Int, work: Int) -> Int {
    max(1, min(asked == 0 ? processorCount() : asked, work))
}

/// Runs `work` on `workers` threads at once, and waits for all of them. A
/// worker is given its number.
func onWorkers(_ workers: Int, _ work: @Sendable (Int) -> Void) {
    if workers <= 1 {
        work(0)
        return
    }
    DispatchQueue.concurrentPerform(iterations: workers) { work($0) }
}

/// Takes the items of a list one at a time, on several threads, and stops
/// handing them out once one of them fails. The first error is kept.
final class Dealer: @unchecked Sendable {
    private let lock = Lock()
    private var next = 0
    private var stopped = false
    private var error: (any Error)?
    let count: Int

    init(count: Int) {
        self.count = count
    }

    /// The next item's place, or nil when all are dealt or the work has failed.
    func take() -> Int? {
        lock.withLock {
            if stopped || next >= count {
                return nil
            }
            next += 1
            return next - 1
        }
    }

    /// Stops the work for `error`. Only the first error is kept.
    func fail(_ error: any Error) {
        lock.withLock {
            if self.error == nil {
                self.error = error
            }
            stopped = true
        }
    }

    /// Throws the first error, if one came.
    func check() throws {
        if let error = lock.withLock({ error }) {
            throw error
        }
    }
}
