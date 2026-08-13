import Foundation

/// Configuration for batch dispatch. Per-batch caps are clamped into
/// 1...maximumConfigurableBatchSize at use time; concurrency is clamped to at
/// least 1.
public struct UsageBatchConfiguration: Sendable, Equatable {
    /// Hard upper bound for any configurable per-batch cap.
    public static let maximumConfigurableBatchSize = 2000

    public var maxBucketsPerBatch: Int
    public var maxSessionsPerBatch: Int
    public var maxConcurrentBatches: Int

    public init(
        maxBucketsPerBatch: Int = 500,
        maxSessionsPerBatch: Int = 1_000,
        maxConcurrentBatches: Int = 2
    ) {
        self.maxBucketsPerBatch = maxBucketsPerBatch
        self.maxSessionsPerBatch = maxSessionsPerBatch
        self.maxConcurrentBatches = maxConcurrentBatches
    }

    var effectiveBucketCap: Int {
        min(max(maxBucketsPerBatch, 1), Self.maximumConfigurableBatchSize)
    }

    var effectiveSessionCap: Int {
        min(max(maxSessionsPerBatch, 1), Self.maximumConfigurableBatchSize)
    }

    var effectiveConcurrency: Int { max(maxConcurrentBatches, 1) }
}

/// One independently dispatched unit of work. Callers that build batches
/// themselves may tag them with an opaque batchID and/or revision snapshot,
/// which are echoed verbatim in the per-batch ack/failure.
public struct UsageBatch: Sendable, Equatable {
    public var batchID: String?
    public var revision: String?
    public var request: UsageIngestRequest

    public init(batchID: String? = nil, revision: String? = nil, request: UsageIngestRequest) {
        self.batchID = batchID
        self.revision = revision
        self.request = request
    }
}

/// Per-batch success: what was in the batch (counts, plus any caller tag) and
/// the decoded server acknowledgement.
public struct UsageBatchAck: Sendable, Equatable {
    public let batchIndex: Int
    public let batchID: String?
    public let revision: String?
    public let bucketCount: Int
    public let sessionCount: Int
    public let autonomySessionCount: Int
    public let response: UsageIngestResponse

    public init(
        batchIndex: Int,
        batchID: String? = nil,
        revision: String? = nil,
        bucketCount: Int,
        sessionCount: Int,
        autonomySessionCount: Int = 0,
        response: UsageIngestResponse
    ) {
        self.batchIndex = batchIndex
        self.batchID = batchID
        self.revision = revision
        self.bucketCount = bucketCount
        self.sessionCount = sessionCount
        self.autonomySessionCount = autonomySessionCount
        self.response = response
    }
}

/// Per-batch failure. The error is category-only; it never carries the
/// response body or token material.
public struct UsageBatchFailure: Sendable, Equatable {
    public let batchIndex: Int
    public let batchID: String?
    public let revision: String?
    public let bucketCount: Int
    public let sessionCount: Int
    public let error: IngestClientError

    public init(
        batchIndex: Int,
        batchID: String? = nil,
        revision: String? = nil,
        bucketCount: Int,
        sessionCount: Int,
        error: IngestClientError
    ) {
        self.batchIndex = batchIndex
        self.batchID = batchID
        self.revision = revision
        self.bucketCount = bucketCount
        self.sessionCount = sessionCount
        self.error = error
    }
}

/// Aggregated outcome of a run: acks for batches that succeeded, failures
/// for batches that did not. A run with a fatal auth error stops dispatching
/// subsequent batches; a run that hit lock contention degrades to serial
/// dispatch for the rest of the run.
public struct UsageBatchOutcome: Sendable, Equatable {
    public let acks: [UsageBatchAck]
    public let failures: [UsageBatchFailure]

    public init(acks: [UsageBatchAck] = [], failures: [UsageBatchFailure] = []) {
        self.acks = acks
        self.failures = failures
    }

    public var succeeded: Bool { failures.isEmpty }
}

/// Splits a request into independent batches and dispatches them with bounded
/// concurrency. Each batch is a separate request; ordinary ingest adds no
/// query item or idempotency key. Partial success is reported per batch.
public struct UsageBatchOrchestrator: Sendable {
    private let client: UsageIngestClient
    private let configuration: UsageBatchConfiguration

    public init(client: UsageIngestClient, configuration: UsageBatchConfiguration = UsageBatchConfiguration()) {
        self.client = client
        self.configuration = configuration
    }

    /// Splits the request into batches (buckets and sessions chunked by the
    /// configured caps; autonomy payloads and full-sync flags ride on the
    /// first batch) and dispatches them.
    public func ingest(_ request: UsageIngestRequest) async throws -> UsageBatchOutcome {
        try await ingest(batches: Self.split(request, configuration: configuration))
    }

