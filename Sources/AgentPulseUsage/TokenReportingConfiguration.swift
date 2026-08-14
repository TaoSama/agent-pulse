import Foundation
import AgentPulseReporting

/// 本地上报配置。文件由用户自行创建；缺失或字段为空时，普通上报保持禁用。
///
/// 这里不提供任何环境相关默认值：请求路径、header 名、静态 header、取 token
/// 命令和 JSON 路径都必须显式配置。
public struct TokenReportingConfiguration: Codable, Equatable, Sendable {
    public var canonicalHostname: String
    public var path: String
    public var headers: HeaderNames
    public var staticHeaders: [StaticHeaderValue]
    /// Runtime header templates resolved against a small, fixed set of
    /// runtime variables (platform / app_version / user_agent / app_id).
    /// Resolution is fail-closed: any unknown variable, unclosed placeholder,
    /// CR/LF in a value, illegal header name, or collision with a
    /// client-controlled header makes the whole configuration `unready`.
    public var runtimeHeaders: RuntimeHeaders
    public var tokenCommand: Command
    public var localeEnvironmentVariables: [String]
    public var batch: Batch
    public var retry: Retry
    /// Optional, configuration-driven full-sync endpoint and wire vocabulary.
    /// Absent means the feature is unavailable while incremental reporting may
    /// remain usable.
    public var fullSync: FullSync?
    /// Configuration-driven identity endpoint used to prove the account for the
    /// full-sync path. It is queried with the same auth header/static headers as
    /// the main request and must return a positive integer user id at the
    /// configured response key; the namespace is then derived over the request
    /// origin and that id. Absent means full-sync identity cannot be proven and
    /// full-sync stays unavailable.
    public var identityEndpoint: IdentityEndpoint?
    /// Names of the token claims used to derive a stable account identity.
    /// Generic issuer/subject defaults keep this environment-agnostic.
    public var accountClaimKeys: ClaimKeys

    public init(
        canonicalHostname: String = "",
        path: String = "",
        headers: HeaderNames = HeaderNames(),
        staticHeaders: [StaticHeaderValue] = [],
        runtimeHeaders: RuntimeHeaders = RuntimeHeaders(),
        tokenCommand: Command = Command(),
        localeEnvironmentVariables: [String] = [],
        batch: Batch = Batch(),
        retry: Retry = Retry(),
        fullSync: FullSync? = nil,
        identityEndpoint: IdentityEndpoint? = nil,
        accountClaimKeys: ClaimKeys = ClaimKeys()
    ) {
        self.canonicalHostname = canonicalHostname
        self.path = path
        self.headers = headers
        self.staticHeaders = staticHeaders
        self.runtimeHeaders = runtimeHeaders
        self.tokenCommand = tokenCommand
        self.localeEnvironmentVariables = localeEnvironmentVariables
        self.batch = batch
        self.retry = retry
        self.fullSync = fullSync
        self.identityEndpoint = identityEndpoint
        self.accountClaimKeys = accountClaimKeys
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalHostname = Self.trimmed(try container.decodeIfPresent(String.self, forKey: .canonicalHostname))
        path = Self.trimmed(try container.decodeIfPresent(String.self, forKey: .path))
        headers = try container.decodeIfPresent(HeaderNames.self, forKey: .headers) ?? HeaderNames()
        staticHeaders = try container.decodeIfPresent([StaticHeaderValue].self, forKey: .staticHeaders) ?? []
        runtimeHeaders = try container.decodeIfPresent(RuntimeHeaders.self, forKey: .runtimeHeaders) ?? RuntimeHeaders()
        tokenCommand = try container.decodeIfPresent(Command.self, forKey: .tokenCommand) ?? Command()
        localeEnvironmentVariables = try container.decodeIfPresent([String].self, forKey: .localeEnvironmentVariables)?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        batch = try container.decodeIfPresent(Batch.self, forKey: .batch) ?? Batch()
        retry = try container.decodeIfPresent(Retry.self, forKey: .retry) ?? Retry()
        fullSync = try container.decodeIfPresent(FullSync.self, forKey: .fullSync)
        identityEndpoint = try container.decodeIfPresent(IdentityEndpoint.self, forKey: .identityEndpoint)
        accountClaimKeys = try container.decodeIfPresent(ClaimKeys.self, forKey: .accountClaimKeys) ?? ClaimKeys()
    }

