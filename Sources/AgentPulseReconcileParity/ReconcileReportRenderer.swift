import Foundation

/// 把对齐结果渲染成脱敏文本表：只输出字段名、聚合数与 ✓/✗，
/// 绝不输出 token、凭证、会话正文、完整路径。hostname 本身是设备标识
/// （非机密），可展示。
public enum ReconcileReportRenderer {
    /// 渲染单个 hostname 的对齐报告。
    public static func render(_ comparison: HostnameComparison) -> String {
        var lines: [String] = []
        let header = "hostname=\(comparison.hostname) · 上游=\(comparison.upstreamPresent ? "有数据" : "无此设备数据")"
        lines.append(header)
        lines.append(String(repeating: "-", count: max(header.count, 40)))

        for field in comparison.fields {
            lines.append(renderField(field))
        }

        let verdict = comparison.isAligned
            ? "✅ 全部权威维度一致"
            : "❌ 存在不一致（见上方 ✗ 行）"
        lines.append(String(repeating: "-", count: max(header.count, 40)))
        lines.append(verdict)
        return lines.joined(separator: "\n")
    }

    /// 渲染多个 hostname + 总结。
    public static func renderAll(_ comparisons: [HostnameComparison]) -> String {
        guard !comparisons.isEmpty else {
            return "（无本地 hostname 聚合可对齐）"
        }
        var blocks = comparisons.map(render)
        let alignedCount = comparisons.filter(\.isAligned).count
        blocks.append("=== 总结：\(alignedCount)/\(comparisons.count) 个 hostname 全部权威维度一致 ===")
        return blocks.joined(separator: "\n\n")
    }

    private static func renderField(_ field: FieldComparison) -> String {
        let marker: String
        switch field.kind {
        case .authoritative:
            marker = (field.equal ?? false) ? "✓" : "✗"
        case .localOnlyDetail:
            marker = "·"
        case .advisory:
            marker = "~"
        }
        let name = field.field.padding(toLength: 30, withPad: " ", startingAt: 0)
        return "\(marker) \(name) AP=\(field.localValue) | 上游=\(field.upstreamValue)"
    }
}
