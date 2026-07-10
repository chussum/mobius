import XCTest
@testable import MobiusCore

final class AutoSwitchEngineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var primary: AccountProfile!; var fb1: AccountProfile!; var fb2: AccountProfile!
    var file: AccountsFile!

    override func setUp() {
        primary = AccountProfile(id: UUID(), nickname: "primary", emailAddress: "a@x",
                                 organizationName: "", tierDescription: "")
        fb1 = AccountProfile(id: UUID(), nickname: "fb1", emailAddress: "b@x",
                             organizationName: "", tierDescription: "")
        fb2 = AccountProfile(id: UUID(), nickname: "fb2", emailAddress: "c@x",
                             organizationName: "", tierDescription: "")
        file = AccountsFile(accounts: [primary, fb1, fb2], activeAccountID: primary.id)
    }

    func testHitOnActiveSwitchesToFirstAvailableFallback() {
        let engine = AutoSwitchEngine()
        let d = engine.onRateLimitHit(file: file,
                                      hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)),
                                      now: t0)
        XCTAssertEqual(d, .switchTo(fb1.id, reason: .activeExhausted))
    }

    func testSkipsLimitedAndReauthFallbacks() {
        file.accounts[1].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(999), recordedAt: t0)
        var d = AutoSwitchEngine().onRateLimitHit(
            file: file, hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)), now: t0)
        XCTAssertEqual(d, .switchTo(fb2.id, reason: .activeExhausted))

        file.accounts[2].needsReauth = true
        d = AutoSwitchEngine().onRateLimitHit(
            file: file, hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)), now: t0)
        XCTAssertEqual(d, .allExhausted) // 갈 곳 없음
    }

    func testAutoSwitchDisabledDoesNothing() {
        file.autoSwitchEnabled = false
        let d = AutoSwitchEngine().onRateLimitHit(
            file: file, hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)), now: t0)
        XCTAssertEqual(d, .none)
    }

    func testTickReturnsToPrimaryAfterResetPlusMargin() {
        // fb1 활성, primary는 t0+100에 리셋
        file.activeAccountID = fb1.id
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(100), recordedAt: t0)
        let engine = AutoSwitchEngine()
        // 리셋 전: 복귀 안 함
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(50)), .none)
        // 리셋 직후(margin 60초 전): 아직
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(110)), .none)
        // 리셋 + margin 후: 복귀
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(161)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }

    func testCooldownPreventsFlapping() {
        let engine = AutoSwitchEngine()
        _ = engine.onRateLimitHit(file: file,
                                  hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)), now: t0)
        engine.noteSwitched(now: t0) // 호출자가 실제 전환 후 알려줌
        // 쿨다운(120초) 내 primary 회복 틱 → 억제
        file.activeAccountID = fb1.id
        file.accounts[0].rateLimit = nil
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(60)), .none)
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(121)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }

    func testNilResetsAtUses24HourFallback() {
        // 월간 지출 한도 등 리셋 시각 없는 이벤트 → 보수적 24시간 폴백
        let hit = RateLimitHit(resetsAt: nil)
        XCTAssertEqual(hit.effectiveResetsAt(now: t0), t0.addingTimeInterval(24 * 3600))
        // 시각형 이벤트는 자기 시각 그대로
        XCTAssertEqual(RateLimitHit(resetsAt: t0.addingTimeInterval(3600)).effectiveResetsAt(now: t0),
                       t0.addingTimeInterval(3600))

        let engine = AutoSwitchEngine()
        // nil resetsAt도 fallback 전환은 그대로 일어난다
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: t0),
                       .switchTo(fb1.id, reason: .activeExhausted))
        engine.noteSwitched(now: t0)

        // 호출자의 실제 반영을 시뮬레이션: primary에 24h 폴백 기록, fb1 활성
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: hit.effectiveResetsAt(now: t0),
                                                   recordedAt: t0)
        file.activeAccountID = fb1.id
        // 24h + margin 전: 복귀 안 함
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(24 * 3600 + 30)), .none)
        // 24h + margin 후: 복귀 후보
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(24 * 3600 + 61)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }
}
