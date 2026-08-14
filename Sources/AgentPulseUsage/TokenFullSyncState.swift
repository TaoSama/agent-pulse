import Foundation
import CryptoKit
import AgentPulseReporting

// Atomic, crash-safe persistence for a resumable full-sync upload.
//
// The state directory holds one JSON state file plus one snapshot blob per
// staged chunk. Every write is atomic (write to a temp sibling, fsync, rename)
// and every file is created with owner-only 0600 permissions. Because the exact
// staged chunk bytes are snapshotted to disk, a resume re-reads identical bytes
// and recomputes an identical digest regardless of any later change to the
// caller source data; the digest can never drift out from under an in-flight
// upload.

/// One chunk of one kind: its row range into the snapshot, the exact staged
/// request bytes (referenced by a snapshot file), the digest over those bytes,
/// and whether the server confirmed it.
public struct FullSyncChunkRecord: Codable, Equatable, Sendable {
    public var kind: FullSyncKind
    public var chunkIndex: Int
    public var offset: Int
    public var rows: Int
    /// Lowercase hex SHA-256 over the exact staged request body bytes.
    public var digest: String
    /// Relative name of the snapshot blob holding the staged body bytes.
    public var snapshotFile: String
    /// True once the server acknowledged this chunk.
    public var confirmed: Bool

    public init(
        kind: FullSyncKind,
        chunkIndex: Int,
        offset: Int,
        rows: Int,
        digest: String,
        snapshotFile: String,
        confirmed: Bool
    ) {
        self.kind = kind
        self.chunkIndex = chunkIndex
        self.offset = offset
        self.rows = rows
        self.digest = digest
        self.snapshotFile = snapshotFile
        self.confirmed = confirmed
    }
}

/// The complete persisted upload record. Binds the reserved server fence and
/// the account identity to the payload fingerprint, so a resume can prove the
/// in-flight upload still corresponds to the same account, the same reserved
/// fence, and the same payload bytes.
public struct FullSyncState: Codable, Equatable, Sendable {
    /// State-file schema version, so a future format can be detected.
    public var version: Int
    public var uploadID: String
    public var hostname: String
    public var phase: FullSyncPhase
    /// Server-reserved fence revision (>= 0). Echoed on every subsequent call.
    public var fenceRevision: Int64
    /// Stable account identity captured at reserve time; the resume fence
    /// compares the current identity against this value.
    public var authIdentity: String
    /// SHA-256 over the canonical serialization of the whole payload snapshot.
    public var payloadFingerprint: String
    /// Source generation captured before reserve. The later snapshot must be
    /// read at this exact generation.
    public var generationBaseline: Int64
    /// True only after the exact payload fingerprint and counts are persisted.
    public var payloadBound: Bool
    /// Bound source generation. Equal to generationBaseline once bound.
    public var rawGeneration: Int64
    /// Expected row counts per kind, captured at reserve time.
    public var expectedBuckets: Int
    public var expectedSessions: Int
    public var expectedAutonomySessions: Int
    public var autonomySources: [String]
    public var autonomyWindowStart: String
    public var autonomyWindowEnd: String
    /// Chunk records accumulated as staging proceeds.
    public var chunks: [FullSyncChunkRecord]
    /// Populated once phase == .committed.
    public var committedBucketsUpserted: Int?
    public var committedSessionsUpserted: Int?
    public var committedAutonomySessionsUpserted: Int?

    public init(
        version: Int = FullSyncState.currentVersion,
        uploadID: String,
        hostname: String,
        phase: FullSyncPhase,
        fenceRevision: Int64,
        authIdentity: String,
        payloadFingerprint: String,
        generationBaseline: Int64? = nil,
        payloadBound: Bool = true,
        rawGeneration: Int64,
        expectedBuckets: Int,
        expectedSessions: Int,
        expectedAutonomySessions: Int,
        autonomySources: [String],
        autonomyWindowStart: String,
        autonomyWindowEnd: String,
        chunks: [FullSyncChunkRecord] = [],
        committedBucketsUpserted: Int? = nil,
        committedSessionsUpserted: Int? = nil,
        committedAutonomySessionsUpserted: Int? = nil
    ) {
        self.version = version
        self.uploadID = uploadID
        self.hostname = hostname
        self.phase = phase
        self.fenceRevision = fenceRevision
        self.authIdentity = authIdentity
        self.payloadFingerprint = payloadFingerprint
        self.generationBaseline = generationBaseline ?? rawGeneration
        self.payloadBound = payloadBound
        self.rawGeneration = rawGeneration
        self.expectedBuckets = expectedBuckets
        self.expectedSessions = expectedSessions
        self.expectedAutonomySessions = expectedAutonomySessions
        self.autonomySources = autonomySources
        self.autonomyWindowStart = autonomyWindowStart
        self.autonomyWindowEnd = autonomyWindowEnd
        self.chunks = chunks
        self.committedBucketsUpserted = committedBucketsUpserted
        self.committedSessionsUpserted = committedSessionsUpserted
        self.committedAutonomySessionsUpserted = committedAutonomySessionsUpserted
    }

