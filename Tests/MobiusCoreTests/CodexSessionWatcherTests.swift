import XCTest
@testable import MobiusCore

/// tailOnly 정책(Codex 세션 감시)의 스펙: 히스토리 재생 금지, 오래된 파일 무시,
/// resume로 되살아난 옛 파일의 append만 파싱.
final class CodexSessionWatcherTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var dayDir: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-cxwatch-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        dayDir = env.codexSessionsDir.appendingPathComponent("2026/07/12")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func statusLine(pct: Double) -> String {
        #"{"timestamp":"2026-07-12T09:07:14.309Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(pct),"window_minutes":300,"resets_at":1783861033},"rate_limit_reached_type":null}}}"#
    }

    func append(_ line: String, to url: URL) throws {
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
        let now = Date()
        let log = dayDir.appendingPathComponent("rollout-a.jsonl")
        try append(statusLine(pct: 100.0), to: log) // 과거 소진 이벤트 (재생되면 오탐)

        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 첫 스캔: 프라이밍만

        try append(statusLine(pct: 42.0), to: log)   // 새 append만 파싱
        let statuses = watcher.scan(now: now)
        XCTAssertEqual(statuses.map(\.primary?.usedPercent), [42.0])
    }

    func testStaleUntrackedFileIsNeverOpened() throws {
        let now = Date()
        let old = dayDir.appendingPathComponent("rollout-old.jsonl")
        try append(statusLine(pct: 100.0), to: old)
        try setMtime(old, now.addingTimeInterval(-3600)) // recentWindow(600s) 밖

        let watcher = SessionLogWatcher.codex(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)
        // 이후 스캔에서도 무시 (히스토리 재생 없음)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)
    }

    func testResumedOldFileTailsFromFirstSight() throws {
        let now = Date()
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
        let now = Date()
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
        let now = Date()
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
}
