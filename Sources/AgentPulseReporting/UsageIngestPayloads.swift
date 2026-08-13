import Foundation

// Wire payloads for the usage-ingest endpoint. Field names and empty-value
// elision mirror the backend's accepted request schema exactly: keys marked
// "omit when empty" are dropped from the JSON entirely, while the remaining
// keys are always emitted, even at their zero value.

/// A per-(source, model, project, bucketStart) usage aggregate.
public struct UsageBucketPayload: Sendable, Equatable {
    public var source: String
    public var model: String
    public var project: String
    public var skills: [String]
    public var skillCounts: [String: Int]
    public var mcpCounts: [String: Int]
    public var bucketStart: String
    public var hostname: String
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cachedInputTokens: Int64
    public var cacheCreationInputTokens: Int64
    public var reasoningOutputTokens: Int64
    public var totalTokens: Int64
    public var linesAdded: Int64
    public var linesDeleted: Int64
    public var linesNet: Int64
    /// Tags how the code-line columns were measured. Emitted only when non-zero
    /// so a legacy zero value stays absent from the wire, matching the backend's
    /// treatment of the missing field.
    public var codeMetricVersion: Int

    public init(
        source: String,
        model: String,
        project: String,
        skills: [String] = [],
        skillCounts: [String: Int] = [:],
        mcpCounts: [String: Int] = [:],
        bucketStart: String,
        hostname: String = "",
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        cacheCreationInputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        linesAdded: Int64 = 0,
        linesDeleted: Int64 = 0,
        linesNet: Int64 = 0,
        codeMetricVersion: Int = 0
    ) {
        self.source = source
        self.model = model
        self.project = project
        self.skills = skills
        self.skillCounts = skillCounts
        self.mcpCounts = mcpCounts
        self.bucketStart = bucketStart
        self.hostname = hostname
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.linesAdded = linesAdded
        self.linesDeleted = linesDeleted
        self.linesNet = linesNet
        self.codeMetricVersion = codeMetricVersion
    }
}

/// A per-session activity summary.
public struct UsageSessionPayload: Sendable, Equatable {
    public var source: String
    public var project: String
    public var skills: [String]
    public var sessionHash: String
    public var hostname: String
    public var firstMessageAt: String
    public var lastMessageAt: String
    public var durationSeconds: Int
    public var activeSeconds: Int
    public var messageCount: Int
    public var userMessageCount: Int
    public var userPromptHours: [Int]

    public init(
        source: String,
        project: String,
        skills: [String] = [],
        sessionHash: String,
        hostname: String = "",
        firstMessageAt: String,
        lastMessageAt: String,
        durationSeconds: Int = 0,
        activeSeconds: Int = 0,
        messageCount: Int = 0,
        userMessageCount: Int = 0,
        userPromptHours: [Int] = []
    ) {
        self.source = source
        self.project = project
        self.skills = skills
        self.sessionHash = sessionHash
        self.hostname = hostname
        self.firstMessageAt = firstMessageAt
        self.lastMessageAt = lastMessageAt
        self.durationSeconds = durationSeconds
        self.activeSeconds = activeSeconds
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.userPromptHours = userPromptHours
    }
}

/// A per-session autonomy assessment.
public struct AutonomySessionPayload: Sendable, Equatable {
    public var source: String
    public var project: String
    public var skills: [String]
    public var sessionHash: String
    public var hostname: String
    public var firstEventAt: String
    public var lastEventAt: String
    public var firstUserAt: String
    public var handoffAt: String
    public var handoffReason: String
    public var autonomyStatus: String
    public var clarificationTurnCount: Int
    public var interventionCount: Int
    public var observedAutonomousSeconds: Int
    public var clippedIdleSeconds: Int
    public var messageCount: Int
    public var userMessageCount: Int
    public var agentEventCount: Int
    public var toolCallCount: Int
    public var confidence: String
    public var confidenceReasons: [String]
    public var schemaVersion: Int
    public var parserVersion: String
    public var computedAt: String

