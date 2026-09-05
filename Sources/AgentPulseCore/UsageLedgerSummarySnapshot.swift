import Foundation

public struct UsageLedgerSummaryWindowSnapshot: Sendable {
    public let window: UsageSummaryWindow?
    public let summary: UsageSummary?
    public let models: [UsageModelTokenSummary]

    public init(window: UsageSummaryWindow?, summary: UsageSummary?, models: [UsageModelTokenSummary]) {
        self.window = window
        self.summary = summary
        self.models = models
    }
}

/// All rows describe one SQLite read snapshot. Revision orders completed snapshots from this
/// store instance, allowing asynchronous consumers to reject a late result from an older read.
public struct UsageLedgerSummarySnapshot: Sendable {
    public let revision: Int64
    public let windows: [UsageLedgerSummaryWindowSnapshot]
    public let outputBuckets: [(bucketStart: Date, outputTokens: Int64)]
    public let outputBucketsByModel: [(bucketStart: Date, model: String, outputTokens: Int64)]

    public init(
        revision: Int64,
        windows: [UsageLedgerSummaryWindowSnapshot],
        outputBuckets: [(bucketStart: Date, outputTokens: Int64)],
        outputBucketsByModel: [(bucketStart: Date, model: String, outputTokens: Int64)]
    ) {
        self.revision = revision
        self.windows = windows
        self.outputBuckets = outputBuckets
        self.outputBucketsByModel = outputBucketsByModel
    }
}
