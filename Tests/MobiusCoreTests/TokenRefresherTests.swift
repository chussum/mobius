import XCTest
@testable import MobiusCore

final class TokenRefresherTests: XCTestCase {
    // claude 실측 blob 형태 (2026-07-13): claudeAiOauth 래퍼 + 실측 키들
    let blob = Data(#"""
    {"claudeAiOauth":{
      "accessToken":"OLD_AT","refreshToken":"OLD_RT",
      "expiresAt":1700000000000,"refreshTokenExpiresAt":1800000000000,
      "scopes":["user:inference","user:profile"],
      "subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}
    """#.utf8)

    // MARK: buildRequest — claude와 동일 형식

    func testBuildRequestMatchesClaude() throws {
        let req = OAuthTokenRefresher.buildRequest(refreshToken: "RT", scopes: ["user:inference", "user:profile"])
        XCTAssertEqual(req.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // ★ User-Agent 필수 — 없으면 서버가 400 invalid_request_format / Cloudflare 403(실측)
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "claude-cli/2.1.207 (external, cli)")
        XCTAssertEqual(req.timeoutInterval, 30)
        let body = try XCTUnwrap(req.httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(obj["refresh_token"] as? String, "RT")
        XCTAssertEqual(obj["client_id"] as? String, "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(obj["scope"] as? String, "user:inference user:profile")
    }

    // MARK: parseResponse

    func testParse200Rotation() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let data = Data(#"{"access_token":"NEW_AT","refresh_token":"NEW_RT","expires_in":3600,"refresh_token_expires_in":1000000,"scope":"user:inference"}"#.utf8)
        let t = try OAuthTokenRefresher.parseResponse(status: 200, data: data, now: now)
        XCTAssertEqual(t.accessToken, "NEW_AT")
        XCTAssertEqual(t.refreshToken, "NEW_RT")
        XCTAssertEqual(t.expiresAtMs, 1_000_000_000 + 3600 * 1000)
        XCTAssertEqual(t.refreshTokenExpiresAtMs, 1_000_000_000 + 1_000_000 * 1000)
        XCTAssertEqual(t.scopes, ["user:inference"])
    }

    func testParseInvalidGrantIsDeath() {
        let data = Data(#"{"error":"invalid_grant","error_description":"expired"}"#.utf8)
        XCTAssertThrowsError(try OAuthTokenRefresher.parseResponse(status: 400, data: data, now: Date())) {
            XCTAssertEqual($0 as? TokenRefresherError, .invalidGrant)
        }
    }

    func testParseOther4xxIsTransientNotDeath() {
        // invalid_grant가 아닌 4xx는 죽음으로 단정하지 않는다(오탐 방지)
        let data = Data(#"{"error":"rate_limited"}"#.utf8)
        XCTAssertThrowsError(try OAuthTokenRefresher.parseResponse(status: 429, data: data, now: Date())) {
            XCTAssertEqual($0 as? TokenRefresherError, .transient)
        }
    }

    func testParse5xxIsTransient() {
        XCTAssertThrowsError(try OAuthTokenRefresher.parseResponse(status: 503, data: Data(), now: Date())) {
            XCTAssertEqual($0 as? TokenRefresherError, .transient)
        }
    }

    // MARK: 로컬 선검사 (네트워크 0)

    func testRefreshTokenExpiryLocalCheck() {
        // refreshTokenExpiresAt = 1800000000000ms = 2027-01-15경
        let before = Date(timeIntervalSince1970: 1_700_000_000) // 이전 → 아직 유효
        let after = Date(timeIntervalSince1970: 1_900_000_000)  // 이후 → 만료
        XCTAssertFalse(CredentialBlob.isRefreshTokenExpired(blob: blob, now: before))
        XCTAssertTrue(CredentialBlob.isRefreshTokenExpired(blob: blob, now: after))
    }

    func testRefreshTokenExpiryUnknownIsNotDeath() {
        // 필드 없으면 죽음으로 단정하지 않는다
        let noRte = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#.utf8)
        XCTAssertFalse(CredentialBlob.isRefreshTokenExpired(blob: noRte, now: Date(timeIntervalSince1970: 9_999_999_999)))
    }

    func testReadRefreshTokenAndScopes() {
        XCTAssertEqual(CredentialBlob.refreshToken(from: blob), "OLD_RT")
        XCTAssertEqual(CredentialBlob.scopes(from: blob), ["user:inference", "user:profile"])
    }

    func testEmptyRefreshTokenTreatedAsNil() {
        // 손상/미완성 스냅샷(빈 refreshToken) — 실측 fore.st 케이스. nil로 취급해 재로그인 유도.
        let empty = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"","refreshTokenExpiresAt":1900000000000}}"#.utf8)
        XCTAssertNil(CredentialBlob.refreshToken(from: empty))
        let missing = Data(#"{"claudeAiOauth":{"accessToken":"a"}}"#.utf8)
        XCTAssertNil(CredentialBlob.refreshToken(from: missing))
    }

    // MARK: blob 재구성 — 토큰 갱신 + 다른 필드 보존

    func testRebuildPreservesOtherFields() throws {
        let t = RefreshedTokens(accessToken: "NEW_AT", refreshToken: "NEW_RT",
                                expiresAtMs: 1750000000000, refreshTokenExpiresAtMs: 1850000000000,
                                scopes: nil)
        let newBlob = try XCTUnwrap(CredentialBlob.rebuild(blob: blob, applying: t))
        let oauth = try XCTUnwrap((try JSONSerialization.jsonObject(with: newBlob) as? [String: Any])?["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "NEW_AT")
        XCTAssertEqual(oauth["refreshToken"] as? String, "NEW_RT")
        XCTAssertEqual(oauth["expiresAt"] as? Int, 1750000000000)
        XCTAssertEqual(oauth["refreshTokenExpiresAt"] as? Int, 1850000000000)
        // 보존되어야 하는 필드들
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["rateLimitTier"] as? String, "default_claude_max_20x")
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:inference", "user:profile"]) // scopes:nil이라 원본 유지
    }

    // MARK: 스냅샷 적용 — 원자성(재구성 실패 시 nil)

    func testSnapshotApplyRebuildsBothBlobs() throws {
        let snap = CredentialsSnapshot(keychainBlob: blob, credentialsFileData: blob, oauthAccountJSON: Data("{}".utf8))
        let t = RefreshedTokens(accessToken: "N_AT", refreshToken: "N_RT", expiresAtMs: 123, refreshTokenExpiresAtMs: 456, scopes: nil)
        let out = try XCTUnwrap(snap.applyingRefreshedTokens(t))
        XCTAssertEqual(CredentialBlob.refreshToken(from: out.keychainBlob), "N_RT")
        XCTAssertEqual(CredentialBlob.refreshToken(from: out.credentialsFileData), "N_RT")
        XCTAssertEqual(out.oauthAccountJSON, Data("{}".utf8)) // 메타 불변
    }

    func testSnapshotApplyReturnsNilOnGarbageBlob() {
        let snap = CredentialsSnapshot(keychainBlob: Data("not json".utf8), credentialsFileData: blob, oauthAccountJSON: nil)
        let t = RefreshedTokens(accessToken: "a", refreshToken: "r", expiresAtMs: 1, refreshTokenExpiresAtMs: nil, scopes: nil)
        XCTAssertNil(snap.applyingRefreshedTokens(t)) // keychainBlob 재구성 실패 → 반쪽 저장 금지
    }

    // MARK: 전송 주입 — 캐닝 응답으로 end-to-end (네트워크 없음)

    func testRefreshWithInjectedTransport() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let refresher = OAuthTokenRefresher { req in
            // 요청 형식 확인
            XCTAssertEqual(req.url?.host, "platform.claude.com")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"access_token":"AT2","refresh_token":"RT2","expires_in":100}"#.utf8)
            return (data, resp)
        }
        let t = try await refresher.refresh(refreshToken: "OLD", scopes: ["user:inference"], now: now)
        XCTAssertEqual(t.accessToken, "AT2")
        XCTAssertEqual(t.refreshToken, "RT2")
        XCTAssertEqual(t.expiresAtMs, 2_000_000_000 + 100_000)
    }

    func testRefreshMapsNetworkErrorToTransient() async {
        struct Boom: Error {}
        let refresher = OAuthTokenRefresher { _ in throw Boom() }
        do {
            _ = try await refresher.refresh(refreshToken: "x", scopes: [], now: Date())
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? TokenRefresherError, .transient)
        }
    }
}
