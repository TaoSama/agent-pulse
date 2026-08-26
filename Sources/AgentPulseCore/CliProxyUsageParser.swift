import CryptoKit
import CoreFoundation
import Foundation

/// cliproxyapi management `/v0/management/usage` 响应的采集与映射。
///
/// 该端点返回全量、无界、按 `endpoint → model → details[]` 分组的逐请求明细，
/// 不支持任何服务端过滤。本解析器在**本地**按目标 apikey 的 SHA256 与每条明细的
/// `api_key_hash` 精确比对，只提取目标 key 的用量，映射为账本可直接 record 的
/// `UsageEvent`，复用既有 finalizeDerived / 上报链路。
///
/// 隐私：产出的 `UsageEvent` 只含 hash 后的 key 身份、resolved model、token 计数与
/// 时间戳；绝不保留明文 apikey、掩码 source、base URL 或 management key。
public enum CliProxyUsageParser {
    /// 采集来源标识，与 `codex` / `claude-code` 并列。
    public static let source = "cliproxy"

    /// 解析器版本；字段口径或去重策略变化时递增。
    public static let parserVersion = 1

    /// 目标 apikey 明文的 SHA256 hex（服务端 `api_key_hash` 的口径，已实测验证）。
    public static func apiKeyHash(for plaintextKey: String) -> String {
        SHA256.hash(data: Data(plaintextKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 目标 apikey 的稳定短身份（不含明文），用作账本 project / sessionHash 维度。
    public static func apiKeyIdentity(for plaintextKey: String) -> String {
        String(apiKeyHash(for: plaintextKey).prefix(16))
    }

    /// 从 usage JSON 数据中提取目标 apikey 的用量事件。
    ///
    /// - Parameters:
    ///   - data: `/v0/management/usage` 的完整响应体。
    ///   - targetAPIKey: 要监控的目标 apikey（明文，仅用于本地计算 SHA256 比对，不外发）。
    /// - Returns: 目标 key 的 `UsageEvent` 列表；数据不可解析或无匹配时返回空数组。
    public static func parse(
        data: Data,
        targetAPIKey: String,
        sourceIdentifier: String? = nil
    ) -> [UsageEvent] {
        let trimmedKey = targetAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return [] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let apis = root["apis"] as? [String: Any] else { return [] }

        let targetHash = apiKeyHash(for: trimmedKey)
        let identity = sourceIdentity(apiKeyHash: targetHash, sourceIdentifier: sourceIdentifier)

        var events: [UsageEvent] = []
        var seenIDs = Set<String>()

        for (_, apiValue) in apis {
            guard let apiObject = apiValue as? [String: Any],
                  let models = apiObject["models"] as? [String: Any] else { continue }
            for (groupModel, modelValue) in models {
                guard let modelObject = modelValue as? [String: Any],
                      let details = modelObject["details"] as? [[String: Any]] else { continue }
                for detail in details {
                    guard string(detail["api_key_hash"]) == targetHash else { continue }
                    guard let event = event(
                        from: detail,
                        groupModel: groupModel,
                        identity: identity,
                        seenIDs: &seenIDs
                    ) else { continue }
                    events.append(event)
                }
            }
        }
        return events
    }

    /// 默认来源沿用历史 key 身份；具名来源把来源标识纳入不可逆身份，避免相同 key
    /// 在多个 CPA 部署上的事件 ID / bucket 自然键碰撞。
    static func sourceIdentity(apiKeyHash: String, sourceIdentifier: String?) -> String {
        guard let sourceIdentifier = sourceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceIdentifier.isEmpty else {
            return String(apiKeyHash.prefix(16))
        }
        return String(hash("cliproxy-source|\(sourceIdentifier)|\(apiKeyHash)").prefix(16))
    }

    /// 把单条 detail 映射为一个 `UsageEvent`；无有效时间戳或零用量时跳过。
    private static func event(
        from detail: [String: Any],
        groupModel: String,
        identity: String,
        seenIDs: inout Set<String>
    ) -> UsageEvent? {
        guard let timestamp = UsageTimestamp.parse(detail["timestamp"]) else { return nil }
        let model = nonemptyString(detail["resolved_model"]) ?? nonemptyString(groupModel) ?? "unknown"
        let counts = tokenCounts(dictionary(detail["tokens"]))
        guard counts.total > 0 else { return nil }

        // 稳定幂等 id：绑定目标 key 身份 + model + 纳秒时间戳 + 归一后各分量，
        // 重复整包下载不会重复计数（账本按 event_id 幂等 UPSERT）。
        let eventID = hash("cliproxy-usage|\(identity)|\(model)|\(iso(timestamp))|\(usageIdentity(counts))")
        guard seenIDs.insert(eventID).inserted else { return nil }

        return UsageEvent(
            id: eventID,
            source: source,
            model: model,
            project: identity,
            timestamp: timestamp,
            counts: counts,
            sessionHash: identity,
            sourceFileHash: identity,
            rolloutKey: "",
            parentRolloutKey: "",
            inherited: false,
            hasTotalSnapshot: false,
            lineageFingerprint: ""
        )
    }

    /// tokens 对象 → `UsageTokenCounts`。
    ///
    /// 口径与仓库既有 Codex parser 一致：`input_tokens` 为原始 prompt 总量（含
    /// cache_read / cache_creation），据此把缓存分量从 raw input 里减出，避免重复计。
    static func tokenCounts(_ tokens: [String: Any]) -> UsageTokenCounts {
        let rawInput = integer(tokens["input_tokens"])
        let rawOutput = integer(tokens["output_tokens"])
        let cached = min(rawInput, integer(tokens["cache_read_tokens"]) + integer(tokens["cached_tokens"]) + integer(tokens["cache_tokens"]))
        let creation = min(max(0, rawInput - cached), integer(tokens["cache_creation_tokens"]))
        let reasoning = min(rawOutput, integer(tokens["reasoning_tokens"]))
        return UsageTokenCounts(
            input: rawInput - cached - creation,
            output: rawOutput - reasoning,
            cachedInput: cached,
            cacheCreationInput: creation,
            reasoningOutput: reasoning,
            reportedTotal: integer(tokens["total_tokens"])
        )
    }

    // MARK: - Helpers

    private static func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private static func string(_ value: Any?) -> String? { value as? String }
    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private static func nonemptyString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func integer(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.int64Value }
        return Int64(value as? String ?? "") ?? 0
    }
    private static func usageIdentity(_ counts: UsageTokenCounts) -> String {
        "\(counts.input)|\(counts.output)|\(counts.cachedInput)|\(counts.cacheCreationInput)|\(counts.reasoningOutput)|\(counts.reportedTotal)"
    }
    private static func iso(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
