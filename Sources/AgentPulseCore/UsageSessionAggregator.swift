import Foundation

/// 从 append-only 的会话活动事件重建会话级派生聚合。
///
/// 纯函数、无副作用；账本在 finalizeDerived / hostname 重建时调用它，
/// 由调用方在同一事务内落库，避免旧的错误 hostname 或过期聚合残留。
public enum UsageSessionAggregator {
    /// 活跃秒数分段规则：
    /// - 一个 user / synthetic_user 事件锚定一段对话的开始（计时从首个后续 assistant 起）。
    /// - 首个 assistant 打开计时段（段起点 = 该 assistant 时间戳）。
    /// - 后续 assistant 持续延长段终点。
    /// - 下一个 user / synthetic_user 关闭当前段并重新锚定。
    /// 活跃秒数 = 各段 (段终点 - 段起点) 之和。
    ///
    /// - messageCount: 去重后的全部会话事件数。
    /// - userMessageCount: 非 synthetic 的 user 事件数。
    /// - hourHistogramUTC: 按「非 synthetic user prompt」的 UTC 小时落桶（长度 24）。
    /// - projectForSession: 按自然键 (source, sessionHash) 解析该会话的 project 内容字段；
    ///   project 不参与分组 / 去重 / 排序（自然键仍为 hostname/source/sessionHash），
    ///   仅作为内容字段写入结果。默认返回空串，调用方（账本）可注入真实来源。
    /// - hostname: 派生会话归属的本机采集标识（单一本机口径）。原始事件虽携带各自
    ///   采集机 hostname，但派生统一归属传入的 hostname；历史归属由改名时的原地 UPDATE 维护。
    public static func aggregate(
        events: [UsageSessionEvent],
        hostname: String,
        projectForSession: (_ source: String, _ sessionHash: String) -> String = { _, _ in "" },
        skillsForSession: (_ source: String, _ sessionHash: String) -> [String] = { _, _ in [] }
    ) -> [UsageSession] {
        // 1) 去重：按 (source, eventID)。
        var deduped: [String: UsageSessionEvent] = [:]
        for event in events {
            deduped["\(event.source)\u{0}\(event.id)"] = event
        }

        // 2) 分组：按 (source, sessionHash)。
        var grouped: [SessionGroupKey: [UsageSessionEvent]] = [:]
        for event in deduped.values {
            grouped[SessionGroupKey(source: event.source, sessionHash: event.sessionHash), default: []].append(event)
        }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        var sessions: [UsageSession] = []
        for (key, rawEvents) in grouped {
            // 3) 时间排序（同刻 user / synthetic_user 在 assistant 之前，保证段边界确定）。
            let sorted = rawEvents.sorted { left, right in
                if left.timestamp != right.timestamp { return left.timestamp < right.timestamp }
                return roleRank(left.role) < roleRank(right.role)
            }
            guard let first = sorted.first else { continue }

            var activeSeconds: Double = 0
            var messageCount: Int64 = 0
            var userMessageCount: Int64 = 0
            var assistantEvents: Int64 = 0
            var histogram = [Int64](repeating: 0, count: 24)

            var anchoredByUser = false
            var segmentStart: Date?
            var segmentEnd: Date?
            var lastActivity = first.timestamp

            func closeSegment() {
                if let start = segmentStart, let end = segmentEnd, end > start {
                    activeSeconds += end.timeIntervalSince(start)
                }
                segmentStart = nil
                segmentEnd = nil
            }

            for event in sorted {
                messageCount += 1
                lastActivity = max(lastActivity, event.timestamp)
                switch event.role {
                case .user:
                    userMessageCount += 1
                    // 直方图按非 synthetic user prompt 落桶。
                    let hour = utcCalendar.component(.hour, from: event.timestamp)
                    if hour >= 0 && hour < 24 { histogram[hour] += 1 }
                    closeSegment()
                    anchoredByUser = true
                case .syntheticUser:
                    // 参与时间线锚定，但不计入 userMessageCount / 直方图。
                    closeSegment()
                    anchoredByUser = true
                case .assistant:
                    assistantEvents += 1
                    if anchoredByUser {
                        if segmentStart == nil {
                            segmentStart = event.timestamp
                            segmentEnd = event.timestamp
                        } else {
                            segmentEnd = event.timestamp
                        }
                    }
                }
            }
            closeSegment()

            sessions.append(UsageSession(
                hostname: hostname,
                source: key.source,
                sessionHash: key.sessionHash,
                project: projectForSession(key.source, key.sessionHash),
                skills: skillsForSession(key.source, key.sessionHash),
                firstActivity: first.timestamp,
                lastActivity: lastActivity,
                activeSeconds: Int64(activeSeconds.rounded()),
                messageCount: messageCount,
                userMessageCount: userMessageCount,
                assistantEvents: assistantEvents,
                hourHistogramUTC: histogram
            ))
        }

        return sessions.sorted { left, right in
            if left.source != right.source { return left.source < right.source }
            return left.sessionHash < right.sessionHash
        }
    }

    private struct SessionGroupKey: Hashable {
        let source: String
        let sessionHash: String
    }

    private static func roleRank(_ role: UsageSessionEvent.Role) -> Int {
        switch role {
        case .user: return 0
        case .syntheticUser: return 1
        case .assistant: return 2
        }
    }
}
