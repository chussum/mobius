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

    /// 프로바이더 키 딕셔너리는 JSON **객체**로 저장돼야 한다 — Provider를 딕셔너리 키로
    /// 그대로 인코딩하면 Swift Codable이 배열(["claude", …])로 저장한다(CodingKeyRepresentable
    /// 미채택). 사람이 읽을 수 있고 unknown 키 스킵이 가능한 객체 형태를 보증한다.
    func testProviderMapsEncodeAsJSONObjects() throws {
        let id = UUID()
        var file = AccountsFile()
        file.activeByProvider = [.claude: id]
        file.autoSwitchByProvider[.codex] = false
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(file)) as? [String: Any])
        let active = try XCTUnwrap(obj["activeByProvider"] as? [String: String])
        XCTAssertEqual(active, ["claude": id.uuidString])
        let auto = try XCTUnwrap(obj["autoSwitchByProvider"] as? [String: Bool])
        XCTAssertEqual(auto, ["codex": false])
    }

    /// 미래 버전이 추가한 프로바이더 키가 있어도(다운그레이드) 그 키만 스킵하고 파일은
    /// 정상 디코드돼야 한다 — unknown raw value 하나가 파일 전체 디코드 실패(→ corrupt
    /// 백업 + 빈 스토어)로 번지는 실패 기록 13 클래스의 예방.
    func testUnknownProviderKeyIsSkippedNotFatal() throws {
        let id = UUID()
        let json = """
        {"accounts": [],
         "activeByProvider": {"claude": "\(id.uuidString)", "gemini": "\(UUID().uuidString)"},
         "autoSwitchByProvider": {"claude": true, "gemini": false},
         "autoSwitchedByProvider": {"gemini": true}}
        """
        let file = try JSONDecoder().decode(AccountsFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.activeByProvider, [.claude: id])
        XCTAssertTrue(file.isAutoSwitchEnabled(.claude))
        XCTAssertFalse(file.isAutoSwitchedFromPrimary(.claude)) // gemini 값은 버려짐
    }

    /// 아는 프로바이더 키의 값 손상은 조용히 삼키지 않고 throw해야 한다 — try?로 삼키면
    /// 손상 파일이 빈 상태로 디코드되고 다음 save가 원본을 덮어써, AccountStore의
    /// corrupt 백업 경로(원본 보존)가 무력화된다 (리뷰 지적 반영).
    func testCorruptValueUnderKnownProviderKeyThrows() {
        let corrupt = """
        {"accounts": [], "activeByProvider": {"claude": "not-a-uuid"}}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(AccountsFile.self, from: Data(corrupt.utf8)))
        // 모르는 프로바이더 키는 값이 무엇이든 스킵 (전방호환 — 위와 구분되는 경계)
        let unknownOnly = """
        {"accounts": [], "activeByProvider": {"gemini": 12345}}
        """
        XCTAssertNoThrow(try JSONDecoder().decode(AccountsFile.self, from: Data(unknownOnly.utf8)))
    }

    /// 초기 v2 파일(배열 형태 딕셔너리 — [String:] 명시 인코딩 이전 버전이 저장)도
    /// 읽을 수 있어야 한다.
    func testEarlyV2ArrayFormProviderMapStillDecodes() throws {
        let id = UUID()
        let json = """
        {"accounts": [],
         "activeByProvider": ["claude", "\(id.uuidString)"],
         "autoSwitchByProvider": ["codex", false]}
        """
        let file = try JSONDecoder().decode(AccountsFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.activeByProvider, [.claude: id])
        XCTAssertFalse(file.isAutoSwitchEnabled(.codex))
        XCTAssertTrue(file.isAutoSwitchEnabled(.claude))
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
