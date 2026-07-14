import XCTest
@testable import MobiusCore

/// CodexStatusRouter의 격리 정책: 활성 계정이 바뀌면 그때까지 관찰된 파일의 상태는
/// 무시한다 — 구 세션(이전 계정 토큰)의 매턴 100% 상태가 새 계정을 소진으로 오염시켜
/// 연쇄 전환되는 것을 막는다.
final class CodexStatusRouterTests: XCTestCase {
    typealias Batch = SessionLogWatcher<CodexRateLimitStatus>.Batch

    let accountA = UUID()
    let accountB = UUID()

    func status(pct: Double, at t: TimeInterval) -> CodexRateLimitStatus {
        CodexRateLimitStatus(
            primary: .init(usedPercent: pct, windowMinutes: 300,
                           resetsAt: Date(timeIntervalSince1970: t + 3600)),
            secondary: nil, reachedType: nil,
            timestamp: Date(timeIntervalSince1970: t))
    }

    func testRoutesUsageAndHitsForCurrentActive() {
        let router = CodexStatusRouter()
        let routed = router.route(
            batches: [Batch(file: "/s/a.jsonl", events: [status(pct: 42, at: 100)])],
            trackedFiles: ["/s/a.jsonl"], activeID: accountA)
        XCTAssertEqual(routed.latestUsage?.primary?.usedPercent, 42)
        XCTAssertTrue(routed.exhaustionHits.isEmpty)

        let exhausted = router.route(
            batches: [Batch(file: "/s/a.jsonl", events: [status(pct: 100, at: 200)])],
            trackedFiles: ["/s/a.jsonl"], activeID: accountA)
        XCTAssertEqual(exhausted.exhaustionHits.count, 1)
    }

    func testSwitchQuarantinesPreviouslySeenFiles() {
        let router = CodexStatusRouter()
        // A 활성 시절 관찰된 파일 (소진 → 전환 유발 상황)
        _ = router.route(
            batches: [Batch(file: "/s/old.jsonl", events: [status(pct: 100, at: 100)])],
            trackedFiles: ["/s/old.jsonl"], activeID: accountA)

        // B로 전환된 뒤에도 구 세션(A의 토큰)이 계속 100%를 찍는다 — 무시돼야 한다
        let routed = router.route(
            batches: [Batch(file: "/s/old.jsonl", events: [status(pct: 100, at: 300)])],
            trackedFiles: ["/s/old.jsonl"], activeID: accountB)
        XCTAssertNil(routed.latestUsage)             // 게이지 오염 없음
        XCTAssertTrue(routed.exhaustionHits.isEmpty) // 연쇄 전환 없음

        // 전환 후 새로 생긴 세션 파일은 B에 귀속된다
        let fresh = router.route(
            batches: [Batch(file: "/s/new.jsonl", events: [status(pct: 7, at: 400)])],
            trackedFiles: ["/s/old.jsonl", "/s/new.jsonl"], activeID: accountB)
        XCTAssertEqual(fresh.latestUsage?.primary?.usedPercent, 7)
    }

    func testSwitchQuarantinesTrackedButQuietFiles() {
        let router = CodexStatusRouter()
        // 이벤트를 안 냈지만 추적 중이던(전환 시점에 유휴) 세션도 격리 대상
        _ = router.route(batches: [], trackedFiles: ["/s/idle.jsonl"], activeID: accountA)
        let routed = router.route(
            batches: [Batch(file: "/s/idle.jsonl", events: [status(pct: 100, at: 500)])],
            trackedFiles: ["/s/idle.jsonl"], activeID: accountB)
        XCTAssertTrue(routed.exhaustionHits.isEmpty)
        XCTAssertNil(routed.latestUsage)
    }

    func testLaunchBaselineDoesNotQuarantine() {
        let router = CodexStatusRouter()
        // 앱 시작 첫 라우팅(lastActive nil → A)은 격리하지 않는다 — 기존 세션은 현 활성 소유로 본다
        let routed = router.route(
            batches: [Batch(file: "/s/a.jsonl", events: [status(pct: 90, at: 100)])],
            trackedFiles: ["/s/a.jsonl"], activeID: accountA)
        XCTAssertEqual(routed.latestUsage?.primary?.usedPercent, 90)
    }

    func testLatestUsageWinsByTimestampAcrossFiles() {
        let router = CodexStatusRouter()
        let routed = router.route(
            batches: [
                Batch(file: "/s/a.jsonl", events: [status(pct: 30, at: 100)]),
                Batch(file: "/s/b.jsonl", events: [status(pct: 80, at: 200)]),
            ],
            trackedFiles: [], activeID: accountA)
        XCTAssertEqual(routed.latestUsage?.primary?.usedPercent, 80)
    }

    func testNoActiveAccountRoutesNothing() {
        let router = CodexStatusRouter()
        let routed = router.route(
            batches: [Batch(file: "/s/a.jsonl", events: [status(pct: 100, at: 100)])],
            trackedFiles: [], activeID: nil)
        XCTAssertNil(routed.latestUsage)
        XCTAssertTrue(routed.exhaustionHits.isEmpty)
    }
}
