import Foundation

/// A bearer token wrapped so it never lands in logs, error messages, or debug
/// dumps. Only reveal() exposes the raw value, and every stringy conversion is
/// redacted.
public struct SecretToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    public init(_ value: String) { self.value = value }

    /// Returns the underlying token. Call this only at the point of use (for
    /// example when setting a request header) and never store the result.
    public func reveal() -> String { value }

    public var isEmpty: Bool { value.isEmpty }

    public var description: String { "SecretToken(redacted)" }
    public var debugDescription: String { description }
}

/// Errors surfaced while obtaining a token. Messages describe only the failure
/// category and never embed any token bytes or raw command output that could
/// contain a token.
public enum TokenProviderError: Error, Equatable, Sendable {
    /// No command was configured, so the provider refuses to run anything.
    case configurationMissing
    /// The helper binary could not be launched.
    case launchFailed
    /// The helper exited with a non-zero status.
    case commandFailed(exitCode: Int32)
    /// The helper output was not valid UTF-8 or not the expected JSON envelope.
    case malformedOutput
    /// The envelope reported a non-success status or carried an error field.
    case unsuccessfulResponse
    /// The envelope parsed but contained no usable token.
    case missingToken
}

/// Abstraction over "run a command and collect its output" so the provider can
/// be unit-tested without spawning a real process.
public protocol ProcessRunning: Sendable {
    /// Runs the executable with the given arguments and returns its exit status
    /// and captured standard output bytes. Implementations must not log the
    /// arguments or output, which may contain secrets.
    func run(executable: String, arguments: [String]) throws -> ProcessResult
}

/// Captured result of a single command invocation.
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data

    public init(exitCode: Int32, standardOutput: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
    }
}

/// Default ProcessRunning backed by a subprocess. Standard error is
/// intentionally discarded rather than captured or logged, because helper
/// diagnostics may echo token material.
public struct SubprocessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw TokenProviderError.launchFailed
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(exitCode: process.terminationStatus, standardOutput: data)
    }
}

/// Configuration for a command-based token provider. Every field is supplied by
/// the caller; the defaults are empty so an unconfigured provider performs no
/// process execution at all.
public struct CommandTokenProviderConfiguration: Sendable, Equatable {
    /// Executable to run. Empty means "not configured".
    public var executable: String
    /// Arguments used for a normal fetch.
    public var arguments: [String]
    /// Extra arguments appended when a forced refresh is requested.
    public var forceRefreshArguments: [String]
    /// Envelope status key; when present and not equal to successStatus the
    /// response is treated as a failure. Empty disables the status check.
    public var statusKey: String
    /// Value of statusKey that indicates success.
    public var successStatus: String
    /// Envelope error key; when present and non-empty the response is a failure.
    /// Empty disables the error check.
    public var errorKey: String
    /// Ordered keys used to walk into the JSON envelope to reach the token
    /// string (for example ["data", "token"]).
    public var tokenKeyPath: [String]

    public init(
        executable: String = "",
        arguments: [String] = [],
        forceRefreshArguments: [String] = [],
        statusKey: String = "",
        successStatus: String = "",
        errorKey: String = "",
        tokenKeyPath: [String] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.forceRefreshArguments = forceRefreshArguments
        self.statusKey = statusKey
        self.successStatus = successStatus
        self.errorKey = errorKey
        self.tokenKeyPath = tokenKeyPath
    }

    /// True when an executable and a token path are configured.
    public var isConfigured: Bool { !executable.isEmpty && !tokenKeyPath.isEmpty }
}

/// Obtains a token by invoking a caller-configured command and parsing its JSON
/// output entirely in memory. The token is never written to disk, logged, or
/// embedded in error messages, and is returned wrapped in SecretToken.
///
/// When the configuration is empty the provider throws configurationMissing and
/// launches no process, so an unconfigured build performs zero execution.
///
/// Refresh policy: token(forceRefresh:) appends the configured force-refresh
/// arguments only when asked. The ingest client asks for exactly one forced
/// refresh after an unauthorized response.
public struct ConfiguredCommandTokenProvider: Sendable {
    private let configuration: CommandTokenProviderConfiguration
    private let runner: ProcessRunning

    public init(
        configuration: CommandTokenProviderConfiguration = CommandTokenProviderConfiguration(),
        runner: ProcessRunning = SubprocessRunner()
    ) {
        self.configuration = configuration
        self.runner = runner
    }

    /// Fetches a token. When forceRefresh is true the configured force-refresh
    /// arguments are appended. Throws configurationMissing (running nothing) if
    /// the provider is not configured.
    public func token(forceRefresh: Bool = false) throws -> SecretToken {
        guard configuration.isConfigured else {
            throw TokenProviderError.configurationMissing
        }

        var arguments = configuration.arguments
        if forceRefresh {
            arguments.append(contentsOf: configuration.forceRefreshArguments)
        }

        let result = try runner.run(executable: configuration.executable, arguments: arguments)
        guard result.exitCode == 0 else {
            throw TokenProviderError.commandFailed(exitCode: result.exitCode)
        }
        return try Self.parseToken(from: result.standardOutput, configuration: configuration)
    }

    /// Parses the JSON envelope and extracts the token along the configured key
    /// path. All parsing stays in memory; nothing is logged.
    public static func parseToken(from data: Data, configuration: CommandTokenProviderConfiguration) throws -> SecretToken {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TokenProviderError.malformedOutput
        }
        guard let object = root as? [String: Any] else {
            throw TokenProviderError.malformedOutput
        }

        if !configuration.statusKey.isEmpty, let status = object[configuration.statusKey] as? String, status != configuration.successStatus {
            throw TokenProviderError.unsuccessfulResponse
        }
        if !configuration.errorKey.isEmpty, let apiError = object[configuration.errorKey] as? String, !apiError.isEmpty {
            throw TokenProviderError.unsuccessfulResponse
        }

        guard let token = walk(object, path: configuration.tokenKeyPath), !token.isEmpty else {
            throw TokenProviderError.missingToken
        }
        return SecretToken(token)
    }

    /// Walks a nested dictionary along path and returns the terminal string.
    private static func walk(_ object: [String: Any], path: [String]) -> String? {
        guard !path.isEmpty else { return nil }
        var current: Any? = object
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current as? String
    }
}

