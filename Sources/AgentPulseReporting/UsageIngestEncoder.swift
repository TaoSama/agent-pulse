import Foundation

// Serializes UsageIngestRequest into the exact JSON byte layout the backend
// accepts. The struct-tag ordering and empty-value elision of the server's
// request schema are reproduced deterministically here rather than relying on
// JSONEncoder, which sorts or randomizes object keys and cannot express
// per-field "omit when empty" rules.
//
// Rules encoded:
// - Object keys are emitted in schema-declared order.
// - "omit when empty" fields (empty string is NOT omitted here; only the
//   fields whose schema marks them optional) are dropped when they hold an
//   empty array, empty object, or the integer zero.
// - All other fields are always present, even at their zero value.
public struct UsageIngestEncoder: Sendable {
    public init() {}

    /// Encodes the request into UTF-8 JSON bytes.
    public func encode(_ request: UsageIngestRequest) -> Data {
       var root = JSONObjectBuilder()
       root.putArray("buckets", request.buckets.map(Self.bucketNode)) // always present
        root.putArrayOmitEmpty("sessions", request.sessions.map(Self.sessionNode))
        root.putArrayOmitEmpty("autonomySessions", request.autonomySessions.map(Self.autonomySessionNode))
        root.putArrayOmitEmpty("autonomySourceStatuses", request.autonomySourceStatuses.map(Self.autonomyStatusNode))
        root.putStringOmitEmpty("autonomyWindowStart", request.autonomyWindowStart)
        root.putStringOmitEmpty("autonomyWindowEnd", request.autonomyWindowEnd)
        root.putBoolOmitFalse("fullSync", request.fullSync)
        root.putBoolOmitFalse("fullSyncReset", request.fullSyncReset)
        return root.finish()
    }

    private static func bucketNode(_ b: UsageBucketPayload) -> JSONNode {
        var o = JSONObjectBuilder()
        o.putString("source", b.source)
        o.putString("model", b.model)
        o.putString("project", b.project)
        o.putStringArrayOmitEmpty("skills", b.skills)
        o.putStringIntMapOmitEmpty("skill_counts", b.skillCounts)
        o.putStringIntMapOmitEmpty("mcp_counts", b.mcpCounts)
        o.putString("bucketStart", b.bucketStart)
        o.putString("hostname", b.hostname)
        o.putInt("inputTokens", Int(b.inputTokens))
        o.putInt("outputTokens", Int(b.outputTokens))
        o.putInt("cachedInputTokens", Int(b.cachedInputTokens))
        o.putIntOmitZero("cacheCreationInputTokens", Int(b.cacheCreationInputTokens))
        o.putInt("reasoningOutputTokens", Int(b.reasoningOutputTokens))
        o.putInt("totalTokens", Int(b.totalTokens))
        o.putIntOmitZero("linesAdded", Int(b.linesAdded))
        o.putIntOmitZero("linesDeleted", Int(b.linesDeleted))
        o.putIntOmitZero("linesNet", Int(b.linesNet))
        o.putIntOmitZero("codeMetricVersion", b.codeMetricVersion)
        return .object(o)
    }

    private static func sessionNode(_ s: UsageSessionPayload) -> JSONNode {
        var o = JSONObjectBuilder()
        o.putString("source", s.source)
        o.putString("project", s.project)
        o.putStringArrayOmitEmpty("skills", s.skills)
        o.putString("sessionHash", s.sessionHash)
        o.putString("hostname", s.hostname)
        o.putString("firstMessageAt", s.firstMessageAt)
        o.putString("lastMessageAt", s.lastMessageAt)
        o.putInt("durationSeconds", s.durationSeconds)
        o.putInt("activeSeconds", s.activeSeconds)
        o.putInt("messageCount", s.messageCount)
        o.putInt("userMessageCount", s.userMessageCount)
        o.putIntArray("userPromptHours", s.userPromptHours) // always present, even when empty
        return .object(o)
    }

    private static func autonomySessionNode(_ a: AutonomySessionPayload) -> JSONNode {
        var o = JSONObjectBuilder()
        o.putString("source", a.source)
        o.putString("project", a.project)
        o.putStringArrayOmitEmpty("skills", a.skills)
        o.putString("sessionHash", a.sessionHash)
        o.putString("hostname", a.hostname)
        o.putString("firstEventAt", a.firstEventAt)
        o.putString("lastEventAt", a.lastEventAt)
        o.putStringOmitEmpty("firstUserAt", a.firstUserAt)
        o.putStringOmitEmpty("handoffAt", a.handoffAt)
        o.putStringOmitEmpty("handoffReason", a.handoffReason)
        o.putString("autonomyStatus", a.autonomyStatus)
        o.putInt("clarificationTurnCount", a.clarificationTurnCount)
        o.putInt("interventionCount", a.interventionCount)
        o.putInt("observedAutonomousSeconds", a.observedAutonomousSeconds)
        o.putInt("clippedIdleSeconds", a.clippedIdleSeconds)
        o.putInt("messageCount", a.messageCount)
        o.putInt("userMessageCount", a.userMessageCount)
        o.putInt("agentEventCount", a.agentEventCount)
        o.putInt("toolCallCount", a.toolCallCount)
        o.putString("confidence", a.confidence)
        o.putStringArrayOmitEmpty("confidenceReasons", a.confidenceReasons)
        o.putInt("schemaVersion", a.schemaVersion)
        o.putStringOmitEmpty("parserVersion", a.parserVersion)
        o.putString("computedAt", a.computedAt)
        return .object(o)
    }

