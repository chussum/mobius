import Foundation

/// 배지(인증 의심) 판정 — **무상태**. 세션 활동 × 토큰 만료 상관으로 "claude가 라이브 토큰
/// 갱신을 시도했으나 실패했다"를 감지한다. 옛 연속-401 누적(AuthFailureRecord)은 (a) 팝오버를
/// 열어야만 신호가 쌓여 감지가 늦고, (b) 폴링이 빨라지면 반대로 오탐하는 양방향 결함이 있어
/// 제거됐다 (AppState 통합 goal에서 마지막 참조까지 삭제 완료).
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
public enum AuthSuspicion {

    // MARK: - 무상태 판정 (세션 활동 × 토큰 만료 상관)

    /// 두 조건이 공유하는 창(10분). "방금 세션이 돌았다"의 방금, 그리고 "토큰이 충분히
    /// 오래 만료돼 있다"의 충분히가 같은 값이다.
    ///
    /// ★ 왜 이 조합인가: claude는 **세션이 돌 때만** 라이브 토큰을 갱신한다. 그러므로
    /// "세션이 최근에 돌았는데도 토큰이 10분 넘게 만료된 채"는 곧 **claude가 갱신을 시도했고
    /// 실패했다**는 뜻이다(2026-07-20 실패: flosdor의 라이브 로그인이 죽었는데 14시간 침묵).
    /// 어느 한쪽만으로는 판정이 안 된다 — 밤새 CLI를 안 쓰면 토큰은 당연히 만료돼 있고(오탐),
    /// 세션이 도는데 토큰이 신선한 건 정상이다.
    ///
    /// ★ 이 신호를 `needsReauth`로 승격하지 말 것 — AutoSwitchEngine이 needsReauth를 폴백
    /// 후보 제외(`:39`)와 주계정 강등(`:93`)에 쓰므로, 추측성 신호를 넣으면 멀쩡한 주계정을
    /// 밀어내는 이슈 #4가 그대로 재발한다. 이건 **표시 전용**이다.
    public static let activityWindow: TimeInterval = 10 * 60

    /// 값싼 1차 조건 — **IO 0**. 세션 워처의 인메모리 최근 활동 시각과 이미 캐시된
    /// 스냅샷 만료 시각만 본다. 매 틱(3초) 돌아도 공짜여야 하므로 여기서 Keychain·네트워크를
    /// 건드리면 안 된다 (실패 기록 3/3b: 매 틱 Keychain 접근 = 승인창 폭탄).
    ///
    /// - Parameters:
    ///   - lastActivityAt: Claude 세션 워처의 `lastActivity` (nil = 아직 아무것도 못 봄 → false).
    ///   - storedExpiresAt: 저장 스냅샷에서 뽑은 access 토큰 만료 시각 (nil = 판단 근거 없음 → false).
    /// - Returns: 최근 활동 **그리고** 충분히 만료됨을 모두 만족할 때만 true.
    public static func cheapConditionsHold(lastActivityAt: Date?,
                                           storedExpiresAt: Date?,
                                           now: Date) -> Bool {
        guard let lastActivityAt, let storedExpiresAt else { return false }
        let recentlyActive = now.timeIntervalSince(lastActivityAt) <= activityWindow
        return recentlyActive && isSufficientlyExpired(storedExpiresAt, now: now)
    }

    /// 2차 확인 — 1차(`cheapConditionsHold`)가 이미 참일 때만 호출한다. 같은 10분 만료
    /// 조건을 **라이브 기준으로 얻은** 만료 시각에 다시 적용한다.
    ///
    /// ★ 이것은 **독립적인 두 번째 읽기가 아니라 신선도 단언**이다 — 호출측은 이번 사이클에
    /// 방금 동기화된(refreshActiveSnapshotIfStable이 true를 돌려준) 그 스토어 스냅샷을 그대로
    /// 넘긴다. 1차가 캐시로 읽은 값과 출처가 같고, 다만 "이 값이 이번 5분 블록에 갱신된
    /// 것임"이 보장된 상태다.
    ///
    /// ★ "더 독립적으로 만들자"며 여기에 라이브 Keychain 읽기를 넣지 말 것 — 5분 창당
    /// 라이브 자격증명 subprocess 1회로 묶은 통합(배지·임계값 폴링·스냅샷 동기화가 한 번을
    /// 나눠 쓴다)이 통째로 깨지고, 실패 기록 3/3b의 승인창 폭탄으로 되돌아간다.
    ///
    /// - Parameter liveExpiresAt: 방금 동기화된 스냅샷에서 뽑은 만료 시각 (nil이면 false).
    public static func confirmed(liveExpiresAt: Date?, now: Date) -> Bool {
        guard let liveExpiresAt else { return false }
        return isSufficientlyExpired(liveExpiresAt, now: now)
    }

    /// 만료된 지 `activityWindow` **이상** 지났는가. 경계(정확히 10분)는 참 —
    /// 두 함수가 같은 판정을 쓰도록 한 곳에 둔다.
    private static func isSufficientlyExpired(_ expiresAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(expiresAt) >= activityWindow
    }
}
