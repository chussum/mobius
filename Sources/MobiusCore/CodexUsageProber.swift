import Foundation

/// 비활성 codex 게이지 프로브의 결과. **재인증(needsReauth) 케이스가 없다** — 게이지 전용이라
/// 어떤 실패도 계정을 죽었다고 마킹하지 않는다.
public enum CodexProbeResult: Equatable, Sendable {
    case usage(UsageSnapshot)   // 200 — 게이지 갱신
    case stale                  // 401/403 또는 만료 토큰 — 게이지를 마지막 값에 둔다(무해)
    case transient              // 네트워크/일시 오류 — 다음 기회에 재시도
}

/// 비활성 codex 계정의 게이지 프로브 — 저장된 auth.json 스냅샷 바이트로 usage를 GET 조회해
/// UsageSnapshot으로 투영한다.
///
/// ★ **게이지 전용 안전 계약**(CLAUDE.md: Codex 재인증 자동 감지는 의도적으로 미구현):
/// - usage 캐시만 채운다. setNeedsReauth·AutoSwitchEngine·rateLimit 기록을 절대 호출하지 않는다
///   (시끄러운 401이 자동 전환 폴백 후보를 죽이면 안 된다).
/// - 자격증명 **읽기 전용**: auth.json을 쓰지 않고, 토큰을 refresh/회전하지 않으며, codex
///   프로세스를 띄우지 않는다.
/// - 활성 codex 계정은 세션 로그 in-band 경로가 담당하므로 이 프로브의 대상이 아니다.
public struct CodexUsageProber: Sendable {
    let fetch: @Sendable (Data) async throws -> CodexRateLimitStatus?

    /// - Parameter fetch: HTTP 조회(주입식) — 테스트는 캐닝된 상태를 넣는다.
    public init(fetch: @escaping @Sendable (Data) async throws -> CodexRateLimitStatus?
                = { try await CodexUsageFetcher.fetch(authJSON: $0) }) {
        self.fetch = fetch
    }

    /// - Parameters:
    ///   - authJSON: 저장된 codex auth.json 스냅샷 바이트 (읽기 전용 — 절대 쓰지 않는다).
    ///   - now: 게이지 fetchedAt / 만료 판정 기준.
    public func probe(authJSON: Data, now: Date = Date()) async -> CodexProbeResult {
        // 신선도 최적화: 저장 토큰이 **명백히 만료**됐으면 네트워크를 아끼고 stale로 둔다
        // (만료를 못 읽으면 그냥 시도한다 — 401은 무해).
        if let exp = CodexAuthBlob.accessTokenExpiry(fromAuthJSON: authJSON), exp <= now {
            return .stale
        }
        do {
            guard let status = try await fetch(authJSON) else { return .transient }
            return .usage(status.usageSnapshot(fetchedAt: now))
        } catch is CodexUsageFetcherError {
            return .stale       // 401/403 — 만료된 비활성 토큰. 무해, 마킹 없음.
        } catch {
            return .transient   // 네트워크/일시 오류 — 다음 기회에.
        }
    }
}
