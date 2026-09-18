import Foundation

/// Serialises tests that read or mutate process-wide environment variables.
///
/// swift-testing runs tests in parallel inside one process, and `setenv` is
/// global. A test that sets `VPHONE_ROOT` to assert the override behaviour is
/// therefore visible to a concurrent test asserting the default, which fails
/// with a value it never set.
///
/// Guarding the readers with `if environment["VPHONE_ROOT"] != nil { return }`
/// does not fix it: that is a check-then-read race, and the window between the
/// check and the assertion is exactly where the other test's `setenv` lands.
/// This flaked intermittently — often green, and red under load.
///
/// Anything touching these variables takes this lock for the whole test body,
/// readers included, so a reader either sees a clean environment or waits for
/// the mutator to restore one.
enum ProcessEnvironment {
    private static let lock = NSLock()

    /// Run `body` with exclusive access to the process environment.
    static func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
