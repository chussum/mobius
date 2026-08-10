import XCTest
@testable import MobiusCore

final class UsageFetcherTests: XCTestCase {
    // 실측 응답(2026-07-11) 축약본
    let sample = #"""
    {
     "five_hour": {"utilization": 42.0, "resets_at": "2026-07-10T19:09:59.895133+00:00"},
     "seven_day": {"utilization": 33.0, "resets_at": "2026-07-12T22:59:59.895158+00:00"},
     "extra_usage": {"is_enabled": true}
    }
    """#

    func testParseRealSchema() throws {
        let snap = try XCTUnwrap(UsageFetcher.parse(Data(sample.utf8)))
        XCTAssertEqual(snap.fiveHourPercent, 42.0)
        XCTAssertEqual(snap.sevenDayPercent, 33.0)
        // 마이크로초 fractional seconds 파싱 확인
        let expected = ISO8601DateFormatter()
        XCTAssertEqual(Int(snap.fiveHourResetsAt!.timeIntervalSince1970),
                       Int(expected.date(from: "2026-07-10T19:09:59+00:00")!.timeIntervalSince1970))
        XCTAssertNotNil(snap.sevenDayResetsAt)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(UsageFetcher.parse(Data("not json".utf8)))
        XCTAssertNil(UsageFetcher.parse(Data(#"{"unrelated": 1}"#.utf8)))
    }

    func testAccessTokenExtraction() {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r"}}"#.utf8)
        XCTAssertEqual(UsageFetcher.accessToken(from: blob), "tok-123")
        XCTAssertNil(UsageFetcher.accessToken(from: Data("{}".utf8)))
    }

    func testParsesScopedModelLimit() {
        let json = Data(#"""
        {"five_hour":{"utilization":47},"seven_day":{"utilization":72,"resets_at":"2026-07-12T23:00:00.000+00:00"},
         "limits":[
           {"kind":"session","group":"session","percent":47},
           {"kind":"weekly_all","group":"weekly","percent":72},
           {"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical",
            "resets_at":"2026-07-12T23:00:00.000+00:00","scope":{"model":{"display_name":"Fable"}}}
         ]}
        """#.utf8)
        let snap = UsageFetcher.parse(json)
        XCTAssertEqual(snap?.scopedLimits?.count, 1)
        XCTAssertEqual(snap?.scopedLimits?.first?.label, "Fable")
        XCTAssertEqual(snap?.scopedLimits?.first?.percent, 100)
        XCTAssertNotNil(snap?.scopedLimits?.first?.resetsAt)
    }

    func testOldCacheWithoutScopedDecodes() throws {
        // 구버전 캐시(scopedLimits 키 없음)도 디코드되어야 한다
        let old = Data(#"{"fiveHourPercent":10,"sevenDayPercent":20,"fetchedAt":0}"#.utf8)
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: old)
        XCTAssertEqual(snap.fiveHourPercent, 10)
        XCTAssertNil(snap.scopedLimits)
    }

    // 이슈 #4: 잠자기 뒤 첫 팝오버의 401 — 활성 계정도 자연 만료면 오탐이라 마킹하면 안 된다
    // (오마킹 → 엔진이 멀쩡한 주계정을 밀어내 폴백 전환 + 재로그인 뱃지 연쇄).
    func testAuthErrorMarkingPolicy() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = 1_500_000_000_000, future = 1_900_000_000_000   // epoch ms
        func blob(access: Int, rte: Int? = nil) -> Data {
            let rtePart = rte.map { #","refreshTokenExpiresAt":\#($0)"# } ?? ""
            return Data(#"{"claudeAiOauth":{"accessToken":"A","expiresAt":\#(access)\#(rtePart)}}"#.utf8)
        }
        // (a) access 유효한데 401 = 폐기 → 활성/비활성 모두 마킹
        XCTAssertTrue(UsageFetcher.shouldMarkReauthAfterAuthError(
            blob: blob(access: future, rte: future), isActive: true, now: now))
        XCTAssertTrue(UsageFetcher.shouldMarkReauthAfterAuthError(
            blob: blob(access: future, rte: future), isActive: false, now: now))
        // (b) ★ 활성 + access 만료 + refresh 토큰 생존 → claude가 다음 세션에서 갱신 = 마킹 금지
        XCTAssertFalse(UsageFetcher.shouldMarkReauthAfterAuthError(
            blob: blob(access: past, rte: future), isActive: true, now: now))
        // (c) 활성 + refresh 토큰까지 시간 만료 → 진짜 죽음 = 마킹
        XCTAssertTrue(UsageFetcher.shouldMarkReauthAfterAuthError(
            blob: blob(access: past, rte: past), isActive: true, now: now))
        // (d) 비활성 + access 만료 → 정상 휴면 = 마킹 금지 (refresh 만료는 validateFallbacksLocally 전담)
        XCTAssertFalse(UsageFetcher.shouldMarkReauthAfterAuthError(
            blob: blob(access: past, rte: past), isActive: false, now: now))
        // (e) refresh 만료 정보가 없으면 죽었다고 단정하지 않는다 (오탐 방지)
        XCTAssertFalse(UsageFetcher.shouldMarkReauthAfterAuthError(
            blob: blob(access: past), isActive: true, now: now))
    }

    func testExhaustionHitMirrorsCodexSemantics() {
        let now = Date(timeIntervalSince1970: 1_784_300_000)
        let fiveReset = now.addingTimeInterval(3600)
        let weekReset = now.addingTimeInterval(86_400)
        func snap(_ five: Double?, _ week: Double?) -> UsageSnapshot {
            UsageSnapshot(fiveHourPercent: five, fiveHourResetsAt: five != nil ? fiveReset : nil,
                          sevenDayPercent: week, sevenDayResetsAt: week != nil ? weekReset : nil,
                          fetchedAt: now)
        }
        // 창 여유 → 소진 아님 (monthly spend만 도달한 상황)
        XCTAssertNil(snap(40, 39).exhaustionHit(now: now))
        // 5시간 창 소진 → 그 창의 리셋 시각
        XCTAssertEqual(snap(100, 39).exhaustionHit(now: now), RateLimitHit(resetsAt: fiveReset))
        // 둘 다 소진 → 더 늦은 주간 리셋 시각
        XCTAssertEqual(snap(100, 100).exhaustionHit(now: now), RateLimitHit(resetsAt: weekReset))
        // 100%지만 리셋 시각이 이미 지남 → 소진 아님 (낡은 스냅샷 방어)
        let stale = UsageSnapshot(fiveHourPercent: 100,
                                  fiveHourResetsAt: now.addingTimeInterval(-60),
                                  sevenDayPercent: 10, sevenDayResetsAt: weekReset, fetchedAt: now)
        XCTAssertNil(stale.exhaustionHit(now: now))
    }

    func testExpiresAtParsing() {
        // 실측: claudeAiOauth.expiresAt는 13자리 epoch 밀리초 (2026-07-11 확인)
        let ms = Data(#"{"claudeAiOauth":{"expiresAt":1783785648000}}"#.utf8)
        XCTAssertEqual(UsageFetcher.expiresAt(from: ms),
                       Date(timeIntervalSince1970: 1_783_785_648))
        let secs = Data(#"{"expiresAt":1783785648}"#.utf8) // 방어: 초 단위도 허용
        XCTAssertEqual(UsageFetcher.expiresAt(from: secs),
                       Date(timeIntervalSince1970: 1_783_785_648))
        XCTAssertNil(UsageFetcher.expiresAt(from: Data("{}".utf8)))
    }

    /// usage 요청에는 `Authorization: Bearer <액세스 토큰>` 헤더가 실린다. 세션에 디스크
    /// URLCache가 붙어 있으면 그 요청이 직렬화되어 `~/Library/Caches/<번들ID>/Cache.db`에
    /// 저장되고 토큰이 평문으로 남는다(실측 2026-08-10: 액세스 토큰 13개, 파일 0644).
    /// 여기서는 **기본 전송 경로가 물고 있는 세션**의 설정만 본다 — 이 검사만으로는
    /// 회귀를 못 잡는다(호출부가 URLSession.shared로 돌아가도 이 속성은 그대로다).
    /// 실제 방어는 아래 testFetchGoesThroughInjectedTransport.
    func testSessionKeepsNothingOnDisk() {
        let cfg = UsageFetcher.session.configuration
        XCTAssertNil(cfg.urlCache,
                     "URLCache가 붙으면 Authorization 헤더가 디스크 Cache.db에 평문으로 남는다")
        // ephemeral 세션의 쿠키 저장소는 nil이 아니라 **메모리 전용 인스턴스**다.
        // 따라서 nil 여부가 아니라 공유 저장소와 다른지로 확인해야 한다.
        XCTAssertFalse(cfg.httpCookieStorage === HTTPCookieStorage.shared,
                       "공유 쿠키 저장소를 쓰면 디스크에 남는다")
    }

    /// ★ 유출 회귀를 실제로 막는 테스트 — fetch가 **주입된 전송 경로로만** 나가는지 본다.
    /// 누군가 호출부를 `URLSession.shared.data(for: req)`로 되돌리면(= 디스크 캐시에 토큰이
    /// 다시 평문으로 남으면) 주입한 spy가 호출되지 않아 이 테스트가 빨간불이 된다.
    /// 세션 속성만 보는 검사로는 잡히지 않던 구멍이다.
    func testFetchGoesThroughInjectedTransport() async throws {
        let calls = Spy()
        let body = Data(#"{"five_hour":{"utilization":42}}"#.utf8)
        let snap = try await UsageFetcher.fetch(
            keychainBlob: Data(#"{"claudeAiOauth":{"accessToken":"tok-abc"}}"#.utf8),
            transport: { req in
                await calls.record(req)
                let resp = HTTPURLResponse(url: UsageFetcher.endpoint, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
                return (body, resp)
            })

        let seen = await calls.requests
        XCTAssertEqual(seen.count, 1,
                       "fetch가 주입 전송 경로를 안 탔다 — 호출부가 다른 세션을 직접 쓰고 있다")
        // 이 요청이 캐시에 남으면 안 되는 이유 자체를 고정해 둔다.
        XCTAssertEqual(seen.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-abc")
        XCTAssertEqual(seen.first?.url, UsageFetcher.endpoint)
        XCTAssertEqual(snap?.fiveHourPercent, 42)
    }

    /// 주입 전송 경로가 받은 요청을 모으는 액터(동시성 안전).
    private actor Spy {
        var requests: [URLRequest] = []
        func record(_ req: URLRequest) { requests.append(req) }
    }
}
