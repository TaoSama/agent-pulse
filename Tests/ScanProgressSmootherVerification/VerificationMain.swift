import AgentPulseUI
import Foundation

@main
struct ScanProgressSmootherVerification {
    @MainActor
    static func main() throws {
        let smoother = ScanProgressSmoother(tickInterval: 0.001)

        smoother.setTarget(0.25)
        try require(smoother.isAnimating, "new progress did not start animation")
        try waitUntilStopped(smoother)
        try require(abs(smoother.displayed - 0.25) < 0.000_001, "display did not converge to target")

        let stalledValue = smoother.displayed
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        try require(!smoother.isAnimating, "stalled target restarted animation")
        try require(smoother.displayed == stalledValue, "stalled target kept changing display")

        smoother.setTarget(0.25)
        try require(!smoother.isAnimating, "repeated target restarted animation")

        smoother.setTarget(0.40)
        try require(smoother.isAnimating, "new target did not restart animation")
        try waitUntilStopped(smoother)
        try require(abs(smoother.displayed - 0.40) < 0.000_001, "second target did not converge")

        smoother.setTarget(0.80)
        try require(smoother.isAnimating, "active target did not animate")
        smoother.cancelAnimation()
        try require(!smoother.isAnimating, "view disappearance did not stop animation")

        smoother.setTarget(0.80)
        smoother.setTarget(nil)
        try require(!smoother.isAnimating, "scan end did not stop animation")
        try require(smoother.displayed == 0, "scan end did not reset display")

        print("ScanProgressSmoother verification passed")
    }

    @MainActor
    private static func waitUntilStopped(
        _ smoother: ScanProgressSmoother,
        timeout: TimeInterval = 1
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while smoother.isAnimating, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        try require(!smoother.isAnimating, "animation did not stop before timeout")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw VerificationFailure(message: message) }
    }
}

private struct VerificationFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