    /// 路径、取 token 命令和必要 header 都配置后，才具备发起普通上报的条件。
    public var isReady: Bool {
        !canonicalHostname.isEmpty
            && !path.isEmpty
            && tokenCommand.isConfigured
            && !headers.authToken.isEmpty
            && !headers.contentEncoding.isEmpty
            && !headers.contentType.isEmpty
            && batch.isValid
            && retry.isValid
            && resolvedStaticHeaders() != nil
    }

    /// Resolves the combined static + runtime-template headers, fail-closed.
    /// Returns nil when any runtime template is invalid or targets a
    /// client-controlled header, so the configuration reads as `unready` and
    /// no request is ever built with a partial header set. Incremental and
    /// full-sync both draw from this single resolver, guaranteeing identical
    /// resolved headers on the wire.
    func resolvedStaticHeaders() -> [StaticHeader]? {
        let reserved = headers.requestHeaderNames.reservedNames

        // Explicit static headers are validated with the same rules as runtime
        // templates so they can never bypass the guard: a blank name is dropped
        // (omitted), but any present name must be RFC-legal, must not collide
        // with a client-controlled header, and its value must not carry a CR/LF
        // that would break header framing. Any violation fails closed (nil).
        var explicit: [StaticHeader] = []
        for header in staticHeaders {
            if header.name.isEmpty { continue }
            guard StaticHeader.isValidName(header.name) else { return nil }
            guard !reserved.contains(header.name.lowercased()) else { return nil }
            guard !StaticHeader.containsLineBreak(header.value) else { return nil }
            explicit.append(StaticHeader(name: header.name, value: header.value))
        }

        guard let templated = try? StaticHeader.resolvedList(
            runtimeHeaders.templatePairs,
            context: runtimeHeaders.context.headerContext,
            reservedNames: reserved
        ) else {
            return nil
        }

        let combined = explicit + templated
        // A duplicate header name (case-insensitive) across the explicit and
        // templated sets is rejected: two conflicting values for one header must
        // not be emitted, and a runtime header must not silently shadow or be
        // shadowed by an explicit one.
        var seen = Set<String>()
        for header in combined {
            let key = header.name.lowercased()
            guard seen.insert(key).inserted else { return nil }
        }
        return combined
    }

    public func ingestConfiguration(baseURL: URL, hostname: String) -> IngestClientConfiguration {
        IngestClientConfiguration(
            baseURL: baseURL,
            path: path,
            hostname: hostname,
            headerNames: headers.requestHeaderNames,
            staticHeaders: resolvedStaticHeaders() ?? [],
            localeEnvironmentVariables: localeEnvironmentVariables,
            retryPolicy: retry.transportPolicy,
            lockContentionStatusCodes: Set(retry.lockContentionStatusCodes),
            lockContentionBodyFragments: retry.lockContentionBodyFragments
        )
    }

    public var isFullSyncReady: Bool {
        guard isReady, let fullSync else { return false }
       return fullSync.isValid && resolvedStaticHeaders() != nil
   }

    /// Full-sync additionally requires a valid identity endpoint so the account
    /// can be proven by an authenticated lookup rather than trusting token
    /// bytes. Without it, full-sync stays unavailable (fail-closed).
    public var isIdentityEndpointReady: Bool {
        guard let identityEndpoint else { return false }
        return identityEndpoint.isValid
    }

