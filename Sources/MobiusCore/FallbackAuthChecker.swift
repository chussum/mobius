import Foundation

/// 폴백(비활성) 계정의 **로그인 생사를 미리 판정**한다 — 자동 fallback이 실제로 넘어가기 전에
/// 그 계정이 쓸 수 있는지 알기 위함. 판정 신호는 **refresh 결과**다(모호한 usage 401 아님):
///   - 로컬 선검사(네트워크 0): `refreshTokenExpiresAt`가 지났으면 죽음 확정
///   - refresh 성공 → 살아있음(+새 토큰 원자 저장 → usage도 살아남)
///   - invalid_grant → 죽음 확정 → 재로그인 필요
///   - 네트워크/5xx → 일시적(죽음으로 단정 안 함)
///
/// ★ 활성(라이브) 계정은 **절대** refresh하지 않는다 — claude가 관리하는 토큰을 로테이션하면
///   실행 중 세션이 깨진다. 첫 guard로 차단한다.
/// ★ 원자성: refresh가 성공하면 old refresh 토큰은 서버에서 이미 소비된다. 새 토큰 저장에
///   실패하면 계정이 벽돌이 되므로, 저장 실패 시 needsReauth로 마킹해 재로그인으로 복구시킨다.

public enum FallbackCheckResult: Equatable, Sendable {
    case notFallback     // 활성 계정 — 건드리지 않음
    case noSecret        // 저장 스냅샷 없음
    case noRefreshToken  // 스냅샷에 refresh 토큰 없음 → 재로그인 필요
    case locallyDead     // refreshTokenExpiresAt 지남(네트워크 0) → 재로그인 필요
    case refreshedAlive  // refresh 성공 + 새 스냅샷 원자 저장
    case dead            // invalid_grant → 재로그인 필요
    case transient       // 네트워크/5xx → 마킹 안 함(재시도)
    case storeFailed     // refresh 성공했으나 저장 실패 → 새 토큰 유실 → 재로그인 필요로 마킹
}

public final class FallbackAuthChecker: @unchecked Sendable {
    let store: AccountStore
    let refresher: TokenRefresher

    public init(store: AccountStore, refresher: TokenRefresher = OAuthTokenRefresher()) {
        self.store = store
        self.refresher = refresher
    }

    /// 폴백 하나를 검증하고 부작용(스냅샷 저장 / needsReauth)을 적용한다.
    /// 값싼 조건(활성 여부 → 스냅샷 → refresh 토큰 → 로컬 만료)을 먼저 통과시키고
    /// **네트워크 refresh는 정말 필요할 때만** 호출한다 (계정 리스크 최소화).
    /// allowNetwork=false면 **네트워크 0 로컬 검사만** 한다(팝오버용) — 빈/만료 refresh 토큰만
    /// 즉시 플래그하고, 실제 refresh가 필요한 경우엔 .transient로 물러난다.
    /// allowNetwork=true면 필요 시 실제 refresh까지 한다(자동 폴백 전환 직전용).
    @discardableResult
    public func check(_ id: UUID, activeAccountID: UUID?, now: Date = Date(),
                      allowNetwork: Bool = true) async -> FallbackCheckResult {
        guard id != activeAccountID else { return .notFallback }           // 활성 절대 제외
        guard let snap = try? store.secret(for: id) else { return .noSecret }
        guard let rt = CredentialBlob.refreshToken(from: snap.keychainBlob) else {
            try? store.setNeedsReauth(id, true); return .noRefreshToken
        }
        // 네트워크 0: refresh 토큰 자체가 시간상 만료 → 죽음 확정
        if CredentialBlob.isRefreshTokenExpired(blob: snap.keychainBlob, now: now) {
            try? store.setNeedsReauth(id, true); return .locallyDead
        }
        guard allowNetwork else { return .transient }   // 로컬 검사 통과 — 네트워크는 생략
        let scopes = CredentialBlob.scopes(from: snap.keychainBlob)
        do {
            let tokens = try await refresher.refresh(refreshToken: rt, scopes: scopes, now: now)
            // 여기 도달 = old refresh 토큰은 서버에서 소비됨. 새 토큰을 반드시 저장해야 한다.
            guard let newSnap = snap.applyingRefreshedTokens(tokens) else {
                try? store.setNeedsReauth(id, true); return .storeFailed
            }
            do {
                try store.setSecret(newSnap, for: id)     // 원자 저장(temp→rename)
                try? store.setNeedsReauth(id, false)      // 살아있음 → 딱지 해제
                return .refreshedAlive
            } catch {
                // 새 토큰 유실 → old RT는 이미 죽음 → 재로그인이 복구 경로
                try? store.setNeedsReauth(id, true); return .storeFailed
            }
        } catch TokenRefresherError.invalidGrant {
            try? store.setNeedsReauth(id, true); return .dead
        } catch {
            return .transient   // 네트워크/5xx — 죽음으로 단정하지 않음
        }
    }
}
