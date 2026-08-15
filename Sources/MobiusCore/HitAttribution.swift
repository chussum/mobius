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
        /// 모델 전용 한도 소진이 보이지만 **믿을 수 없다**(최근 전환 직후 = 오귀인 위험 구간).
        /// 호출측은 이 트리거를 **버리되 `.discard`와 달리 백오프 카운터에는 넣지 않는다**
        /// (우리가 스스로 만든 판정 불가라 "이 계정과 무관한 hit"의 증거가 아니다).
        /// 진짜 모델 한도라면 창이 지난 뒤 **새 hit**이 와서 그때 기록된다.
        case notYetTrusted
        /// 소진은 맞는데 **쓸 수 있는 리셋 시각이 없다**(누락/파싱 실패/이미 지남).
        /// "여유"와 섞으면 안 된다 — 트리거를 보류해 다음 기회에 다시 본다(셀프리뷰 지적).
        case inconclusive
    }

    /// 조회 실패 후 같은 계정을 다시 조회하기까지의 최소 간격.
    /// 보류된 트리거의 재시도 주기이기도 하다(3초 틱마다 두드리지 않게).
    public static let cooldown: TimeInterval = 60

    /// **모델 전용 한도 기록이 이미 있는** 계정의 재확인 간격.
    /// 그 계정은 계속 쓸 수 있으므로(그 모델만 막힘) 사용자가 작업을 이어가고, 그러면 한도
    /// 에러 hit이 **끊임없이** 온다. 매번 60초마다 조회하면 사실상 배경 폴링이 된다.
    /// 그렇다고 완전히 스킵할 수도 없다 — 그 사이 **계정 창 자체가** 소진될 수 있고, 그건
    /// 반드시 잡아야 하는 신호다. 그래서 "끄지 않고 늦춘다".
    ///
    /// ★ 이 값은 **두 나쁜 결과 사이의 저울**이다: 길수록 조회는 줄지만, 모델 한도가 걸린
    ///   계정의 **5시간 창이 새로 소진됐을 때** 그만큼 오래 기록이 안 되고 — 기록이 없으면
    ///   `onTick`의 자가복구도 못 도므로 — 사용자는 자동 전환 없이 막혀 있게 된다.
    ///   그래서 **한 값으로 두 요구를 맞추지 않고 2단으로 나눈다**: 첫 재확인은 빠르게(아래),
    ///   같은 결과가 반복되면 느리게(`modelLimitedSteadyRecheck`). 모델 한도는 며칠 가는
    ///   상태라, 그 상태에서 계속 3분마다 두드리면 하루 수백 번이 되어 "게이지 끄면 폴링 0"
    ///   계약이 무너진다(셀프리뷰 지적).
    public static let modelLimitedRecheck: TimeInterval = 180

    /// 모델 한도를 **같은 값으로 다시 확인한 뒤**의 재확인 간격(정상 상태 감시).
    public static let modelLimitedSteadyRecheck: TimeInterval = 15 * 60

    /// 이번 트리거를 어떻게 처리할지 정한다. 순수 함수 — 부작용 없음.
    /// 값싼 조건부터 본다(실패 기록 3b: 비싼 부작용은 뒤로).
    ///
    /// - Parameters:
    ///   - accountIsLimited: 계정 자체(5시간/주간) 소진 기록이 이미 있는가 → 완전 스킵
    ///   - hasModelLimitRecord: 모델 전용 한도 기록이 이미 있는가 → 재확인하되 저빈도로
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
    /// - Parameter modelLimitReconfirmed: 그 모델 한도를 이미 **같은 값으로 다시 확인**했는가
    ///   (= 더 알아낼 게 "계정 창이 새로 소진됐는지"뿐인 정상 상태) → 재확인을 더 늦춘다.
    public static func plan(accountIsLimited: Bool,
                            hasModelLimitRecord: Bool = false,
                            modelLimitReconfirmed: Bool = false,
                            cachedUsageAt: Date?,
                            hitObservedAt: Date,
                            lastFetchAttemptAt: Date?,
                            now: Date) -> Action {
        if accountIsLimited { return .skipAlreadyRecorded }
        if let cachedUsageAt, cachedUsageAt >= hitObservedAt { return .verifyWithCache }
        let backoff: TimeInterval
        if hasModelLimitRecord {
            backoff = modelLimitReconfirmed ? modelLimitedSteadyRecheck : modelLimitedRecheck
        } else {
            backoff = cooldown
        }
        if let lastFetchAttemptAt, now.timeIntervalSince(lastFetchAttemptAt) < backoff {
            return .skipCooldown
        }
        return .fetchUsage
    }

    /// 사용량 스냅샷으로 이 hit이 **이 계정의 것**인지 판정한다.
    ///
    /// 모델 전용 한도를 귀속 증거로 **믿을 수 있는 최소 시간** — 마지막 활성 계정 변경 이후.
    ///
    /// ★ 두 신호의 성격이 다르다: 계정 창 100%는 "이 계정이 **지금** 막혀 있다"라서 방금 그
    ///   에러를 낸 주체라는 증거가 되지만, 모델 전용 한도 100%는 **며칠 가는 상태**라 누가
    ///   이 에러를 냈는지에 대해 아무 말도 하지 않는다. 오귀인은 **전환 직후**에만 생기므로
    ///   (전환 전에 시작된 턴이 뒤늦게 에러를 남긴다), 최근에 전환이 있었다면 모델 한도
    ///   증거는 쓰지 않는다. 진짜로 모델 한도에 걸린 사용자는 계속 그 에러를 만나므로
    ///   이 창이 지난 뒤의 hit에서 정상적으로 기록된다(최대 이만큼 늦어질 뿐).
    public static let modelScopeTrustWindow: TimeInterval = 300

    /// **계정 창(5시간/주간)을 먼저 본다.** 계정 자체가 소진이면 그걸로 기록한다.
    ///
    /// 계정 창은 여유인데 **모델 전용 한도**(`weekly_scoped`, 예: Fable)가 100%면 그것도
    /// 진짜 소진이므로 `modelScoped: true`로 기록한다 — 이 갈래가 없으면 모델 한도로 막힌
    /// 사용자는 hit이 매번 버려져 **자동 전환을 아예 못 받는다.**
    ///
    /// ★ 이 갈래는 `AccountProfile.isLimited`가 modelScoped를 **제외**하게 된 뒤에야 안전하다
    ///   (같은 PR의 앞선 커밋). 모델 한도 100%는 며칠 유지되는 **상태**라, 그 상태를 근거로
    ///   "계정 사용 불가"를 며칠 박으면 멀쩡한 폴백이 후보에서 사라져 이 이슈가 시간만 늘어난
    ///   채 재현된다. 지금은 그 기록이 "그 모델만 불가"를 뜻하므로 폴백 자격을 잃지 않는다.
    ///
    /// ★ 100%인데 **리셋 시각이 없거나 이미 지난** 창은 `.inconclusive`다 — `.discard`가
    /// **아니다.** 잘못된 24시간 폴백을 박아 멀쩡한 계정을 하루 막지도 않고, "여유"로
    /// 오해해 트리거를 태워 없애지도 않는다(둘을 같은 값으로 돌려주면 호출측이 트리거를
    /// 소비해 버려 그 소진은 영영 기록되지 않는다 — 셀프리뷰 지적).
    /// - Parameter trustModelScope: 모델 전용 한도를 귀속 증거로 써도 되는가
    ///   (= 마지막 활성 계정 변경으로부터 `modelScopeTrustWindow`가 지났는가).
    /// API가 아직 100%를 안 보여줘도 "곧 그렇게 될" 수준이면 판정을 미루는 경계.
    ///
    /// ★ 로그 hit은 **CLI가 실제로 막혔다는 사실**이고, `utilization`은 다른 서비스의
    ///   근사값이다. 소진 순간 API가 99%로 보이면 `.discard`가 되는데, 그러면 트리거가
    ///   타 없어지고 — 막힌 사용자는 (당연히) 타이핑을 멈추므로 새 hit도 안 와서 — 그
    ///   소진은 영영 기록되지 않는다(셀프리뷰 지적). 그래서 **한도에 바짝 붙어 있으면**
    ///   버리지 않고 보류해 다음 조회에서 다시 본다. 오귀인 쪽(폴백 7일 16%)은 이 선에
    ///   한참 못 미쳐 즉시 버려지므로 비용이 늘지 않는다.
    public static let nearLimitPercent: Double = 95

    public static func verdict(usage: UsageSnapshot, now: Date,
                               trustModelScope: Bool = true) -> Verdict {
        if let hit = usage.exhaustionHit(now: now) { return .record(hit) }
        // ★ **계정 창이 100%면 모델 한도보다 먼저 결론 낸다** — 리셋 시각을 못 얻어
        //   `exhaustionHit`이 nil이었을 뿐, 계정은 실제로 막혀 있다. 여기서 모델 갈래로
        //   내려가면 "그 모델만 막힘"으로 기록돼 **완전히 소진된 계정이 폴백 후보로 남고**
        //   메뉴바도 빨강이 안 되며 핀이 걸려 있으면 자동 전환도 멈춘다(셀프리뷰 지적).
        if usage.hasExhaustedAccountWindow() { return .inconclusive }
        if let scoped = usage.scopedExhaustionHit(now: now) {
            // 전환 직후엔 이 증거를 안 믿는다 — 그리고 **기다린다고 믿을 수 있게 되지도
            // 않는다**(그 100%는 며칠 그대로다). 그러니 이 트리거는 버린다. 진짜 모델 한도
            // 사용자는 계속 그 에러를 만나므로, 창이 지난 뒤 **새로 도착한 hit**이 기록한다
            // — 그게 "전환과 무관한 신호"라는 증거다. 같은 스냅샷을 나중에 다시 판정하면
            // 신뢰 창은 오귀인을 5분 미루기만 할 뿐 막지 못한다(셀프리뷰 지적).
            return trustModelScope ? .record(scoped) : .notYetTrusted
        }
        // ★ 한도에 바짝 붙은 경우의 보류는 **5시간 창에만** 적용한다. 주간 사용률은 주말
        //   즈음이면 정상적으로 95%를 넘는데, 거기에 이 규칙을 걸면 **남의 hit이 영영
        //   `.discard`에 도달하지 못해** 15분 내내 60초마다 조회하는 상태로 굳는다
        //   (discard 카운터도 안 올라 백오프가 안 걸린다 — 셀프리뷰 지적).
        //   5시간 창은 갑자기 차오르는 쪽이라 API 지연이 실제로 문제되는 창이기도 하다.
        if (usage.fiveHourPercent ?? 0) >= nearLimitPercent { return .inconclusive }
        return .discard
    }
}
