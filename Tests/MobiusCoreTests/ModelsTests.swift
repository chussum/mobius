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

    /// M1 시절 accounts.json(신규 필드 없음)이 그대로 디코드되는지 — Codable 하위호환
    func testDecodesLegacyAccountsFileWithoutNewFields() throws {
        let legacy = """
        {"accounts": [], "activeAccountID": null,
         "autoSwitchEnabled": false, "desktopSyncEnabled": true}
        """
        let file = try JSONDecoder().decode(AccountsFile.self, from: Data(legacy.utf8))
        // 구 전역 autoSwitchEnabled는 양쪽 풀에 동일 적용
        XCTAssertFalse(file.isAutoSwitchEnabled(.claude))
        XCTAssertFalse(file.isAutoSwitchEnabled(.codex))
        XCTAssertTrue(file.desktopSyncEnabled)
        XCTAssertFalse(file.desktopAutoSwitchEnabled) // 없으면 기본 끔
        XCTAssertFalse(file.autoSwitchedFromPrimary)  // 없으면 기본 false (수동 상태로 간주)
    }

    func testAutoSwitchByProviderRoundtripAndLegacyKey() throws {
        var file = AccountsFile()
        file.autoSwitchByProvider[.codex] = false
        let data = try JSONEncoder().encode(file)
        let back = try JSONDecoder().decode(AccountsFile.self, from: data)
        XCTAssertTrue(back.isAutoSwitchEnabled(.claude))  // 기록 없는 풀은 기본 켬
        XCTAssertFalse(back.isAutoSwitchEnabled(.codex))
        // 다운그레이드 완충: 레거시 전역 키에는 Claude 풀 값이 실린다
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["autoSwitchEnabled"] as? Bool, true)

        file.autoSwitchByProvider[.claude] = false
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(file)) as? [String: Any])
        XCTAssertEqual(obj2["autoSwitchEnabled"] as? Bool, false)
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
