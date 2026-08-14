import AgentPulseReporting
import AgentPulseUsage
import Foundation

// Dependency-free verification that the full-sync path shares the exact same
// wire-field normalization and natural-key collision rejection as the
// incremental ingest client. Both must:
//   - stamp the canonical hostname and apply identical per-field byte caps,
//   - collapse and reject duplicate natural keys per dimension
//     (bucket: hostname+source+model+project+bucketStart;
//      session/autonomy: hostname+source+sessionHash),
//   - serialize a normalized row byte-for-byte identically on either wire,
//   - and run the guard as a pure, side-effect-free step (no token, no I/O),
//     rejecting a collision before returning any bound snapshot.
// Run with: swift run FullSyncWireParityVerification
@main
struct FullSyncWireParityVerification {
    static func main() throws {
        try verifyHostnameAndCapsMatchIncremental()
        try verifyBucketRowBytesMatchIncrementalWire()
        try verifyDuplicateBucketKeyRejected()
        try verifyDuplicateSessionKeyRejectedIgnoringProject()
        try verifyDuplicateAutonomyKeyRejected()
        try verifyNormalizedCapCollapseRejected()
        try verifyCrossDimensionOverlapPasses()
        try verifyCollisionReturnsNoSnapshotAndIsPure()
        try verifyRawGenerationPreserved()
        print("FullSyncWireParity verification passed")
    }