    public static let currentVersion = 2

    public func expectedRows(for kind: FullSyncKind) -> Int {
        switch kind {
        case .buckets: return expectedBuckets
        case .sessions: return expectedSessions
        case .autonomySessions: return expectedAutonomySessions
        }
    }

    /// Locates a chunk record by kind and index, if present.
    public func chunk(kind: FullSyncKind, index: Int) -> FullSyncChunkRecord? {
        chunks.first { $0.kind == kind && $0.chunkIndex == index }
    }

    /// Enforces all invariants needed before persisted data can influence a
    /// network request. Snapshot files themselves are checked lazily because a
    /// confirmed chunk deliberately no longer depends on its local body.
    public func validate() throws {
        guard version == Self.currentVersion,
              Self.isLowercaseHex(uploadID, minCount: 32, maxCount: 64),
              !hostname.isEmpty, hostname == CanonicalHostname.normalize(hostname),
              !authIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fenceRevision >= 0, generationBaseline >= 0, rawGeneration >= 0,
              expectedBuckets >= 0, expectedSessions >= 0, expectedAutonomySessions >= 0 else {
            throw FullSyncError.corruptState
        }

        let commitValues = [
            committedBucketsUpserted, committedSessionsUpserted, committedAutonomySessionsUpserted,
        ]
        if phase == .committed {
            guard commitValues.allSatisfy({ $0 != nil }),
                  committedBucketsUpserted == expectedBuckets,
                  committedSessionsUpserted == expectedSessions,
                  committedAutonomySessionsUpserted == expectedAutonomySessions else {
                throw FullSyncError.corruptState
            }
        } else if commitValues.contains(where: { $0 != nil }) {
            throw FullSyncError.corruptState
        }

        if payloadBound {
            guard phase != .reserved, rawGeneration == generationBaseline,
                  Self.isLowercaseHex(payloadFingerprint, count: 64),
                  autonomySources == Array(Set(autonomySources)).sorted(),
                  autonomySources.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw FullSyncError.corruptState
            }
        } else {
            guard phase == .reserved, payloadFingerprint.isEmpty, rawGeneration == generationBaseline,
                  expectedBuckets == 0, expectedSessions == 0, expectedAutonomySessions == 0,
                  autonomySources.isEmpty, autonomyWindowStart.isEmpty, autonomyWindowEnd.isEmpty,
                  chunks.isEmpty else {
                throw FullSyncError.corruptState
            }
        }

        var seen = Set<String>()
        for record in chunks {
            let key = "\(record.kind.rawValue):\(record.chunkIndex)"
            let expectedFile = "chunk-\(record.kind.rawValue)-\(record.chunkIndex).body"
            guard record.chunkIndex >= 0, record.offset >= 0, record.rows > 0,
                  record.offset <= expectedRows(for: record.kind),
                  record.rows <= expectedRows(for: record.kind) - record.offset,
                  Self.isLowercaseHex(record.digest, count: 64),
                  record.snapshotFile == expectedFile, Self.isSafeRelativeFileName(record.snapshotFile),
                  seen.insert(key).inserted else {
                throw FullSyncError.corruptState
            }
        }
        for kind in FullSyncKind.allCases {
            let records = chunks.filter { $0.kind == kind }.sorted { $0.chunkIndex < $1.chunkIndex }
            var nextOffset = 0
            for (index, record) in records.enumerated() {
                guard record.chunkIndex == index, record.offset == nextOffset else {
                    throw FullSyncError.corruptState
                }
                nextOffset += record.rows
            }
            if phase == .staged || phase == .committed {
                guard nextOffset == expectedRows(for: kind), records.allSatisfy(\.confirmed) else {
                    throw FullSyncError.corruptState
                }
            }
        }
        if phase == .prepared, !chunks.isEmpty { throw FullSyncError.corruptState }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    /// A recovered upload ID is accepted when it is lowercase hex whose length
    /// falls within an inclusive range. Freshly generated IDs are still exactly
    /// 64 hex chars; on recovery a server-issued ID as short as 32 hex chars is
    /// honored so an in-flight upload survives across differing ID lengths.
    private static func isLowercaseHex(_ value: String, minCount: Int, maxCount: Int) -> Bool {
        let length = value.utf8.count
        return length >= minCount && length <= maxCount && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    static func isSafeRelativeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && URL(fileURLWithPath: name).lastPathComponent == name
    }
}

/// Owns the on-disk representation of an upload: atomic 0600 reads/writes of the
/// state file, plus atomic 0600 snapshot blobs for staged chunk bodies.
public struct FullSyncStateStore: Sendable {
    /// Directory holding the state file and chunk snapshots. Created 0700.
    public let directory: URL
    private let stateFileName = "full-sync-state.json"

