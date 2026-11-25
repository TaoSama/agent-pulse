import Foundation
import XCTest
@testable import AgentPulse

final class ManagedSettingsTests: XCTestCase {
    func testR2LoadsIndependentlyFromReportingAndAsterUsingFieldLabels() throws {
        let item = """
            {"fields":[
                {"id":"f1","label":"R2_ACCOUNT_ID","value":"fixture123"},
                {"id":"f2","label":"R2_BUCKET","value":"label-bucket"},
                {"id":"R2_BUCKET","label":"Bucket ID override","value":"id-bucket"},
                {"id":"f3","label":"R2_PUBLIC_BASE_URL","value":"https://images.invalid/clipboard"},
                {"id":"f4","label":"R2_ACCESS_KEY_ID","value":"fixture-access-key"},
                {"id":"f5","label":"R2_SECRET_ACCESS_KEY","value":"fixture-secret"},
                {"id":"unused","label":"Unused field"},
                {"id":"f6","label":"REPORTING_PROTOCOL","value":"invalid JSON"}
            ]}
            """
        let settings = try ManagedSettingsLoader.parseItem(Data(item.utf8))
        XCTAssertEqual(settings.r2?.configuration.bucket, "id-bucket")
        XCTAssertEqual(settings.r2?.configuration.publicBaseURL.path, "/clipboard")
        XCTAssertNil(settings.reporting)
        XCTAssertNil(settings.asterManagementKey)
    }

    func testAsterLoadsWhenReportingAndR2AreAbsent() throws {
        let item = """
            {"fields":[
                {"id":"random-id","label":"ASTER_MANAGEMENT_KEY","value":"fixture-management-key"},
                {"id":"REPORT_CANONICAL_HOSTNAME","value":"  fixture-host  "}
            ]}
            """
        let settings = try ManagedSettingsLoader.parseItem(Data(item.utf8))
        XCTAssertTrue(settings.asterManagementKey == "fixture-management-key")
        XCTAssertEqual(settings.canonicalHostname, "fixture-host")
        XCTAssertNil(settings.reporting)
        XCTAssertNil(settings.r2)
    }

    func testReportingLoadsWhenAsterAndR2AreAbsent() throws {
        let reportingProtocol = """
            {"path":"/usage","headers":{"authToken":"Authorization","contentEncoding":"Content-Encoding","contentType":"Content-Type"},
             "tokenCommand":{"executable":"/usr/bin/false","tokenKeyPath":["token"]}}
            """
        let item = try JSONSerialization.data(withJSONObject: ["fields": [
            ["id": "REPORT_BASE_URL", "value": "https://usage.invalid"],
            ["id": "REPORT_CANONICAL_HOSTNAME", "value": "fixture-host"],
            ["id": "generated-id", "label": "REPORTING_PROTOCOL", "value": reportingProtocol]
        ]])
        let settings = try ManagedSettingsLoader.parseItem(item)
        XCTAssertEqual(settings.reportingBaseURL?.host, "usage.invalid")
        XCTAssertEqual(settings.reporting?.canonicalHostname, "fixture-host")
        XCTAssertTrue(settings.reporting?.isReady == true)
        XCTAssertNil(settings.asterManagementKey)
        XCTAssertNil(settings.r2)
    }
}
