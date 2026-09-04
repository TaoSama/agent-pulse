import Foundation

public struct CliProxyCollectionOptions: Sendable {
    public let pageSize: Int
    public let auditPageBudget: Int
    public let incrementalPageBudget: Int
    public let backfillPageBudget: Int
    public let maximumStagingBytes: Int

    public init(pageSize: Int = 5_000, auditPageBudget: Int = 8, incrementalPageBudget: Int = 2,
                backfillPageBudget: Int = 2, maximumStagingBytes: Int = 256 * 1024 * 1024) {
        self.pageSize = min(5_000, max(1, pageSize))
        self.auditPageBudget = min(32, max(1, auditPageBudget))
        self.incrementalPageBudget = min(32, max(1, incrementalPageBudget))
        self.backfillPageBudget = min(32, max(1, backfillPageBudget))
        self.maximumStagingBytes = max(1, maximumStagingBytes)
    }
}

extension CliProxyUsageService {
    private static let maximumConcurrentSources = 2
    private static let initialRealtimeWindowMS: Int64 = 30 * 60 * 1_000

    /// New activity is collected immediately; a separate persisted descending
    /// sweep eventually revisits all historical timestamps, including late
    /// inserts behind the realtime watermark. Pages stay off the heap until
    /// their source's completed cursor can be committed atomically.
    public func collectUsage(
        atPath path: String,
        statesByIdentity: [String: CliProxyCollectionState],
        options: CliProxyCollectionOptions = CliProxyCollectionOptions(),
        now: Date = Date()
    ) async throws -> CliProxyCollectionResult {
        let loaded = try Self.loadConfigurationSet(atPath: path)
        let nowMS = Int64(now.timeIntervalSince1970 * 1_000)
        var collections: [CliProxyStagedCollection] = []
        var failures = loaded.invalidSourceCount
        var errors = Array(repeating: CliProxyUsageError.invalidConfiguration, count: failures)
        await withTaskGroup(of: Result<CliProxyStagedCollection, CliProxyUsageError>.self) { group in
            var pending = loaded.configurations.makeIterator()
            func enqueue(_ configuration: Configuration) {
                group.addTask {
                    do {
                        return .success(try await collect(configuration,
                            state: statesByIdentity[configuration.identity] ?? CliProxyCollectionState(),
                            options: options, nowMS: nowMS))
                    } catch let error as CliProxyUsageError {
                        return .failure(error)
                    } catch {
                        return .failure(.network)
                    }
                }
            }
            for _ in 0..<Self.maximumConcurrentSources {
                if let configuration = pending.next() { enqueue(configuration) }
            }
            while let result = await group.next() {
                switch result {
                case let .success(collection): collections.append(collection)
                case let .failure(error): failures += 1; errors.append(error)
                }
                if !Task.isCancelled, let configuration = pending.next() { enqueue(configuration) }
            }
        }
        try Task.checkCancellation()
        if collections.isEmpty, let error = errors.max(by: { $0.reportingPriority < $1.reportingPriority }) {
            throw error
        }
        return CliProxyCollectionResult(collections: collections,
            sourceCount: loaded.configurations.count + loaded.invalidSourceCount,
            failedSourceCount: failures,
            migrationSourceCount: collections.filter { $0.state.requiresIdentityCheck }.count)
    }

