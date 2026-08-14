import AgentPulseReporting
import AgentPulseUsage
import Foundation

// Dependency-free verification for runtime header template wiring. XCTest is
// unavailable under the Command Line Tools toolchain, so this executable mirrors
// unit-test assertions. All fixtures use generic, non-routable values.
@main
struct RuntimeHeaderParityVerification {
    static func main() throws {
        try verifyResolverFailClosed()
        try verifyProtectedHeaderOverrideRejected()
        try verifyReservedNames()
        try verifyConfigGatingZeroTrust()
        try verifyIncrementalAndFullSyncShareResolvedHeaders()
        try verifyInvalidTemplateMakesConfigUnready()
        try verifyStatusReflectsResolvedHeaders()
        try verifyStaticHeaderSelfValidation()
        print("RuntimeHeaderParity verification passed")
    }

    enum VerificationError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { if case let .failed(m) = self { return m }; return "failed" }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationError.failed(message) }
    }

    private static func expectThrows(_ expected: HeaderTemplateError, _ message: String, _ body: () throws -> Void) throws {
        do {
            try body()
            throw VerificationError.failed("\(message): expected throw, got success")
        } catch let error as HeaderTemplateError {
            try expect(error == expected, "\(message): expected \(expected), got \(error)")
        }
    }

    private static func verifyResolverFailClosed() throws {
        let ctx = RuntimeHeaderContext([.platform: "macos", .appVersion: "1.2.3", .userAgent: "agent/1", .appID: "abc"])
        try expect(try ctx.resolve(template: "{{platform}} {{app_version}}") == "macos 1.2.3", "recognised vars resolve")
        try expect(try ctx.resolve(template: "{{user_agent}}|{{app_id}}") == "agent/1|abc", "recognised vars resolve 2")
        try expect(try ctx.resolve(template: "no-holes") == "no-holes", "literal passthrough")
        try expect(try ctx.resolve(template: "{platform}") == "{platform}", "single braces literal")
        try expectThrows(.unknownVariable("app_version"), "unknown variable") {
            _ = try RuntimeHeaderContext([.platform: "macos"]).resolve(template: "{{app_version}}")
        }
        try expectThrows(.unknownVariable("region"), "unrecognised name") {
            _ = try ctx.resolve(template: "{{region}}")
        }
        try expectThrows(.unclosedPlaceholder, "unclosed") {
            _ = try ctx.resolve(template: "prefix {{platform")
        }
        try expectThrows(.newlineInValue("platform"), "LF") {
            _ = try RuntimeHeaderContext([.platform: "a\nb"]).resolve(template: "{{platform}}")
        }
        try expectThrows(.newlineInValue("app_id"), "CR") {
            _ = try RuntimeHeaderContext([.appID: "a\rb"]).resolve(template: "{{app_id}}")
        }
        try expectThrows(.invalidHeaderName(""), "empty name") {
            _ = try StaticHeader.resolved(name: "", template: "{{platform}}", context: ctx)
        }
        try expectThrows(.invalidHeaderName("X:Bad"), "colon name") {
            _ = try StaticHeader.resolved(name: "X:Bad", template: "{{platform}}", context: ctx)
        }
        try expectThrows(.invalidHeaderName("X\rBad"), "CR name") {
            _ = try StaticHeader.resolved(name: "X\rBad", template: "{{platform}}", context: ctx)
        }
        try expectThrows(.invalidHeaderName("X\"Bad"), "quote name") {
            _ = try StaticHeader.resolved(name: "X\"Bad", template: "{{platform}}", context: ctx)
        }
        try expectThrows(.newlineInValue("X-Literal"), "literal CRLF") {
            _ = try StaticHeader.resolved(name: "X-Literal", template: "a\r\nb", context: ctx)
        }
        try expectThrows(.unknownVariable("app_version"), "batch all-or-nothing") {
            _ = try StaticHeader.resolvedList([(name: "X-Good", template: "{{platform}}"), (name: "X-Bad", template: "{{app_version}}")], context: RuntimeHeaderContext([.platform: "macos"]), reservedNames: [])
        }
        let ordered = try StaticHeader.resolvedList([(name: "X-Platform", template: "os={{platform}}"), (name: "X-Version", template: "v{{app_version}}")], context: ctx, reservedNames: [])
        try expect(ordered == [StaticHeader(name: "X-Platform", value: "os=macos"), StaticHeader(name: "X-Version", value: "v1.2.3")], "ordered/valued")
    }

    private static func verifyProtectedHeaderOverrideRejected() throws {
        let ctx = RuntimeHeaderContext([.platform: "macos"])
        try expectThrows(.protectedHeaderName("content-TYPE"), "protected override") {
            _ = try StaticHeader.resolvedList([(name: "content-TYPE", template: "{{platform}}")], context: ctx, reservedNames: ["content-type", "x-auth"])
        }
    }

    private static func verifyReservedNames() throws {
        let names = RequestHeaderNames(authToken: "X-Auth", timeZoneOffset: "X-TZ", locale: "X-Locale", contentEncoding: "Content-Encoding", contentType: "Content-Type")
        try expect(names.reservedNames == ["x-auth", "x-tz", "x-locale", "content-encoding", "content-type"], "reserved names lowercased")
        let sparse = RequestHeaderNames(authToken: "", timeZoneOffset: "", locale: "", contentEncoding: "Content-Encoding", contentType: "Content-Type")
        try expect(sparse.reservedNames == ["content-encoding", "content-type"], "empty names omitted")
    }

   private static func readyConfiguration(runtimeHeaders: TokenReportingConfiguration.RuntimeHeaders = .init(), staticHeaders: [TokenReportingConfiguration.StaticHeaderValue] = [], fullSync: TokenReportingConfiguration.FullSync? = nil) -> TokenReportingConfiguration {
       TokenReportingConfiguration(
           canonicalHostname: "device",
           path: "/usage",
           headers: .init(authToken: "X-Auth", timeZoneOffset: "X-TZ", locale: "X-Locale", contentEncoding: "Content-Encoding", contentType: "Content-Type"),
           staticHeaders: staticHeaders,
           runtimeHeaders: runtimeHeaders,
           tokenCommand: .init(executable: "/bin/echo", tokenKeyPath: ["token"]),
            fullSync: fullSync,
            // Full-sync now proves the account via a configured identity endpoint,
            // so a full-sync-ready fixture must supply one. All values are generic
            // placeholders; the real endpoint/path/key come only from reporting.json.
            identityEndpoint: .init(path: "/whoami", method: "GET", responseIDKeyPath: ["id"], successStatusCodes: [200])
       )
   }

    private static func verifyConfigGatingZeroTrust() throws {
        let okRuntime = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "macos", appVersion: "1.0"), templates: [.init(name: "X-Platform", template: "{{platform}}"), .init(name: "X-Version", template: "v{{app_version}}")])
        try expect(readyConfiguration(runtimeHeaders: okRuntime).isReady, "valid runtime headers keep config ready")
    }

    private static func verifyInvalidTemplateMakesConfigUnready() throws {
        let unknownVar = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "macos"), templates: [.init(name: "X-Version", template: "{{app_version}}")])
        try expect(!readyConfiguration(runtimeHeaders: unknownVar).isReady, "unknown variable => unready")
        let unclosed = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "macos"), templates: [.init(name: "X-P", template: "{{platform")])
        try expect(!readyConfiguration(runtimeHeaders: unclosed).isReady, "unclosed => unready")
        let crlf = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "a\nb"), templates: [.init(name: "X-P", template: "{{platform}}")])
        try expect(!readyConfiguration(runtimeHeaders: crlf).isReady, "CRLF => unready")
        let badName = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "macos"), templates: [.init(name: "X:Bad", template: "{{platform}}")])
        try expect(!readyConfiguration(runtimeHeaders: badName).isReady, "illegal name => unready")
        let override = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "macos"), templates: [.init(name: "content-type", template: "{{platform}}")])
        try expect(!readyConfiguration(runtimeHeaders: override).isReady, "protected override => unready")
        let fs = TokenReportingConfiguration.FullSync(path: "/usage/full-sync")
        try expect(!readyConfiguration(runtimeHeaders: override, fullSync: fs).isFullSyncReady, "override => full-sync unready")
        try expect(readyConfiguration(fullSync: fs).isFullSyncReady, "valid config => full-sync ready")
        let base = URL(string: "https://example.invalid")!
        try expect(readyConfiguration(runtimeHeaders: override, fullSync: fs).fullSyncConfiguration(baseURL: base, hostname: "device") == nil, "invalid => nil full-sync config")
    }

    private static func verifyIncrementalAndFullSyncShareResolvedHeaders() throws {
        let runtime = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "macos", appVersion: "1.0", userAgent: "agent/1", appID: "abc"), templates: [.init(name: "X-Platform", template: "{{platform}}"), .init(name: "X-Version", template: "v{{app_version}}"), .init(name: "X-UA", template: "{{user_agent}}")])
        let staticHeaders = [TokenReportingConfiguration.StaticHeaderValue(name: "X-Client", value: "verifier")]
        let fs = TokenReportingConfiguration.FullSync(path: "/usage/full-sync")
        let config = readyConfiguration(runtimeHeaders: runtime, staticHeaders: staticHeaders, fullSync: fs)
        try expect(config.isReady && config.isFullSyncReady, "config ready for both transports")
        let base = URL(string: "https://example.invalid")!
        let incremental = config.ingestConfiguration(baseURL: base, hostname: "device")
        guard let fullSync = config.fullSyncConfiguration(baseURL: base, hostname: "device") else {
            throw VerificationError.failed("full-sync config unexpectedly nil")
        }
        try expect(incremental.staticHeaders == fullSync.staticHeaders, "resolved headers diverge between transports")
        try expect(incremental.staticHeaders == [StaticHeader(name: "X-Client", value: "verifier"), StaticHeader(name: "X-Platform", value: "macos"), StaticHeader(name: "X-Version", value: "v1.0"), StaticHeader(name: "X-UA", value: "agent/1")], "resolved header set incorrect")
        try expect(incremental.headerNames == fullSync.headerNames, "header names diverge")
    }
}

