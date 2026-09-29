import Foundation

/// 판정이 안 끝난 창 소진 트리거 하나(`AppState.verifyAndRecordWindowHit`, 이슈 #19).
///
/// 두 시각을 **따로** 들고 있다: 언제까지 재시도할지(TTL)와, 어떤 스냅샷을 믿을지(신선도).
/// 하나로 합치면 둘 중 하나가 반드시 틀린다 — 신선도 기준을 갱신하면 TTL이 영영 안 오고,
/// TTL 기준을 그대로 쓰면 이미 "모르겠다"고 판정한 스냅샷으로 계속 같은 답을 낸다.
///
/// 새 hit이 올 때와 백오프가 풀릴 때 트리거를 어떻게 바꾸는지는 이 타입이 정한다. AppState에는
/// 테스트 타깃이 없어서, 이 규칙이 거기 있으면 값 하나를 잘못 넘겨도 테스트가 잡지 못한다(리뷰 지적).
public struct PendingHitTrigger: Equatable, Sendable {
    /// TTL 기준 — 이 트리거를 처음 본 시각. 백오프가 풀릴 때만 다시 건다(`restartingLifetime`).
    public private(set) var firstSeenAt: Date
    /// 이 시각 **이후에 뜬** 스냅샷만 판정에 쓴다.
    public var needsFresherThan: Date
    /// 이 트리거를 만든 로그 hit(창 소진일 때만). 검증이 **끝내 불가능**할 때의
    /// 최후 폴백에 쓴다 — `AppState.giveUpVerification` 참조. P3처럼 창 신호가 아닌 경우 nil.
    public private(set) var logHit: RateLimitHit?
    /// 이 트리거의 hit이 **도착한 순간에** 마지막 활성 계정 변경보다 `modelScopeTrustWindow` 넘게
    /// 뒤였는가(`HitAttribution.logFallbackAllowed`). 최후 폴백, 429 중 앞당김, 모델 전용 한도를 귀속
    /// 증거로 믿을지가 모두 이 값을 쓴다. `logHit`이 nil이면 트리거를 만든 신호(P3)가 도착한 순간의 판정이다.
    ///
    /// ★ 포기하거나 검증하는 시각(now)으로 재지 않는다(리뷰 지적). 트리거는 수명(20분)이나 429 대기
    ///   동안 붙들려 있으므로, 그 시각으로 재면 전환 17초 뒤에 도착한 오귀인 hit도 5분 뒤에는 믿게 된다.
    /// ★ 도착 시각을 들고 있다가 그때그때의 마지막 전환과 비교하지도 않는다. 그러면 hit이 도착한
    ///   **뒤에** 사용자가 전환했을 때 차이가 음수가 되어, 전환 전에 도착한 진짜 소진을 끝내 믿지
    ///   못한다(리뷰 지적). 도착하는 순간의 마지막 전환이 그 hit에 관한 유일한 기준이다.
    public private(set) var hitTrusted: Bool
    /// 마지막 판정이 **모델 전용 한도** 때문에 보류됐는가(계정 창은 여유였다).
    ///
    /// ★ 로그 라인에는 **모델 이름이 없어서** `logHit.modelScoped`는 항상 false다
    ///   (`RateLimitParser`가 true를 세우는 곳은 P3 경로뿐이고 그건 여기 안 온다).
    ///   그래서 이 값 없이 최후 폴백을 쓰면 "그 모델만 막힘"이어야 할 상황이
    ///   **계정 전체 소진**으로 기록된다 — 메뉴바가 빨개지고, CLI 라벨이 틀리고,
    ///   무엇보다 `autoSwitchMayLeave`가 `isLimited`에서 **핀을 보기 전에 단락**해
    ///   사용자가 고정해 둔 계정에서 15분 뒤 강제로 밀려난다(셀프리뷰 H1).
    /// ★ 새 hit이나 백오프 해제로 트리거가 바뀌어도 **물려받는다**(리뷰 지적). 예전에는 트리거를 다시
    ///   만들 때마다 false로 돌아가, 모델 한도만 걸린 계정에 hit이 한 번 더 오면 이 보호가 사라졌다.
    public var lastInconclusiveWasModelScoped = false

    /// 보류 중인 트리거가 없을 때 새 신호로 트리거를 만든다.
    /// - Parameters:
    ///   - now: 신호가 도착한 시각(틱의 스캔 시각).
    ///   - lastActiveChangeAt: 도착하는 순간의 마지막 Claude 활성 계정 변경 시각.
    public init(logHit: RateLimitHit?, arrivedAt now: Date, lastActiveChangeAt: Date) {
        self.firstSeenAt = now
        self.needsFresherThan = now
        self.logHit = logHit
        self.hitTrusted = HitAttribution.logFallbackAllowed(hitArrivedAt: now,
                                                            lastActiveChangeAt: lastActiveChangeAt)
    }

    /// 보류 중인 트리거에 새 신호가 왔다.
    ///
    /// 새 신호는 **새 데이터를 요구**한다(`needsFresherThan = now`) — 그 사이 팝오버가 떠 놓은 *소진
    /// 이전* 스냅샷이 "트리거보다 나중"으로 통과해 진짜 소진을 "여유"로 판정하는 걸 막는다.
    /// ★ 단 **TTL 기준(firstSeenAt)은 물려받는다**: 새 hit마다 수명을 리셋하면, 판정이 계속
    ///   "모르겠다"로 끝나는 상황(리셋 시각을 안 주는 창)에서 사용자가 작업을 이어가는 한 hit이 계속
    ///   와 **수명이 영영 안 차고 60초마다 조회가 무한 반복**된다(셀프리뷰 지적).
    ///
    /// 새 창 hit은 트리거의 hit과 신뢰 판정을 바꾼다 — 전환 직후 도착해 믿지 못하던 트리거에 전환과
    /// 무관한 hit이 오면 그 hit으로 기록할 수 있게 된다. 단 **이미 믿을 만한 hit을 믿지 못할 hit으로
    /// 덮어쓰지는 않는다**(리뷰 지적): 전환이 오간 직후 다른 계정의 늦은 에러가 도착해도, 앞서 이
    /// 계정이 활성이던 때 도착한 hit의 귀속은 그대로 옳다. P3 신호(`hit == nil`)는 창 hit이 아니므로
    /// 트리거의 hit과 판정을 그대로 둔다.
    public func receiving(_ hit: RateLimitHit?, at now: Date, lastActiveChangeAt: Date) -> Self {
        var next = self
        next.needsFresherThan = now
        guard let hit else { return next }
        let trusted = HitAttribution.logFallbackAllowed(hitArrivedAt: now,
                                                        lastActiveChangeAt: lastActiveChangeAt)
        if logHit != nil, hitTrusted, !trusted { return next }
        next.logHit = hit
        next.hitTrusted = trusted
        return next
    }

    /// 백오프 동안은 시도조차 안 했으므로 수명 시계만 다시 건다 — 안 그러면 쉬는 사이에 수명이
    /// 차서, 재개하자마자 곧바로 다시 포기하게 된다. hit과 그 신뢰 판정, 모델 한도 표시는 그대로다.
    public func restartingLifetime(at now: Date) -> Self {
        var next = self
        next.firstSeenAt = now
        return next
    }
}