    private func collect(_ configuration: Configuration, state original: CliProxyCollectionState,
                         options: CliProxyCollectionOptions, nowMS: Int64) async throws -> CliProxyStagedCollection {
        let writer = try CliProxyStageWriter(maximumBytes: options.maximumStagingBytes)
        var state = original
        if state.endpoint == .mixed { throw CliProxyUsageError.protocolIdentityUnresolved }
        if state.endpoint == .unresolved {
            state.endpoint = .detectingAnalytics
            state.resetAudit()
        }
        if state.endpoint == .legacy || state.endpoint == .detectingLegacy {
            try writer.append(try await fetchLegacyUsage(configuration))
            return writer.finish(identity: configuration.identity, state: state,
                                 migrationPassComplete: state.requiresIdentityCheck)
        }

        if !state.requiresIdentityCheck {
            let fromMS = max(1, state.incrementalThroughMS > 0
                ? state.incrementalThroughMS : nowMS - Self.initialRealtimeWindowMS)
            do {
                let latest = try await stageAnalytics(configuration, writer: writer, fromMS: fromMS, toMS: nowMS,
                    beforeMS: nil, beforeID: nil, budget: options.incrementalPageBudget, options: options)
                if latest.beforeMS != nil {
                    if state.backfill == nil {
                        state.backfill = CliProxyBackfillCursor(fromMS: fromMS, throughMS: nowMS,
                            beforeMS: latest.beforeMS, beforeID: latest.beforeID)
                    } else {
                        state.queuedBackfillFromMS = min(state.queuedBackfillFromMS ?? fromMS, fromMS)
                        state.queuedBackfillThroughMS = max(state.queuedBackfillThroughMS ?? nowMS, nowMS)
                    }
                }
                state.endpoint = .analytics
                state.incrementalThroughMS = nowMS
            } catch AnalyticsFallback.unsupported where original.endpoint == .discover {
                // Discovery can fall back only before any analytics page was
                // accepted. Established sources never mix two ID domains.
                try writer.append(try await fetchLegacyUsage(configuration))
                state.endpoint = .legacy
                return writer.finish(identity: configuration.identity, state: state)
            } catch AnalyticsFallback.unsupported {
                throw CliProxyUsageError.protocolIdentityUnresolved
            }
            try await advanceBackfill(configuration, writer: writer, state: &state, options: options)
        }

        let auditTo = state.auditThroughMS ?? nowMS
        let cursor: AuditCursor
        do {
            cursor = try await stageAnalytics(configuration, writer: writer, fromMS: 1, toMS: auditTo,
                beforeMS: state.auditBeforeMS, beforeID: state.auditBeforeID,
                budget: options.auditPageBudget, options: options)
        } catch AnalyticsFallback.unsupported where state.endpoint == .detectingAnalytics
            && state.auditBeforeMS == nil {
            state.endpoint = .detectingLegacy
            state.resetAudit()
            try writer.append(try await fetchLegacyUsage(configuration))
            return writer.finish(identity: configuration.identity, state: state, migrationPassComplete: true)
        } catch AnalyticsFallback.unsupported {
            throw CliProxyUsageError.protocolIdentityUnresolved
        }
        state.auditedPages += cursor.pages
        let complete = cursor.beforeMS == nil
        if complete {
            state.resetAudit()
        } else {
            state.auditThroughMS = auditTo
            state.auditBeforeMS = cursor.beforeMS
            state.auditBeforeID = cursor.beforeID
        }
        return writer.finish(identity: configuration.identity, state: state,
                             migrationPassComplete: state.requiresIdentityCheck && complete)
    }

    /// A bounded queue preserves a fixed in-progress snapshot while coalescing
    /// later overflow ranges. Recent requests still get a separate first pass;
    /// backlog progress cannot be reset by continuous new activity.
    private func advanceBackfill(_ configuration: Configuration, writer: CliProxyStageWriter,
                                 state: inout CliProxyCollectionState,
                                 options: CliProxyCollectionOptions) async throws {
        guard var pending = state.backfill else { return }
        let cursor = try await stageAnalytics(configuration, writer: writer,
            fromMS: pending.fromMS, toMS: pending.throughMS, beforeMS: pending.beforeMS,
            beforeID: pending.beforeID, budget: options.backfillPageBudget, options: options)
        if cursor.beforeMS != nil {
            pending.beforeMS = cursor.beforeMS
            pending.beforeID = cursor.beforeID
            state.backfill = pending
        } else if let from = state.queuedBackfillFromMS, let through = state.queuedBackfillThroughMS {
            state.backfill = CliProxyBackfillCursor(fromMS: from, throughMS: through, beforeMS: nil, beforeID: nil)
            state.queuedBackfillFromMS = nil
            state.queuedBackfillThroughMS = nil
        } else {
            state.backfill = nil
        }
    }

