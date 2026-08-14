import Foundation

/// "재로그인 필요"(`needsReauth`) 딱지를 **언제 내려도 되는가**를 판정하는 순수 규칙.
///
/// 딱지의 의미는 정확히 하나다 — **저장된 *그* refresh 토큰이 폐기됐다**(invalid_grant,
/// 시간 만료, 빈 토큰, 회전본 저장 실패). 그러므로 그 토큰이 **다른 값으로 교체**되면
/// 판정의 전제 자체가 사라진다. 교체가 일어나는 경로는 둘뿐이고 둘 다 살아있다는 증거다:
///   - 성공한 refresh(회전) — 서버가 old 토큰을 소비하고 새 토큰을 내줬다
///   - 새 로그인 — 사용자가 실제로 다시 인증했다
///
/// ★ **"저장 바이트가 바뀌면 해제"로 넓히지 말 것** — `Switcher.refreshActiveSnapshotIfStable`이
///   활성 Claude 계정의 라이브 스냅샷을 **5분마다 무조건 되저장**한다. 계정이 진짜로 죽어도
///   같은 죽은 바이트가 계속 저장되므로, 쓰기 자체를 해제 신호로 삼으면 needsReauth가 활성
///   계정에서 5분 이상 버티지 못하고 엔진(AutoSwitchEngine)이 죽은 계정을 정상 후보로 취급한다.
///   판정 대상은 **refresh 토큰 값**이어야 한다.
///
/// ★ 이 규칙은 딱지를 **내리기만** 한다. 켜는 것은 여전히 refresh 결과(FallbackAuthChecker)와
///   usage 401(UsageFetcher.shouldMarkReauthAfterAuthError)뿐이다 — 추측성 신호를
///   needsReauth로 승격하지 말라는 `AuthSuspicion`의 경고(이슈 #4)와 방향이 반대라 무관하다.
public enum ReauthClearance {
    /// 저장 스냅샷을 `previous` → `next`로 교체하는 것이 딱지를 내릴 근거가 되는가.
    ///
    /// 파싱 불가/토큰 없음(빈 문자열 포함 — `CredentialBlob.refreshToken`이 nil로 준다)이면
    /// **false**로 보수적으로 물러난다: 모르면 딱지를 유지한다(살아있다고 단정하지 않는다).
    /// Claude 자격증명 형식 전용이라, Codex처럼 형식이 다른 secret은 자연히 false가 된다.
    public static func refreshTokenRotated(previous: Data?, next: Data) -> Bool {
        guard let previous,
              let old = refreshToken(fromSecret: previous),
              let new = refreshToken(fromSecret: next)
        else { return false }
        return old != new
    }

    /// 저장 secret 바이트에서 refresh 토큰을 꺼낸다.
    /// Claude의 secret은 **`CredentialsSnapshot` JSON**이고 토큰은 그 안의 `keychainBlob`에
    /// 들어 있다(`ClaudeConfigIO.readLiveSecretData`). 한 겹 벗기지 않고 바깥 JSON을 그대로
    /// 파싱하면 `refreshToken` 키가 없어 항상 nil이 되고, 그러면 이 규칙 전체가 조용히
    /// 무력해진다 — 그래서 스냅샷 디코드를 먼저 시도한다. 디코드가 안 되면 blob을 직접
    /// 준 경우로 보고 그대로 읽는다(테스트·향후 호출부 관용성).
    private static func refreshToken(fromSecret data: Data) -> String? {
        if let snap = try? JSONDecoder().decode(CredentialsSnapshot.self, from: data) {
            return CredentialBlob.refreshToken(from: snap.keychainBlob)
        }
        return CredentialBlob.refreshToken(from: data)
    }
}
