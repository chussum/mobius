import Foundation

/// Codex rate_limits 상태의 계정 귀속 정책.
///
/// 문제: rollout 로그에는 계정 식별자가 없고(실측 — session_meta에도 없음), 실행 중인
/// codex 프로세스는 시작 시점에 로드한 토큰을 계속 쓴다. 전환 후에도 구 세션은 이전
/// 계정의 사용량(소진 포함)을 매 턴 로그에 남기므로, "스캔 시점의 활성 계정"에 단순
/// 귀속하면 새 계정이 구 계정의 100%로 오염돼 연쇄 전환이 난다.
///
/// 정책(보수적): 활성 codex 계정이 바뀌는 순간까지 관찰된(이벤트를 냈거나 추적 중인)
/// 파일은 격리한다 — 그 파일의 이후 상태는 게이지·소진 판정에 쓰지 않는다. 전환 뒤
/// 새로 나타난 파일만 현재 활성 계정에 귀속한다. 격리는 다음 활성 변경 때 갱신된다.
///
/// 한계(의도된 트레이드오프): 전환 전부터 있던 세션을 resume해 새 계정으로 쓰는 경우
/// 그 파일의 신호는 계속 무시된다(새 프로세스 감지 신호가 로그에 없음 — session_meta는
/// 생성 시 1회뿐, 실측). 오귀속-오전환(위험)보다 신호 누락(보수)을 택했다 —
/// 새 세션이 시작되면 신호는 자연 복구된다. 앱 재시작 시 격리 상태는 초기화된다.
public final class CodexStatusRouter: @unchecked Sendable {
    private var seenFiles: Set<String> = []
    private var quarantined: Set<String> = []
    private var lastActiveID: UUID?
    private let lock = NSLock()

    public init() {}

    public struct Routed: Equatable, Sendable {
        /// 현재 활성 계정에 귀속되는 가장 최신 사용량 (격리 파일 제외)
        public var latestUsage: CodexRateLimitStatus?
        /// 현재 활성 계정에 귀속되는 소진 hit들 (격리 파일 제외)
        public var exhaustionHits: [RateLimitHit]
    }

    /// - Parameters:
    ///   - batches: 이번 스캔의 파일별 상태 묶음
    ///   - trackedFiles: 워처가 추적 중인 전체 파일 (이벤트를 안 낸 유휴 세션도 격리 대상에 넣기 위함)
    ///   - activeID: 현재 활성 codex 계정 (전환 감지의 기준 — 앱/CLI/외부 로그인 어느 경로로
    ///     바뀌었든 여기서 일괄 감지된다)
    public func route(batches: [SessionLogWatcher<CodexRateLimitStatus>.Batch],
                      trackedFiles: Set<String>,
                      activeID: UUID?) -> Routed {
        lock.lock(); defer { lock.unlock() }

        if activeID != lastActiveID {
            // 활성 계정 변경 — 지금까지 관찰된 모든 파일은 이전 계정의 세션일 수 있다
            if lastActiveID != nil {
                quarantined = seenFiles.union(trackedFiles)
            }
            lastActiveID = activeID
        }
        seenFiles.formUnion(trackedFiles)
        for batch in batches { seenFiles.insert(batch.file) }

        var routed = Routed(latestUsage: nil, exhaustionHits: [])
        guard activeID != nil else { return routed }
        for batch in batches where !quarantined.contains(batch.file) {
            for status in batch.events {
                if let hit = status.exhaustionHit() {
                    routed.exhaustionHits.append(hit)
                }
                let current = routed.latestUsage?.timestamp ?? .distantPast
                if (status.timestamp ?? .distantPast) >= current {
                    routed.latestUsage = status
                }
            }
        }
        return routed
    }
}
