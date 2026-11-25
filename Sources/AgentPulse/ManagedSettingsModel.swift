import AgentPulseCore
import AgentPulseR2
import AgentPulseReporting
import AgentPulseUsage
import Combine
import Foundation

struct ManagedSettingsSnapshot: Sendable {
    let reportingBaseURL: URL?
    let canonicalHostname: String
    let reporting: TokenReportingConfiguration?
    let asterManagementKey: String?
    let r2: EnvironmentR2Configuration?
}

enum ManagedSettingsLoader {
    private static let vault = "DEV-CREDENTIALS"
    private static let item = "Agent Pulse"
    private static let cliPaths = ["/opt/homebrew/bin/op", "/usr/local/bin/op"]
    private static let bootstrapPath = ".credentials/tokens/1password_service_account"
    private static let timeout: TimeInterval = 30

    enum Failure: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: "无法读取 1Password 中的 Agent Pulse 配置"
            }
        }
    }

    private struct Item: Decodable {
        struct Field: Decodable {
            let id: String
            let label: String?
            let value: String?
        }
        let fields: [Field]
    }

    static func load() throws -> ManagedSettingsSnapshot {
        let files = FileManager.default
        let bootstrapURL = files.homeDirectoryForCurrentUser.appendingPathComponent(bootstrapPath)
        guard let cli = cliPaths.first(where: files.isExecutableFile(atPath:)),
              let data = try? OwnerOnlyFileReader.read(url: bootstrapURL),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { throw Failure.unavailable }

        let runner = SubprocessRunner(environmentOverrides: ["OP_SERVICE_ACCOUNT_TOKEN": token])
        let result = try runner.run(executable: cli,
            arguments: ["item", "get", item, "--vault", vault, "--format", "json"], timeout: timeout)
        guard result.exitCode == 0 else { throw Failure.unavailable }
        return try parseItem(result.standardOutput)
    }

    static func parseItem(_ data: Data) throws -> ManagedSettingsSnapshot {
        guard let item = try? JSONDecoder().decode(Item.self, from: data) else { throw Failure.unavailable }

        // Custom fields added in the app may have generated IDs. Accept unique labels, with IDs taking precedence.
        var fields: [String: String] = [:]
        for (label, matches) in Dictionary(grouping: item.fields, by: \.label) {
            if let label, matches.count == 1 { fields[label] = matches[0].value }
        }
        for field in item.fields {
            fields[field.id] = field.value
        }
        let values = fields.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        let hostname = CanonicalHostname.normalize(values["REPORT_CANONICAL_HOSTNAME"] ?? "")
        let reporting = values["REPORTING_PROTOCOL"].flatMap { protocolJSON -> TokenReportingConfiguration? in
            guard var configuration = try? JSONDecoder().decode(TokenReportingConfiguration.self,
                                                                  from: Data(protocolJSON.utf8)) else { return nil }
            configuration.canonicalHostname = hostname
            return configuration.isReady && TokenUsageReporter.isValidPath(configuration.path) ? configuration : nil
        }
        let baseURL = values["REPORT_BASE_URL"].flatMap(URL.init(string:)).flatMap {
            TokenUsageReporter.isValidBaseURL($0) ? $0 : nil
        }
        let r2 = try? EnvironmentR2Configuration(environment: values)
        return ManagedSettingsSnapshot(reportingBaseURL: baseURL, canonicalHostname: hostname, reporting: reporting,
                                       asterManagementKey: values["ASTER_MANAGEMENT_KEY"], r2: r2)
    }
}

@MainActor
final class ManagedSettingsModel: ObservableObject {
    @Published private(set) var hasLoadedItem = false
    @Published private(set) var isR2Configured = false
    @Published private(set) var errorText: String?
    private(set) var snapshot: ManagedSettingsSnapshot?
    var onChange: ((ManagedSettingsSnapshot?) -> Void)?
    private var reloadTask: Task<Void, Never>?

    func reload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try ManagedSettingsLoader.load() } }.value
            guard let self else { return }
            self.reloadTask = nil
            switch result {
            case let .success(snapshot):
                self.snapshot = snapshot
                hasLoadedItem = true
                isR2Configured = snapshot.r2 != nil
                errorText = nil
            case let .failure(error):
                snapshot = nil
                hasLoadedItem = false
                isR2Configured = false
                errorText = (error as? ManagedSettingsLoader.Failure)?.errorDescription ?? "1Password 读取失败"
            }
            onChange?(snapshot)
        }
    }
}