    public init(
        source: String,
        project: String,
        skills: [String] = [],
        sessionHash: String,
        hostname: String = "",
        firstEventAt: String,
        lastEventAt: String,
        firstUserAt: String = "",
        handoffAt: String = "",
        handoffReason: String = "",
        autonomyStatus: String,
        clarificationTurnCount: Int = 0,
        interventionCount: Int = 0,
        observedAutonomousSeconds: Int = 0,
        clippedIdleSeconds: Int = 0,
        messageCount: Int = 0,
        userMessageCount: Int = 0,
        agentEventCount: Int = 0,
        toolCallCount: Int = 0,
        confidence: String,
        confidenceReasons: [String] = [],
        schemaVersion: Int = 0,
        parserVersion: String = "",
        computedAt: String
    ) {
        self.source = source
        self.project = project
        self.skills = skills
        self.sessionHash = sessionHash
        self.hostname = hostname
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
        self.firstUserAt = firstUserAt
        self.handoffAt = handoffAt
        self.handoffReason = handoffReason
        self.autonomyStatus = autonomyStatus
        self.clarificationTurnCount = clarificationTurnCount
        self.interventionCount = interventionCount
        self.observedAutonomousSeconds = observedAutonomousSeconds
        self.clippedIdleSeconds = clippedIdleSeconds
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.agentEventCount = agentEventCount
        self.toolCallCount = toolCallCount
        self.confidence = confidence
        self.confidenceReasons = confidenceReasons
        self.schemaVersion = schemaVersion
        self.parserVersion = parserVersion
        self.computedAt = computedAt
    }
}

/// Per-source autonomy pipeline status.
public struct AutonomySourceStatusPayload: Sendable, Equatable {
    public var source: String
    public var hostname: String
    public var status: String
    public var error: String

    public init(source: String, hostname: String = "", status: String, error: String = "") {
        self.source = source
        self.hostname = hostname
        self.status = status
        self.error = error
    }
}

/// Envelope for a single ingest request. Autonomy payloads and full-sync flags
/// carries buckets, sessions, autonomy snapshots, and the full-sync flags the
/// backend recognizes. The client does not orchestrate full-sync batching; the
/// flags exist so a single request body can express the complete contract.
public struct UsageIngestRequest: Sendable, Equatable {
    public var buckets: [UsageBucketPayload]
    public var sessions: [UsageSessionPayload]
    public var autonomySessions: [AutonomySessionPayload]
    public var autonomySourceStatuses: [AutonomySourceStatusPayload]
    public var autonomyWindowStart: String
    public var autonomyWindowEnd: String
    public var fullSync: Bool
    public var fullSyncReset: Bool

    public init(
        buckets: [UsageBucketPayload] = [],
        sessions: [UsageSessionPayload] = [],
        autonomySessions: [AutonomySessionPayload] = [],
        autonomySourceStatuses: [AutonomySourceStatusPayload] = [],
        autonomyWindowStart: String = "",
        autonomyWindowEnd: String = "",
        fullSync: Bool = false,
        fullSyncReset: Bool = false
    ) {
        self.buckets = buckets
        self.sessions = sessions
        self.autonomySessions = autonomySessions
        self.autonomySourceStatuses = autonomySourceStatuses
        self.autonomyWindowStart = autonomyWindowStart
        self.autonomyWindowEnd = autonomyWindowEnd
        self.fullSync = fullSync
        self.fullSyncReset = fullSyncReset
    }
}

/// Server acknowledgement returned by the ingest endpoint.
public struct UsageIngestResponse: Sendable, Equatable, Decodable {
    public var bucketsUpserted: Int
    public var sessionsUpserted: Int
    public var autonomySessionsUpserted: Int

    public init(bucketsUpserted: Int = 0, sessionsUpserted: Int = 0, autonomySessionsUpserted: Int = 0) {
        self.bucketsUpserted = bucketsUpserted
        self.sessionsUpserted = sessionsUpserted
        self.autonomySessionsUpserted = autonomySessionsUpserted
    }

    private enum CodingKeys: String, CodingKey {
        case bucketsUpserted = "buckets_upserted"
        case sessionsUpserted = "sessions_upserted"
        case autonomySessionsUpserted = "autonomy_sessions_upserted"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bucketsUpserted = try container.decode(Int.self, forKey: .bucketsUpserted)
        self.sessionsUpserted = try container.decode(Int.self, forKey: .sessionsUpserted)
        self.autonomySessionsUpserted = try container.decode(Int.self, forKey: .autonomySessionsUpserted)
    }

    /// A batch is acknowledged only when every server count exactly matches
    /// the corresponding request dimension.
    public func confirmsExactCounts(for request: UsageIngestRequest) -> Bool {
        bucketsUpserted == request.buckets.count
            && sessionsUpserted == request.sessions.count
            && autonomySessionsUpserted == request.autonomySessions.count
    }
}