    /// Maps the configured identity endpoint (plus the shared header names and
    /// resolved static headers) into the reporting-layer resolver configuration.
    /// Returns nil unless the endpoint is valid and the shared headers resolve,
    /// so the resolver is never built from a partial configuration.
    public func identityEndpointConfiguration() -> IdentityEndpointConfiguration? {
        guard let identityEndpoint, identityEndpoint.isValid,
              let method = identityEndpoint.parsedMethod,
              let resolvedHeaders = resolvedStaticHeaders() else { return nil }
        return IdentityEndpointConfiguration(
            path: identityEndpoint.path,
            method: method,
            responseIDKeyPath: identityEndpoint.responseIDKeyPath,
            successStatusCodes: Set(identityEndpoint.successStatusCodes),
            headerNames: headers.requestHeaderNames,
            staticHeaders: resolvedHeaders
        )
    }

   public func fullSyncConfiguration(baseURL: URL, hostname: String) -> FullSyncConfiguration? {
       guard let fullSync, fullSync.isValid,
             isIdentityEndpointReady,
              let resolvedHeaders = resolvedStaticHeaders() else { return nil }
        return FullSyncConfiguration(
            baseURL: baseURL,
            path: fullSync.path,
            hostname: hostname,
            headerNames: headers.requestHeaderNames,
            staticHeaders: resolvedHeaders,
            localeEnvironmentVariables: localeEnvironmentVariables,
            actionNames: fullSync.actionNames.protocolValue,
            kindNames: fullSync.kindNames.protocolValue,
            successStatuses: fullSync.successStatuses.protocolValue,
            maxRowsPerChunk: fullSync.maxRowsPerChunk,
            maxBytesPerChunk: fullSync.maxBytesPerChunk,
            payloadTooLargeStatus: fullSync.payloadTooLargeStatus,
            payloadTooLargeCode: fullSync.payloadTooLargeCode?.protocolValue,
            retryPolicy: (fullSync.retry ?? retry).transportPolicy,
            reserveRetryPolicy: fullSync.reserveRetry?.transportPolicy
                ?? FullSyncConfiguration.defaultReserveRetryPolicy
        )
    }

    public struct FullSync: Codable, Equatable, Sendable {
        public var path: String
        public var actionNames: ActionNames
        public var kindNames: KindNames
        public var successStatuses: SuccessStatuses
       public var maxRowsPerChunk: Int
       public var maxBytesPerChunk: Int
       public var retry: Retry?
        /// HTTP status the server uses to reject a chunk as too large. Default
        /// 413. Configuration-driven so no numeric wire contract is hardcoded.
        public var payloadTooLargeStatus: Int
        /// Optional JSON error-code trigger for the too-large signal.
        public var payloadTooLargeCode: PayloadTooLargeCodeRule?
        /// Optional retry policy for the reserve request. Defaults to a short,
        /// fixed 500/502/503/504 backoff when omitted.
        public var reserveRetry: Retry?

       public init(
           path: String = "",
           actionNames: ActionNames = ActionNames(),
           kindNames: KindNames = KindNames(),
           successStatuses: SuccessStatuses = SuccessStatuses(),
           maxRowsPerChunk: Int = 2_000,
           maxBytesPerChunk: Int = 8 * 1024 * 1024,
            retry: Retry? = nil,
            payloadTooLargeStatus: Int = 413,
            payloadTooLargeCode: PayloadTooLargeCodeRule? = nil,
            reserveRetry: Retry? = nil
       ) {
           self.path = path
           self.actionNames = actionNames
           self.kindNames = kindNames
           self.successStatuses = successStatuses
           self.maxRowsPerChunk = maxRowsPerChunk
           self.maxBytesPerChunk = maxBytesPerChunk
           self.retry = retry
            self.payloadTooLargeStatus = payloadTooLargeStatus
            self.payloadTooLargeCode = payloadTooLargeCode
            self.reserveRetry = reserveRetry
       }

