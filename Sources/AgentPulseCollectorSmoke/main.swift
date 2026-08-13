import AgentPulseCore
import Darwin
import Foundation

@main
struct AgentPulseCollectorSmoke {
    static func main() async {
        do {
            let configuration = try CodexRuntimeMetricsConfiguration.live()
            let collector = try CodexRuntimeMetricsCollector(configuration: configuration)
            let clock = ContinuousClock()
            let coldStart = clock.now
            _ = try await collector.scan()
            let coldScanMilliseconds = milliseconds(clock.now - coldStart)
            try await clock.sleep(for: .seconds(1))
            let cachedStart = clock.now
            let metrics = try await collector.scan()
            let cachedScanMilliseconds = milliseconds(clock.now - cachedStart)
            guard cachedScanMilliseconds < 2_000 else {
                throw SmokeFailure.warmScanTooSlow(milliseconds: cachedScanMilliseconds)
            }
            print("collector_smoke=pass")
            print("cold_scan_ms=\(coldScanMilliseconds)")
            print("cached_rescan_ms=\(cachedScanMilliseconds)")
            print("rollout_files_scanned=\(metrics.filesScanned)")
            print("unreadable_rollout_files=\(metrics.unreadableFiles)")
            print("files_reused_from_cache=\(metrics.filesReusedFromCache)")
            print("files_read_incrementally=\(metrics.filesReadIncrementally)")
            print("files_fully_parsed=\(metrics.filesFullyParsed)")
            print("configured_roots=\(metrics.diagnostics.configuredRoots)")
            print("canonical_roots=\(metrics.diagnostics.canonicalRoots)")
            print("jsonl_files_discovered=\(metrics.diagnostics.discoveredJSONLFiles)")
            print("aggregate_files_excluded=\(metrics.diagnostics.excludedAggregateFiles)")
            print("empty_files_excluded=\(metrics.diagnostics.excludedEmptyFiles)")
            print("stale_files_excluded=\(metrics.diagnostics.excludedStaleFiles)")
            print("duplicate_files_excluded=\(metrics.diagnostics.duplicateFiles)")
            print("live_files_tracked=\(metrics.diagnostics.trackedLiveFiles)")
            print("cli_files_tracked=\(metrics.diagnostics.cliFiles)")
            print("desktop_files_tracked=\(metrics.diagnostics.desktopFiles)")
            print("subagent_files_tracked=\(metrics.diagnostics.subagentFiles)")
            print("unknown_provider_files_tracked=\(metrics.diagnostics.unknownProviderFiles)")
            print("parsed_output_observations=\(metrics.diagnostics.parsedOutputObservations)")
            print("cumulative_observations=\(metrics.diagnostics.cumulativeObservations)")
            print("incremental_observations=\(metrics.diagnostics.incrementalObservations)")
            print("baseline_observations=\(metrics.diagnostics.baselineObservations)")
            print("counter_reset_observations=\(metrics.diagnostics.counterResetObservations)")
            print("duplicate_message_observations=\(metrics.diagnostics.duplicateMessageObservations)")
            print("emitted_token_events=\(metrics.diagnostics.emittedTokenEvents)")
            print("tokens_before_deduplication=\(metrics.diagnostics.tokensBeforeDeduplication)")
            print("tokens_after_deduplication=\(metrics.diagnostics.tokensAfterDeduplication)")
            print("overlap_tokens_180_seconds=\(String(format: "%.0f", metrics.diagnostics.overlapTokens180Seconds))")
            print("active_sessions=\(metrics.diagnostics.activeSessions)")
            print("desktop_active=\(formatted(metrics.desktopActive))")
            print("terminal_active=\(formatted(metrics.terminalActive))")
            print("completed_non_automation_lower_bound=\(formatted(metrics.completed.value))")
            print("completed_quality=\(metrics.completed.quality.rawValue)")
            print("completed_scope=\(metrics.completed.scope.rawValue)")
            print("completed_is_lower_bound=\(metrics.completed.isLowerBound)")
            print("tps_state=\(metrics.liveRate.state.rawValue)")
            print("tps_basis=\(LiveRateSample.basis)")
            print("tps_window_seconds=\(LiveRateSample.windowSeconds)")
            print("tps=\(metrics.liveRate.tps.map { String(format: "%.6f", $0) } ?? "unavailable")")
            print("history_samples_restored=\(metrics.history.count)")
            print("database=Application Support/AgentPulse/agent-pulse.sqlite")
        } catch {
            fputs("collector_smoke=failed\n", stderr)
            fputs("error_type=\(String(describing: type(of: error)))\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func formatted(_ value: Int?) -> String {
        value.map(String.init) ?? "unavailable"
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}

private enum SmokeFailure: Error {
    case warmScanTooSlow(milliseconds: Int64)
}
