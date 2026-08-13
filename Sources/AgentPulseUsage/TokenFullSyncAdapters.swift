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
/// cooperative executor and honors the single forced refresh, while
/// `TokenAccountIdentity` derives the stable, comparable account identity the
/// core fences on. Both the token source and the claim keys are injected, so no
/// environment-specific command or claim name is hardcoded here.
public struct CommandFullSyncTokenSupplier: FullSyncTokenSupplying {
    private let tokenSupplier: TokenSupplying
    private let identity: TokenAccountIdentity

    /// Injects the token source and identity deriver directly. Useful for tests
    /// and for reusing an already-constructed supplier.
    public init(tokenSupplier: TokenSupplying, identity: TokenAccountIdentity) {
        self.tokenSupplier = tokenSupplier
        self.identity = identity
    }

    /// Builds the production supplier from the reporting configuration, wiring
    /// the configured token command through `CommandTokenSupplier` and the
    /// configured claim keys through `TokenAccountIdentity`. This mirrors how the
    /// incremental client is assembled, so both paths resolve the same token and
    /// the same identity for a given credential.
    public init(configuration: TokenReportingConfiguration, runner: ProcessRunning = SubprocessRunner()) {
        let provider = ConfiguredCommandTokenProvider(
            configuration: configuration.tokenCommand.providerConfiguration,
            runner: runner
        )
        self.init(
            tokenSupplier: CommandTokenSupplier(provider: provider),
            identity: TokenAccountIdentity(claimKeys: configuration.tokenAccountClaimKeys)
        )
    }

    public func token(forceRefresh: Bool) async throws -> SecretToken {
        try await tokenSupplier.token(forceRefresh: forceRefresh)
    }

    public func stableAccountIdentity(forToken token: SecretToken) -> String {
        identity.comparisonIdentity(token.reveal())
    }

    /// Prefetches a token and derives its stable identity in one step, so a
    /// coordinator can obtain the `authIdentity` the core's `upload` entry point
    /// requires before starting an upload. The revealed token stays local to
    /// this call and is never returned or stored alongside the identity.
    public func prefetchIdentity(forceRefresh: Bool = false) async throws -> String {
        let token = try await tokenSupplier.token(forceRefresh: forceRefresh)
        return stableAccountIdentity(forToken: token)
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
}