    private static func autonomyStatusNode(_ s: AutonomySourceStatusPayload) -> JSONNode {
        var o = JSONObjectBuilder()
        o.putString("source", s.source)
        o.putString("hostname", s.hostname)
        o.putString("status", s.status)
        o.putStringOmitEmpty("error", s.error)
        return .object(o)
    }
}

// MARK: - Ordered JSON building

/// A minimal ordered JSON value tree. Only the shapes required by the ingest
/// schema are modeled; this keeps key ordering explicit and side-steps the
/// unordered object output of the standard encoder.
enum JSONNode {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONNode])
    case object(JSONObjectBuilder)
}

/// Accumulates object members in insertion order and serializes them.
struct JSONObjectBuilder {
    private var members: [(key: String, value: JSONNode)] = []

    mutating func putString(_ key: String, _ value: String) {
        members.append((key, .string(value)))
    }

    mutating func putStringOmitEmpty(_ key: String, _ value: String) {
        guard !value.isEmpty else { return }
        members.append((key, .string(value)))
    }

    mutating func putBoolOmitFalse(_ key: String, _ value: Bool) {
        guard value else { return }
        members.append((key, .bool(value)))
    }

    mutating func putInt(_ key: String, _ value: Int) {
        members.append((key, .int(value)))
    }

    mutating func putIntOmitZero(_ key: String, _ value: Int) {
        guard value != 0 else { return }
        members.append((key, .int(value)))
    }

    mutating func putIntArray(_ key: String, _ values: [Int]) {
        members.append((key, .array(values.map(JSONNode.int))))
    }

    mutating func putStringArrayOmitEmpty(_ key: String, _ values: [String]) {
        guard !values.isEmpty else { return }
        members.append((key, .array(values.map(JSONNode.string))))
    }

    mutating func putStringIntMapOmitEmpty(_ key: String, _ map: [String: Int]) {
        guard !map.isEmpty else { return }
        // Object keys are sorted so the serialized bytes are deterministic for
        // tests and idempotent transports; map order is not semantically
        // meaningful on the wire.
        var o = JSONObjectBuilder()
        for k in map.keys.sorted() {
            o.putInt(k, map[k]!)
        }
        members.append((key, .object(o)))
    }

    mutating func putArray(_ key: String, _ nodes: [JSONNode]) {
        members.append((key, .array(nodes)))
    }

    mutating func putArrayOmitEmpty(_ key: String, _ nodes: [JSONNode]) {
        guard !nodes.isEmpty else { return }
        members.append((key, .array(nodes)))
    }

    func finish() -> Data {
        var out = String()
        Self.write(.object(self), into: &out)
        return Data(out.utf8)
    }

    static func write(_ node: JSONNode, into out: inout String) {
        switch node {
        case let .string(s):
            out.append(encodeString(s))
        case let .int(i):
            out.append(String(i))
        case let .bool(b):
            out.append(b ? "true" : "false")
        case let .array(items):
            out.append("[")
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(",") }
                write(item, into: &out)
            }
            out.append("]")
        case let .object(builder):
            out.append("{")
            for (index, member) in builder.members.enumerated() {
                if index > 0 { out.append(",") }
                out.append(encodeString(member.key))
                out.append(":")
                write(member.value, into: &out)
            }
            out.append("}")
        }
    }

    /// Escapes a string with deterministic JSON rules (including HTML-safe
    /// escaping of < > &) so encoded bytes are stable for shared inputs.
    static func encodeString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result.append("\\\"")
            case "\\":
                result.append("\\\\")
            case "\n":
                result.append("\\n")
            case "\r":
                result.append("\\r")
            case "\t":
                result.append("\\t")
            case "<":
                result.append("\\u003c")
            case ">":
                result.append("\\u003e")
            case "&":
                result.append("\\u0026")
            default:
                if scalar.value < 0x20 {
                    result.append(String(format: "\\u%04x", scalar.value))
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result.append("\"")
        return result
    }
}
