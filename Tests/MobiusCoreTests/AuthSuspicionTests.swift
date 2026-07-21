import XCTest
@testable import MobiusCore

final class AuthSuspicionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

    // 옛 연속-401 누적(AuthFailureRecord/recordFailure/isSuspect/minElapsed) 기반 테스트는
    // 무상태 판정으로 대체돼 그 심볼과 함께 삭제됐다(AppState 통합 goal — 아래가 대체 테스트).

    // MARK: - 무상태 판정 (세션 활동 × 토큰 만료)

    private var window: TimeInterval { AuthSuspicion.activityWindow }

    /// 값싼 1차 조건의 전체 조합 — 최근 활동 × 만료 정도.
    /// 둘 다 만족할 때만 참이어야 한다(어느 하나만이면 각각 흔한 정상 상태다).
    func testCheapConditionsMatrix() {
        // ① 최근 활동 + 충분히 만료 → 유일한 참. claude가 세션을 돌리면서도 토큰을
        //    못 살렸다는 뜻(2026-07-20 flosdor 케이스).
        XCTAssertTrue(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: t0.addingTimeInterval(-60),
            storedExpiresAt: t0.addingTimeInterval(-window - 60),
            now: t0))
        // ② 최근 활동 + 토큰 신선 → 완전 정상.
        XCTAssertFalse(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: t0.addingTimeInterval(-60),
            storedExpiresAt: t0.addingTimeInterval(3600),
            now: t0))
        // ③ 활동 없음(밤새 CLI 미사용) + 만료 → 오탐의 주범. 반드시 거짓.
        XCTAssertFalse(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: t0.addingTimeInterval(-6 * 3600),
            storedExpiresAt: t0.addingTimeInterval(-6 * 3600),
            now: t0))
        // ④ 활동 없음 + 토큰 신선.
        XCTAssertFalse(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: t0.addingTimeInterval(-6 * 3600),
            storedExpiresAt: t0.addingTimeInterval(3600),
            now: t0))
        // ⑤ 최근 활동 + 방금 만료(창 미달) → 아직 판정하지 않는다. claude가 갱신할 시간.
        XCTAssertFalse(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: t0.addingTimeInterval(-60),
            storedExpiresAt: t0.addingTimeInterval(-60),
            now: t0))
    }

    /// 워처가 아직 한 번도 스캔하지 않았거나 스냅샷에 만료 정보가 없으면 판단 근거가 없다 —
    /// "모름"을 "의심"으로 승격하지 않는다.
    func testCheapConditionsNilInputsAreNeverSuspect() {
        XCTAssertFalse(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: nil, storedExpiresAt: t0.addingTimeInterval(-6 * 3600), now: t0))
        XCTAssertFalse(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: t0.addingTimeInterval(-60), storedExpiresAt: nil, now: t0))
        XCTAssertFalse(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: nil, storedExpiresAt: nil, now: t0))
    }

    /// 활동 창 경계 — 정확히 10분 전 활동은 아직 '최근'으로 친다(포함).
    func testCheapConditionsActivityBoundary() {
        let expired = t0.addingTimeInterval(-window - 60)
        XCTAssertTrue(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: t0.addingTimeInterval(-window), storedExpiresAt: expired, now: t0))
        XCTAssertFalse(AuthSuspicion.cheapConditionsHold(
            lastActivityAt: t0.addingTimeInterval(-window - 1), storedExpiresAt: expired, now: t0))
    }

    /// 2차 확인의 경계 — 만료된 지 정확히 10분이면 참, 1초 모자라면 거짓.
    func testConfirmedBoundaryAtTenMinutes() {
        XCTAssertTrue(AuthSuspicion.confirmed(liveExpiresAt: t0.addingTimeInterval(-window), now: t0))
        XCTAssertFalse(AuthSuspicion.confirmed(liveExpiresAt: t0.addingTimeInterval(-window + 1), now: t0))
        XCTAssertTrue(AuthSuspicion.confirmed(liveExpiresAt: t0.addingTimeInterval(-window - 1), now: t0))
    }

    func testConfirmedIsFalseForFreshOrMissingExpiry() {
        XCTAssertFalse(AuthSuspicion.confirmed(liveExpiresAt: t0.addingTimeInterval(3600), now: t0))
        XCTAssertFalse(AuthSuspicion.confirmed(liveExpiresAt: nil, now: t0))
    }

    /// 합성: 값싼 조건은 참인데 방금 동기화된 스냅샷의 만료가 신선하면 전체는 거짓.
    /// (캐시가 낡아 1차가 참이 됐던 경우 — 2차가 신선도 단언 역할을 한다.)
    func testCheapHoldsButLiveDisagreesYieldsFalse() {
        let cheap = AuthSuspicion.cheapConditionsHold(
            lastActivityAt: t0.addingTimeInterval(-60),
            storedExpiresAt: t0.addingTimeInterval(-window - 3600), // 캐시된 옛 만료
            now: t0)
        XCTAssertTrue(cheap)
        // 방금 동기화해 보니 토큰이 갱신돼 있었다 → 의심 아님.
        let live = AuthSuspicion.confirmed(liveExpiresAt: t0.addingTimeInterval(1800), now: t0)
        XCTAssertFalse(live)
        XCTAssertFalse(cheap && live)
    }
}
