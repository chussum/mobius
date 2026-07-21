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

    // MARK: 임계값 선제 경고 (advisory) — 실패 기록 13 게이트

    /// ★ 실패 기록 13 게이트: advisory/pinnedAt 키가 **없는** 변경 전 accounts.json이
    /// 그대로 디코드돼야 한다. 여기서 throw하면 AppState가 빈 스토어로 폴백하고 다음
    /// reconcile이 파일을 덮어써 **계정이 영구 유실**된다 — 이 테스트가 그 경로의 문지기다.
    /// 픽스처는 실제 현행 스키마(실측)에서 두 신규 키만 뺀 것이다.
    func testDecodesPreAdvisoryAccountsFileFixture() throws {
        let file = try JSONDecoder().decode(
            AccountsFile.self, from: Data(preAdvisoryAccountsFileFixture.utf8))
        XCTAssertEqual(file.accounts.count, 2)
        let limited = try XCTUnwrap(file.accounts.first)   // rateLimit 있는 계정
        let plain = try XCTUnwrap(file.accounts.last)      // rateLimit 없는 계정

        // 신규 필드는 없으면 nil (기본값) — 디코드 실패가 아니라 관대한 흡수
        for p in file.accounts {
            XCTAssertNil(p.advisory)
            XCTAssertNil(p.pinnedAt)
            XCTAssertFalse(p.hasActiveAdvisory(now: fixtureNow))
        }
        // 기존 신호는 그대로 — advisory 도입이 isLimited/autoSwitchMayLeave를 건드리지 않았다
        XCTAssertTrue(limited.isLimited(now: fixtureNow))
        XCTAssertTrue(limited.autoSwitchMayLeave(now: fixtureNow))
        XCTAssertFalse(plain.isLimited(now: fixtureNow))
        XCTAssertFalse(plain.autoSwitchMayLeave(now: fixtureNow))
        // 구 파일의 나머지 상태도 온전히 (빈 스토어 폴백이 아님을 명확히)
        XCTAssertEqual(file.active?.id, limited.id)
        XCTAssertTrue(limited.userPinned)
    }

    /// 두 신규 필드가 모두 실린 파일의 왕복 — 저장→로드에서 값이 보존되는가
    func testAdvisoryAndPinnedAtRoundtrip() throws {
        let pinned = Date(timeIntervalSince1970: 5_000)
        let advisory = AdvisoryRecord(utilization: 92.5,
                                      resetsAt: Date(timeIntervalSince1970: 9_000),
                                      detectedAt: Date(timeIntervalSince1970: 4_000))
        let p = AccountProfile(id: UUID(), nickname: "n", emailAddress: "e",
                               organizationName: "o", tierDescription: "t",
                               userPinned: true, pinnedAt: pinned, advisory: advisory)
        let file = AccountsFile(accounts: [p], activeAccountID: p.id)
        let back = try JSONDecoder().decode(
            AccountsFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(back, file)
        let got = try XCTUnwrap(back.accounts.first)
        XCTAssertEqual(got.advisory, advisory)
        XCTAssertEqual(got.pinnedAt, pinned)
    }

    /// advisory 시간 게이트 — 리셋 경계에서 true/false, 한참 지난 뒤에도 (필드가 남아
    /// 있어도) false. isLimited와 같은 모양의 게이트를 갖는지 보증한다.
    func testAdvisoryTimeGateAtResetBoundary() {
        let resets = Date(timeIntervalSince1970: 2_000)
        var p = AccountProfile(id: UUID(), nickname: "n", emailAddress: "e",
                               organizationName: "o", tierDescription: "t")
        XCTAssertFalse(p.hasActiveAdvisory(now: Date(timeIntervalSince1970: 1_000))) // nil이면 false
        p.advisory = AdvisoryRecord(utilization: 91, resetsAt: resets,
                                    detectedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(p.hasActiveAdvisory(now: Date(timeIntervalSince1970: 1_999)))
        XCTAssertFalse(p.hasActiveAdvisory(now: resets))                              // 경계 포함 X
        XCTAssertFalse(p.hasActiveAdvisory(now: Date(timeIntervalSince1970: 2_001)))
        // 필드가 남아 있어도 한참 지나면 계속 false (잔존 상태가 되살아나지 않는다)
        XCTAssertNotNil(p.advisory)
        XCTAssertFalse(p.hasActiveAdvisory(now: Date(timeIntervalSince1970: 999_999)))
    }

    /// ★ 누출 회귀: advisory만 세워진 계정은 **소진이 아니다**. isLimited와
    /// autoSwitchMayLeave가 모두 false여야 메뉴바·CLI·알림 문구가 정직하게 유지된다.
    /// 진짜 rateLimit이 함께 있으면 종전대로 동작해야 한다(경고가 기존 신호를 가리지도 않음).
    func testAdvisoryAloneDoesNotLeakIntoLimitedSignals() {
        let now = Date(timeIntervalSince1970: 1_000)
        var p = AccountProfile(id: UUID(), nickname: "n", emailAddress: "e",
                               organizationName: "o", tierDescription: "t")
        p.advisory = AdvisoryRecord(utilization: 99, resetsAt: Date(timeIntervalSince1970: 9_000),
                                    detectedAt: now)
        XCTAssertTrue(p.hasActiveAdvisory(now: now))
        XCTAssertFalse(p.isLimited(now: now))
        XCTAssertFalse(p.autoSwitchMayLeave(now: now))

        // 진짜 소진이 함께 있으면 오늘과 동일하게 동작
        p.rateLimit = RateLimitInfo(resetsAt: Date(timeIntervalSince1970: 2_000), recordedAt: now)
        XCTAssertTrue(p.isLimited(now: now))
        XCTAssertTrue(p.autoSwitchMayLeave(now: now))
        // 모델 전용 한도 + 핀이면 밀어내지 않는 기존 규칙도 advisory와 무관하게 유지
        p.rateLimit = RateLimitInfo(resetsAt: Date(timeIntervalSince1970: 2_000),
                                    recordedAt: now, modelScoped: true)
        p.userPinned = true
        XCTAssertTrue(p.isLimited(now: now))
        XCTAssertFalse(p.autoSwitchMayLeave(now: now))
    }

    /// 히스테리시스 경계 행렬 — set은 임계값 이상, clear는 임계값-5 이하.
    /// 밴드 내부(임계값-5 초과 ~ 임계값 미만)에서는 **둘 다 false**라 기존 상태가 유지된다
    /// (경계에서 사용률이 오르내려도 경고가 깜빡이지 않는 근거).
    func testAdvisoryHysteresisBoundaryMatrix() {
        let t: Double = 90
        // shouldSet: 미만 false, 같으면 true, 초과 true
        XCTAssertFalse(AdvisoryRecord.shouldSet(utilization: 89.9, threshold: t))
        XCTAssertTrue(AdvisoryRecord.shouldSet(utilization: 90, threshold: t))
        XCTAssertTrue(AdvisoryRecord.shouldSet(utilization: 99.9, threshold: t))
        // shouldClear: 임계값-5 이하 true, 그 위는 false
        XCTAssertTrue(AdvisoryRecord.shouldClear(utilization: 80, threshold: t))
        XCTAssertTrue(AdvisoryRecord.shouldClear(utilization: 85, threshold: t))
        XCTAssertFalse(AdvisoryRecord.shouldClear(utilization: 85.1, threshold: t))
        // 밴드 내부에서는 둘 다 false (그래서 아무것도 바뀌지 않는다)
        for u in [85.1, 87.0, 89.9] {
            XCTAssertFalse(AdvisoryRecord.shouldSet(utilization: u, threshold: t))
            XCTAssertFalse(AdvisoryRecord.shouldClear(utilization: u, threshold: t))
        }
        // 다른 임계값에서도 밴드 폭은 고정 5포인트
        XCTAssertTrue(AdvisoryRecord.shouldSet(utilization: 50, threshold: 50))
        XCTAssertTrue(AdvisoryRecord.shouldClear(utilization: 45, threshold: 50))
        XCTAssertFalse(AdvisoryRecord.shouldClear(utilization: 45.1, threshold: 50))
    }
}