// MARK: - Appended coverage: status gating + static header self-validation
extension RuntimeHeaderParityVerification {
    private static func statusFor(_ config: TokenReportingConfiguration) -> TokenReportingConfigurationStatus {
        let reporter = TokenUsageReporter(configurationLoader: { _ in config })
        return reporter.configurationStatus(for: URL(fileURLWithPath: "/dev/null"))
    }

    private static func staticHeader(_ name: String, _ value: String) -> TokenReportingConfiguration.StaticHeaderValue {
        TokenReportingConfiguration.StaticHeaderValue(name: name, value: value)
    }

    static func verifyStatusReflectsResolvedHeaders() throws {
        // A valid config reports ready.
        try expect(statusFor(readyConfiguration()) == .ready, "baseline ready")
        // Invalid runtime header (unknown variable) must report .invalid, not .ready.
        let badRuntime = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "macos"), templates: [.init(name: "X-Version", template: "{{app_version}}")])
        try expect(statusFor(readyConfiguration(runtimeHeaders: badRuntime)) == .invalid, "invalid runtime header => status .invalid")
        // Protected-header override via runtime template.
        let overrideRuntime = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "macos"), templates: [.init(name: "content-type", template: "{{platform}}")])
        try expect(statusFor(readyConfiguration(runtimeHeaders: overrideRuntime)) == .invalid, "runtime protected override => status .invalid")
    }

    static func verifyStaticHeaderSelfValidation() throws {
        let base = URL(string: "https://example.invalid")!
        // Illegal name in an explicit static header fails closed.
        let illegalName = readyConfiguration(staticHeaders: [staticHeader("X:Bad", "v")])
        try expect(!illegalName.isReady, "illegal static header name => unready")
        try expect(statusFor(illegalName) == .invalid, "illegal static header name => status .invalid")
        // CRLF in an explicit static header value fails closed.
        let crlfValue = readyConfiguration(staticHeaders: [staticHeader("X-Bad", "a\r\nInjected: 1")])
        try expect(!crlfValue.isReady, "CRLF static header value => unready")
        // Protected-header collision via explicit static header fails closed.
        let protectedStatic = readyConfiguration(staticHeaders: [staticHeader("Content-Type", "text/plain")])
        try expect(!protectedStatic.isReady, "protected static header => unready")
        // Duplicate name across explicit + runtime template fails closed.
        let dupRuntime = TokenReportingConfiguration.RuntimeHeaders(context: .init(platform: "macos"), templates: [.init(name: "X-Dup", template: "{{platform}}")])
        let dup = readyConfiguration(runtimeHeaders: dupRuntime, staticHeaders: [staticHeader("x-dup", "explicit")])
        try expect(!dup.isReady, "duplicate header name across sets => unready")
        // Duplicate among explicit-only also fails closed.
        let dupExplicit = readyConfiguration(staticHeaders: [staticHeader("X-Same", "a"), staticHeader("x-same", "b")])
        try expect(!dupExplicit.isReady, "duplicate explicit header name => unready")
        // A blank explicit name is dropped (omitted), leaving config ready.
        let blankName = readyConfiguration(staticHeaders: [staticHeader("", "ignored"), staticHeader("X-Ok", "v")])
        try expect(blankName.isReady, "blank static header name is omitted, config stays ready")
        let inc = blankName.ingestConfiguration(baseURL: base, hostname: "device")
        try expect(inc.staticHeaders == [StaticHeader(name: "X-Ok", value: "v")], "blank-name header omitted from resolved set")
    }
}
