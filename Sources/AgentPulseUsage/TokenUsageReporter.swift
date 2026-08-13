import Foundation
import AgentPulseCore
import AgentPulseReporting

public enum TokenUsageReporterError: Error, Equatable, Sendable {
    case configurationMissing
    case invalidConfigurationPermissions
    case invalidBaseURL
    case canonicalHostnameMissing
    case hostnameRebuildRequired
    case reportingIneligible
}

public enum TokenReportingConfigurationStatus: Equatable, Sendable {
    case ready
    case missing
    case invalid
    case pathMissing
    case commandMissing
    case headersMissing
    case hostnameMissing
}

public protocol UsageBatchReporting: Sendable {
    func ingest(batches: [UsageBatch]) async throws -> UsageBatchOutcome
}

extension UsageBatchOrchestrator: UsageBatchReporting {}

public struct TokenUsagePartialFailure: Equatable, Sendable {
    public let revision: Int64
    public let bucketCount: Int
    public let sessionCount: Int
    public let error: IngestClientError

    public init(revision: Int64, bucketCount: Int, sessionCount: Int, error: IngestClientError) {
        self.revision = revision
        self.bucketCount = bucketCount
        self.sessionCount = sessionCount
        self.error = error
    }
}

public struct TokenUsageReport: Equatable, Sendable {
    public var bucketsAttempted: Int
    public var bucketsAcknowledged: Int
    public var bucketsPending: Int
    public var sessionsAttempted: Int
    public var sessionsAcknowledged: Int
    public var sessionsPending: Int
    public var partialFailures: [TokenUsagePartialFailure]
    public var responses: [UsageIngestResponse]

    public init(
        bucketsAttempted: Int = 0,
        bucketsAcknowledged: Int = 0,
        bucketsPending: Int = 0,
        sessionsAttempted: Int = 0,
        sessionsAcknowledged: Int = 0,
        sessionsPending: Int = 0,
        partialFailures: [TokenUsagePartialFailure] = [],
        responses: [UsageIngestResponse] = []
    ) {
        self.bucketsAttempted = bucketsAttempted
        self.bucketsAcknowledged = bucketsAcknowledged
        self.bucketsPending = bucketsPending
        self.sessionsAttempted = sessionsAttempted
        self.sessionsAcknowledged = sessionsAcknowledged
        self.sessionsPending = sessionsPending
        self.partialFailures = partialFailures
        self.responses = responses
    }

    public var bucketCount: Int { bucketsAcknowledged }
    public var sessionCount: Int { sessionsAcknowledged }
    public var hasPartialFailures: Bool { !partialFailures.isEmpty }
}

/// 普通增量上报组装层。只读取账本的 pending revision，不设置 full-sync 标志；
/// 每个 revision-safe batch 成功后才精确 ack，失败批次和其后的数据保持 pending。
public struct TokenUsageReporter: Sendable {
    public typealias ConfigurationLoader = @Sendable (URL) throws -> TokenReportingConfiguration
    public typealias ClientFactory = @Sendable (IngestClientConfiguration, TokenReportingConfiguration) -> UsageBatchReporting

    private let configurationLoader: ConfigurationLoader
    private let clientFactory: ClientFactory

    public init(
        configurationLoader: @escaping ConfigurationLoader = TokenUsageReporter.loadConfiguration,
        clientFactory: @escaping ClientFactory = TokenUsageReporter.makeClient
    ) {
        self.configurationLoader = configurationLoader
        self.clientFactory = clientFactory
    }

