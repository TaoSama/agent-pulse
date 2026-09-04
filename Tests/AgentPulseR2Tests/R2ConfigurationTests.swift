import Foundation
import XCTest
@testable import AgentPulseR2

final class R2ConfigurationTests: XCTestCase {
    func testParsesSecureEnvironmentWithoutExposingCredentialValues() throws {
        let accessKey = "unit-test-access-key"
        let secret = "unit-test-secret-key"
        let value = try EnvironmentR2Configuration(environment: validEnvironment(
            accessKey: accessKey,
            secret: secret
        ))

        XCTAssertEqual(value.configuration.region, "auto")
        XCTAssertEqual(value.configuration.bucket, "image-bucket")
        XCTAssertEqual(value.credentials.accessKeyID, accessKey)
        XCTAssertEqual(value.credentials.secretAccessKey, secret)
        XCTAssertFalse(String(describing: value).contains(accessKey))
        XCTAssertFalse(String(reflecting: value.credentials).contains(secret))
    }

    func testMissingConfigurationErrorOnlyContainsFieldName() {
        let secret = "must-not-appear"
        var environment = validEnvironment(accessKey: "access", secret: secret)
        environment.removeValue(forKey: "R2_ACCOUNT_ID")

        XCTAssertThrowsError(try EnvironmentR2Configuration(environment: environment)) { error in
            XCTAssertEqual(error as? R2Error, .invalidConfiguration(fields: ["R2_ACCOUNT_ID"]))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testRejectsInsecurePublicBaseURLWithoutEchoingValue() {
        let insecureValue = "http://private.invalid"
        var environment = validEnvironment(accessKey: "access", secret: "secret")
        environment["R2_PUBLIC_BASE_URL"] = insecureValue

        XCTAssertThrowsError(try EnvironmentR2Configuration(environment: environment)) { error in
            XCTAssertEqual(error as? R2Error, .invalidConfiguration(fields: ["R2_PUBLIC_BASE_URL"]))
            XCTAssertFalse(error.localizedDescription.contains(insecureValue))
        }
    }

    func testEndpointIsDerivedFromAccountAndIgnoresLegacyOverride() throws {
        var environment = validEnvironment(accessKey: "access", secret: "secret")
        let expectedEndpoint = "https://account.r2.cloudflarestorage.com"
        XCTAssertEqual(try EnvironmentR2Configuration(environment: environment).configuration.endpoint.absoluteString, expectedEndpoint)
        environment["R2_ENDPOINT"] = "http://untrusted.invalid/steal"
        let resolved = try EnvironmentR2Configuration(environment: environment)
        XCTAssertEqual(resolved.configuration.endpoint.absoluteString, expectedEndpoint)
        XCTAssertEqual(resolved.configuration.endpoint.scheme, "https")
        XCTAssertNil(resolved.configuration.endpoint.user)
        XCTAssertNil(resolved.configuration.endpoint.password)
    }

    func testRejectsAccountHostBoundaryInjectionWithoutEchoingValues() {
        let secret = "must-not-appear"
        let invalidAccountIDs = ["account.attacker.invalid", "account/path", "account@attacker", "account:443"]
        for accountID in invalidAccountIDs {
            var environment = validEnvironment(accessKey: "access", secret: secret)
            environment["R2_ACCOUNT_ID"] = accountID
            XCTAssertThrowsError(try EnvironmentR2Configuration(environment: environment)) { error in
                XCTAssertEqual(error as? R2Error, .invalidConfiguration(fields: ["R2_ACCOUNT_ID"]))
                XCTAssertFalse(error.localizedDescription.contains(accountID))
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }
    }

    private func validEnvironment(accessKey: String, secret: String) -> [String: String] {
        [
            "R2_ACCOUNT_ID": "account",
            "R2_BUCKET": "image-bucket",
            "R2_PUBLIC_BASE_URL": "https://images.example.test/base/",
            "R2_ACCESS_KEY_ID": accessKey,
            "R2_SECRET_ACCESS_KEY": secret,
        ]
    }
}
