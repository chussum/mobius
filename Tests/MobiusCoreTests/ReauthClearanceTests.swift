import XCTest
@testable import MobiusCore

/// `needsReauth`("재로그인 필요") 딱지를 내려도 되는지의 순수 판정.
/// 딱지의 의미가 "저장된 **그** refresh 토큰이 폐기됨"이므로, 근거는 오직
/// **refresh 토큰이 다른 값으로 교체됐는가**다 — 그 외에는 전부 보수적으로 유지한다.
final class ReauthClearanceTests: XCTestCase {
    private func blob(refresh: String?, access: String = "A") -> Data {
        var oauth: [String: Any] = ["accessToken": access]
        if let refresh { oauth["refreshToken"] = refresh }
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    func testRotatedRefreshTokenClears() {
        XCTAssertTrue(ReauthClearance.refreshTokenRotated(previous: blob(refresh: "R0"),
                                                          next: blob(refresh: "R1")))
    }

    func testSameRefreshTokenDoesNotClear() {
        // 활성 계정의 5분 라이브싱크는 죽은 계정도 같은 토큰을 계속 되저장한다.
        // access 토큰만 달라져도 살아있다는 증거가 아니다.
        XCTAssertFalse(ReauthClearance.refreshTokenRotated(previous: blob(refresh: "R0", access: "A0"),
                                                           next: blob(refresh: "R0", access: "A1")))
    }

    func testMissingPreviousDoesNotClear() {
        // 비교 대상이 없으면 회전을 확인할 수 없다 → 유지.
        XCTAssertFalse(ReauthClearance.refreshTokenRotated(previous: nil, next: blob(refresh: "R1")))
    }

    func testMissingRefreshTokenOnEitherSideDoesNotClear() {
        XCTAssertFalse(ReauthClearance.refreshTokenRotated(previous: blob(refresh: nil),
                                                           next: blob(refresh: "R1")))
        XCTAssertFalse(ReauthClearance.refreshTokenRotated(previous: blob(refresh: "R0"),
                                                           next: blob(refresh: nil)))
    }

    func testEmptyRefreshTokenDoesNotClear() {
        // 빈 문자열은 손상 스냅샷(실측 fore.st) — CredentialBlob이 nil로 주므로 유지된다.
        // 손상된 blob으로 덮어쓰는 것이 "복구됨"으로 읽히면 안 된다.
        XCTAssertFalse(ReauthClearance.refreshTokenRotated(previous: blob(refresh: "R0"),
                                                           next: blob(refresh: "")))
    }

    func testUnparsableSecretDoesNotClear() {
        // Claude 형식이 아닌 secret(예: Codex auth.json)은 판정 대상이 아니다.
        XCTAssertFalse(ReauthClearance.refreshTokenRotated(previous: Data("not json".utf8),
                                                           next: Data("still not json".utf8)))
    }

    func testReadsRefreshTokenInsideStoredSnapshot() {
        // ★ 저장 secret은 raw blob이 아니라 **CredentialsSnapshot JSON**이다
        //   (ClaudeConfigIO.readLiveSecretData). 한 겹 안 벗기면 refreshToken 키를 못 찾아
        //   항상 nil → 이 규칙 전체가 컴파일도 테스트도 통과하면서 조용히 무력해진다.
        func stored(_ refresh: String) -> Data {
            try! JSONEncoder().encode(CredentialsSnapshot(keychainBlob: blob(refresh: refresh),
                                                          credentialsFileData: blob(refresh: refresh),
                                                          oauthAccountJSON: nil))
        }
        XCTAssertTrue(ReauthClearance.refreshTokenRotated(previous: stored("R0"), next: stored("R1")))
        XCTAssertFalse(ReauthClearance.refreshTokenRotated(previous: stored("R0"), next: stored("R0")))
    }

    func testFlatBlobShapeIsAlsoRead() {
        // blob은 {claudeAiOauth:{…}} 또는 평면 형태 둘 다 허용 (CredentialBlob과 동일 관용성).
        let old = Data(#"{"refreshToken":"R0"}"#.utf8)
        let new = Data(#"{"refreshToken":"R1"}"#.utf8)
        XCTAssertTrue(ReauthClearance.refreshTokenRotated(previous: old, next: new))
    }
}
