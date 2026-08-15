import Foundation

/// 세션 로그 rate-limit hit의 **계정 귀속** 정책 (이슈 #19, 제보 @Phantomn).
///
/// 문제: Claude 세션 로그의 한도 에러 라인에는 **어느 계정 것인지가 적혀 있지 않다.** 그래서
/// "스캔 시점의 활성 계정"에 귀속했는데, 그 hit의 진짜 주인은 **요청을 보낼 때 활성이던
/// 계정**이다. 소진 직후엔 전환이 일어나고, 전환 시점에 이미 진행 중이던 턴은 옛 계정의
/// 에러를 **전환 뒤에** 로그에 남긴다(실측: 같은 에러가 2분 반에 걸쳐 흩어짐). 그 결과
/// 멀쩡한 폴백에 소진이 기록되고 → `isLimited`가 그 계정을 후보에서 빼고 → `.allExhausted`
/// ("모든 계정 한도 소진")가 반복되며 **자동 전환이 통째로 죽는다.**
///
/// ★ **hit 자신의 타임스탬프로는 못 거른다** — 전환보다 나중이기 때문이다.
///
/// 정책: **로그 hit을 증거가 아니라 트리거로 강등**한다. 판정은 usage API가 한다 —
/// 계정별 토큰으로 조회하므로 오귀인이 **구조적으로 불가능**하다. 이미 `needsReauth`에
/// 같은 논리를 쓰고 있다(로그의 authentication_failed는 무시하고 usage 401만 신뢰).
///
/// ★ **트리거는 버리지 않는다** — 판정이 안 서면(조회 실패/쿨다운) 그 트리거를 **보류로
/// 남겨 다음 틱에 다시 판정**한다(`AppState.pendingHitVerify`). 로그 hit은 워처 오프셋이
/// 전진하므로 **한 번만 배달된다.** "다음 hit에서 다시 잡히겠지"에 기대면, 사용자가 한도
/// 에러를 보고 (자연스럽게) 타이핑을 멈춘 순간 새 에러가 안 나와 **진짜 소진이 영영 기록되지
/// 않는다** — 조회가 한 번 실패했다는 이유로 자동 전환이 통째로 사라진다(셀프리뷰 지적).
public enum HitAttribution {

    /// hit 하나를 이번에 어떻게 처리할지.
    public enum Action: Equatable, Sendable {
        /// 이 계정에 이미 소진 기록이 있다 → 아무것도 하지 않는다(트리거도 해소된 것으로 본다).
        /// 소진 상태에서는 매 요청이 같은 에러를 남기므로, 이 가드가 없으면 hit마다
        /// 알림·엔진 호출이 반복된다(Codex 경로에는 원래 있던 가드 — 알림 폭풍 방지).
        /// 놓친 전환은 `AutoSwitchEngine.onTick`의 자가복구가 다음 틱에 처리한다.
        case skipAlreadyRecorded
        /// 아직 판정할 수 없다(직전 조회 실패 후 쿨다운 중) → **트리거는 보류로 유지**하고
        /// 다음 기회에 다시 본다. 귀속을 날조하지 않되, 포기하지도 않는다.
        case skipCooldown
        /// 캐시된 사용량으로 판정 — 네트워크 0.
        case verifyWithCache
        /// 사용량을 새로 조회해 판정.
        case fetchUsage
    }

    /// 검증 결과.
    public enum Verdict: Equatable, Sendable {
        /// 진짜 소진 — **API의 실제 리셋 시각**으로 기록한다(로그 문구 파싱값보다 정확하다:
        /// 실측 "resets 9pm"=21:00 vs API 20:59:59).
        case record(RateLimitHit)
        /// 창에 여유가 있다 = 이 hit은 **다른 계정 것**이었다 → 버린다.
        case discard
    }

    /// 조회 실패 후 같은 계정을 다시 조회하기까지의 최소 간격.
    /// 보류된 트리거의 재시도 주기이기도 하다(3초 틱마다 두드리지 않게).
    public static let cooldown: TimeInterval = 60

