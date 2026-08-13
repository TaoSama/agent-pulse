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
    /// The helper did not finish within the configured timeout and was
    /// terminated. No output is captured or surfaced.
    case timedOut
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
    ///
    /// The runner must enforce timeout: if the child does not finish within
    /// timeout seconds it must be terminated and TokenProviderError.timedOut
    /// thrown. A non-positive timeout means "no timeout".
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> ProcessResult
}

public extension ProcessRunning {
    /// Convenience overload defaulting to no timeout, preserving older call
    /// sites that do not care about deadlines.
    func run(executable: String, arguments: [String]) throws -> ProcessResult {
        try run(executable: executable, arguments: arguments, timeout: 0)
    }
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

    public func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        // Drain stdout on a dedicated thread so a helper that writes more than
        // the OS pipe buffer can never deadlock against our wait. The buffer is
        // guarded by a lock and never logged.
        let drainedOutput = LockedData()
        let readHandle = stdoutPipe.fileHandleForReading
        let drainThread = Thread {
            let data = readHandle.readDataToEndOfFile()
            drainedOutput.set(data)
        }
        drainThread.name = "token-helper-stdout-drain"

        do {
            try process.run()
        } catch {
            throw TokenProviderError.launchFailed
        }
        drainThread.start()

        if timeout > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() >= deadline {
                    // Terminate then hard-kill to guarantee the child cannot
                    // outlive the deadline, then let the drain finish so the
                    // pipe is closed and the thread exits cleanly.
                    process.terminate()
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    process.waitUntilExit()
                    _ = drainedOutput.waitForCompletion(timeout: 1.0)
                    throw TokenProviderError.timedOut
                }
                // Poll cheaply; the child usually finishes well before this.
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        process.waitUntilExit()
        // Ensure the drain thread has observed EOF before we read the buffer.
        _ = drainedOutput.waitForCompletion(timeout: 1.0)
        return ProcessResult(exitCode: process.terminationStatus, standardOutput: drainedOutput.get())
    }
}

/// A tiny thread-safe box for the drained stdout bytes. Isolating the buffer
/// behind a lock keeps the reader thread and the waiter from racing, and keeps
/// the captured bytes (which may contain a token) off any log path.
private final class LockedData: @unchecked Sendable {
    private let lock = NSCondition()
    private var data = Data()
    private var completed = false

    func set(_ value: Data) {
        lock.lock()
        data = value
        completed = true
        lock.signal()
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    /// Waits up to timeout seconds for set() to be called. Returns true when
    /// the drain completed, false on timeout.
    @discardableResult
    func waitForCompletion(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while !completed {
            if !lock.wait(until: deadline) { return completed }
        }
        return true
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
    /// Maximum seconds the helper may run before it is terminated and
    /// TokenProviderError.timedOut is thrown. Defaults to 30 seconds; a
    /// non-positive value disables the timeout.
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

        let result = try runner.run(
            executable: configuration.executable,
            arguments: arguments,
            timeout: configuration.timeoutSeconds
        )
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
