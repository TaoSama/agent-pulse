import XCTest
@testable import AgentPulseReporting

final class TokenAccountIdentityTests: XCTestCase {
    private func jwt(_ payloadJSON: String) -> String { makeTestJWT(payloadJSON) }

    func testSameTenantUsernameMatchesAcrossUnrelatedClaims() {
        let identity = TokenAccountIdentity(claimKeys: TokenAccountClaimKeys(tenant: "tenant_id", username: "username"))
        let a = jwt("{\"iss\":\"issuer\",\"tenant_id\":\"t1\",\"username\":\"u1\"}")
        let b = jwt("{\"iss\":\"issuer\",\"tenant_id\":\"t1\",\"username\":\"u1\",\"exp\":123}")
        XCTAssertTrue(identity.sameStableAccount(a, b))
    }

    func testDifferentAccountsDiffer() {
        let identity = TokenAccountIdentity(claimKeys: TokenAccountClaimKeys(tenant: "tenant_id", username: "username"))
        let a = jwt("{\"iss\":\"issuer\",\"tenant_id\":\"t1\",\"username\":\"u1\"}")
        let b = jwt("{\"iss\":\"issuer\",\"tenant_id\":\"t2\",\"username\":\"u2\"}")
        XCTAssertFalse(identity.sameStableAccount(a, b))
    }

    func testFallsBackToSubjectThenUUID() {
        let identity = TokenAccountIdentity()
        let sub = jwt("{\"iss\":\"issuer\",\"sub\":\"subject-1\"}")
        let subSame = jwt("{\"iss\":\"issuer\",\"sub\":\"subject-1\"}")
        XCTAssertTrue(identity.sameStableAccount(sub, subSame))
        let uuidKeys = TokenAccountIdentity(claimKeys: TokenAccountClaimKeys(subject: "", uuid: "uuid"))
        let u = jwt("{\"iss\":\"issuer\",\"uuid\":\"abc\"}")
        XCTAssertTrue(uuidKeys.sameStableAccount(u, jwt("{\"iss\":\"issuer\",\"uuid\":\"abc\"}")))
        XCTAssertFalse(uuidKeys.sameStableAccount(u, jwt("{\"iss\":\"issuer\",\"uuid\":\"def\"}")))
    }

    func testOpaqueTokensCompareByDigest() {
        let identity = TokenAccountIdentity()
        XCTAssertTrue(identity.sameStableAccount("opaque", "opaque"))
        XCTAssertFalse(identity.sameStableAccount("opaque-1", "opaque-2"))
    }

    func testEmptyTokenNeverMatches() {
        let identity = TokenAccountIdentity()
        XCTAssertFalse(identity.sameStableAccount("", ""))
    }

    func testMissingIssuerFallsBackToDigest() {
        // Without an issuer claim the identity degrades to a token digest, so two
        // distinct claim-bearing tokens are treated as different accounts.
        let identity = TokenAccountIdentity()
        let a = jwt("{\"sub\":\"only-sub\"}")
        let b = jwt("{\"sub\":\"only-sub\"}")
        // Same bytes => same digest => match; different bytes => differ.
        XCTAssertTrue(identity.sameStableAccount(a, b))
        XCTAssertFalse(identity.sameStableAccount(a, jwt("{\"sub\":\"other\"}")))
    }
}