    /// 이번 트리거를 어떻게 처리할지 정한다. 순수 함수 — 부작용 없음.
    /// 값싼 조건부터 본다(실패 기록 3b: 비싼 부작용은 뒤로).
    ///
    /// - Parameters:
    ///   - activeIsLimited: 귀속 후보 계정에 이미 유효한 소진 기록이 있는가
    ///   - cachedUsageAt: 그 계정의 사용량 캐시 시각 (없으면 nil)
    ///   - hitObservedAt: 이 트리거(로그 hit)를 **처음 본** 시각
    ///   - lastFetchAttemptAt: 그 계정에 대해 마지막으로 **네트워크 조회를 시도**한 시각
    ///   - now: 현재 시각
    ///
    /// ★ 캐시는 **트리거보다 나중에 뜬 것만** 쓴다(셀프리뷰 지적). "60초 이내면 신선하다"로
    ///   두면, 40초 전 96%였던 스냅샷으로 방금 100%가 된 창을 "여유"로 오판해 **진짜 소진을
    ///   버린다** — 게다가 그 버림은 조회 흔적조차 안 남아 "소진이 아니었다"와 구분되지 않는다.
    ///   이 규칙이면 한 배치 안의 두 번째 hit부터는(첫 hit이 방금 조회했으므로) 그대로 캐시를
    ///   타 네트워크 0을 유지하면서, 오래된 스냅샷으로는 절대 판정하지 않는다.
    public static func plan(activeIsLimited: Bool,
                            cachedUsageAt: Date?,
                            hitObservedAt: Date,
                            lastFetchAttemptAt: Date?,
                            now: Date) -> Action {
        if activeIsLimited { return .skipAlreadyRecorded }
        if let cachedUsageAt, cachedUsageAt >= hitObservedAt { return .verifyWithCache }
        if let lastFetchAttemptAt, now.timeIntervalSince(lastFetchAttemptAt) < cooldown {
            return .skipCooldown
        }
        return .fetchUsage
    }

    /// 사용량 스냅샷으로 이 hit이 **이 계정의 것**인지 판정한다.
    ///
    /// ★ **계정 창(5시간/주간)만 본다 — 모델 전용 한도(`weekly_scoped`, 예: Fable)는 보지
    ///   않는다.** 처음엔 "모델 한도로 막힌 진짜 소진을 놓치지 않으려고" 포함했는데,
    ///   **그게 이 이슈를 더 나쁘게 재현시킨다**(셀프리뷰 지적): 모델 한도 100%는 며칠씩
    ///   유지되는 **상태**이지 "이 익명 로그 라인이 이 계정 것"이라는 증거가 아니다. 게다가
    ///   `AccountProfile.isLimited`는 `modelScoped`를 구분하지 않으므로, 그렇게 기록하면
    ///   멀쩡한 폴백이 **며칠 동안** 후보에서 빠져 `.allExhausted`가 난다 — 고치려던 증상이
    ///   시간만 늘어난 채 그대로다. CLAUDE.md의 기존 방침("모델 전용 한도는 계정 소진에서
    ///   제외")과도 어긋난다.
    ///   → 모델 스코프 소진으로 전환하려면 **먼저 `isLimited`/`firstAvailable`이 modelScoped를
    ///   이해하도록** 고쳐야 한다. 그건 메뉴바·CLI·게이지까지 걸치는 별도 변경이라 후속으로 둔다.
    ///
    /// ★ 한계(의도한 보수 선택): 100%인데 **리셋 시각이 없거나 이미 지난** 창은 소진으로
    /// 치지 않는다. 잘못된 24시간 폴백을 박아 멀쩡한 계정을 하루 막는 것보다, 판정을 미루고
    /// 다음 기회에 다시 보는 쪽이 안전하다.
    public static func verdict(usage: UsageSnapshot, now: Date) -> Verdict {
        guard let hit = usage.exhaustionHit(now: now) else { return .discard }
        return .record(hit)
    }
}
