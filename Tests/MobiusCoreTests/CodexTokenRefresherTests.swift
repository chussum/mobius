import XCTest
@testable import MobiusCore

/// codex 비활성 계정 토큰 자동 갱신(게이지 전용). rebuildAuthJSON 병합의 정확성·보존,
/// invalidated/transient 분류, 그리고 저장 직전 신원 검증(AppState가 credential lock 안에서
/// 쓰는 세 조건)을 순수 함수 단위로 검증한다. 네트워크는 주입 transport로 대체(호출 0).
final class CodexTokenRefresherTests: XCTestCase {
    // base64url(JWT 세그먼트) — 서명 검증을 하지 않으므로 유효 서명 불필요.
    private func b64url(_ obj: [String: Any]) -> String {
        let d = try! JSONSerialization.data(withJSONObject: obj)
        return d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private func idToken(email: String) -> String {
        "\(b64url(["alg": "RS256"])).\(b64url(["email": email])).sig"
    }
    private func response(access: String, refresh: String?, idEmail: String?) -> Data {
        var obj: [String: Any] = ["access_token": access, "expires_in": 3600]
        if let refresh { obj["refresh_token"] = refresh }
        if let idEmail { obj["id_token"] = idToken(email: idEmail) }
        return try! JSONSerialization.data(withJSONObject: obj)
    }
    private func mockTransport(status: Int, body: Data)
        -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { req in
            (body, HTTPURLResponse(url: req.url ?? CodexTokenRefresher.endpoint,
                                   statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: rebuildAuthJSON (순수 병합)

    func testRebuildMergesRotatedTokensAndPreservesFields() throws {
        let old = CodexFixtures.authJSON(email: "dev@corp.com", accessToken: "at-old")
        let resp = response(access: "at-new", refresh: "rt-new", idEmail: "dev@corp.com")
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let rebuilt = try XCTUnwrap(CodexTokenRefresher.rebuildAuthJSON(old: old, response: resp, now: when))

        let obj = try XCTUnwrap((try JSONSerialization.jsonObject(with: rebuilt)) as? [String: Any])
        let tokens = try XCTUnwrap(obj["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["access_token"] as? String, "at-new")     // 갱신
        XCTAssertEqual(tokens["refresh_token"] as? String, "rt-new")    // 회전 반영
        XCTAssertEqual(CodexConfigIO.email(fromAuthJSON: rebuilt), "dev@corp.com") // id_token 갱신
        XCTAssertEqual(tokens["account_id"] as? String, "acct-123")     // ★ 보존
        XCTAssertEqual(obj["auth_mode"] as? String, "chatgpt")          // ★ 보존
        XCTAssertEqual(obj["last_refresh"] as? String, CodexTokenRefresher.iso8601.string(from: when))
    }

    func testRebuildKeepsOldRefreshTokenWhenResponseOmitsIt() throws {
        let old = CodexFixtures.authJSON()   // tokens.refresh_token == "rt-1"
        let resp = response(access: "at-new", refresh: nil, idEmail: nil)  // 회전 없음
        let rebuilt = try XCTUnwrap(CodexTokenRefresher.rebuildAuthJSON(old: old, response: resp))
        XCTAssertEqual(CodexTokenRefresher.refreshToken(fromAuthJSON: rebuilt), "rt-1") // 기존 유지
        XCTAssertEqual(CodexAuthBlob.accessToken(fromAuthJSON: rebuilt), "at-new")
    }

    func testRebuildRejectsEmptyRefreshAndGarbage() {
        let old = Data(#"{"tokens":{"refresh_token":""}}"#.utf8)   // 기존도 빈 refresh
        // 응답도 빈 refresh → 최종 refresh_token이 비어 저장 금지(brick 방지)
        XCTAssertNil(CodexTokenRefresher.rebuildAuthJSON(
            old: old, response: Data(#"{"access_token":"at","refresh_token":""}"#.utf8)))
        // access_token 없음 → nil
        XCTAssertNil(CodexTokenRefresher.rebuildAuthJSON(
            old: CodexFixtures.authJSON(), response: Data(#"{"refresh_token":"rt"}"#.utf8)))
        // 쓰레기 응답/구 auth → nil
        XCTAssertNil(CodexTokenRefresher.rebuildAuthJSON(old: Data("x".utf8), response: Data("y".utf8)))
    }

    // MARK: classify (비-200 판정)

    func testClassifyInvalidatedForDeadCodes() {
        for code in ["refresh_token_invalidated", "invalid_grant"] {
            let body = Data(#"{"error":{"code":"\#(code)","type":"invalid_request_error"}}"#.utf8)
            XCTAssertEqual(CodexTokenRefresher.classify(status: 401, data: body), .invalidated,
                           "\(code) → invalidated")
            XCTAssertEqual(CodexTokenRefresher.classify(status: 400, data: body), .invalidated)
        }
        // error가 문자열인 변형도 인식(방어)
        XCTAssertEqual(CodexTokenRefresher.classify(status: 400,
            data: Data(#"{"error":"invalid_grant"}"#.utf8)), .invalidated)
    }

    func testClassifyTransientForOtherErrors() {
        // 죽음 코드가 아닌 4xx → 죽음으로 단정하지 않음(오탐 방지)
        XCTAssertEqual(CodexTokenRefresher.classify(status: 400,
            data: Data(#"{"error":{"code":"invalid_request"}}"#.utf8)), .transient)
        XCTAssertEqual(CodexTokenRefresher.classify(status: 500, data: Data("oops".utf8)), .transient)
        XCTAssertEqual(CodexTokenRefresher.classify(status: 429, data: Data("{}".utf8)), .transient)
    }

    // MARK: refresh (주입 transport)

    func testRefreshSuccessReturnsMergedBytes() async {
        let old = CodexFixtures.authJSON(email: "dev@corp.com", accessToken: "at-old")
        let resp = response(access: "at-new", refresh: "rt-new", idEmail: "dev@corp.com")
        let refresher = CodexTokenRefresher(transport: mockTransport(status: 200, body: resp))
        let out = await refresher.refresh(authJSON: old)
        guard case .refreshed(let bytes) = out else { return XCTFail("expected .refreshed, got \(out)") }
        XCTAssertEqual(CodexAuthBlob.accessToken(fromAuthJSON: bytes), "at-new")
        XCTAssertEqual(CodexTokenRefresher.refreshToken(fromAuthJSON: bytes), "rt-new")
    }

    func testRefreshInvalidatedFromServerBody() async {
        let body = Data(#"{"error":{"code":"refresh_token_invalidated"}}"#.utf8)
        let refresher = CodexTokenRefresher(transport: mockTransport(status: 401, body: body))
        let out = await refresher.refresh(authJSON: CodexFixtures.authJSON())
        XCTAssertEqual(out, .invalidated)
    }

    func testRefreshTransientOnNetworkErrorAndServerError() async {
        let netFail = CodexTokenRefresher(transport: { _ in throw URLError(.notConnectedToInternet) })
        let outNet = await netFail.refresh(authJSON: CodexFixtures.authJSON())
        XCTAssertEqual(outNet, .transient)

        let serverErr = CodexTokenRefresher(transport: mockTransport(status: 503, body: Data("down".utf8)))
        let out5xx = await serverErr.refresh(authJSON: CodexFixtures.authJSON())
        XCTAssertEqual(out5xx, .transient)
    }

    func testRefreshMissingRefreshTokenIsTransientWithoutNetwork() async {
        var called = false
        let refresher = CodexTokenRefresher(transport: { _ in
            called = true
            return (Data(), HTTPURLResponse())
        })
        // refresh_token 없는 auth.json → 시도 불가 → transient(죽음으로 단정 안 함), 네트워크 0
        let out = await refresher.refresh(authJSON: Data(#"{"tokens":{"access_token":"a"}}"#.utf8))
        XCTAssertEqual(out, .transient)
        XCTAssertFalse(called, "refresh 토큰이 없으면 네트워크를 쏘지 않아야 한다")
    }

    // MARK: 저장 직전 신원 검증 (AppState가 credential lock 안에서 쓰는 세 조건)

    func testIdentityMismatchRebuiltBytesRejected() throws {
        // 회전본의 id_token 이메일이 대상 프로필과 다르면 저장 거부돼야 한다(실패 기록 1/13 클래스).
        let old = CodexFixtures.authJSON(email: "me@corp.com", accessToken: "at-old")
        let resp = response(access: "at-new", refresh: "rt-new", idEmail: "stranger@evil.com")
        let rebuilt = try XCTUnwrap(CodexTokenRefresher.rebuildAuthJSON(old: old, response: resp))

        let env = MobiusEnvironment(home: URL(fileURLWithPath: NSTemporaryDirectory()), localUser: "t")
        let codexIO = CodexConfigIO(env: env)
        // AppState의 세 검증 조건을 그대로 재현
        XCTAssertTrue(codexIO.recognizesSecret(rebuilt))                              // 형태는 OK
        XCTAssertNotEqual(CodexConfigIO.email(fromAuthJSON: rebuilt), "me@corp.com")  // ★ 신원 불일치 → 거부
        XCTAssertFalse(CodexTokenRefresher.refreshToken(fromAuthJSON: rebuilt)?.isEmpty ?? true)

        // 일치하는 경우는 통과
        let ok = try XCTUnwrap(CodexTokenRefresher.rebuildAuthJSON(
            old: old, response: response(access: "a", refresh: "r", idEmail: "me@corp.com")))
        XCTAssertEqual(CodexConfigIO.email(fromAuthJSON: ok), "me@corp.com")
    }
}
