import Foundation

/// Backoff/retry policy for transient transport failures. Every knob is
/// caller-supplied; the defaults match the agreed transport contract:
/// 502/503/504 are retried, a 500 is retried only when its body matches a
/// configured fragment, and at most three retries are made with 2/5/11
/// second pauses.
public struct RetryPolicy: Sendable, Equatable {
    /// Number of retries after the initial attempt (3 means up to 4 sends).
    public var maxRetries: Int
    /// Status codes retried without inspecting the body.
    public var retryableStatusCodes: Set<Int>
    /// Per-status body fragments that make a response retryable. A response
    /// qualifies when its body contains at least one configured fragment for
    /// its status code. Used to opt specific 500 responses into retry without
    /// retrying every 500 blindly.
    public var retryableStatusBodyFragments: [Int: [String]]
    /// Pause before retry N (1-based). The last value is reused for any
    /// further retry.
    public var backoffSeconds: [TimeInterval]

    public init(
        maxRetries: Int = 3,
        retryableStatusCodes: Set<Int> = [502, 503, 504],
        retryableStatusBodyFragments: [Int: [String]] = [:],
        backoffSeconds: [TimeInterval] = [2, 5, 11]
    ) {
        self.maxRetries = maxRetries
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableStatusBodyFragments = retryableStatusBodyFragments
        self.backoffSeconds = backoffSeconds
    }

    /// True when the response is worth retrying: a configured status code, or
    /// a status with configured body fragments where the body matches one.
    public func isRetryable(_ response: HTTPResponse) -> Bool {
        if retryableStatusCodes.contains(response.statusCode) { return true }
        guard let fragments = retryableStatusBodyFragments[response.statusCode], !fragments.isEmpty else { return false }
        let body = String(decoding: response.body, as: UTF8.self)
        return fragments.contains { body.contains($0) }
    }

    /// Backoff for the given 1-based retry index.
    public func backoff(forRetryIndex index: Int) -> TimeInterval {
        guard !backoffSeconds.isEmpty else { return 0 }
        return backoffSeconds[min(max(index - 1, 0), backoffSeconds.count - 1)]
    }
}

/// Injects the retry delay so tests can run deterministically and production
/// can swap the wait strategy.
public protocol RetrySleeper: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

/// Default RetrySleeper backed by Task.sleep.
public struct TaskSleepSleeper: RetrySleeper {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
