import Foundation

/// A single running process observed on the host, reduced to the read-only fields
/// the collector needs. Kept small so scanning back ends stay cheap and easy to fake.
public struct RunningProcess: Sendable, Equatable {
    public let pid: Int32
    /// Full executable path or the best available command string for the process.
    public let executablePath: String
    /// Resident set size in bytes, when the scanner could measure it.
    public let residentMemoryBytes: UInt64?
    /// CPU usage percentage (0...N; may exceed 100 on multi-core), when available.
    public let cpuUsagePercent: Double?

    public init(
        pid: Int32,
        executablePath: String,
        residentMemoryBytes: UInt64? = nil,
        cpuUsagePercent: Double? = nil
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.residentMemoryBytes = residentMemoryBytes
        self.cpuUsagePercent = cpuUsagePercent
    }
}

/// Errors raised while enumerating processes. Callers must handle these explicitly;
/// the collector maps them into a degraded status instead of surfacing a throw.
public enum ProcessScanError: Error, Sendable, Equatable {
    /// The scanner process could not be launched (binary missing, sandbox denial, ...).
    case launchFailed(String)
    /// The scanner ran but exited with a non-zero status.
    case scannerExited(code: Int32, message: String)
    /// The scanner output could not be decoded as UTF-8 text.
    case undecodableOutput
}

/// Abstraction over "list the processes currently running on this machine".
///
/// This is the single seam that makes the collector testable without touching the
/// real process table: tests inject a deterministic fake, production injects
/// SystemProcessScanner.
public protocol ProcessScanning: Sendable {
    /// Returns a snapshot of currently running processes.
    /// Throws ProcessScanError when the underlying source is unavailable.
    func scan() throws -> [RunningProcess]
}

/// Real, read-only process scanner backed by /bin/ps.
///
/// It only reads the process table; it never signals, kills, or otherwise mutates
/// any process. Using ps keeps the implementation dependency-free and the output
/// trivially parseable and injectable for tests.
public struct SystemProcessScanner: ProcessScanning {
    private let executableURL: URL
    private let arguments: [String]

    /// - Parameters:
    ///   - executableURL: Path to the ps binary. Overridable for tests/edge hosts.
    ///   - arguments: Arguments producing pid, rss (KiB), pcpu, then the command path.
    ///     The command column is last so paths containing spaces stay intact.
    public init(
        executableURL: URL = URL(fileURLWithPath: "/bin/ps"),
        arguments: [String] = ["-axo", "pid=,rss=,pcpu=,comm="]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public func scan() throws -> [RunningProcess] {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ProcessScanError.launchFailed(String(describing: error))
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            throw ProcessScanError.scannerExited(
                code: process.terminationStatus,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard let text = String(data: outData, encoding: .utf8) else {
            throw ProcessScanError.undecodableOutput
        }

        return Self.parse(psOutput: text)
    }

    /// Parses "pid rss pcpu command" style output: three leading numeric columns
    /// followed by the command path for the remainder of the line. The command is
    /// last so paths with spaces (e.g. app bundles) survive intact. Lines that do
    /// not begin with a numeric pid are skipped rather than treated as errors,
    /// since ps may emit blank trailing lines.
    ///
    /// rss is reported by ps in KiB and converted to bytes. Unparseable rss/pcpu
    /// columns yield nil for that single field without dropping the process.
    static func parse(psOutput: String) -> [RunningProcess] {
        var result: [RunningProcess] = []
        for rawLine in psOutput.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Split off the three leading numeric columns; keep the command tail whole.
            let scanner = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard scanner.count == 4 else { continue }
            guard let pid = Int32(scanner[0]) else { continue }

            let rssKiB = UInt64(scanner[1])
            let residentMemoryBytes = rssKiB.map { $0 * 1024 }
            let cpuUsagePercent = Double(scanner[2])

            let command = scanner[3].trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }

            result.append(
                RunningProcess(
                    pid: pid,
                    executablePath: command,
                    residentMemoryBytes: residentMemoryBytes,
                    cpuUsagePercent: cpuUsagePercent
                )
            )
        }
        return result
    }
}
