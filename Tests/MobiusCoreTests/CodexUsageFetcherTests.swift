import XCTest
@testable import MobiusCore

final class CodexUsageFetcherTests: XCTestCase {
    // 실측 응답(HTTP 200) — 스펙 캡처본 그대로. 게이지 프로브가 파싱해야 하는 정확한 형태.
    let sample = #"""
    {
      "user_id": "user-abc", "account_id": "user-abc", "email": "dev@corp.com", "plan_type": "prolite",
      "rate_limit": {
        "allowed": true, "limit_reached": false,
        "primary_window":  { "used_percent": 12, "limit_window_seconds": 604800, "reset_after_seconds": 449233, "reset_at": 1784961938 },
        "secondary_window": null
      },
      "code_review_rate_limit": null,
      "additional_rate_limits": [
        { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
          "rate_limit": { "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 0, "limit_window_seconds": 604800, "reset_after_seconds": 604800, "reset_at": 1785117506 }, "secondary_window": null } }
      ],
      "credits": { "has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0" },
      "spend_control": { "reached": false, "individual_limit": null },
      "rate_limit_reached_type": null,
      "rate_limit_reset_credits": { "available_count": 1, "applicable_available_count": 0 }
    }
    """#

    func testParseRealSchema() throws {
        let status = try XCTUnwrap(CodexUsageFetcher.parse(Data(sample.utf8)))
        // primary_window = 주간(604800s = 10080분) — 슬롯이 아니라 window_minutes로 판정한다.
        let weekly = try XCTUnwrap(status.weeklyWindow)
        XCTAssertEqual(weekly.usedPercent, 12)
        XCTAssertEqual(weekly.windowMinutes, 10080)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_784_961_938))
        // secondary_window null → 단기(5시간) 창 없음
        XCTAssertNil(status.secondary)
        XCTAssertNil(status.shortWindow)
        // 게이지 투영: 주간만
        let usage = status.usageSnapshot(fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(usage.fiveHourPercent)
        XCTAssertEqual(usage.sevenDayPercent, 12)
        XCTAssertEqual(usage.sevenDayResetsAt, Date(timeIntervalSince1970: 1_784_961_938))
        // ★ additional_rate_limits(GPT-5.3-Codex-Spark, 모델 전용)는 계정 창에서 제외 — 창은 하나뿐.
        XCTAssertEqual([status.primary, status.secondary].compactMap { $0 }.count, 1)
        // 소진 아님 (limit_reached=false, reached_type=null, 12%)
        XCTAssertNil(status.exhaustionHit())
    }

    /// used_percent 100 + limit_reached true → 소진. (그 창의 리셋 시각으로 hit.)
    func testExhaustedByLimitReached() throws {
        let json = #"""
        {"rate_limit":{"allowed":false,"limit_reached":true,
          "primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_at":1784961938},
          "secondary_window":null},
         "additional_rate_limits":[], "rate_limit_reached_type":null}
        """#
        let status = try XCTUnwrap(CodexUsageFetcher.parse(Data(json.utf8)))
        let hit = try XCTUnwrap(status.exhaustionHit())
        XCTAssertEqual(hit.resetsAt, Date(timeIntervalSince1970: 1_784_961_938))
    }

    /// used_percent < 100 이어도 top-level rate_limit_reached_type가 있으면 소진 —
    /// 관찰된 창 중 가장 늦은 리셋(보수적, 슬롯 위치 무관).
    func testExhaustedByReachedTypeUnderHundred() throws {
        let json = #"""
        {"rate_limit":{"allowed":false,"limit_reached":false,
          "primary_window":{"used_percent":97,"limit_window_seconds":18000,"reset_at":1784900000},
          "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1784961938}},
         "rate_limit_reached_type":"primary"}
        """#
        let status = try XCTUnwrap(CodexUsageFetcher.parse(Data(json.utf8)))
        XCTAssertNotNil(status.reachedType)
        // primary=5시간(18000s=300분), secondary=주간(10080분) — 둘 다 매핑, 늦은 쪽(주간) 리셋.
        XCTAssertEqual(status.shortWindow?.usedPercent, 97)
        XCTAssertEqual(status.weeklyWindow?.usedPercent, 40)
        XCTAssertEqual(status.exhaustionHit()?.resetsAt, Date(timeIntervalSince1970: 1_784_961_938))
    }

    func testRejectsGarbageAndEmpty() {
        XCTAssertNil(CodexUsageFetcher.parse(Data("not json".utf8)))
        XCTAssertNil(CodexUsageFetcher.parse(Data(#"{"unrelated":1}"#.utf8)))
        // rate_limit 있으나 두 창 모두 null → 게이지 실체 없음 → nil
        XCTAssertNil(CodexUsageFetcher.parse(
            Data(#"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#.utf8)))
    }

    // MARK: CodexAuthBlob (조회에 필요한 값 추출)

    func testAuthBlobExtraction() {
        let auth = CodexFixtures.authJSON(accessToken: "at-xyz")
        XCTAssertEqual(CodexAuthBlob.accessToken(fromAuthJSON: auth), "at-xyz")
        XCTAssertEqual(CodexAuthBlob.accountId(fromAuthJSON: auth), "acct-123")
        XCTAssertNil(CodexAuthBlob.accessToken(fromAuthJSON: Data("{}".utf8)))
    }

    func testAccessTokenExpiryFromJWT() {
        func b64url(_ obj: [String: Any]) -> String {
            let d = try! JSONSerialization.data(withJSONObject: obj)
            return d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        // exp(epoch초) 클레임이 있는 access_token JWT → 만료 시각.
        let jwt = "\(b64url(["alg": "RS256"])).\(b64url(["exp": 1_784_961_938])).sig"
        let auth = Data(#"{"tokens":{"access_token":"\#(jwt)","account_id":"a"}}"#.utf8)
        XCTAssertEqual(CodexAuthBlob.accessTokenExpiry(fromAuthJSON: auth),
                       Date(timeIntervalSince1970: 1_784_961_938))
        // 불투명(비 JWT) access_token + exp 없는 id_token → nil (그래도 조회는 허용됨).
        XCTAssertNil(CodexAuthBlob.accessTokenExpiry(fromAuthJSON: CodexFixtures.authJSON()))
    }

    // MARK: CodexUsageProber (게이지 전용 — 마킹 없음)

    func testProberMapsSuccessToUsage() async {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let prober = CodexUsageProber(fetch: { _ in CodexUsageFetcher.parse(Data(self.sample.utf8)) })
        let result = await prober.probe(authJSON: CodexFixtures.authJSON(), now: now)
        guard case .usage(let snap) = result else { return XCTFail("expected .usage, got \(result)") }
        XCTAssertEqual(snap.sevenDayPercent, 12)
        XCTAssertEqual(snap.fetchedAt, now)
    }

    func testProberUnauthorizedIsStaleNotReauth() async {
        let prober = CodexUsageProber(fetch: { _ in throw CodexUsageFetcherError.unauthorized })
        let result = await prober.probe(authJSON: CodexFixtures.authJSON())
        XCTAssertEqual(result, .stale)   // 401 → stale (계정을 죽었다고 마킹하지 않는다)
    }

    func testProberSkipsNetworkForExpiredToken() async {
        // exp가 과거인 토큰이면 네트워크 호출 없이(fetch 호출 시 실패로 표식) stale 반환.
        func b64url(_ obj: [String: Any]) -> String {
            let d = try! JSONSerialization.data(withJSONObject: obj)
            return d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let expiredJWT = "\(b64url(["alg": "RS256"])).\(b64url(["exp": 1_000_000_000])).sig"
        let auth = Data(#"{"tokens":{"access_token":"\#(expiredJWT)","account_id":"a"}}"#.utf8)
        var fetched = false
        let prober = CodexUsageProber(fetch: { _ in fetched = true; return nil })
        let result = await prober.probe(authJSON: auth, now: Date(timeIntervalSince1970: 1_784_000_000))
        XCTAssertEqual(result, .stale)
        XCTAssertFalse(fetched, "만료 토큰은 네트워크를 건너뛰어야 한다")
    }
}
