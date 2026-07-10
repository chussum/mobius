import XCTest
@testable import MobiusCore

final class ModelsTests: XCTestCase {
    func testEnvironmentPaths() {
        let env = MobiusEnvironment(home: URL(fileURLWithPath: "/tmp/x"), localUser: "u")
        XCTAssertEqual(env.credentialsFile.path, "/tmp/x/.claude/.credentials.json")
        XCTAssertEqual(env.claudeKeychainService, "Claude Code-credentials")
    }

    func testAccountsFileRoundtripAndOrdering() throws {
        let a = AccountProfile(id: UUID(), nickname: "personal", emailAddress: "p@x.com",
                               organizationName: "P Org", tierDescription: "Max 20x")
        let b = AccountProfile(id: UUID(), nickname: "work", emailAddress: "w@x.com",
                               organizationName: "W Org", tierDescription: "Team")
        var file = AccountsFile(accounts: [a, b], activeAccountID: a.id)
        XCTAssertEqual(file.primary?.id, a.id)
        XCTAssertEqual(file.active?.id, a.id)
        let data = try JSONEncoder().encode(file)
        let back = try JSONDecoder().decode(AccountsFile.self, from: data)
        XCTAssertEqual(back, file)
        file.activeAccountID = UUID() // 없는 ID
        XCTAssertNil(file.active)
    }

    func testIsLimited() {
        let now = Date(timeIntervalSince1970: 1_000)
        var p = AccountProfile(id: UUID(), nickname: "n", emailAddress: "e",
                               organizationName: "o", tierDescription: "t")
        XCTAssertFalse(p.isLimited(now: now))
        p.rateLimit = RateLimitInfo(resetsAt: Date(timeIntervalSince1970: 2_000), recordedAt: now)
        XCTAssertTrue(p.isLimited(now: now))
        XCTAssertFalse(p.isLimited(now: Date(timeIntervalSince1970: 2_001)))
    }
}