    /// Dispatches caller-built batches. Tags are echoed in acks and failures.
    public func ingest(batches: [UsageBatch]) async throws -> UsageBatchOutcome {
        guard !batches.isEmpty else { return UsageBatchOutcome() }
        let gate = BatchGate(maxConcurrency: configuration.effectiveConcurrency)
        let collected: [(Int, BatchOutcome)] = try await withThrowingTaskGroup(of: (Int, BatchOutcome).self) { group in
            for (index, batch) in batches.enumerated() {
                group.addTask {
                    guard await gate.acquire() else { return (index, .skipped) }
                    do {
                        try Task.checkCancellation()
                        let response = try await client.ingest(batch.request)
                        await gate.release()
                        return (index, .ack(response))
                    } catch let error as IngestClientError {
                        switch error {
                        case .notAuthenticated, .authIdentityChanged:
                            // Fatal auth error: stop dispatching later batches.
                            await gate.markStopped()
                        case .lockContention:
                            // First lock contention degrades the rest of the
                            // run to serial dispatch.
                            await gate.markSerial()
                        default:
                            // Other failures are aggregated as-is.
                            break
                        }
                        await gate.release()
                        return (index, .failure(error))
                    } catch let error as TokenProviderError {
                        // Token-provider failures cannot produce a per-batch
                        // ingest failure. Stop admission before propagating so
                        // queued tasks are not left waiting for permits.
                        await gate.markStopped()
                        await gate.release()
                        throw error
                    } catch is CancellationError {
                        await gate.release()
                        throw CancellationError()
                    } catch {
                        // An unexpected failure aborts the run. Wake queued
                        // tasks before propagating it through the task group.
                        await gate.markStopped()
                        await gate.release()
                        throw error
                    }
                }
            }
            var collected: [(Int, BatchOutcome)] = []
            for try await result in group { collected.append(result) }
            return collected
        }

        var acks: [UsageBatchAck] = []
        var failures: [UsageBatchFailure] = []
        for (index, outcome) in collected.sorted(by: { $0.0 < $1.0 }) {
            let batch = batches[index]
            switch outcome {
            case let .ack(response):
                acks.append(UsageBatchAck(
                    batchIndex: index,
                    batchID: batch.batchID,
                    revision: batch.revision,
                    bucketCount: batch.request.buckets.count,
                    sessionCount: batch.request.sessions.count,
                    autonomySessionCount: batch.request.autonomySessions.count,
                    response: response
                ))
            case let .failure(error):
                failures.append(UsageBatchFailure(
                    batchIndex: index,
                    batchID: batch.batchID,
                    revision: batch.revision,
                    bucketCount: batch.request.buckets.count,
                    sessionCount: batch.request.sessions.count,
                    error: error
                ))
            case .skipped:
                break
            }
        }
        return UsageBatchOutcome(acks: acks, failures: failures)
    }

    // MARK: - Splitting

    static func split(_ request: UsageIngestRequest, configuration: UsageBatchConfiguration) -> [UsageBatch] {
        let bucketChunks = chunk(request.buckets, configuration.effectiveBucketCap)
        let sessionChunks = chunk(request.sessions, configuration.effectiveSessionCap)
        let count = max(bucketChunks.count, sessionChunks.count, 1)
        var batches: [UsageBatch] = []
        for index in 0..<count {
            var batchRequest = UsageIngestRequest()
            batchRequest.buckets = index < bucketChunks.count ? bucketChunks[index] : []
            batchRequest.sessions = index < sessionChunks.count ? sessionChunks[index] : []
            if index == 0 {
                batchRequest.autonomySessions = request.autonomySessions
                batchRequest.autonomySourceStatuses = request.autonomySourceStatuses
                batchRequest.autonomyWindowStart = request.autonomyWindowStart
                batchRequest.autonomyWindowEnd = request.autonomyWindowEnd
                batchRequest.fullSync = request.fullSync
                batchRequest.fullSyncReset = request.fullSyncReset
            }
            batches.append(UsageBatch(request: batchRequest))
        }
        return batches
    }

    private static func chunk<T>(_ values: [T], _ cap: Int) -> [[T]] {
        guard !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: cap).map { start in
            Array(values[start..<min(start + cap, values.count)])
        }
    }
}

/// Outcome of a single batch dispatch, internal to the orchestrator.
private enum BatchOutcome: Sendable {
    case ack(UsageIngestResponse)
    case failure(IngestClientError)
    case skipped
}

/// Bounds concurrent batch dispatch. Once markSerial() is observed, at most
/// one batch runs at a time for the rest of the run. Once markStopped() is
/// observed, no further batch is admitted.
private actor BatchGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maxConcurrency: Int
    private var active = 0
    private var serial = false
    private var stopped = false
    private var waiters: [Waiter] = []

    init(maxConcurrency: Int) {
        self.maxConcurrency = max(1, maxConcurrency)
    }

    func acquire() async -> Bool {
        if stopped || Task.isCancelled { return false }
        if active < limit() {
            active += 1
            return true
        }

        let waiterID = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
        if granted, Task.isCancelled {
            // Cancellation may race with pump() after it reserved a permit.
            // Return that permit here instead of dispatching the batch.
            release()
            return false
        }
        return granted
    }

    func release() {
        active -= 1
        pump()
    }

    func markSerial() {
        serial = true
    }

    func markStopped() {
        stopped = true
        pump()
    }

    private func limit() -> Int { serial ? 1 : maxConcurrency }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
        pump()
    }

    private func pump() {
        guard !waiters.isEmpty else { return }
        if stopped {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.continuation.resume(returning: false) }
            return
        }

        while !waiters.isEmpty, active < limit() {
            let waiter = waiters.removeFirst()
            // Reserve the permit before resuming the waiter. If cancellation
            // wins after this point, the resumed task owns the permit and its
            // dispatch path is responsible for releasing it exactly once.
            active += 1
            waiter.continuation.resume(returning: true)
        }
    }
}
