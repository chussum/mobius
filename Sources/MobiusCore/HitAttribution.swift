import Foundation

/// 세션 로그 rate-limit hit의 **계정 귀속** 정책 (이슈 #19, 제보 @Phantomn).
///
/// 문제: Claude 세션 로그의 한도 에러 라인에는 **어느 계정 것인지가 적혀 있지 않다.** 그래서
/// "스캔 시점의 활성 계정"에 귀속했는데, 그 hit의 진짜 주인은 **요청을 보낼 때 활성이던
/// 계정**이다. 소진 직후엔 전환이 일어나고, 전환 시점에 이미 진행 중이던 턴은 옛 계정의
/// 에러를 **전환 뒤에** 로그에 남긴다(실측: 같은 에러가 2분 반에 걸쳐 흩어짐). 그 결과
/// 멀쩡한 폴백에 소진이 기록되고 → `isLimited`가 그 계정을 후보에서 빼고 → `.allExhausted`
/// ("모든 계정 한도 소진")가 반복되며 **자동 전환이 통째로 죽는다.** 잘못 박힌 리셋 시각이
/// 만료될 때까지 몇 시간 지속된다.
///
/// ★ **hit 자신의 타임스탬프로는 못 거른다** — 전환보다 나중이기 때문이다. 지연의 상한은
/// "진행 중이던 한 턴 + 429 재시도"라 수 분에 이른다(실행 중 claude 세션은 턴마다
/// 자격증명을 다시 읽으므로 세션 재시작까지 갈 일은 없다 — README 정정 참조).
///
/// 정책: **로그 hit을 증거가 아니라 트리거로 강등**한다. 판정은 usage API가 한다 —
/// 계정별 토큰으로 조회하므로 오귀인이 **구조적으로 불가능**하다. 이미 `needsReauth`에
/// 같은 논리를 쓰고 있다(로그의 authentication_failed는 무시하고 usage 401만 신뢰).
///
/// 비용: 평시 네트워크는 그대로 **0**이다. hit이 있을 때만 최대 1회 조회하고, 같은 소진의
/// 후속 hit은 `skipAlreadyRecorded`/신선한 캐시에서 걸린다. (실측 참고: 개발 Mac의 세션
/// 로그 한 달치에 창 소진 이벤트가 0건 = 이 경로의 호출도 0건이었다.)
public enum HitAttribution {

    /// hit 하나를 이번에 어떻게 처리할지.
    public enum Action: Equatable, Sendable {
        /// 이 계정에 이미 소진 기록이 있다 → 아무것도 하지 않는다.
        /// 소진 상태에서는 매 요청이 같은 에러를 남기므로, 이 가드가 없으면 hit마다
        /// 알림·엔진 호출이 반복된다(Codex 경로에는 원래 있던 가드 — 알림 폭풍 방지).
        /// 놓친 전환은 `AutoSwitchEngine.onTick`의 자가복구가 다음 틱에 처리한다.
        case skipAlreadyRecorded
        /// 직전 네트워크 검증이 실패했고 아직 쿨다운 중 → 이번 hit은 판정하지 않는다.
        /// (귀속을 날조하지 않는다. 소진 중이면 에러가 계속 오므로 다음 hit에서 다시 잡힌다.)
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

    /// 네트워크 검증 실패 후 같은 계정을 다시 조회하기까지의 최소 간격.
    public static let cooldown: TimeInterval = 60

    /// 검증에 쓸 수 있는 캐시의 최대 나이.
    ///
    /// ★ 게이지 표시용 캐시 수명(`AppState.usageStaleness`, 4분)보다 **일부러 짧다.**
    /// 4분 전 스냅샷이 95%였는데 지금 100%라면 진짜 소진을 "여유"로 오판해 **전환이 그만큼
    /// 늦어진다** — 사용자는 그 시간 동안 막힌 채로 있다. hit은 드물게 발생하므로 여기서
    /// 조회 한 번을 더 하는 편이 훨씬 싸다. (표시용 캐시는 그대로 4분을 쓴다.)
    public static let verifyCacheStaleness: TimeInterval = 60

    /// 이번 hit을 어떻게 처리할지 정한다. 순수 함수 — 부작용 없음.
    ///
    /// 값싼 조건부터 본다(실패 기록 3b: 비싼 부작용은 뒤로).
    /// - Parameters:
    ///   - activeIsLimited: 귀속 후보(활성) 계정에 이미 유효한 소진 기록이 있는가
    ///   - cachedUsageAt: 그 계정의 사용량 캐시 시각 (없으면 nil)
    ///   - lastFetchAttemptAt: 그 계정에 대해 마지막으로 **네트워크 조회를 시도**한 시각
    ///   - now: 현재 시각
    public static func plan(activeIsLimited: Bool,
                            cachedUsageAt: Date?,
                            lastFetchAttemptAt: Date?,
                            now: Date) -> Action {
        if activeIsLimited { return .skipAlreadyRecorded }
        if let cachedUsageAt, now.timeIntervalSince(cachedUsageAt) < verifyCacheStaleness {
            return .verifyWithCache
        }
        if let lastFetchAttemptAt, now.timeIntervalSince(lastFetchAttemptAt) < cooldown {
            return .skipCooldown
        }
        return .fetchUsage
    }

    /// 사용량 스냅샷으로 이 hit이 **이 계정의 것**인지 판정한다.
    ///
    /// 계정 창(5시간/주간)이 소진이면 그대로 기록한다. 계정 창은 여유인데 **모델 전용
    /// 한도**(`limits[].weekly_scoped`, 예: Fable)가 차 있으면 그것도 진짜 소진이므로
    /// `modelScoped: true`로 기록한다 — 이 갈래가 없으면 모델 한도로 막힌 사용자가
    /// "창 여유"로 판정돼 **영영 전환되지 않는다**(고치려는 증상과 방향만 반대인 같은 버그).
    /// `modelScoped`는 엔진이 "사용자가 이 계정을 직접 골랐으면 머문다"를 판단하는 데 쓴다.
    ///
    /// ★ 한계(의도한 보수 선택): 100%인데 **리셋 시각이 없거나 이미 지난** 창은 소진으로
    /// 치지 않는다(기존 `exhaustionHit`과 같은 규칙). 잘못된 24시간 폴백을 박아 멀쩡한
    /// 계정을 하루 막는 것보다, 판정을 미루고 다음 hit에서 다시 보는 쪽이 안전하다.
    public static func verdict(usage: UsageSnapshot, now: Date) -> Verdict {
        if let hit = usage.exhaustionHit(now: now) { return .record(hit) }
        if let scoped = usage.scopedExhaustionHit(now: now) { return .record(scoped) }
        return .discard
    }
}
