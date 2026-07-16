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
    /// 이번 스캔에서 열거할 하위 디렉토리를 좁히는 선택자(주입). nil이면 root 전체를 재귀 열거.
    /// 날짜 파티션 루트(Codex: YYYY/MM/DD, 실측 5만 파일/19GB)에서 최근 창의 폴더만 열거해
    /// 매 틱 전수 walk(getattrlistbulk)로 CPU를 태우는 것을 막는다. 좁힌 열거는 "새 파일 발견"
    /// 용도이고, 이미 추적 중인 파일은 폴더 나이와 무관하게 직접 확인하므로(아래 scanBatches)
    /// 며칠 지난 옛 폴더의 resume append도 놓치지 않는다.
    let recentDirs: (@Sendable (_ now: Date) -> [URL]?)?
    private var offsets: [String: UInt64] = [:]   // 파일 경로 → 읽은 위치
    private var primed = false                    // 첫 스캔 여부 — parseFromStart의 프라이밍 판정
                                                  // + recentDirs 프루닝 게이트(첫 스캔은 전수 시딩)
    private let lock = NSLock()
    /// 이 시간 안에 수정된 파일만 본다
    public var recentWindow: TimeInterval = 600

    public init(root: URL, policy: UnseenFilePolicy = .parseFromStart,
                recentDirs: (@Sendable (_ now: Date) -> [URL]?)? = nil,
                parse: @escaping @Sendable (_ line: String, _ now: Date) -> Event?) {
        self.root = root
        self.policy = policy
        self.recentDirs = recentDirs
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

        // 후보 파일 수집.
        // recentDirs 주입 시(Codex, 날짜 파티션): 최근 창의 폴더만 열거해 수만 파일 전수 walk를
        //   피하고, 추적 중인 파일은 폴더 나이와 무관하게 직접 포함한다(옛 폴더 resume의 append를
        //   놓치지 않도록). 사라진 파일의 오프셋은 함께 정리해 추적 집합이 무한정 커지지 않게 한다.
        // ★ 단 첫 스캔(프라이밍)은 프루닝하지 않고 root 전체를 열거한다 — offsets가 메모리
        //   전용이라 앱 재시작(또는 Mobius가 꺼진 채 codex 사용) 후엔 추적이 리셋되는데, 그때
        //   창 밖 옛 폴더에서 이미 최근 수정된 세션(resume 중)을 시딩해 둬야 이후 direct-stat이
        //   그 append를 이어 잡는다. 프라이밍은 파싱 없이 오프셋만 기록하므로 부작용 없이 1회
        //   비용(전수 열거)뿐이고, 스캔은 유틸리티 태스크라 UI를 막지 않는다.
        // 미주입 시(Claude, 프로젝트별 구조): 기존대로 root 전체를 재귀 열거.
        let candidates: [URL]
        if let recentDirs, primed, let dirs = recentDirs(now) {
            var seen = Set<String>()
            var urls: [URL] = []
            for dir in dirs {
                guard let en = fm.enumerator(at: dir,
                                             includingPropertiesForKeys: [.contentModificationDateKey])
                else { continue }
                for case let url as URL in en where url.pathExtension == "jsonl" {
                    if seen.insert(url.path).inserted { urls.append(url) }
                }
            }
            // 추적 중이지만 최근 폴더 밖에 있는 파일(며칠 전 세션 resume)도 직접 확인 대상에 넣는다.
            for path in offsets.keys where seen.insert(path).inserted {
                if fm.fileExists(atPath: path) {
                    urls.append(URL(fileURLWithPath: path))
                } else {
                    offsets[path] = nil // 삭제된 파일 — 추적 해제
                }
            }
            candidates = urls
        } else {
            guard let en = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.contentModificationDateKey])
            else { return [] }
            candidates = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        }

        for url in candidates {
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
    /// 최근 `days`일(당일 포함)의 날짜 파티션 폴더 경로 목록 — 옛 세션 resume 지평까지 커버.
    /// 실측: resume는 며칠 지난 파일에 이어 쓴다(7/8→7/12=4일). 넉넉히 7일을 열거 대상으로 잡되,
    /// 이보다 오래 전에 마지막으로 본 파일도 한 번 추적되면 recentDirs 밖 직접 확인으로 이어진다.
    static let codexLookbackDays = 7

    /// 날짜 파티션 폴더 경로(root/YYYY/MM/DD) — 로컬 날짜 기준. 테스트도 이 함수를 직접 호출해
    /// 경로 계산이 프로덕션과 어긋날 여지를 없앤다.
    static func dateDir(root: URL, for date: Date) -> URL {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return root
            .appendingPathComponent(String(format: "%04d", c.year ?? 0))
            .appendingPathComponent(String(format: "%02d", c.month ?? 0))
            .appendingPathComponent(String(format: "%02d", c.day ?? 0))
    }

    /// 최근 창의 날짜 폴더들. **내일(+1)까지 포함** — 폴더 명명이 로컬 날짜라 타임존 변경·시계
    /// 스큐로 세션이 '내일' 폴더에 떨어져도 잡히게 하는 공짜 보험(없는 폴더 열거는 no-op).
    /// 어제~`days`일 전은 옛 세션 resume 지평(실측 7/8→7/12=4일)을 커버한다.
    static func recentDateDirs(root: URL, now: Date, days: Int) -> [URL] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return (-1...days).compactMap { back in
            cal.date(byAdding: .day, value: -back, to: now).map { dateDir(root: root, for: $0) }
        }
    }

    /// Codex 세션 로그 감시 (~/.codex/sessions + CodexRateLimitParser).
    /// tailOnly — 세션 로그가 수만 개이고 resume가 옛 파일에 이어 쓰므로(실측)
    /// 히스토리 재생 없이 새 append만 본다. 루트가 YYYY/MM/DD 날짜 파티션이라 최근 창의 폴더만
    /// 열거(recentDirs)해 매 틱 전수 walk를 피한다 — 추적된 파일의 append는 폴더 나이와 무관하게 잡힌다.
    public static func codex(env: MobiusEnvironment) -> SessionLogWatcher<CodexRateLimitStatus> {
        let root = env.codexSessionsDir
        let days = codexLookbackDays
        return SessionLogWatcher(
            root: root,
            policy: .tailOnly,
            recentDirs: { now in recentDateDirs(root: root, now: now, days: days) }
        ) { line, _ in
            CodexRateLimitParser.parse(line: line)
        }
    }
}
