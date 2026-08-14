import Foundation
import AgentPulseCore
import AgentPulseReporting

// Production adapters that bind the configuration-driven full-sync core to the
// concrete transport, token source, and ledger snapshot shapes this package
// already uses for incremental reporting. Everything here is a thin bridge: the
// wire contract, retry, and identity-fence logic all live in the core, and each
// environment-specific value continues to arrive from configuration rather than
// a baked-in constant.

// MARK: - Transport adapter

/// A `FullSyncRequestSending` backed by the same `HTTPRequestSending` transport the
/// incremental client uses. It turns the already-resolved full-sync request
/// (URL, headers, body) into a POST `URLRequest`, attaching only the caller-
/// resolved headers, and forwards it to the injected sender so URLSession error
/// classification (request-not-written vs. outcome-unknown) is shared verbatim.
public struct URLSessionFullSyncRequestSender: FullSyncRequestSending {
    private let sender: HTTPRequestSending

    /// Wraps an injected transport. Defaults to the shared URLSession-backed
    /// sender so production callers get identical connectivity semantics to the
    /// incremental path; tests can inject a stub transport.
    public init(sender: HTTPRequestSending = URLSessionRequestSender()) {
        self.sender = sender
    }

    public func send(_ request: FullSyncTransportRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        // The core has already resolved every header name/value (auth token,
        // content type/encoding, metadata) to its configured form; attach them
        // verbatim and set nothing else on the request.
        for (name, value) in request.headers where !name.isEmpty {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return try await sender.send(urlRequest)
    }
}

// MARK: - Token / identity adapter

/// A `FullSyncTokenSupplying` that reuses the incremental path's command token
/// plumbing: `CommandTokenSupplier` runs the caller-configured helper off the
/// cooperative executor and honors the single forced refresh. Account identity
/// is resolved by an authenticated lookup against a configured identity
/// endpoint (`OriginUserIdentityResolver`) rather than by inspecting token
/// bytes, so a JWT claim change or a re-issued opaque token can never silently
/// remap the account. Both the token source and the identity endpoint are
/// injected, so no environment-specific command, path, header, or response key
/// is hardcoded here.
public struct CommandFullSyncTokenSupplier: FullSyncTokenSupplying {
    private let tokenSupplier: TokenSupplying
    private let resolver: OriginUserIdentityResolver

    /// Injects the token source and identity resolver directly. Useful for
    /// tests and for reusing an already-constructed supplier.
    public init(tokenSupplier: TokenSupplying, resolver: OriginUserIdentityResolver) {
        self.tokenSupplier = tokenSupplier
        self.resolver = resolver
    }

    /// Builds the production supplier from the reporting configuration and the
    /// resolved backend base URL, wiring the configured token command through
    /// `CommandTokenSupplier` and the configured identity endpoint (path,
    /// method, response id key, status codes, shared headers) through
    /// `OriginUserIdentityResolver`. Every value arrives from configuration.
   public init(
       configuration: TokenReportingConfiguration,
       baseURL: URL,
       runner: ProcessRunning = SubprocessRunner(),
       identitySender: HTTPRequestSending = URLSessionRequestSender()
   ) {
       let provider = ConfiguredCommandTokenProvider(
           configuration: configuration.tokenCommand.providerConfiguration,
           runner: runner
       )
       self.init(
           tokenSupplier: CommandTokenSupplier(provider: provider),
           resolver: OriginUserIdentityResolver(
               baseURL: baseURL,
                configuration: configuration.identityEndpointConfiguration() ?? IdentityEndpointConfiguration(),
               sender: identitySender
           )
       )
   }

    public func token(forceRefresh: Bool) async throws -> SecretToken {
        try await tokenSupplier.token(forceRefresh: forceRefresh)
    }

    public func accountNamespace(forToken token: SecretToken) async throws -> String {
        try await resolver.resolveNamespace(token: token)
    }