    public static func loadConfiguration(from url: URL) throws -> TokenReportingConfiguration {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600 else {
            throw TokenUsageReporterError.invalidConfigurationPermissions
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try JSONDecoder().decode(TokenReportingConfiguration.self, from: data)
    }

    public static func makeClient(
        configuration: IngestClientConfiguration,
        reporting: TokenReportingConfiguration
    ) -> UsageBatchReporting {
        let provider = ConfiguredCommandTokenProvider(configuration: reporting.tokenCommand.providerConfiguration)
        let client = UsageIngestClient(
            configuration: configuration,
            tokenSupplier: CommandTokenSupplier(provider: provider),
            identity: TokenAccountIdentity(claimKeys: reporting.tokenAccountClaimKeys)
        )
        return UsageBatchOrchestrator(client: client, configuration: reporting.batch.transportConfiguration)
    }

    public func configurationStatus(for url: URL) -> TokenReportingConfigurationStatus {
        do {
            let configuration = try configurationLoader(url)
            if CanonicalHostname.normalize(configuration.canonicalHostname).isEmpty { return .hostnameMissing }
            if configuration.path.isEmpty { return .pathMissing }
            if !Self.isValidPath(configuration.path) { return .invalid }
            if !configuration.tokenCommand.isConfigured { return .commandMissing }
            if configuration.headers.authToken.isEmpty
                || configuration.headers.contentEncoding.isEmpty
                || configuration.headers.contentType.isEmpty {
                return .headersMissing
            }
            return configuration.batch.isValid && configuration.retry.isValid ? .ready : .invalid
        } catch is DecodingError {
            return .invalid
        } catch TokenUsageReporterError.invalidConfigurationPermissions {
            return .invalid
        } catch {
            return .missing
        }
    }

    public func report(
        ledger: UsageLedgerStore,
        hostname: String,
        baseURL: URL,
        configurationURL: URL
    ) async throws -> TokenUsageReport {
        guard Self.isValidBaseURL(baseURL) else { throw TokenUsageReporterError.invalidBaseURL }
        let configuration = try configurationLoader(configurationURL)
        let configuredHostname = CanonicalHostname.normalize(configuration.canonicalHostname)
        let requestedHostname = CanonicalHostname.normalize(hostname)
        guard !configuredHostname.isEmpty, !requestedHostname.isEmpty else {
            throw TokenUsageReporterError.canonicalHostnameMissing
        }
        guard configuration.isReady, Self.isValidPath(configuration.path) else {
            throw TokenUsageReporterError.configurationMissing
        }
        guard configuredHostname == requestedHostname else {
            throw TokenUsageReporterError.hostnameRebuildRequired
        }
        switch try ledger.hostnameState(current: configuredHostname) {
        case .match:
            break
        case .unset:
            throw TokenUsageReporterError.hostnameRebuildRequired
        case .mismatch:
            throw TokenUsageReporterError.hostnameRebuildRequired
        }
        guard try ledger.reportingEligible(hostname: configuredHostname) else {
            throw TokenUsageReporterError.reportingIneligible
        }

        let client = clientFactory(
            configuration.ingestConfiguration(baseURL: baseURL, hostname: configuredHostname),
            configuration
        )
        var report = TokenUsageReport()

        while true {
            let pending = try ledger.pendingBatch(
                hostname: configuredHostname,
                maxBuckets: configuration.batch.maxBucketsPerBatch,
                maxSessions: configuration.batch.maxSessionsPerBatch
            )
            guard !pending.isEmpty else { break }

            report.bucketsAttempted += pending.buckets.count
            report.sessionsAttempted += pending.sessions.count
            let request = UsageIngestRequest(
                buckets: UsageBucketPayloadMapper.payloads(from: pending.buckets.map(\.bucket)),
                sessions: UsageSessionPayloadMapper.payloads(from: pending.sessions.map(\.session))
            )
            let batch = UsageBatch(
                batchID: nil,
                revision: nil,
                request: request
            )
            let outcome = try await client.ingest(batches: [batch])
            try Task.checkCancellation()

            if outcome.failures.isEmpty,
               outcome.acks.count == 1,
               let ack = outcome.acks.first,
               Self.isExactAcknowledgement(ack, for: request) {
                try Task.checkCancellation()
                try ledger.acknowledge(pending)
                report.bucketsAcknowledged += pending.buckets.count
                report.sessionsAcknowledged += pending.sessions.count
                report.responses.append(ack.response)
                continue
            }

            if let failure = outcome.failures.first {
                report.partialFailures.append(TokenUsagePartialFailure(
                    revision: Self.maximumRevision(in: pending),
                    bucketCount: failure.bucketCount,
                    sessionCount: failure.sessionCount,
                    error: failure.error
                ))
            } else {
                report.partialFailures.append(TokenUsagePartialFailure(
                    revision: Self.maximumRevision(in: pending),
                    bucketCount: pending.buckets.count,
                    sessionCount: pending.sessions.count,
                    error: .malformedResponse
                ))
            }
            break
        }

        let remaining = try ledger.pendingCounts(hostname: configuredHostname)
        report.bucketsPending = remaining.buckets
        report.sessionsPending = remaining.sessions
        return report
    }

    private static func maximumRevision(in batch: UsagePendingBatch) -> Int64 {
        max(batch.buckets.map(\.revision).max() ?? 0, batch.sessions.map(\.revision).max() ?? 0)
    }

    private static func isExactAcknowledgement(_ ack: UsageBatchAck, for request: UsageIngestRequest) -> Bool {
        ack.batchIndex == 0
            && ack.bucketCount == request.buckets.count
            && ack.sessionCount == request.sessions.count
            && ack.autonomySessionCount == request.autonomySessions.count
            && ack.response.confirmsExactCounts(for: request)
    }

    public static func isValidBaseURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    public static func isValidPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              URL(string: trimmed)?.scheme == nil else { return false }
        return true
    }
}

private enum UsagePayloadDateFormatter {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public enum UsageBucketPayloadMapper {
    public static func payloads(from buckets: [UsageBucket]) -> [UsageBucketPayload] {
        buckets.map { bucket in
            UsageBucketPayload(
                source: bucket.source,
                model: bucket.model,
                project: bucket.project,
                bucketStart: UsagePayloadDateFormatter.string(from: bucket.bucketStart),
                hostname: bucket.hostname,
                inputTokens: bucket.counts.input,
                outputTokens: bucket.counts.output,
                cachedInputTokens: bucket.counts.cachedInput,
                cacheCreationInputTokens: bucket.counts.cacheCreationInput,
                reasoningOutputTokens: bucket.counts.reasoningOutput,
                totalTokens: bucket.counts.total
            )
        }
    }
}

public enum UsageSessionPayloadMapper {
    public static func payloads(from sessions: [UsageSession]) -> [UsageSessionPayload] {
        sessions.map { session in
            UsageSessionPayload(
                source: session.source,
                project: session.project,
                sessionHash: session.sessionHash,
                hostname: session.hostname,
                firstMessageAt: UsagePayloadDateFormatter.string(from: session.firstActivity),
                lastMessageAt: UsagePayloadDateFormatter.string(from: session.lastActivity),
                durationSeconds: clampedInt(session.lastActivity.timeIntervalSince(session.firstActivity)),
                activeSeconds: clampedInt(session.activeSeconds),
                messageCount: clampedInt(session.messageCount),
                userMessageCount: clampedInt(session.userMessageCount),
                userPromptHours: session.hourHistogramUTC.map(clampedInt)
            )
        }
    }

    private static func clampedInt(_ value: Int64) -> Int {
        Int(clamping: value)
    }

    private static func clampedInt(_ value: TimeInterval) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(clamping: Int64(value.rounded(.down)))
    }
}
