import Foundation

/// usage 조회가 **401/403으로만** 연속 실패한 기록. 계정별로 누적한다.
///
/// ★ 왜 필요한가 (실측 2026-07-20): 활성 계정의 진짜 폐기는
/// `UsageFetcher.shouldMarkReauthAfterAuthError`로 잡히지 않는다 — claude가 refresh에
/// 실패하면 라이브 access 토큰이 만료된 채 남고, 라이브 blob에는 `refreshTokenExpiresAt`가
/// 없어 두 조건 모두 false가 되기 때문이다(이슈 #4에서 오탐을 없앤 대가). 그 결과 앱은
/// 401을 조용히 버리고, 게이지는 마지막 성공 스냅샷에 얼어붙어 정상처럼 보였다
/// (flosdor: 08:54 스냅샷이 22:52까지 14시간 표시됨).
///
/// ★ 이 신호를 `needsReauth`로 승격하지 말 것 — `AutoSwitchEngine`이 needsReauth를 폴백
/// 후보 제외(`:39`)와 주계정 강등(`:93`)에 쓰므로, 추측성 신호를 넣으면 멀쩡한 주계정을
/// 밀어내는 이슈 #4가 그대로 재발한다. 이건 **표시 전용**이다.
public struct AuthFailureRecord: Codable, Equatable {
    /// 연속 401/403 횟수. 조회 200 성공 시 기록 자체가 삭제된다.
    public var count: Int
    /// 이번 연속 실패의 첫 발생 시각 — 경과 시간 조건의 기준.
    public var firstFailedAt: Date
    /// 알림을 이미 보냈는지 — 팝오버를 열 때마다 반복 알림이 가지 않게 한다.
    public var notified: Bool

    public init(count: Int, firstFailedAt: Date, notified: Bool = false) {
        self.count = count
        self.firstFailedAt = firstFailedAt
        self.notified = notified
    }
}

public enum AuthSuspicion {
    /// 연속 401/403 횟수 임계값.
    public static let threshold = 3
    /// 첫 실패로부터 최소 경과 시간. 횟수만 쓰면 팝오버를 연달아 여는 것만으로 임계값을
    /// 넘길 수 있고, 시간만 쓰면 단발성 실패가 방치된다 — 둘 다 만족해야 한다.
    public static let minElapsed: TimeInterval = 30 * 60

    /// 401/403 1회 기록. 기존 기록이 있으면 횟수만 올리고 첫 실패 시각은 보존한다.
    public static func recordFailure(_ existing: AuthFailureRecord?, now: Date) -> AuthFailureRecord {
        guard var r = existing else {
            return AuthFailureRecord(count: 1, firstFailedAt: now)
        }
        r.count += 1
        return r
    }

    /// 표시 임계값 도달 여부 — 횟수 **그리고** 경과 시간을 모두 만족할 때만 true.
    public static func isSuspect(_ record: AuthFailureRecord?, now: Date) -> Bool {
        guard let record else { return false }
        return record.count >= threshold
            && now.timeIntervalSince(record.firstFailedAt) >= minElapsed
    }
}