    enum VerificationError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { if case let .failed(m) = self { return m }; return "failed" }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationError.failed(message) }
    }

    private static func expectDuplicate(
        _ error: Error,
        dimension: IngestClientError.NaturalKeyDimension,
        label: String
    ) throws {
        guard let ingestError = error as? IngestClientError else {
            throw VerificationError.failed("\(label): expected IngestClientError, got \(error)")
        }
        guard ingestError == .duplicateNaturalKey(dimension: dimension) else {
            throw VerificationError.failed("\(label): wrong error: \(ingestError)")
        }
    }

    // MARK: - Fixtures

    private static let hostname = "  Device-Host.LOCAL  "

    private static func bucket(model: String, source: String = "codex", project: String = "demo", start: String = "2026-01-01T00:00:00Z") -> UsageBucketPayload {
        UsageBucketPayload(source: source, model: model, project: project, bucketStart: start, hostname: "ignored-host", totalTokens: 7)
    }

    private static func session(project: String, hash: String, source: String = "codex") -> UsageSessionPayload {
        UsageSessionPayload(source: source, project: project, sessionHash: hash, hostname: "ignored-host", firstMessageAt: "2026-01-01T00:00:00Z", lastMessageAt: "2026-01-01T00:30:00Z")
    }

    private static func autonomy(project: String, hash: String, source: String = "codex") -> AutonomySessionPayload {
        AutonomySessionPayload(source: source, project: project, sessionHash: hash, hostname: "ignored-host", firstEventAt: "2026-01-01T00:00:00Z", lastEventAt: "2026-01-01T00:30:00Z", autonomyStatus: "autonomous", confidence: "high", computedAt: "2026-01-01T00:30:00Z")
    }

    private static func snapshot(
        buckets: [UsageBucketPayload] = [],
        sessions: [UsageSessionPayload] = [],
        autonomySessions: [AutonomySessionPayload] = [],
        rawGeneration: Int64 = 42
    ) -> FullSyncPayloadSnapshot {
        FullSyncPayloadSnapshot(buckets: buckets, sessions: sessions, autonomySessions: autonomySessions, rawGeneration: rawGeneration)
    }

    // MARK: - (a) hostname + caps parity

    private static func verifyHostnameAndCapsMatchIncremental() throws {
        let longSource = String(repeating: "s", count: 80)
        let longModel = String(repeating: "m", count: 400)
        let longProject = String(repeating: "p", count: 300)
        let normalized = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(
            from: snapshot(buckets: [bucket(model: longModel, source: longSource, project: longProject)]),
            hostname: hostname
        )
        let row = normalized.buckets[0]
        try expect(row.hostname == CanonicalHostname.normalize(hostname), "hostname must be canonicalized identically")
        try expect(row.source == UsageIngestClient.truncate(longSource, UsageWireNormalizer.sourceMaxBytes), "source cap parity")
        try expect(row.model == UsageIngestClient.truncate(longModel, UsageWireNormalizer.modelMaxBytes), "model cap parity")
        try expect(row.project == UsageIngestClient.truncate(longProject, UsageWireNormalizer.projectMaxBytes), "project cap parity")
        try expect(Array(row.source.utf8).count <= UsageWireNormalizer.sourceMaxBytes, "source within byte cap")
        try expect(Array(row.model.utf8).count <= UsageWireNormalizer.modelMaxBytes, "model within byte cap")
        try expect(Array(row.project.utf8).count <= UsageWireNormalizer.projectMaxBytes, "project within byte cap")
    }

    // MARK: - (b) staged row bytes equal incremental wire

    private static func verifyBucketRowBytesMatchIncrementalWire() throws {
        let encoder = UsageIngestEncoder()
        let raw = bucket(model: "gpt-<x>&y", source: "co dex", project: "proj/與")
        // Full-sync normalized row.
        let fs = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(from: snapshot(buckets: [raw]), hostname: hostname)
        // Incremental normalized row via the shared normalizer + shared encoder.
        let incremental = UsageWireNormalizer.normalize(UsageIngestRequest(buckets: [raw]), hostname: hostname)
        let fsBytes = encoder.encode(UsageIngestRequest(buckets: fs.buckets))
        let incBytes = encoder.encode(incremental)
        try expect(fsBytes == incBytes, "full-sync bucket bytes must equal incremental wire bytes")
    }

    // MARK: - (c) duplicate bucket key

    private static func verifyDuplicateBucketKeyRejected() throws {
        let s = snapshot(buckets: [bucket(model: "gpt"), bucket(model: "gpt")])
        do {
            _ = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(from: s, hostname: hostname)
            try expect(false, "duplicate bucket key must be rejected")
        } catch { try expectDuplicate(error, dimension: .buckets, label: "buckets") }
    }

    // MARK: - (d) duplicate session key ignoring project

    private static func verifyDuplicateSessionKeyRejectedIgnoringProject() throws {
        let s = snapshot(sessions: [session(project: "demo", hash: "h1"), session(project: "other", hash: "h1")])
        do {
            _ = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(from: s, hostname: hostname)
            try expect(false, "duplicate session key must be rejected")
        } catch { try expectDuplicate(error, dimension: .sessions, label: "sessions") }
    }

    // MARK: - (e) duplicate autonomy key

    private static func verifyDuplicateAutonomyKeyRejected() throws {
        let s = snapshot(autonomySessions: [autonomy(project: "demo", hash: "h1"), autonomy(project: "other", hash: "h1")])
        do {
            _ = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(from: s, hostname: hostname)
            try expect(false, "duplicate autonomy key must be rejected")
        } catch { try expectDuplicate(error, dimension: .autonomySessions, label: "autonomy") }
    }

    // MARK: - (f) normalized-cap collapse rejected (parity with incremental)

    private static func verifyNormalizedCapCollapseRejected() throws {
        let longA = String(repeating: "m", count: 255) + "-tail-a"
        let longB = String(repeating: "m", count: 255) + "-tail-b"
        let s = snapshot(buckets: [bucket(model: longA), bucket(model: longB)])
        do {
            _ = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(from: s, hostname: hostname)
            try expect(false, "rows collapsing to one normalized key must be rejected")
        } catch { try expectDuplicate(error, dimension: .buckets, label: "normalized") }
    }

    // MARK: - (g) cross-dimension overlap is allowed

    private static func verifyCrossDimensionOverlapPasses() throws {
        // Same hash reused across sessions and autonomy is fine; only WITHIN a
        // dimension are duplicates rejected.
        let s = snapshot(
            buckets: [bucket(model: "gpt", start: "2026-01-01T00:00:00Z"), bucket(model: "gpt", start: "2026-01-01T01:00:00Z")],
            sessions: [session(project: "demo", hash: "h1"), session(project: "demo", hash: "h2")],
            autonomySessions: [autonomy(project: "demo", hash: "h1"), autonomy(project: "demo", hash: "h2")]
        )
        let normalized = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(from: s, hostname: hostname)
        try expect(normalized.buckets.count == 2 && normalized.sessions.count == 2 && normalized.autonomySessions.count == 2, "clean cross-dimension snapshot must pass unchanged in count")
    }

    // MARK: - (h) collision returns no snapshot and is pure

    private static func verifyCollisionReturnsNoSnapshotAndIsPure() throws {
        // The guard is a pure function: it takes no transport or token supplier,
        // so a rejection cannot have any external effect. We assert it throws
        // (rather than returning a partially bound snapshot) on collision.
        let s = snapshot(buckets: [bucket(model: "gpt"), bucket(model: "gpt")])
        var returned: FullSyncPayloadSnapshot?
        do {
            returned = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(from: s, hostname: hostname)
        } catch {
            returned = nil
        }
        try expect(returned == nil, "a collision must not yield a bound snapshot")
    }

    // MARK: - (i) rawGeneration is preserved through normalization

    private static func verifyRawGenerationPreserved() throws {
        let normalized = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(
            from: snapshot(buckets: [bucket(model: "gpt")], rawGeneration: 987),
            hostname: hostname
        )
        try expect(normalized.rawGeneration == 987, "rawGeneration must survive normalization so the fence still binds")
    }
}
