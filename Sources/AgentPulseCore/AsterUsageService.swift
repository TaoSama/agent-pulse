import Foundation

public enum AsterUsageError: Error, Sendable, Equatable {
    case invalidCredential
    case unauthorized
    case http(Int)
    case invalidResponse
    case responseTooLarge
    case network
}

struct AsterEventCursor: Codable, Sendable, Equatable {
    let createdAt: String
    let eventID: String
}

struct AsterCollectionState: Codable, Sendable {
    var watermark: Date?
    var historyCursor: AsterEventCursor?
    var historyComplete = false
    var incrementalCursor: AsterEventCursor?
    var incrementalNewest: Date?
}

/// 管理凭证仅用于请求鉴权；账本仅保存统计值和事件身份哈希。
public struct AsterUsageService: Sendable {
    public static let source = "aster"
    public static let maximumResponseBytes = 8 * 1024 * 1024
    private static let pageLimit = 500
    private static let pagesPerPass = 100
    private static let overlapSeconds: TimeInterval = 5 * 60
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await AsterUsageService.boundedResponse(for: $0)
    }) {
        self.transport = transport
    }

    /// 每页的事件、派生 bucket 和游标一并提交，失败重试不会跳过或重复累计。
    /// 初始历史较大时分轮推进，同时优先采集当前增量。
    public func collect(managementKey: String, ledger: UsageLedgerStore, hostname: String) async throws -> Int {
        let key = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else {
            throw AsterUsageError.invalidCredential
        }
        var state = try ledger.asterCollectionState(hostname: hostname)
        let lowerBound = try ledger.asterCollectionLowerBound(hostname: hostname)
        var fetched = 0
        if let watermark = state.watermark {
            var seenCursors = Set<String>()
            let since = max(watermark.addingTimeInterval(-Self.overlapSeconds), lowerBound ?? .distantPast)
            for _ in 0..<Self.pagesPerPass {
                try Task.checkCancellation()
                let page = try await fetch(key: key, since: since, cursor: state.incrementalCursor)
                if page.rows.isEmpty {
                    state.watermark = max(watermark, state.incrementalNewest ?? watermark)
                    state.incrementalCursor = nil
                    state.incrementalNewest = nil
                    try ledger.commitAsterCollection(events: [], state: state, hostname: hostname)
                    break
                }
                if state.incrementalNewest == nil { state.incrementalNewest = page.newest }
                state.incrementalCursor = try advancing(page.cursor, from: state.incrementalCursor, seen: &seenCursors)
                try ledger.commitAsterCollection(events: page.events, state: state, hostname: hostname)
                fetched += page.rows.count
            }
        }
        if !state.historyComplete {
            var seenCursors = Set<String>()
            for _ in 0..<Self.pagesPerPass {
                try Task.checkCancellation()
                let page = try await fetch(key: key, since: lowerBound, cursor: state.historyCursor)
                if page.rows.isEmpty {
                    state.historyComplete = true
                    state.historyCursor = nil
                    try ledger.commitAsterCollection(events: [], state: state, hostname: hostname)
                    break
                }
                if state.watermark == nil { state.watermark = page.newest }
                state.historyCursor = try advancing(page.cursor, from: state.historyCursor, seen: &seenCursors)
                if let lowerBound, let last = page.rows.last,
                   let oldest = UsageTimestamp.parse(last.created_at), oldest < lowerBound {
                    state.historyComplete = true
                    state.historyCursor = nil
                }
                try ledger.commitAsterCollection(events: page.events, state: state, hostname: hostname)
                fetched += page.rows.count
                if state.historyComplete { break }
            }
        }
        return fetched
    }

    private func advancing(_ cursor: AsterEventCursor?, from previous: AsterEventCursor?,
                           seen: inout Set<String>) throws -> AsterEventCursor {
        guard let cursor, cursor != previous,
              seen.insert(cursor.createdAt + "\u{1}" + cursor.eventID).inserted,
              let date = UsageTimestamp.parse(cursor.createdAt) else { throw AsterUsageError.invalidResponse }
        if let previous {
            guard let priorDate = UsageTimestamp.parse(previous.createdAt), date <= priorDate else {
                throw AsterUsageError.invalidResponse
            }
        }
        return cursor
    }

    private func fetch(key: String, since: Date?, cursor: AsterEventCursor?) async throws -> Page {
        var components = URLComponents(string: "https://aster.taoai.site/api/admin/events")!
        var query = [URLQueryItem(name: "limit", value: String(Self.pageLimit))]
        if let since { query.append(URLQueryItem(name: "since", value: since.ISO8601Format())) }
        if let cursor {
            query.append(URLQueryItem(name: "after_created_at", value: cursor.createdAt))
            query.append(URLQueryItem(name: "after_event_id", value: cursor.eventID))
        }
        components.queryItems = query
        guard let url = components.url else { throw AsterUsageError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AsterUsageError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AsterUsageError.network
        }
        guard let http = response as? HTTPURLResponse else { throw AsterUsageError.invalidResponse }
        guard http.statusCode != 401, http.statusCode != 403 else { throw AsterUsageError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw AsterUsageError.http(http.statusCode) }
        guard data.count <= Self.maximumResponseBytes else { throw AsterUsageError.responseTooLarge }
        return try Self.parse(data)
    }

    struct Page: Sendable {
        let rows: [Row]
        let events: [UsageEvent]
        let newest: Date?
        let cursor: AsterEventCursor?
    }

    struct Row: Decodable, Sendable {
        let event_id: String
        let provider: String
        let requested_model: String
        let upstream_model: String?
        let created_at: String
        let input_tokens: Int64
        let output_tokens: Int64
        let cache_creation_tokens: Int64
        let cache_tokens: Int64
        let reasoning_tokens: Int64
        let usage_semantic: String?
        let usage_measured: Bool?
    }

    static func parse(_ data: Data) throws -> Page {
        let rows: [Row]
        do { rows = try JSONDecoder().decode([Row].self, from: data) }
        catch { throw AsterUsageError.invalidResponse }
        guard rows.count <= pageLimit else { throw AsterUsageError.invalidResponse }
        var events: [UsageEvent] = []
        var newest: Date?
        var previous: Date?
        var seen = Set<String>()
        for row in rows {
            guard !row.event_id.isEmpty, let timestamp = UsageTimestamp.parse(row.created_at),
                  row.input_tokens >= 0, row.output_tokens >= 0, row.cache_creation_tokens >= 0,
                  row.cache_tokens >= 0, row.reasoning_tokens >= 0,
                  seen.insert(row.event_id).inserted,
                  previous.map({ timestamp <= $0 }) ?? true else { throw AsterUsageError.invalidResponse }
            newest = newest ?? timestamp
            previous = timestamp
            guard row.usage_measured != false else { continue }
            let counts = try normalizedCounts(row)
            guard counts.total > 0 else { continue }
            let identity = ContentDigest.sha256("aster\u{1}" + row.event_id)
            let model = row.upstream_model.flatMap { $0.isEmpty ? nil : $0 } ?? row.requested_model
            events.append(UsageEvent(id: identity, source: source, model: model, project: source,
                timestamp: timestamp, counts: counts, sessionHash: "", sourceFileHash: ""))
        }
        return Page(rows: rows, events: events, newest: newest,
            cursor: rows.last.map { AsterEventCursor(createdAt: $0.created_at, eventID: $0.event_id) })
    }

    private static func normalizedCounts(_ row: Row) throws -> UsageTokenCounts {
        let semantic: String
        if let declared = row.usage_semantic,
           ["independent", "separate_reasoning", "subset", "unclassified"].contains(declared) { semantic = declared }
        else {
            let provider = row.provider.lowercased()
            if ["claude", "anthropic", "kiro"].contains(where: provider.contains) { semantic = "independent" }
            else if ["gemini", "aistudio", "antigravity", "vertex", "interaction"].contains(where: provider.contains) {
                semantic = "separate_reasoning"
            } else { semantic = "subset" }
        }
        let independent = semantic == "independent"
        let separateReasoning = semantic == "separate_reasoning"
        let cached = independent ? row.cache_tokens : min(row.cache_tokens, row.input_tokens)
        let creation = independent ? row.cache_creation_tokens
            : min(row.cache_creation_tokens, row.input_tokens - cached)
        let reasoning = separateReasoning ? row.reasoning_tokens : min(row.reasoning_tokens, row.output_tokens)
        let input = independent ? row.input_tokens : row.input_tokens - cached - creation
        let output = separateReasoning ? row.output_tokens : row.output_tokens - reasoning
        var total: Int64 = 0
        for value in [input, output, cached, creation, reasoning] {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw AsterUsageError.invalidResponse }
            total = sum
        }
        return UsageTokenCounts(input: input, output: output, cachedInput: cached,
            cacheCreationInput: creation, reasoningOutput: reasoning, reportedTotal: total)
    }

    public static func boundedResponse(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: AsterRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            bytes.task.cancel()
            throw AsterUsageError.responseTooLarge
        }
        var data = Data()
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                guard data.count + buffer.count < maximumResponseBytes else { throw AsterUsageError.responseTooLarge }
                buffer.append(byte)
                if buffer.count == 64 * 1024 {
                    data.append(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            data.append(contentsOf: buffer)
        } catch {
            bytes.task.cancel()
            throw error
        }
        return (data, response)
    }
}

private final class AsterRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
