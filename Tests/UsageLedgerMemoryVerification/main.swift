import AgentPulseCore
import Foundation

enum UsageLedgerMemoryVerification {
    static func run() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let databasePath = environment["AGENT_PULSE_MEMORY_DB"], !databasePath.isEmpty,
              let hostname = environment["AGENT_PULSE_MEMORY_HOSTNAME"], !hostname.isEmpty else {
            FileHandle.standardError.write(Data(
                "set AGENT_PULSE_MEMORY_DB and AGENT_PULSE_MEMORY_HOSTNAME\n".utf8
            ))
            Foundation.exit(2)
        }

        let startedAt = Date()
        let ledger = try UsageLedgerStore(path: databasePath)
        let result = try ledger.finalizeDerived(hostname: hostname) { done, total in
            let elapsed = Date().timeIntervalSince(startedAt)
            let elapsedText = String(format: "%.2f", elapsed)
            FileHandle.standardError.write(Data(
                "UsageLedgerMemoryVerification: stage=\(done)/\(total) elapsed=\(elapsedText)s\n".utf8
            ))
        }
        print(
            "UsageLedgerMemoryVerification: PASS elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s "
                + "eligible=\(result.reportingEligible)"
        )
    }
}

do {
    try UsageLedgerMemoryVerification.run()
} catch {
    FileHandle.standardError.write(Data("UsageLedgerMemoryVerification: FAIL \(error)\n".utf8))
    Foundation.exit(1)
}
