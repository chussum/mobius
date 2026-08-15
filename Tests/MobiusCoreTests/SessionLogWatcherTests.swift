import XCTest
@testable import MobiusCore

final class SessionLogWatcherTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var log: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-watch-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        try FileManager.default.createDirectory(
            at: env.projectsDir.appendingPathComponent("proj1"),
            withIntermediateDirectories: true)
        log = env.projectsDir.appendingPathComponent("proj1/session.jsonl")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 레거시 epoch 포맷의 hit 라인 (timestamp 없음 → 파서는 now 기준으로 sanity 검사)
    func legacyHitLine(epoch: Int) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Claude AI usage limit reached|\#(epoch)"}]}}"#
    }

    func currentFormatLine(text: String) -> String {
        #"{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    func append(_ line: String) throws { try appendRaw(line + "\n") }

    func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    func testDetectsOnlyNewlyAppendedHits() throws {
        let now = Date()
        let epoch = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
        // 기존 내용에 이미 hit이 있어도 첫 스캔에서는 무시해야 함
        try (legacyHitLine(epoch: epoch) + "\n").write(to: log, atomically: true, encoding: .utf8)

        let watcher = SessionLogWatcher(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 첫 스캔: 오프셋만 기록

        // 새 줄 append → 감지되어야 함
        try append(legacyHitLine(epoch: epoch))

        let hits = watcher.scan(now: now)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].resetsAt, Date(timeIntervalSince1970: TimeInterval(epoch)))

        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 같은 내용 재감지 없음
    }

    func testCurrentFormatHitAndServerSideExclusion() throws {
        let now = Date()
        try "".write(to: log, atomically: true, encoding: .utf8)
        let watcher = SessionLogWatcher(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)

        // 서버측 제한(제외 대상) + 일반 라인 → hit 아님
        try append(currentFormatLine(
            text: "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited"))
        try append(#"{"type":"user","message":{"content":[{"type":"text","text":"hello"}]}}"#)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)

        // 현행 포맷의 계정 한도(월간 지출 — 리셋 시각 없음) → hit
        try append(currentFormatLine(
            text: "You've hit your monthly spend limit · raise it at claude.ai/settings/usage"))
        let hits = watcher.scan(now: now)
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits[0].resetsAt)
    }

    func testPartialLineIsNotLostAcrossScans() throws {
        let now = Date()
        let epoch = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
        try "".write(to: log, atomically: true, encoding: .utf8)
        let watcher = SessionLogWatcher(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 프라이밍

        let full = legacyHitLine(epoch: epoch)
        let mid = full.index(full.startIndex, offsetBy: full.count / 2)
        // ① 개행 없는 부분 라인만 도착 (쓰기 도중 스캔) → 히트 0, 오프셋 전진 없어야 함
        try appendRaw(String(full[..<mid]))
        XCTAssertTrue(watcher.scan(now: now).isEmpty)
        // ② 나머지 + 개행 도착 → 분할된 이벤트가 온전한 한 줄로 파싱됨
        try appendRaw(String(full[mid...]) + "\n")
        let hits = watcher.scan(now: now)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].resetsAt, Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: - lastActivity (배지 판정용 "세션이 최근에 돌았는가")

    func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// 스캔 전에는 nil — "오래 전 활동"이 아니라 "관찰 자체가 없었다"는 뜻이라
    /// 값싼 조건이 이 상태를 의심으로 승격하면 안 된다.
    func testLastActivityIsNilBeforeFirstScan() throws {
        try "".write(to: log, atomically: true, encoding: .utf8)
        let watcher = SessionLogWatcher(env: env)
        XCTAssertNil(watcher.lastActivity)
    }

    /// 한 스캔에서 본 후보 파일 mtime의 **최댓값**. 여러 프로젝트 세션이 동시에 도는 게
    /// 정상이므로 "가장 최근에 쓰인 세션"이 활동 시각이다.
    func testLastActivityIsMaxModificationTimeSeen() throws {
        let now = Date()
        try "".write(to: log, atomically: true, encoding: .utf8)
        let other = env.projectsDir.appendingPathComponent("proj1/other.jsonl")
        try "".write(to: other, atomically: true, encoding: .utf8)
        let older = now.addingTimeInterval(-300)
        let newer = now.addingTimeInterval(-30)
        try setMtime(log, older)
        try setMtime(other, newer)

        let watcher = SessionLogWatcher(env: env)   // Claude 정책(parseFromStart, 전수 열거)
        _ = watcher.scan(now: now)
        XCTAssertEqual(watcher.lastActivity?.timeIntervalSince1970 ?? 0,
                       newer.timeIntervalSince1970, accuracy: 1)
    }

    /// ★ 파일시스템 호출이 늘지 않았음의 구조적 증거: **열지도 않는 파일**의 mtime이
    /// lastActivity에 반영된다 = 값의 출처가 이미 계산돼 있던 mtime(열거 시 읽은
    /// resourceValues)이지 별도의 stat/open이 아니다. tailOnly는 오래된 파일을 guard에서
    /// 걸러 FileHandle을 아예 열지 않으므로(추적도 안 함) 이 관찰이 성립한다.
    func testLastActivityComesFromAlreadyComputedMtimeOfSkippedFile() throws {
        let now = codexNow
        let stale = codexDayDir.appendingPathComponent("rollout-stale.jsonl")
        try FileManager.default.createDirectory(at: codexDayDir, withIntermediateDirectories: true)
        try "{}\n".write(to: stale, atomically: true, encoding: .utf8)
        let staleAt = now.addingTimeInterval(-3600)  // recentWindow(600s) 밖 → 스킵
        try setMtime(stale, staleAt)

        let watcher = SessionLogWatcher.codex(env: env)
        _ = watcher.scan(now: now)
        XCTAssertTrue(watcher.trackedFiles.isEmpty)  // 열지 않았다(오프셋 없음)
        XCTAssertEqual(watcher.lastActivity?.timeIntervalSince1970 ?? 0,
                       staleAt.timeIntervalSince1970, accuracy: 1)
    }

    /// 두 정책 모두에서 갱신되어야 한다 — 여기서는 tailOnly(Codex, 날짜 파티션 프루닝).
    /// 앱이 실제로 읽는 건 Claude 워처뿐이지만, 값 갱신 지점이 정책 분기보다 위에 있다는
    /// 보증이 없으면 프루닝 경로에서 조용히 멈춘다.
    func testLastActivityUpdatesUnderTailOnlyPolicy() throws {
        let now = codexNow
        let log = codexDayDir.appendingPathComponent("rollout-a.jsonl")
        try FileManager.default.createDirectory(at: codexDayDir, withIntermediateDirectories: true)
        try "{}\n".write(to: log, atomically: true, encoding: .utf8)
        let first = now.addingTimeInterval(-120)
        try setMtime(log, first)

        let watcher = SessionLogWatcher.codex(env: env)
        _ = watcher.scan(now: now)                   // 프라이밍(전수 열거)
        XCTAssertEqual(watcher.lastActivity?.timeIntervalSince1970 ?? 0,
                       first.timeIntervalSince1970, accuracy: 1)

        // 프라이밍 이후 스캔은 recentDirs로 프루닝된다 — 그 경로에서도 전진해야 한다.
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile(); handle.write(Data("{}\n".utf8)); try handle.close()
        let second = now.addingTimeInterval(-10)
        try setMtime(log, second)
        _ = watcher.scan(now: now)
        XCTAssertEqual(watcher.lastActivity?.timeIntervalSince1970 ?? 0,
                       second.timeIntervalSince1970, accuracy: 1)
    }

    /// 고정 기준 시각 — Codex 날짜 파티션 폴더가 lookback 창 안인지가 "테스트를 언제
    /// 돌리는지"에 흔들리지 않도록 실제 Date() 대신 이 값을 scan에 넘긴다.
    var codexNow: Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 12))!
    }

    /// 기준일의 날짜 파티션 폴더 — 경로 계산은 프로덕션 헬퍼를 그대로 쓴다.
    var codexDayDir: URL {
        SessionLogWatcher<CodexRateLimitStatus>.dateDir(root: env.codexSessionsDir, for: codexNow)
    }

    func testPartialLineAtPrimingIsCompletedLater() throws {
        let now = Date()
        let epoch = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
        let full = legacyHitLine(epoch: epoch)
        let mid = full.index(full.startIndex, offsetBy: full.count / 2)
        // 프라이밍 시점: 완성된 옛 라인(무시 대상) + 쓰기 도중인 부분 라인
        try (legacyHitLine(epoch: epoch) + "\n" + String(full[..<mid]))
            .write(to: log, atomically: true, encoding: .utf8)

        let watcher = SessionLogWatcher(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 첫 스캔: 마지막 개행까지만 오프셋 기록

        // 부분 라인의 나머지가 완성되면 그 라인은 파싱되어야 함
        try appendRaw(String(full[mid...]) + "\n")
        let hits = watcher.scan(now: now)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].resetsAt, Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: 이슈 #15 — 접근자가 진행 중인 스캔을 기다리면 안 된다

    /// 첫 파싱에서 **딱 한 번** 멈추는 게이트 — "스캔 락을 쥔 채 오래 도는 스캔"을 결정적으로
    /// 재현한다(sleep 기반 타이밍 의존 없음). 한 스캔이 파일 여러 개를 파싱할 수 있으므로
    /// 재무장하지 않는다 — 두 번째 이후 파싱은 그냥 통과시켜 스캔이 스스로 끝나게 둔다.
    final class ParseGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var armed = true
        func hold() {
            lock.lock()
            guard armed else { lock.unlock(); return }
            armed = false
            lock.unlock()
            entered.signal()
            release.wait()
        }
        func open() { release.signal() }
    }

    func names(_ paths: Set<String>) -> [String] {
        paths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
    }

    func gatedWatcher(_ gate: ParseGate) -> SessionLogWatcher<String> {
        SessionLogWatcher<String>(root: env.projectsDir) { line, _ in
            gate.hold()
            return line
        }
    }

    /// 스캔이 락을 쥐고 도는 **도중에** lastActivity/trackedFiles가 즉시 반환해야 한다.
    ///
    /// 회귀 시 무슨 일이 벌어지나: 두 접근자를 스캔 락(`lock`)으로 되돌리면 이 테스트가
    /// 타임아웃한다. 실제 앱에서는 그 대기가 메인 액터에서 일어나므로
    /// (AppState.recomputeBadgeCheap이 3초마다 lastActivity를 읽는다) 세션 로그가 큰 환경에서
    /// UI가 영구 정지한다 — 크래시가 아니라 행(hang)이라 크래시 리포트도 안 남는다
    /// (실측 제보: 4.3GB/5,690개, 재시작 약 6분 후 재현).
    func testAccessorsDoNotWaitForAnInProgressScan() throws {
        let gate = ParseGate()
        let watcher = gatedWatcher(gate)
        try "primed\n".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertTrue(watcher.scan().isEmpty)   // 프라이밍 — 오프셋만 기록, parse 미호출
        try append("appended")

        let scanFinished = expectation(description: "scan finished")
        DispatchQueue.global().async {
            _ = watcher.scan()
            scanFinished.fulfill()
        }
        // 스캔이 파싱 구간(= 스캔 락 보유 중)에 진입할 때까지 기다린다.
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success,
                       "스캔이 파싱 구간에 진입하지 못했다 — 테스트 전제가 깨짐")

        let accessorsReturned = expectation(description: "accessors returned during scan")
        DispatchQueue.global().async {
            _ = watcher.lastActivity
            _ = watcher.trackedFiles
            accessorsReturned.fulfill()
        }
        wait(for: [accessorsReturned], timeout: 2)   // 스캔 락을 잡으면 여기서 타임아웃

        gate.open()
        wait(for: [scanFinished], timeout: 5)
    }

    /// "안 막힌다"만 보증하고 값이 비어 있으면 배지 판정이 조용히 false로 굳으므로, 게시되는
    /// 값의 내용도 못 박는다. lastActivity는 스캔 **도중** 관찰 즉시 반영되고(정지 판정을
    /// 늦추지 않는다), trackedFiles는 스캔 **완료 시점** 스냅샷이라 진행 중에는 직전 값이
    /// 보인다(절반만 갱신된 중간 상태를 노출하지 않는다).
    func testAccessorValuesDuringAndAfterScan() throws {
        let gate = ParseGate()
        let watcher = gatedWatcher(gate)
        try "primed\n".write(to: log, atomically: true, encoding: .utf8)
        _ = watcher.scan()
        let afterPriming = try XCTUnwrap(watcher.lastActivity)
        // 경로는 파일명으로 비교한다 — enumerator는 /var를 /private/var로 해석해 돌려주므로
        // 같은 파일인데도 문자열이 다르다(심볼릭 링크).
        XCTAssertEqual(names(watcher.trackedFiles), ["session.jsonl"])

        // 두 파일 모두 프라이밍보다 확실히 나중으로 못 박는다 — 열거 순서가 보장되지 않으므로
        // 어느 쪽이 먼저 관찰되든 lastActivity가 올라야 한다.
        let other = env.projectsDir.appendingPathComponent("proj1/other.jsonl")
        try "x\n".write(to: other, atomically: true, encoding: .utf8)
        try append("appended")
        try setMtime(log, afterPriming.addingTimeInterval(30))
        try setMtime(other, afterPriming.addingTimeInterval(60))

        let scanFinished = expectation(description: "scan finished")
        DispatchQueue.global().async { _ = watcher.scan(); scanFinished.fulfill() }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)

        XCTAssertGreaterThan(try XCTUnwrap(watcher.lastActivity), afterPriming)
        XCTAssertEqual(names(watcher.trackedFiles), ["session.jsonl"])   // 아직 직전 스냅샷

        gate.open()
        wait(for: [scanFinished], timeout: 5)
        // 스캔 완료 후: 새 파일이 추적 집합에 반영된다.
        XCTAssertEqual(names(watcher.trackedFiles), ["other.jsonl", "session.jsonl"])
        XCTAssertEqual(try XCTUnwrap(watcher.lastActivity).timeIntervalSince1970,
                       afterPriming.addingTimeInterval(60).timeIntervalSince1970, accuracy: 1)
    }
}
