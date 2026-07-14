import Foundation

/// 세션 로그 루트의 *.jsonl 을 주기 스캔해 "새로 추가된" 이벤트만 파싱해 돌려준다.
/// 네트워크 요청 없음. 앱/CLI 어느 쪽에서든 타이머로 scan()을 호출한다.
/// 첫 스캔에서는 기존 내용을 파싱하지 않고 오프셋만 기록한다 (과거 이벤트로 오탐 방지).
/// 프로바이더별로 (루트, 파서, 정책)을 주입해 인스턴스를 만든다 — Claude는
/// ~/.claude/projects + RateLimitParser, Codex는 ~/.codex/sessions + CodexRateLimitParser.
public final class SessionLogWatcher<Event: Sendable>: @unchecked Sendable {

    /// 추적하지 않던 파일을 만났을 때의 정책.
    public enum UnseenFilePolicy: Sendable {
        /// 프라이밍 후 새로 나타난 파일은 전체를 새 내용으로 파싱 (Claude:
        /// 새 세션 파일은 곧 생긴 파일뿐이고, 세션 초반의 한도 이벤트를 놓치면 안 된다).
        case parseFromStart
        /// 파일을 처음 본 시점의 끝(마지막 개행)까지는 건너뛰고 이후 append만 파싱.
        /// 오래된 미추적 파일은 통째로 무시한다 (Codex: 세션 로그가 수만 개이고 resume가
        /// 며칠 지난 파일에 이어 쓴다 — 히스토리 재생을 막는다). 한 번 추적한 파일의
        /// 오프셋은 유지한다 — append는 mtime을 갱신해 다음 스캔(15초)에 잡히므로,
        /// 오프셋을 버리면 "긴 유휴 후 첫 턴의 소진 이벤트"가 재프라이밍에 삼켜진다.
        case tailOnly
    }

    /// 한 파일에서 이번 스캔에 새로 파싱된 이벤트 묶음.
    /// 호출측이 파일 단위로 귀속(예: Codex 전환 전 파일 격리)할 수 있도록 경로를 붙인다.
    public struct Batch: Sendable {
        public let file: String
        public let events: [Event]
    }

    let root: URL
    let policy: UnseenFilePolicy
    let parse: @Sendable (_ line: String, _ now: Date) -> Event?
    private var offsets: [String: UInt64] = [:]   // 파일 경로 → 읽은 위치
    private var primed = false                    // 첫 스캔 여부 (parseFromStart에서만 의미)
    private let lock = NSLock()
    /// 이 시간 안에 수정된 파일만 본다
    public var recentWindow: TimeInterval = 600

    public init(root: URL, policy: UnseenFilePolicy = .parseFromStart,
                parse: @escaping @Sendable (_ line: String, _ now: Date) -> Event?) {
        self.root = root
        self.policy = policy
        self.parse = parse
    }

    public func scan(now: Date = Date()) -> [Event] {
        scanBatches(now: now).flatMap(\.events)
    }

    /// scan과 동일하되 파일 단위 묶음으로 돌려준다. 이벤트가 없는 파일은 포함하지 않는다.
    public func scanBatches(now: Date = Date()) -> [Batch] {
        lock.lock(); defer { lock.unlock() }
        var batches: [Batch] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let recent = mtime > now.addingTimeInterval(-recentWindow)
            let tracked = offsets[url.path] != nil
            switch policy {
            case .parseFromStart:
                // 최근 수정됐거나 아직 못 본 파일만 연다
                guard recent || !tracked else { continue }
            case .tailOnly:
                // 오래된 파일은 열지 않는다 (append가 생기면 mtime이 갱신돼 다시 잡힌다).
                // 오프셋은 유지 — 유휴 후 첫 append가 재프라이밍에 삼켜지지 않도록.
                guard recent else { continue }
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            // parseFromStart: 첫 스캔 이후 새로 나타난 파일은 전체가 "새 내용" (start=0)
            let start = offsets[url.path] ?? 0
            if start > end { // 파일이 잘렸으면(로테이션) 기준점만 리셋
                offsets[url.path] = end
                continue
            }
            guard start < end else { continue } // 새 내용 없음

            let mustPrime: Bool
            switch policy {
            case .parseFromStart: mustPrime = !primed
            case .tailOnly: mustPrime = !tracked
            }
            if mustPrime {
                // 프라이밍: 파싱 없이 오프셋만 기록하되, 마지막 개행까지만 전진 —
                // 쓰기 도중인 부분 라인은 남겨두어 완성되면 다음 스캔에서 온전히 파싱된다
                offsets[url.path] = offsetAfterLastNewline(in: handle, start: start, end: end) ?? start
                continue
            }

            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(end - start)) else { continue }
            // 마지막 개행(0x0A)까지만 완성 라인으로 취급. 개행이 없으면 오프셋 유지(부분 라인 대기).
            guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let completeLen = data.distance(from: data.startIndex, to: lastNewline) + 1
            offsets[url.path] = start + UInt64(completeLen)
            guard let text = String(data: data.prefix(completeLen), encoding: .utf8) else { continue }
            var events: [Event] = []
            for line in text.split(separator: "\n") {
                if let hit = parse(String(line), now) {
                    events.append(hit)
                }
            }
            if !events.isEmpty {
                batches.append(Batch(file: url.path, events: events))
            }
        }
        primed = true
        return batches
    }

    /// 현재 오프셋을 추적 중인 파일 경로들 — 호출측의 파일 귀속(격리) 판단용 스냅샷.
    public var trackedFiles: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(offsets.keys)
    }

    /// [start, end) 구간에서 마지막 개행(0x0A)의 다음 오프셋을 찾는다.
    /// 큰 파일 전체를 읽지 않도록 뒤에서부터 청크 단위로 역방향 스캔. 개행이 없으면 nil.
    private func offsetAfterLastNewline(in handle: FileHandle,
                                        start: UInt64, end: UInt64) -> UInt64? {
        let chunkSize: UInt64 = 64 * 1024
        var high = end
        while high > start {
            let low = high > start + chunkSize ? high - chunkSize : start
            guard (try? handle.seek(toOffset: low)) != nil,
                  let chunk = try? handle.read(upToCount: Int(high - low)) else { return nil }
            if let idx = chunk.lastIndex(of: 0x0A) {
                return low + UInt64(chunk.distance(from: chunk.startIndex, to: idx)) + 1
            }
            high = low
        }
        return nil
    }
}

extension SessionLogWatcher where Event == RateLimitHit {
    /// Claude 세션 로그 감시 (~/.claude/projects + RateLimitParser)
    public convenience init(env: MobiusEnvironment) {
        self.init(root: env.projectsDir) { RateLimitParser.parse(line: $0, now: $1) }
    }
}

extension SessionLogWatcher where Event == CodexRateLimitStatus {
    /// Codex 세션 로그 감시 (~/.codex/sessions + CodexRateLimitParser).
    /// tailOnly — 세션 로그가 수만 개이고 resume가 옛 파일에 이어 쓰므로(실측)
    /// 히스토리 재생 없이 새 append만 본다.
    public static func codex(env: MobiusEnvironment) -> SessionLogWatcher<CodexRateLimitStatus> {
        SessionLogWatcher(root: env.codexSessionsDir, policy: .tailOnly) { line, _ in
            CodexRateLimitParser.parse(line: line)
        }
    }
}
