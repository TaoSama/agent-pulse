import Foundation
@testable import AgentPulseReporting

/// Records command invocations and replays a scripted result.
final class ClosureProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable { let executable: String; let arguments: [String] }
    private(set) var invocations: [Invocation] = []
    private let body: (String, [String]) throws -> ProcessResult

    init(_ body: @escaping (String, [String]) throws -> ProcessResult) { self.body = body }

    func run(executable: String, arguments: [String]) throws -> ProcessResult {
        invocations.append(Invocation(executable: executable, arguments: arguments))
        return try body(executable, arguments)
    }
}

/// Captures requests and replays scripted responses.
final class CapturingSender: HTTPRequestSending, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private let responses: [HTTPResponse]
    private var index = 0

    init(responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        defer { index += 1 }
        return responses[min(index, responses.count - 1)]
    }
}

/// Records force-refresh calls and hands back scripted tokens.
final class StubTokenSupplier: TokenSupplying, @unchecked Sendable {
    private(set) var calls: [Bool] = []
    private let tokens: [String]
    private var index = 0

    init(tokens: [String]) { self.tokens = tokens }

    func token(forceRefresh: Bool) async throws -> SecretToken {
        calls.append(forceRefresh)
        defer { index += 1 }
        return SecretToken(tokens[min(index, tokens.count - 1)])
    }
}

/// Builds an unsigned JWT with the given payload JSON for identity tests.
func makeTestJWT(_ payloadJSON: String) -> String {
    func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return b64url("{\"alg\":\"none\"}") + "." + b64url(payloadJSON) + ".sig"
}

