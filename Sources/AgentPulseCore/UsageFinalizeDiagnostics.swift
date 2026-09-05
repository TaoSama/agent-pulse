/// Work performed by the most recent finalize call. Statement counters cover
/// instrumented statements; they are not a count of every SQLite operation.
public struct UsageFinalizeDiagnostics: Sendable {
    public var strategy: String
    public var scopedLogicalEvents: Int
    public var sqliteFullScanSteps: Int
    public var sqliteAutoIndexRows: Int
    public var sqliteChangedRows: Int64

    public init(
        strategy: String = "none",
        scopedLogicalEvents: Int = 0,
        sqliteFullScanSteps: Int = 0,
        sqliteAutoIndexRows: Int = 0,
        sqliteChangedRows: Int64 = 0
    ) {
        self.strategy = strategy
        self.scopedLogicalEvents = scopedLogicalEvents
        self.sqliteFullScanSteps = sqliteFullScanSteps
        self.sqliteAutoIndexRows = sqliteAutoIndexRows
        self.sqliteChangedRows = sqliteChangedRows
    }
}
