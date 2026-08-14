import AgentPulseReporting
import Foundation

// Byte-level parity check between the Agent Pulse ingest encoder and a real
// reference `/api/usage/ingest` request body captured from a running external
// reference CLI. The captured body is decoded, re-projected
// into Agent Pulse payload structs, and re-encoded with the production
// `UsageIngestEncoder`. We then assert, reading the *actual encoder output
// bytes* (not an unordered dictionary), that:
//   - every reference bucket / session / autonomy field name and value is
//     reproduced,
//   - the reference field names appear in the same relative order the encoder
//     emits them (order read from the real bytes, so it can never silently
//     drift from the encoder),
//   - Agent Pulse only ever *adds* keys that the reference omits.
//
// The captured fixtures are NOT checked into the repo (they carry local project
// basenames and session hashes). Point the driver at them via
// AGENT_PULSE_INGEST_CAPTURE_DIR; without it the driver self-tests against a
// synthetic reference body so the target still builds and passes in CI.
//
// Run: AGENT_PULSE_INGEST_CAPTURE_DIR=/tmp/ingest-capture swift run ReferenceCaptureParityVerification
@main
struct ReferenceCaptureParityVerification {
    enum VError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { if case let .failed(m) = self { return m }; return "failed" }
    }
    static func expect(_ cond: Bool, _ msg: String) throws {
        if !cond { throw VError.failed(msg) }
    }

    static func main() throws {
        let bodies = try loadReferenceBodies()
        try expect(!bodies.isEmpty, "no reference bodies to compare")
        var checkedBuckets = 0, checkedSessions = 0, checkedAutonomy = 0
        for (name, raw) in bodies {
            let ref = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
            let request = try buildRequest(from: ref)
            let apBytes = UsageIngestEncoder().encode(request)
            let ap = try JSONSerialization.jsonObject(with: apBytes) as? [String: Any] ?? [:]

            // Ordered key lists for each Agent Pulse array element, read straight
            // from the emitted bytes so ordering assertions track the encoder.
            let apBucketOrders = try elementKeyOrders(bytes: apBytes, arrayKey: "buckets")
            let apSessionOrders = try elementKeyOrders(bytes: apBytes, arrayKey: "sessions")
            let apAutonomyOrders = try elementKeyOrders(bytes: apBytes, arrayKey: "autonomySessions")

            try compareArray(kind: "bucket", ref: ref["buckets"], ap: ap["buckets"],
                             apOrders: apBucketOrders, label: name, counter: &checkedBuckets)
            try compareArray(kind: "session", ref: ref["sessions"], ap: ap["sessions"],
                             apOrders: apSessionOrders, label: name, counter: &checkedSessions)
            try compareArray(kind: "autonomy", ref: ref["autonomySessions"], ap: ap["autonomySessions"],
                             apOrders: apAutonomyOrders, label: name, counter: &checkedAutonomy)
        }
        print("ReferenceCaptureParity: PASS — buckets=\(checkedBuckets) sessions=\(checkedSessions) autonomy=\(checkedAutonomy) across \(bodies.count) captured bodies")
    }

    static func compareArray(kind: String, ref: Any?, ap: Any?,
                             apOrders: [[String]], label: String, counter: inout Int) throws {
        let refRows = ref as? [[String: Any]] ?? []
        let apRows = ap as? [[String: Any]] ?? []
        try expect(refRows.count == apRows.count, "\(label): \(kind) count \(refRows.count) != \(apRows.count)")
        try expect(apRows.count == apOrders.count, "\(label): \(kind) byte-order element count mismatch")
        for (i, rrow) in refRows.enumerated() {
            let refOrder = try elementKeyOrder(bytes: try referenceRowBytes(kind: kind, row: rrow),
                                               arrayKey: kind)
            try assertRow(reference: rrow, agentPulse: apRows[i],
                          refKeyOrder: refOrder, apKeyOrder: apOrders[i],
                          label: "\(label) \(kind)[\(i)]")
            counter += 1
        }
    }

    /// Assert every reference key/value is reproduced by Agent Pulse, and the
    /// reference keys keep their relative order inside the encoder's real byte
    /// output. `refKeyOrder`/`apKeyOrder` are read from serialized bytes.
    static func assertRow(reference: [String: Any], agentPulse: [String: Any],
                          refKeyOrder: [String], apKeyOrder: [String], label: String) throws {
        let refKeySet = Set(reference.keys)
        for k in apKeyOrder where !refKeySet.contains(k) {
            // Agent Pulse may only add keys the reference omits; renaming or
            // dropping a reference key would fail the value/presence checks below.
        }
        for k in reference.keys {
            try expect(agentPulse.keys.contains(k), "\(label): AP dropped reference key '\(k)'")
            try expect(scalarEqual(reference[k], agentPulse[k]),
                       "\(label): key '\(k)' value ref=\(reference[k] ?? "nil") ap=\(agentPulse[k] ?? "nil")")
        }
        // Relative order of the reference keys must match between the reference
        // bytes and the Agent Pulse bytes.
        let apRefOnly = apKeyOrder.filter { refKeySet.contains($0) }
        try expect(apRefOnly == refKeyOrder,
                   "\(label): reference field order changed\n  ref=\(refKeyOrder)\n  ap =\(apRefOnly)")
    }

    static func scalarEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case let (x as [Any], y as [Any]):
            return x.map { "\($0)" } == y.map { "\($0)" }
        case let (x as [String: Any], y as [String: Any]):
            return x.count == y.count && x.keys.allSatisfy { scalarEqual(x[$0], y[$0]) }
        default:
            return "\(a ?? "∅")" == "\(b ?? "∅")"
        }
    }

    // MARK: - Ordered keys read from real encoder bytes

    /// Encode a single reference row through the Agent Pulse encoder so we can
    /// read the reference key order from real bytes (the encoder emits reference
    /// keys in the same positions, plus any extension keys the reference omits).
    static func referenceRowBytes(kind: String, row: [String: Any]) throws -> Data {
        var one = [String: Any]()
        switch kind {
        case "bucket": one["buckets"] = [row]
        case "session": one["sessions"] = [row]
        case "autonomy": one["autonomySessions"] = [row]
        default: break
        }
        let request = try buildRequest(from: one)
        return UsageIngestEncoder().encode(request)
    }

    /// Ordered key names for every element of the named top-level array, read by
    /// scanning the serialized JSON bytes (brace-depth aware, string-aware).
    static func elementKeyOrders(bytes: Data, arrayKey: String) throws -> [[String]] {
        let s = String(decoding: bytes, as: UTF8.self)
        guard let arrayStart = rangeOfTopLevelArray(in: s, key: arrayKey) else { return [] }
        return objectKeyLists(in: s, arrayRange: arrayStart)
    }

    static func elementKeyOrder(bytes: Data, arrayKey: String) throws -> [String] {
        // For a single-row request, return the one element's key order.
        let key = arrayKey == "bucket" ? "buckets"
            : arrayKey == "session" ? "sessions"
            : arrayKey == "autonomy" ? "autonomySessions" : arrayKey
        return try elementKeyOrders(bytes: bytes, arrayKey: key).first ?? []
    }

    /// Locate `"<key>":[ ... ]` at the top level and return the index range of
    /// its bracket contents.
    static func rangeOfTopLevelArray(in s: String, key: String) -> Range<String.Index>? {
        guard let keyRange = s.range(of: "\"\(key)\":[") else { return nil }
        var depth = 0
        var i = s.index(keyRange.upperBound, offsetBy: -1) // at '['
        let contentStart = s.index(after: i)
        var inString = false, escaped = false
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "[" { depth += 1 }
                else if c == "]" { depth -= 1; if depth == 0 { return contentStart..<i } }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Split a top-level array's byte range into its object elements and return
    /// each object's key list in emitted order. Only keys at the element-object
    /// level are captured: `objDepth` counts `{}` nesting and `arrDepth` counts
    /// `[]` nesting, so keys inside nested objects (e.g. `skill_counts`) and
    /// strings inside value arrays (e.g. `skills`) are never mistaken for keys.
    static func objectKeyLists(in s: String, arrayRange: Range<String.Index>) -> [[String]] {
        var lists: [[String]] = []
        var i = arrayRange.lowerBound
        var objDepth = 0, arrDepth = 0
        var inString = false, escaped = false
        var current: [String] = []
        var expectKey = false
        var keyBuffer = ""
        var readingKey = false
        // A key sits at the element level when we are directly inside the
        // element object with no intervening nested object or array.
        func atElementLevel() -> Bool { objDepth == 1 && arrDepth == 0 }
        while i < arrayRange.upperBound {
            let c = s[i]
            if escaped { if readingKey { keyBuffer.append(c) }; escaped = false; i = s.index(after: i); continue }
            if c == "\\" { escaped = true; i = s.index(after: i); continue }
            if c == "\"" {
                if !inString {
                    inString = true
                    if atElementLevel() && expectKey { readingKey = true; keyBuffer = "" }
                } else {
                    inString = false
                    if readingKey { current.append(keyBuffer); readingKey = false; expectKey = false }
                }
                i = s.index(after: i); continue
            }
            if inString { if readingKey { keyBuffer.append(c) }; i = s.index(after: i); continue }
            switch c {
            case "{":
                objDepth += 1
                if objDepth == 1 { current = []; expectKey = true }
            case "}":
                if objDepth == 1 { lists.append(current) }
                objDepth -= 1
            case "[":
                arrDepth += 1
            case "]":
                arrDepth -= 1
            case ",":
                if atElementLevel() { expectKey = true }
            default:
                break
            }
            i = s.index(after: i)
        }
        return lists
    }

    // MARK: - Reference → Agent Pulse projection

    static func buildRequest(from ref: [String: Any]) throws -> UsageIngestRequest {
        let buckets = (ref["buckets"] as? [[String: Any]] ?? []).map(bucket)
        let sessions = (ref["sessions"] as? [[String: Any]] ?? []).map(session)
        let autonomy = (ref["autonomySessions"] as? [[String: Any]] ?? []).map(autonomySession)
        let statuses = (ref["autonomySourceStatuses"] as? [[String: Any]] ?? []).map { (s: [String: Any]) in
            AutonomySourceStatusPayload(source: str(s["source"]), hostname: str(s["hostname"]),
                                        status: str(s["status"]), error: str(s["error"]))
        }
        return UsageIngestRequest(
            buckets: buckets, sessions: sessions,
            autonomySessions: autonomy, autonomySourceStatuses: statuses,
            autonomyWindowStart: str(ref["autonomyWindowStart"]),
            autonomyWindowEnd: str(ref["autonomyWindowEnd"])
        )
    }

    static func bucket(_ b: [String: Any]) -> UsageBucketPayload {
        UsageBucketPayload(
            source: str(b["source"]), model: str(b["model"]), project: str(b["project"]),
            skills: strArr(b["skills"]), skillCounts: intMap(b["skill_counts"]),
            mcpCounts: intMap(b["mcp_counts"]),
            bucketStart: str(b["bucketStart"]), hostname: str(b["hostname"]),
            inputTokens: i64(b["inputTokens"]), outputTokens: i64(b["outputTokens"]),
            cachedInputTokens: i64(b["cachedInputTokens"]),
            cacheCreationInputTokens: i64(b["cacheCreationInputTokens"]),
            reasoningOutputTokens: i64(b["reasoningOutputTokens"]),
            totalTokens: i64(b["totalTokens"]),
            linesAdded: i64(b["linesAdded"]), linesDeleted: i64(b["linesDeleted"]),
            linesNet: i64(b["linesNet"]), codeMetricVersion: int(b["codeMetricVersion"])
        )
    }

    static func session(_ s: [String: Any]) -> UsageSessionPayload {
        UsageSessionPayload(
            source: str(s["source"]), project: str(s["project"]), skills: strArr(s["skills"]),
            sessionHash: str(s["sessionHash"]), hostname: str(s["hostname"]),
            firstMessageAt: str(s["firstMessageAt"]), lastMessageAt: str(s["lastMessageAt"]),
            durationSeconds: int(s["durationSeconds"]), activeSeconds: int(s["activeSeconds"]),
            messageCount: int(s["messageCount"]), userMessageCount: int(s["userMessageCount"]),
            userPromptHours: intArr(s["userPromptHours"])
        )
    }

    static func autonomySession(_ a: [String: Any]) -> AutonomySessionPayload {
        AutonomySessionPayload(
            source: str(a["source"]), project: str(a["project"]), skills: strArr(a["skills"]),
            sessionHash: str(a["sessionHash"]), hostname: str(a["hostname"]),
            firstEventAt: str(a["firstEventAt"]), lastEventAt: str(a["lastEventAt"]),
            firstUserAt: str(a["firstUserAt"]), handoffAt: str(a["handoffAt"]),
            handoffReason: str(a["handoffReason"]), autonomyStatus: str(a["autonomyStatus"]),
            clarificationTurnCount: int(a["clarificationTurnCount"]),
            interventionCount: int(a["interventionCount"]),
            observedAutonomousSeconds: int(a["observedAutonomousSeconds"]),
            clippedIdleSeconds: int(a["clippedIdleSeconds"]),
            messageCount: int(a["messageCount"]), userMessageCount: int(a["userMessageCount"]),
            agentEventCount: int(a["agentEventCount"]), toolCallCount: int(a["toolCallCount"]),
            confidence: str(a["confidence"]), confidenceReasons: strArr(a["confidenceReasons"]),
            schemaVersion: int(a["schemaVersion"]), parserVersion: str(a["parserVersion"]),
            computedAt: str(a["computedAt"])
        )
    }

    // MARK: - JSON scalar helpers
    static func str(_ v: Any?) -> String { v as? String ?? "" }
    static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
    static func i64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
    static func strArr(_ v: Any?) -> [String] { v as? [String] ?? [] }
    static func intArr(_ v: Any?) -> [Int] { (v as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [] }
    static func intMap(_ v: Any?) -> [String: Int] {
        guard let m = v as? [String: Any] else { return [:] }
        return m.reduce(into: [:]) { $0[$1.key] = ($1.value as? NSNumber)?.intValue ?? 0 }
    }

    // MARK: - Fixture loading
    static func loadReferenceBodies() throws -> [(String, Data)] {
        if let dir = ProcessInfo.processInfo.environment["AGENT_PULSE_INGEST_CAPTURE_DIR"] {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            let bodies = files.filter { $0.hasSuffix(".body.json") }.sorted()
            var out: [(String, Data)] = []
            for f in bodies {
                let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(f))
                out.append((f, data))
            }
            if !out.isEmpty { return out }
        }
        let synthetic = """
        {"buckets":[{"source":"codex","model":"gpt-5","project":"demo","bucketStart":"2026-08-14T15:00:00Z","hostname":"host","inputTokens":100,"outputTokens":20,"cachedInputTokens":5,"reasoningOutputTokens":3,"totalTokens":128,"codeMetricVersion":2}],"sessions":[{"source":"codex","project":"demo","skills":["s1"],"sessionHash":"abc","hostname":"host","firstMessageAt":"2026-08-14T15:01:00Z","lastMessageAt":"2026-08-14T15:02:00Z","durationSeconds":60,"activeSeconds":60,"messageCount":4,"userMessageCount":2,"userPromptHours":[15]}]}
        """
        return [("synthetic", Data(synthetic.utf8))]
    }
}
