import XCTest
@testable import MobiusCore

/// tailOnly 정책(Codex 세션 감시)의 스펙: 히스토리 재생 금지, 오래된 파일 무시,
/// resume로 되살아난 옛 파일의 append만 파싱. 루트가 날짜 파티션(YYYY/MM/DD)이라
/// 최근 창의 폴더만 열거하되(전수 walk 회피), 추적된 파일은 폴더 나이와 무관하게 tail한다.
final class CodexSessionWatcherTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var dayDir: URL!
    /// 고정 기준 시각 — 폴더가 lookback 창 안/밖인지 판정이 "테스트를 언제 돌리는지"에
    /// 흔들리지 않도록 실제 Date()가 아니라 이 값을 모든 scan에 넘긴다.
    let now: Date = {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 12))!
    }()

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-cxwatch-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        dayDir = folder(daysAgo: 0) // 기준일(당일) 폴더 — lookback 창 안
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 기준 시각에서 daysAgo일 전의 날짜 파티션 폴더. 경로 계산은 프로덕션 헬퍼를 직접 호출해
    /// (@testable) 테스트와 프로덕션이 어긋날 여지를 없앤다.
    func folder(daysAgo: Int) -> URL {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now)!
        return SessionLogWatcher<CodexRateLimitStatus>.dateDir(root: env.codexSessionsDir, for: day)
    }

    func statusLine(pct: Double) -> String {
        #"{"timestamp":"2026-07-12T09:07:14.309Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(pct),"window_minutes":300,"resets_at":1783861033},"rate_limit_reached_type":null}}}"#
    }

    func append(_ line: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try handle.close()
    }

    func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testExistingHistoryIsNotReplayed() throws {
        let log = dayDir.appendingPathComponent("rollout-a.jsonl")
        try append(statusLine(pct: 100.0), to: log) // 과거 소진 이벤트 (재생되면 오탐)

        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 첫 스캔: 프라이밍만

        try append(statusLine(pct: 42.0), to: log)   // 새 append만 파싱
        let statuses = watcher.scan(now: now)
        XCTAssertEqual(statuses.map(\.primary?.usedPercent), [42.0])
    }

    func testStaleUntrackedFileIsNeverOpened() throws {
        let old = dayDir.appendingPathComponent("rollout-old.jsonl")
        try append(statusLine(pct: 100.0), to: old)
        try setMtime(old, now.addingTimeInterval(-3600)) // recentWindow(600s) 밖

        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)
        // 이후 스캔에서도 무시 (히스토리 재생 없음)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)
    }

    func testResumedOldFileTailsFromFirstSight() throws {
        let old = dayDir.appendingPathComponent("rollout-resumed.jsonl")
        try append(statusLine(pct: 90.0), to: old)   // 옛 히스토리
        try setMtime(old, now.addingTimeInterval(-3600))

        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 오래됨 → 무시

        // resume로 되살아나 append 발생 (mtime 갱신)
        try append(statusLine(pct: 95.0), to: old)
        // 처음 본 시점: 프라이밍만 (95.0 라인은 프라이밍 이전 내용이라 건너뜀 — 다음 턴에 반복될 신호)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)
        // 이후 append부터 파싱
        try append(statusLine(pct: 97.0), to: old)
        XCTAssertEqual(watcher.scan(now: now).map(\.primary?.usedPercent), [97.0])
    }

    func testTrackedFileKeepsOffsetAcrossStaleness() throws {
        let log = dayDir.appendingPathComponent("rollout-b.jsonl")
        try append(statusLine(pct: 10.0), to: log)
        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 프라이밍

        try append(statusLine(pct: 20.0), to: log)
        XCTAssertEqual(watcher.scan(now: now).count, 1)

        // 파일이 오래됨 → 열지 않지만 오프셋은 유지
        try setMtime(log, now.addingTimeInterval(-3600))
        XCTAssertTrue(watcher.scan(now: now).isEmpty)
        // 긴 유휴 후 첫 append(소진 이벤트일 수 있음)가 재프라이밍에 삼켜지지 않고 파싱된다
        try append(statusLine(pct: 100.0), to: log)
        XCTAssertEqual(watcher.scan(now: now).map(\.primary?.usedPercent), [100.0])
    }

    func testScanBatchesTagsFilePaths() throws {
        let a = dayDir.appendingPathComponent("rollout-a.jsonl")
        let b = dayDir.appendingPathComponent("rollout-b.jsonl")
        try append(statusLine(pct: 1.0), to: a)
        try append(statusLine(pct: 1.0), to: b)
        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scanBatches(now: now).isEmpty) // 프라이밍
        // 절대 경로는 심링크 해석(/var vs /private/var)이 개입하므로 파일명으로 확인.
        // 격리 정책이 의존하는 것은 trackedFiles와 배치의 file 키가 "같은 표기"라는 점.
        XCTAssertEqual(Set(watcher.trackedFiles.map { ($0 as NSString).lastPathComponent }),
                       ["rollout-a.jsonl", "rollout-b.jsonl"])

        try append(statusLine(pct: 50.0), to: a)
        try append(statusLine(pct: 60.0), to: b)
        let batches = watcher.scanBatches(now: now)
        XCTAssertEqual(Set(batches.map(\.file)), watcher.trackedFiles) // 표기 일관성
        XCTAssertEqual(batches.flatMap(\.events).count, 2)
    }

    // MARK: 날짜 파티션 프루닝 (전수 walk 회피) — 성능 수정의 정확성 계약

    /// lookback 창 밖(수백 일 전) 폴더의 파일도, 창 안에서 한 번 추적된 뒤라면
    /// 폴더가 나이를 먹어 열거 대상에서 빠져도 직접 확인(direct-stat)으로 tail이 이어진다.
    func testTrackedFileInAgedOutFolderStillTailsViaDirectStat() throws {
        // 이 세션은 lookback(7일) 훨씬 밖의 옛 날짜 폴더에 산다.
        let agedDir = folder(daysAgo: 400)
        let f = agedDir.appendingPathComponent("rollout-aged.jsonl")
        // 1) 그 폴더가 '최근'이던 시점(그 날짜 정오)에 스캔해 추적을 시작한다.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let agedDate = cal.date(byAdding: .day, value: -400, to: now)!
        let pastNow = cal.date(bySettingHour: 12, minute: 0, second: 0, of: agedDate)!
        try append(statusLine(pct: 30.0), to: f)
        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scan(now: pastNow).isEmpty) // 프라이밍 (그 시점엔 창 안)
        XCTAssertTrue(watcher.trackedFiles.contains { ($0 as NSString).lastPathComponent == "rollout-aged.jsonl" })

        // 2) 기준 시각(now)으로 넘어오면 이 폴더는 lookback 창 밖 → 열거되지 않는다.
        //    하지만 resume로 append가 생기면(최근 mtime) direct-stat이 잡아야 한다.
        try append(statusLine(pct: 99.0), to: f)
        try setMtime(f, now) // 최근 수정
        XCTAssertEqual(watcher.scan(now: now).map(\.primary?.usedPercent), [99.0])
    }

    /// 재시작 시딩(리뷰 반영): 창 밖(수백 일 전) 폴더의 세션이 최근 수정 상태로 이미 있으면,
    /// 첫 스캔(프라이밍)의 전수 열거가 폴더 나이와 무관하게 시딩한다 → 이후 append를 tail.
    /// 앱 재시작/오프라인 중 codex 사용 후 옛 세션을 resume해도 신호가 끊기지 않는다.
    func testPrimingFullWalkSeedsRecentFileInAgedFolder() throws {
        let f = folder(daysAgo: 400).appendingPathComponent("rollout-warm.jsonl")
        try append(statusLine(pct: 90.0), to: f)
        try setMtime(f, now) // 재시작 직전 resume되어 최근 상태

        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 프라이밍: 전수 열거로 시딩(파싱 없음)
        XCTAssertTrue(watcher.trackedFiles.contains { ($0 as NSString).lastPathComponent == "rollout-warm.jsonl" })

        try append(statusLine(pct: 99.0), to: f)
        XCTAssertEqual(watcher.scan(now: now).map(\.primary?.usedPercent), [99.0]) // direct-stat tail
    }

    /// 잔여 트레이드오프(축소됨): 프라이밍 이후 처음 resume되는 창 밖 세션은 프루닝이 못 본다.
    /// 재시작하면 프라이밍 전수 열거가 다시 시딩하므로, 남는 갭은 "실행 중 첫 resume" 뿐이다.
    /// 계정 한도는 계정 전역이라 활성/최근 세션 이벤트로 교차 반영된다.
    func testAgedFolderFileResumedAfterPrimingIsNotDiscovered() throws {
        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 프라이밍 (창 밖 파일 아직 없음)

        let f = folder(daysAgo: 400).appendingPathComponent("rollout-cold.jsonl")
        try append(statusLine(pct: 100.0), to: f)
        try setMtime(f, now) // 프라이밍 후 처음 나타남 + 최근 mtime, 그러나 창 밖 폴더 + 미추적
        XCTAssertTrue(watcher.scan(now: now).isEmpty)
        try append(statusLine(pct: 100.0), to: f)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)
    }

    /// 당일 폴더의 새 세션 파일은 정상 발견된다 (프루닝이 최근 활동을 가리지 않는다).
    func testTodayFolderNewFileIsDiscovered() throws {
        let watcher = SessionLogWatcher.codex(env: env)
        let f = folder(daysAgo: 0).appendingPathComponent("rollout-new.jsonl")
        try append(statusLine(pct: 5.0), to: f)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)   // 프라이밍
        try append(statusLine(pct: 55.0), to: f)
        XCTAssertEqual(watcher.scan(now: now).map(\.primary?.usedPercent), [55.0])
    }
}