    public init(directory: URL) {
        self.directory = directory
    }

    private var stateURL: URL { directory.appendingPathComponent(stateFileName) }

    /// True when a state file exists (an upload may be resumable).
    public func hasState() -> Bool {
        FileManager.default.fileExists(atPath: stateURL.path)
    }

    /// Ensures the state directory exists with owner-only 0700 permissions.
    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory ignores permissions on an existing dir; enforce them.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Loads and validates the persisted state. Throws corruptState when the
    /// file is missing, unreadable, wrong-permissioned, or malformed.
    public func load() throws -> FullSyncState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            throw FullSyncError.corruptState
        }
        try requireOwnerOnly(stateURL)
        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch {
            throw FullSyncError.corruptState
        }
        let state: FullSyncState
        do {
            state = try JSONDecoder().decode(FullSyncState.self, from: data)
        } catch {
            throw FullSyncError.corruptState
        }
        try state.validate()
        return state
    }

    /// Atomically persists the state file at 0600.
    public func save(_ state: FullSyncState) throws {
        try state.validate()
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try atomicWrite(data, to: stateURL)
    }

    /// Atomically writes a chunk snapshot blob and returns its file name.
    public func writeChunkSnapshot(_ body: Data, kind: FullSyncKind, chunkIndex: Int) throws -> String {
        try ensureDirectory()
        let name = "chunk-\(kind.rawValue)-\(chunkIndex).body"
        try atomicWrite(body, to: directory.appendingPathComponent(name))
        return name
    }

    /// Reads back the exact staged bytes for a chunk snapshot.
    public func readChunkSnapshot(_ name: String) throws -> Data {
        guard FullSyncState.isSafeRelativeFileName(name) else { throw FullSyncError.corruptState }
        let url = directory.appendingPathComponent(name)
        try requireOwnerOnly(url)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw FullSyncError.corruptState
        }
    }

    /// Removes the entire upload state directory (state file + snapshots). Used
    /// after a successful commit or when discarding a fenced/stale upload.
    public func discard() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Atomic 0600 write

    /// Writes data to a temp sibling, fsyncs, sets 0600, then renames over the
    /// destination so a crash mid-write can never leave a partial file in
    /// place. The temp file is created 0600 before any bytes are written.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        FileManager.default.createFile(
            atPath: tempURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        let handle = try FileHandle(forWritingTo: tempURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        // Enforce 0600 in case the create attribute was ignored, then rename.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            // replaceItemAt can fail when no destination exists on some
            // filesystems; fall back to a direct rename.
            do {
                try FileManager.default.moveItem(at: tempURL, to: url)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Rejects a file whose permissions are not exactly owner-only 0600, so a
    /// world-readable state or snapshot is never trusted.
    private func requireOwnerOnly(_ url: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw FullSyncError.corruptState
        }
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600 else {
            throw FullSyncError.corruptState
        }
    }
}

/// Computes the payload fingerprint and chunk digests. The fingerprint is a
/// SHA-256 over a canonical, order-stable serialization of the entire snapshot
/// (kinds, counts, window, sources, and every row encoded with the shared
/// deterministic encoder), so it uniquely binds the upload to its exact bytes.
public enum FullSyncDigest {
    /// Lowercase hex SHA-256 over arbitrary bytes.
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical fingerprint over the whole snapshot. Uses the shared ingest
    /// encoder for each row so the bytes match the wire exactly, and prefixes
    /// each section with its length to avoid cross-section ambiguity.
    public static func fingerprint(
        for snapshot: FullSyncPayloadSnapshot,
        hostname: String,
        encoder: UsageIngestEncoder = UsageIngestEncoder()
    ) -> String {
        var acc = Data()
        func appendField(_ label: String, _ value: String) {
            acc.append(Data("\(label)=\(value.utf8.count):".utf8))
            acc.append(Data(value.utf8))
            acc.append(0x0a)
        }
        appendField("host", hostname)
        appendField("gen", String(snapshot.rawGeneration))
        appendField("winStart", snapshot.autonomyWindowStart)
        appendField("winEnd", snapshot.autonomyWindowEnd)
        appendField("sources", snapshot.autonomySources.joined(separator: ","))
        // Encode each kind's rows through the shared encoder wrapped in a
        // single-kind request so the canonical bytes equal the staged wire
        // bytes for that row set.
        appendField("buckets", String(snapshot.buckets.count))
        acc.append(encoder.encode(UsageIngestRequest(buckets: snapshot.buckets)))
        acc.append(0x0a)
        appendField("sessions", String(snapshot.sessions.count))
        acc.append(encoder.encode(UsageIngestRequest(sessions: snapshot.sessions)))
        acc.append(0x0a)
        appendField("autonomy", String(snapshot.autonomySessions.count))
        acc.append(encoder.encode(UsageIngestRequest(autonomySessions: snapshot.autonomySessions)))
        return hex(acc)
    }
}