    struct AuditCursor {
        let beforeMS: Int64?
        let beforeID: Int64?
        let pages: Int
    }

    func stageAnalytics(_ configuration: Configuration, writer: CliProxyStageWriter,
                                fromMS: Int64, toMS: Int64, beforeMS: Int64?, beforeID: Int64?,
                                budget: Int, options: CliProxyCollectionOptions) async throws -> AuditCursor {
        var beforeMS = beforeMS
        var beforeID = beforeID
        for pageIndex in 0..<budget {
            try Task.checkCancellation()
            let page: CliProxyUsageParser.AnalyticsPage
            do {
                page = try await analyticsPage(configuration, fromMS: fromMS, toMS: toMS,
                    beforeMS: beforeMS, beforeID: beforeID, limit: options.pageSize)
            } catch AnalyticsFallback.unsupported where pageIndex > 0 || beforeMS != nil {
                throw CliProxyUsageError.protocolIdentityUnresolved
            }
            guard page.events.count <= options.pageSize else { throw CliProxyUsageError.responseTooLarge }
            try writer.append(page.events)
            if !page.hasMore { return AuditCursor(beforeMS: nil, beforeID: nil, pages: pageIndex + 1) }
            guard page.nextBeforeMS > 0, page.nextBeforeID > 0,
                  beforeMS == nil || page.nextBeforeMS < beforeMS!
                    || (page.nextBeforeMS == beforeMS! && page.nextBeforeID < (beforeID ?? 0)) else {
                throw CliProxyUsageError.network
            }
            beforeMS = page.nextBeforeMS
            beforeID = page.nextBeforeID
        }
        return AuditCursor(beforeMS: beforeMS, beforeID: beforeID, pages: budget)
    }

    func analyticsPage(_ configuration: Configuration, fromMS: Int64, toMS: Int64,
                               beforeMS: Int64?, beforeID: Int64?, limit: Int) async throws -> CliProxyUsageParser.AnalyticsPage {
        var paging: [String: Any] = ["limit": limit]
        if let beforeMS, let beforeID { paging["before_ms"] = beforeMS; paging["before_id"] = beforeID }
        let payload: [String: Any] = ["from_ms": fromMS, "to_ms": toMS,
            "filters": ["api_key_hashes": [CliProxyUsageParser.apiKeyHash(for: configuration.targetAPIKey)]],
            "include": ["events_page": paging]]
        var request = authorizedRequest(url: configuration.analyticsURL, method: "POST", managementKey: configuration.managementKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await perform(request)
        if [404, 405, 501].contains(http.statusCode) { throw AnalyticsFallback.unsupported }
        try validate(http: http, data: data)
        guard data.count <= Self.maxAnalyticsResponseBytes else { throw CliProxyUsageError.responseTooLarge }
        do {
            return try CliProxyUsageParser.parseAnalyticsPage(data: data, targetAPIKey: configuration.targetAPIKey,
                                                              sourceIdentifier: configuration.sourceIdentifier)
        } catch {
            throw AnalyticsFallback.unsupported
        }
    }

    /// Reject oversized bodies while receiving bytes, including chunked
    /// responses with no Content-Length. Cancel the underlying request as soon
    /// as the limit is reached so URLSession does not finish buffering it.
    public static func boundedResponse(for request: URLRequest, session: URLSession = .shared,
                                       maximumBytes: Int = 128 * 1024 * 1024) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else { throw CliProxyUsageError.responseTooLarge }
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            bytes.task.cancel()
            throw CliProxyUsageError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        do {
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw CliProxyUsageError.responseTooLarge }
                data.append(byte)
            }
        } catch {
            bytes.task.cancel()
            throw error
        }
        return (data, response)
    }
}