       public init(from decoder: any Decoder) throws {
           let container = try decoder.container(keyedBy: CodingKeys.self)
           path = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .path))
           actionNames = try container.decodeIfPresent(ActionNames.self, forKey: .actionNames) ?? ActionNames()
           kindNames = try container.decodeIfPresent(KindNames.self, forKey: .kindNames) ?? KindNames()
           successStatuses = try container.decodeIfPresent(SuccessStatuses.self, forKey: .successStatuses) ?? SuccessStatuses()
           maxRowsPerChunk = max(1, try container.decodeIfPresent(Int.self, forKey: .maxRowsPerChunk) ?? 2_000)
           maxBytesPerChunk = max(1, try container.decodeIfPresent(Int.self, forKey: .maxBytesPerChunk) ?? 8 * 1024 * 1024)
           retry = try container.decodeIfPresent(Retry.self, forKey: .retry)
            payloadTooLargeStatus = try container.decodeIfPresent(Int.self, forKey: .payloadTooLargeStatus) ?? 413
            payloadTooLargeCode = try container.decodeIfPresent(PayloadTooLargeCodeRule.self, forKey: .payloadTooLargeCode)
            reserveRetry = try container.decodeIfPresent(Retry.self, forKey: .reserveRetry)
       }

       public var isValid: Bool {
           path.hasPrefix("/")
               && !path.hasPrefix("//")
               && !actionNames.values.contains(where: \.isEmpty)
               && !kindNames.values.contains(where: \.isEmpty)
               && !successStatuses.values.contains(where: \.isEmpty)
               && maxRowsPerChunk > 0
               && maxBytesPerChunk > 0
               && (retry?.isValid ?? true)
                && (100...599).contains(payloadTooLargeStatus)
                && (payloadTooLargeCode?.isValid ?? true)
                && (reserveRetry?.isValid ?? true)
       }

        public struct ActionNames: Codable, Equatable, Sendable {
            public var reserve: String
            public var begin: String
            public var stage: String
            public var commit: String

            public init(reserve: String = "reserve", begin: String = "begin", stage: String = "stage", commit: String = "commit") {
                self.reserve = reserve; self.begin = begin; self.stage = stage; self.commit = commit
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                reserve = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .reserve))
                begin = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .begin))
                stage = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .stage))
                commit = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .commit))
            }

            var values: [String] { [reserve, begin, stage, commit] }
            var protocolValue: FullSyncActionNames { FullSyncActionNames(reserve: reserve, begin: begin, stage: stage, commit: commit) }
        }

        public struct KindNames: Codable, Equatable, Sendable {
            public var buckets: String
            public var sessions: String
            public var autonomySessions: String

            public init(buckets: String = "buckets", sessions: String = "sessions", autonomySessions: String = "autonomy") {
                self.buckets = buckets; self.sessions = sessions; self.autonomySessions = autonomySessions
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                buckets = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .buckets))
                sessions = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .sessions))
                autonomySessions = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .autonomySessions))
            }

            var values: [String] { [buckets, sessions, autonomySessions] }
            var protocolValue: FullSyncKindNames { FullSyncKindNames(buckets: buckets, sessions: sessions, autonomySessions: autonomySessions) }
        }

        /// Exact response status accepted for each protocol phase. Defaults match
        /// the reserve/begin/stage/commit contract enforced by the upload core, so
        /// a config that omits this section keeps behaving identically. Every value
        /// is trimmed on decode and validated non-empty by `isValid`, so a blank
        /// override fails closed rather than silently accepting any status.
        public struct SuccessStatuses: Codable, Equatable, Sendable {
            public var reserve: String
            public var begin: String
            public var stage: String
            public var commit: String

            public init(
                reserve: String = "reserved",
                begin: String = "staging",
                stage: String = "staging",
                commit: String = "committed"
            ) {
                self.reserve = reserve
                self.begin = begin
                self.stage = stage
                self.commit = commit
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                reserve = try container.decodeIfPresent(String.self, forKey: .reserve).map(TokenReportingConfiguration.trimmed) ?? "reserved"
                begin = try container.decodeIfPresent(String.self, forKey: .begin).map(TokenReportingConfiguration.trimmed) ?? "staging"
                stage = try container.decodeIfPresent(String.self, forKey: .stage).map(TokenReportingConfiguration.trimmed) ?? "staging"
                commit = try container.decodeIfPresent(String.self, forKey: .commit).map(TokenReportingConfiguration.trimmed) ?? "committed"
            }

           var values: [String] { [reserve, begin, stage, commit] }
           var protocolValue: FullSyncSuccessStatuses { FullSyncSuccessStatuses(reserve: reserve, begin: begin, stage: stage, commit: commit) }
       }

        /// Configuration-driven JSON error-code trigger for the payload-too-large
        /// signal. Locates a code at an ordered JSON key path and matches it
        /// against accepted string and/or integer values.
        public struct PayloadTooLargeCodeRule: Codable, Equatable, Sendable {
            public var keyPath: [String]
            public var stringValues: [String]
            public var intValues: [Int]

            public init(keyPath: [String] = [], stringValues: [String] = [], intValues: [Int] = []) {
                self.keyPath = keyPath
                self.stringValues = stringValues
                self.intValues = intValues
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                keyPath = try container.decodeIfPresent([String].self, forKey: .keyPath)?
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty } ?? []
                stringValues = try container.decodeIfPresent([String].self, forKey: .stringValues) ?? []
                intValues = try container.decodeIfPresent([Int].self, forKey: .intValues) ?? []
            }

            public var isValid: Bool {
                !keyPath.isEmpty && (!stringValues.isEmpty || !intValues.isEmpty)
            }

            var protocolValue: PayloadTooLargeCode {
                PayloadTooLargeCode(
                    keyPath: keyPath,
                    stringValues: Set(stringValues),
                    intValues: Set(intValues)
                )
            }
        }
   }

    /// Configuration-driven identity endpoint. Every value (path, HTTP method,
    /// the response key path locating the user id, and the accepted success
    /// status codes) is read from reporting.json; nothing is hardcoded. The
    /// endpoint reuses the main request's auth header and static headers.
    public struct IdentityEndpoint: Codable, Equatable, Sendable {
        public var path: String
        public var method: String
        /// Ordered JSON keys locating the positive-integer user id.
        public var responseIDKeyPath: [String]
        /// Accepted success status codes. Defaults to a single 200.
        public var successStatusCodes: [Int]

        public init(
            path: String = "",
            method: String = "GET",
            responseIDKeyPath: [String] = [],
            successStatusCodes: [Int] = [200]
        ) {
            self.path = path
            self.method = method
            self.responseIDKeyPath = responseIDKeyPath
            self.successStatusCodes = successStatusCodes
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .path))
            method = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .method)).uppercased()
            responseIDKeyPath = try container.decodeIfPresent([String].self, forKey: .responseIDKeyPath)?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            successStatusCodes = try container.decodeIfPresent([Int].self, forKey: .successStatusCodes) ?? [200]
        }

        var parsedMethod: IdentityRequestMethod? {
            switch method.isEmpty ? "GET" : method {
            case "GET": return .get
            case "POST": return .post
            default: return nil
            }
        }

        public var isValid: Bool {
            path.hasPrefix("/")
                && !path.hasPrefix("//")
                && !responseIDKeyPath.isEmpty
                && parsedMethod != nil
                && !successStatusCodes.isEmpty
                && successStatusCodes.allSatisfy { (100...599).contains($0) }
        }
    }

    /// Builds the account-identity claim keys injected into the ingest client
    /// so the forced-refresh identity fence uses the configured claim names.
    public var tokenAccountClaimKeys: TokenAccountClaimKeys {
        accountClaimKeys.tokenAccountClaimKeys
    }

    /// Configurable claim-key names. Only issuer/subject carry generic
    /// defaults; the remaining keys stay empty until explicitly configured, so
    /// no environment-specific claim name is ever baked in.
    public struct ClaimKeys: Codable, Equatable, Sendable {
        public var issuer: String
        public var subject: String
        public var tenant: String
        public var username: String
        public var uuid: String

        public init(
            issuer: String = "iss",
            subject: String = "sub",
            tenant: String = "",
            username: String = "",
            uuid: String = ""
        ) {
            self.issuer = issuer
            self.subject = subject
            self.tenant = tenant
            self.username = username
            self.uuid = uuid
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            issuer = try container.decodeIfPresent(String.self, forKey: .issuer).map(TokenReportingConfiguration.trimmed) ?? "iss"
            subject = try container.decodeIfPresent(String.self, forKey: .subject).map(TokenReportingConfiguration.trimmed) ?? "sub"
            tenant = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .tenant))
            username = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .username))
            uuid = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .uuid))
        }

        var tokenAccountClaimKeys: TokenAccountClaimKeys {
            TokenAccountClaimKeys(
                issuer: issuer,
                subject: subject,
                tenant: tenant,
                username: username,
                uuid: uuid
            )
        }
    }

    public struct Batch: Codable, Equatable, Sendable {
        public var maxBucketsPerBatch: Int
        public var maxSessionsPerBatch: Int
        public var maxConcurrentBatches: Int

        public init(
            maxBucketsPerBatch: Int = 500,
            maxSessionsPerBatch: Int = 1_000,
            maxConcurrentBatches: Int = 2
        ) {
            self.maxBucketsPerBatch = maxBucketsPerBatch
            self.maxSessionsPerBatch = maxSessionsPerBatch
            self.maxConcurrentBatches = maxConcurrentBatches
        }

        public var isValid: Bool {
            (1...UsageBatchConfiguration.maximumConfigurableBatchSize).contains(maxBucketsPerBatch)
                && (1...UsageBatchConfiguration.maximumConfigurableBatchSize).contains(maxSessionsPerBatch)
                && maxConcurrentBatches > 0
        }

        public var transportConfiguration: UsageBatchConfiguration {
            UsageBatchConfiguration(
                maxBucketsPerBatch: maxBucketsPerBatch,
                maxSessionsPerBatch: maxSessionsPerBatch,
                maxConcurrentBatches: maxConcurrentBatches
            )
        }
    }

    public struct Retry: Codable, Equatable, Sendable {
        public var maxRetries: Int
        public var retryableStatusCodes: [Int]
        public var retryableStatusBodyRules: [StatusBodyRule]
        public var backoffSeconds: [Double]
        public var lockContentionStatusCodes: [Int]
        public var lockContentionBodyFragments: [String]

        public init(
            maxRetries: Int = 3,
            retryableStatusCodes: [Int] = [502, 503, 504],
            retryableStatusBodyRules: [StatusBodyRule] = [],
            backoffSeconds: [Double] = [2, 5, 11],
            lockContentionStatusCodes: [Int] = [409],
            lockContentionBodyFragments: [String] = []
        ) {
            self.maxRetries = maxRetries
            self.retryableStatusCodes = retryableStatusCodes
            self.retryableStatusBodyRules = retryableStatusBodyRules
            self.backoffSeconds = backoffSeconds
            self.lockContentionStatusCodes = lockContentionStatusCodes
            self.lockContentionBodyFragments = lockContentionBodyFragments
        }

        public var isValid: Bool {
            let statusCodes = retryableStatusBodyRules.map(\.statusCode)
            return maxRetries >= 0
                && retryableStatusCodes.allSatisfy(Self.isValidStatusCode)
                && retryableStatusBodyRules.allSatisfy(\.isValid)
                && Set(statusCodes).count == statusCodes.count
                && backoffSeconds.allSatisfy { $0.isFinite && $0 >= 0 }
                && lockContentionStatusCodes.allSatisfy(Self.isValidStatusCode)
        }

        private enum CodingKeys: String, CodingKey {
            case maxRetries, retryableStatusCodes, retryableStatusBodyRules
            case backoffSeconds, lockContentionStatusCodes, lockContentionBodyFragments
        }

        // Decode each field independently so a partial `retry` section (e.g. one
        // that only sets maxRetries and backoffSeconds) is accepted and the rest
        // fall back to the same defaults as the memberwise initializer. This
        // mirrors the top-level config, which already treats the whole `retry`
        // section as optional.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Retry()
            maxRetries = try container.decodeIfPresent(Int.self, forKey: .maxRetries) ?? defaults.maxRetries
            retryableStatusCodes = try container.decodeIfPresent([Int].self, forKey: .retryableStatusCodes) ?? defaults.retryableStatusCodes
            retryableStatusBodyRules = try container.decodeIfPresent([StatusBodyRule].self, forKey: .retryableStatusBodyRules) ?? defaults.retryableStatusBodyRules
            backoffSeconds = try container.decodeIfPresent([Double].self, forKey: .backoffSeconds) ?? defaults.backoffSeconds
            lockContentionStatusCodes = try container.decodeIfPresent([Int].self, forKey: .lockContentionStatusCodes) ?? defaults.lockContentionStatusCodes
            lockContentionBodyFragments = try container.decodeIfPresent([String].self, forKey: .lockContentionBodyFragments) ?? defaults.lockContentionBodyFragments
        }

        public var transportPolicy: RetryPolicy {
            RetryPolicy(
                maxRetries: maxRetries,
                retryableStatusCodes: Set(retryableStatusCodes),
                retryableStatusBodyFragments: Dictionary(
                    uniqueKeysWithValues: retryableStatusBodyRules.map { ($0.statusCode, $0.fragments) }
                ),
                backoffSeconds: backoffSeconds
            )
        }

        private static func isValidStatusCode(_ value: Int) -> Bool {
            (100...599).contains(value)
        }

        public struct StatusBodyRule: Codable, Equatable, Sendable {
            public var statusCode: Int
            public var fragments: [String]

            public init(statusCode: Int = 500, fragments: [String] = []) {
                self.statusCode = statusCode
                self.fragments = fragments
            }

            public var isValid: Bool {
                Retry.isValidStatusCode(statusCode)
                    && !fragments.isEmpty
                    && fragments.allSatisfy { !$0.isEmpty }
            }
        }
    }

    static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public struct HeaderNames: Codable, Equatable, Sendable {
        public var authToken: String
        public var timeZoneOffset: String
        public var locale: String
        public var contentEncoding: String
        public var contentType: String

        public init(
            authToken: String = "",
            timeZoneOffset: String = "",
            locale: String = "",
            contentEncoding: String = "",
            contentType: String = ""
        ) {
            self.authToken = authToken
            self.timeZoneOffset = timeZoneOffset
            self.locale = locale
            self.contentEncoding = contentEncoding
            self.contentType = contentType
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            authToken = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .authToken))
            timeZoneOffset = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .timeZoneOffset))
            locale = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .locale))
            contentEncoding = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .contentEncoding))
            contentType = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .contentType))
        }

        var requestHeaderNames: RequestHeaderNames {
            RequestHeaderNames(
                authToken: authToken,
                timeZoneOffset: timeZoneOffset,
                locale: locale,
                contentEncoding: contentEncoding,
                contentType: contentType
            )
        }
    }

    public struct StaticHeaderValue: Codable, Equatable, Sendable {
        public var name: String
        public var value: String

        public init(name: String = "", value: String = "") {
            self.name = name
            self.value = value
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .name))
            value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        }
    }

    /// Runtime header templates plus the runtime variable values used to expand
    /// them. The only recognised variables are platform / app_version /
    /// user_agent / app_id; a template that references any other variable name
    /// fails closed at resolve time. Only non-empty variables are exposed to the
    /// resolver, so an omitted variable that a template references is reported as
    /// unknown rather than silently expanding to an empty string.
    public struct RuntimeHeaders: Codable, Equatable, Sendable {
        public var context: Context
        public var templates: [Template]

        public init(context: Context = Context(), templates: [Template] = []) {
            self.context = context
            self.templates = templates
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            context = try container.decodeIfPresent(Context.self, forKey: .context) ?? Context()
            templates = try container.decodeIfPresent([Template].self, forKey: .templates) ?? []
        }

        /// Ordered (name, template) pairs handed to the header resolver. Only
        /// entries with a non-empty name are forwarded; a blank name is dropped
        /// here and would be rejected by the resolver's name validation anyway.
        var templatePairs: [(name: String, template: String)] {
            templates
                .filter { !$0.name.isEmpty }
                .map { (name: $0.name, template: $0.template) }
        }

        /// The runtime variable values. Every field defaults to empty; an empty
        /// field is not exposed to the resolver.
        public struct Context: Codable, Equatable, Sendable {
            public var platform: String
            public var appVersion: String
            public var userAgent: String
            public var appID: String

            public init(platform: String = "", appVersion: String = "", userAgent: String = "", appID: String = "") {
                self.platform = platform
                self.appVersion = appVersion
                self.userAgent = userAgent
                self.appID = appID
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                platform = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .platform))
                appVersion = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .appVersion))
                userAgent = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .userAgent))
                appID = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .appID))
            }

            enum CodingKeys: String, CodingKey {
                case platform
                case appVersion = "app_version"
                case userAgent = "user_agent"
                case appID = "app_id"
            }

            /// Builds the resolver context, exposing only non-empty variables so a
            /// template that references an omitted variable fails closed as an
            /// unknown variable.
            var headerContext: RuntimeHeaderContext {
                var values: [HeaderTemplateKey: String] = [:]
                if !platform.isEmpty { values[.platform] = platform }
                if !appVersion.isEmpty { values[.appVersion] = appVersion }
                if !userAgent.isEmpty { values[.userAgent] = userAgent }
                if !appID.isEmpty { values[.appID] = appID }
                return RuntimeHeaderContext(values)
            }
        }

        /// A single templated header. The name is trimmed on decode; the
        /// template body is preserved verbatim so intentional whitespace in the
        /// resolved value survives.
        public struct Template: Codable, Equatable, Sendable {
            public var name: String
            public var template: String

            public init(name: String = "", template: String = "") {
                self.name = name
                self.template = template
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .name))
                template = try container.decodeIfPresent(String.self, forKey: .template) ?? ""
            }
        }
    }

    public struct Command: Codable, Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var forceRefreshArguments: [String]
        public var statusKey: String
        public var successStatus: String
        public var errorKey: String
        public var tokenKeyPath: [String]
        /// Maximum seconds the helper may run before it is terminated. Defaults
        /// to 30; a non-positive value disables the timeout.
        public var timeoutSeconds: TimeInterval

        public init(
            executable: String = "",
            arguments: [String] = [],
            forceRefreshArguments: [String] = [],
            statusKey: String = "",
            successStatus: String = "",
            errorKey: String = "",
            tokenKeyPath: [String] = [],
            timeoutSeconds: TimeInterval = 30
        ) {
            self.executable = executable
            self.arguments = arguments
            self.forceRefreshArguments = forceRefreshArguments
            self.statusKey = statusKey
            self.successStatus = successStatus
            self.errorKey = errorKey
            self.tokenKeyPath = tokenKeyPath
            self.timeoutSeconds = timeoutSeconds
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            executable = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .executable))
            arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
            forceRefreshArguments = try container.decodeIfPresent([String].self, forKey: .forceRefreshArguments) ?? []
            statusKey = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .statusKey))
            successStatus = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .successStatus))
            errorKey = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .errorKey))
            tokenKeyPath = try container.decodeIfPresent([String].self, forKey: .tokenKeyPath)?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            // A missing or non-positive/non-finite value falls back to the 30s
            // default so a malformed config can never disable the guard silently.
            if let decoded = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds),
               decoded.isFinite, decoded > 0 {
                timeoutSeconds = decoded
            } else {
                timeoutSeconds = 30
            }
        }

        public var isConfigured: Bool {
            !executable.isEmpty && !tokenKeyPath.isEmpty
        }

        public var providerConfiguration: CommandTokenProviderConfiguration {
            CommandTokenProviderConfiguration(
                executable: executable,
                arguments: arguments,
                forceRefreshArguments: forceRefreshArguments,
                statusKey: statusKey,
                successStatus: successStatus,
                errorKey: errorKey,
                tokenKeyPath: tokenKeyPath,
                timeoutSeconds: timeoutSeconds
            )
        }
    }
}
