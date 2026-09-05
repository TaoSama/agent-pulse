import Foundation

/// Created once per report, so successive batches reuse a credential only in
/// memory. Refreshes are fenced before replacing the cached credential.
public actor ReportTokenSupplier: TokenSupplying {
    private let supplier: TokenSupplying
    private let identity: TokenAccountIdentity
    private var cached: SecretToken?
    private struct Waiter {
        let latch: ContinuationLatch
        let forceRefresh: Bool
    }
    private struct InFlight {
        let id: UUID
        let forceRefresh: Bool
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }
    private var inFlight: InFlight?
    var pendingWaiterCount: Int { inFlight?.waiters.count ?? 0 }

    public init(supplier: TokenSupplying, identity: TokenAccountIdentity = TokenAccountIdentity()) {
        self.supplier = supplier
        self.identity = identity
    }

    public func token(forceRefresh: Bool) async throws -> SecretToken {
        try Task.checkCancellation()
        if inFlight == nil, !forceRefresh, let cached { return cached }
        let id = UUID()
        let latch = ContinuationLatch()
        let token = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                latch.attach(continuation)
                let waiter = Waiter(latch: latch, forceRefresh: forceRefresh)
                if inFlight != nil { inFlight?.waiters[id] = waiter }
                else { start(forceRefresh: forceRefresh, waiters: [id: waiter]) }
            }
        } onCancel: {
            latch.resolve(.failure(CancellationError()))
            Task { await self.cancelWaiter(id) }
        }
        try Task.checkCancellation()
        return token
    }

    private func start(forceRefresh: Bool, waiters: [UUID: Waiter]) {
        let id = UUID()
        let task = Task {
            let result: Result<SecretToken, Error>
            do { result = .success(try await supplier.token(forceRefresh: forceRefresh)) }
            catch { result = .failure(error) }
            finish(id: id, result: result)
        }
        inFlight = InFlight(id: id, forceRefresh: forceRefresh, task: task, waiters: waiters)
    }

    private func finish(id: UUID, result: Result<SecretToken, Error>) {
        guard let flight = inFlight, flight.id == id else { return }
        inFlight = nil
        var result = result
        if case let .success(token) = result {
            if let cached, !identity.sameStableAccount(cached.reveal(), token.reveal()) {
                result = .failure(IngestClientError.authIdentityChanged)
            } else { cached = token }
        }
        let identityRejected: Bool
        if case let .failure(error) = result { identityRejected = (error as? IngestClientError) == .authIdentityChanged }
        else { identityRejected = false }
        if !flight.forceRefresh, !identityRejected {
            // Force callers overlapping initial acquisition require one actual
            // refresh even if acquisition failed. Register it before resuming peers.
            let forced = flight.waiters.filter { $0.value.forceRefresh }
            if !forced.isEmpty { start(forceRefresh: true, waiters: forced) }
            for waiter in flight.waiters.values where !waiter.forceRefresh { waiter.latch.resolve(result) }
        } else {
            for waiter in flight.waiters.values { waiter.latch.resolve(result) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        inFlight?.waiters.removeValue(forKey: id)
        if let flight = inFlight, flight.waiters.isEmpty {
            inFlight = nil
            flight.task.cancel()
        }
    }
}