    /// Prefetches a token and resolves its account namespace in one step, so a
    /// coordinator can obtain the pinned `authIdentity` the core's `upload`
    /// entry point requires before starting an upload. The revealed token stays
    /// local to this call and is never returned or stored alongside the
    /// identity.
    public func prefetchIdentity(forceRefresh: Bool = false) async throws -> String {
        let token = try await tokenSupplier.token(forceRefresh: forceRefresh)
        return try await accountNamespace(forToken: token)
    }
}

// MARK: - Snapshot mapper

/// Maps the ledger's full-sync snapshot into the core's caller-supplied payload
/// snapshot. Buckets and sessions are converted through the same payload mappers
/// the incremental path uses, so a row serializes byte-for-byte identically on
/// either wire. The ledger's monotonic `generation` is carried through exactly as
/// `rawGeneration` so a resume can detect the source was regenerated underneath an
/// in-flight upload. Autonomy is not sourced from the token ledger, so every
/// autonomy field is left empty.
public enum UsageFullSyncSnapshotMapper {
    public static func payloadSnapshot(from snapshot: UsageFullSyncSnapshot) -> FullSyncPayloadSnapshot {
        FullSyncPayloadSnapshot(
            buckets: UsageBucketPayloadMapper.payloads(from: snapshot.buckets.map(\.bucket)),
            sessions: UsageSessionPayloadMapper.payloads(from: snapshot.sessions.map(\.session)),
            autonomySessions: [],
            autonomySourceStatuses: [],
            autonomyWindowStart: "",
            autonomyWindowEnd: "",
            rawGeneration: snapshot.generation
        )
    }

    /// Normalizes a full-sync payload snapshot through the shared wire
    /// normalizer and rejects any natural-key collision across every
    /// dimension. This is a pure function: it performs no I/O and mutates no
    /// shared state, so the caller can run it before reserving a fence,
    /// writing upload state, taking a token, or opening any connection. A
    /// collision throws `IngestClientError.duplicateNaturalKey`, matching the
    /// incremental client byte-for-byte, and leaves the world untouched.
    ///
    /// The canonical hostname and per-field caps are applied here exactly as
    /// the incremental client applies them in `ingest`, so a row staged by the
    /// full-sync path serializes identically to the same row sent
    /// incrementally. `rawGeneration` is preserved so the reservation's
    /// generation fence still binds.
    public static func normalizedPayloadSnapshot(
        from snapshot: FullSyncPayloadSnapshot,
        hostname: String
    ) throws -> FullSyncPayloadSnapshot {
        var request = UsageIngestRequest(
            buckets: snapshot.buckets,
            sessions: snapshot.sessions,
            autonomySessions: snapshot.autonomySessions,
            autonomySourceStatuses: snapshot.autonomySourceStatuses,
            autonomyWindowStart: snapshot.autonomyWindowStart,
            autonomyWindowEnd: snapshot.autonomyWindowEnd
        )
        request = UsageWireNormalizer.normalize(request, hostname: hostname)
        try UsageWireNormalizer.ensureUniqueNaturalKeys(request)
        return FullSyncPayloadSnapshot(
            buckets: request.buckets,
            sessions: request.sessions,
            autonomySessions: request.autonomySessions,
            autonomySourceStatuses: request.autonomySourceStatuses,
            autonomyWindowStart: request.autonomyWindowStart,
            autonomyWindowEnd: request.autonomyWindowEnd,
            rawGeneration: snapshot.rawGeneration
        )
    }

    /// Builds the normalized, collision-checked payload snapshot directly from
    /// a ledger snapshot in one step. Convenience for callers that want to run
    /// the guard before any fence reservation or network side-effect.
    public static func normalizedPayloadSnapshot(
        from snapshot: UsageFullSyncSnapshot,
        hostname: String
    ) throws -> FullSyncPayloadSnapshot {
        try normalizedPayloadSnapshot(from: payloadSnapshot(from: snapshot), hostname: hostname)
    }
}
