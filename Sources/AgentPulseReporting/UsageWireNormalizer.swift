import Foundation

/// The single source of truth for wire-field normalization and natural-key
/// collision rejection shared by the incremental ingest client and the
/// full-sync path. Both callers must run identical field-length caps, the same
/// canonical hostname stamping, and the same per-dimension natural-key guard so
/// a row serializes byte-for-byte and collides identically on either wire.
///
/// Every entry point is pure: it copies the request, never performs I/O, and
/// never mutates shared state. A natural-key collision throws before the caller
/// acquires a token or opens a connection, so a rejection has zero external
/// effect.
public enum UsageWireNormalizer {
    /// Field-length caps applied before encoding (defense in depth). These are
    /// the exact byte budgets the incremental client has always enforced; the
    /// full-sync path reuses them verbatim.
    public static let sourceMaxBytes = 30
    public static let modelMaxBytes = 255
    public static let projectMaxBytes = 200
    public static let errorMaxBytes = 300

    /// Applies the canonical hostname and per-field byte caps to every row in
    /// the request, returning a copy. The hostname is canonicalized once and
    /// stamped onto every bucket, session, autonomy session, and autonomy
    /// source status, replacing whatever the caller supplied, so the wire
    /// hostname is authoritative and uniform across dimensions.
    public static func normalize(_ request: UsageIngestRequest, hostname rawHostname: String) -> UsageIngestRequest {
        let hostname = CanonicalHostname.normalize(rawHostname)
        var copy = request
        copy.buckets = request.buckets.map { bucket in
            var b = bucket
            b.hostname = hostname
            b.model = truncate(bucket.model, modelMaxBytes)
            b.source = truncate(bucket.source, sourceMaxBytes)
            b.project = truncate(bucket.project, projectMaxBytes)
            return b
        }
        copy.sessions = request.sessions.map { session in
            var s = session
            s.hostname = hostname
            s.source = truncate(session.source, sourceMaxBytes)
            s.project = truncate(session.project, projectMaxBytes)
            return s
        }
        copy.autonomySessions = request.autonomySessions.map { session in
            var s = session
            s.hostname = hostname
            s.source = truncate(session.source, sourceMaxBytes)
            s.project = truncate(session.project, projectMaxBytes)
            return s
        }
        copy.autonomySourceStatuses = request.autonomySourceStatuses.map { status in
            var s = status
            s.hostname = hostname
            s.source = truncate(status.source, sourceMaxBytes)
            s.error = truncate(status.error, errorMaxBytes)
            return s
        }
        return copy
    }

    /// Rejects a batch when two rows in one dimension collapse to the same
    /// natural key. Callers must run this after `normalize` (so the caps and
    /// canonical hostname are already applied) and before any token acquisition
    /// or network I/O, keeping a rejection deterministic and side-effect free.
    ///
    /// The bucket key is (hostname, source, model, project, bucketStart) — the
    /// ledger primary key. The session and autonomy-session key is
    /// (hostname, source, sessionHash); project is descriptive content, not
    /// part of the key.
    public static func ensureUniqueNaturalKeys(_ request: UsageIngestRequest) throws {
        try ensureUnique(request.buckets, dimension: .buckets) {
            BucketNaturalKey(hostname: $0.hostname, source: $0.source, model: $0.model, project: $0.project, bucketStart: $0.bucketStart)
        }
        try ensureUnique(request.sessions, dimension: .sessions) {
            SessionNaturalKey(hostname: $0.hostname, source: $0.source, sessionHash: $0.sessionHash)
        }
        try ensureUnique(request.autonomySessions, dimension: .autonomySessions) {
            SessionNaturalKey(hostname: $0.hostname, source: $0.source, sessionHash: $0.sessionHash)
        }
    }

    private static func ensureUnique<T, Key: Hashable>(
        _ rows: [T],
        dimension: IngestClientError.NaturalKeyDimension,
        naturalKey: (T) -> Key
    ) throws {
        var seen = Set<Key>()
        for row in rows {
            let key = naturalKey(row)
            if seen.contains(key) {
                throw IngestClientError.duplicateNaturalKey(dimension: dimension)
            }
            seen.insert(key)
        }
    }

    /// Truncates to at most n UTF-8 bytes without splitting a multibyte scalar.
    public static func truncate(_ value: String, _ maxBytes: Int) -> String {
        let utf8 = Array(value.utf8)
        guard utf8.count > maxBytes else { return value }
        var end = maxBytes
        while end > 0 && (utf8[end] & 0xC0) == 0x80 { end -= 1 }
        return String(decoding: utf8[0..<end], as: UTF8.self)
    }

    /// Natural key of a bucket row: the ledger primary key
    /// (hostname, source, model, project, bucketStart).
    private struct BucketNaturalKey: Hashable {
        let hostname: String
        let source: String
        let model: String
        let project: String
        let bucketStart: String
    }

    /// Natural key of a session or autonomy row: (hostname, source,
    /// sessionHash). project is descriptive content, not part of the key.
    private struct SessionNaturalKey: Hashable {
        let hostname: String
        let source: String
        let sessionHash: String
    }
}
