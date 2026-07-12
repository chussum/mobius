import XCTest
@testable import MobiusCore

final class SyncEngineTests: XCTestCase {
    var tmp: URL!
    var claudeDir: URL!   // 로컬 ~/.claude 모사
    var syncRoot: URL!    // 클라우드 동기화 폴더 모사
    var trash: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-sync-\(UUID().uuidString)")
        claudeDir = tmp.appendingPathComponent("claude")
        syncRoot = tmp.appendingPathComponent("cloud")
        trash = tmp.appendingPathComponent("trash")
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: syncRoot, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    /// busyWindow=0 (테스트 파일은 방금 만들어져 항상 busy로 걸리므로)
    func engine(id: String = "mac-a") -> SyncEngine {
        SyncEngine(machineID: id, localTrashDir: trash, busyWindow: 0)
    }

    func write(_ base: URL, _ rel: String, _ text: String,
               mtime: Date? = nil) throws {
        let url = base.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }
    func read(_ base: URL, _ rel: String) -> String? {
        try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8)
    }
    var plansLocal: URL { claudeDir.appendingPathComponent("plans") }
    var plansRemote: URL { syncRoot.appendingPathComponent("plans") }

    func testUploadsAndDownloadsNewFiles() throws {
        try write(plansLocal, "a.md", "local-only")
        try write(plansRemote, "b.md", "remote-only")
        let r = engine().sync(categories: [.plans], claudeDir: claudeDir,
                              syncRoot: syncRoot, propagateDeletes: false)
        XCTAssertEqual(r.uploaded, 1)
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(read(plansRemote, "a.md"), "local-only")
        XCTAssertEqual(read(plansLocal, "b.md"), "remote-only")
    }

    func testNewerMtimeWins() throws {
        let old = Date(timeIntervalSinceNow: -3600), new = Date(timeIntervalSinceNow: -60)
        try write(plansLocal, "p.md", "OLD-local", mtime: old)
        try write(plansRemote, "p.md", "NEW-remote", mtime: new)
        let r = engine().sync(categories: [.plans], claudeDir: claudeDir,
                              syncRoot: syncRoot, propagateDeletes: false)
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(read(plansLocal, "p.md"), "NEW-remote")
    }

    func testBusyFileSkipped() throws {
        let e = SyncEngine(machineID: "m", localTrashDir: trash, busyWindow: 3600)
        try write(plansLocal, "busy.md", "writing…") // 방금 씀 → busy
        let r = e.sync(categories: [.plans], claudeDir: claudeDir,
                       syncRoot: syncRoot, propagateDeletes: false)
        XCTAssertEqual(r.skippedBusy, 1)
        XCTAssertFalse(fm.fileExists(atPath: plansRemote.appendingPathComponent("busy.md").path))
    }

    func testCredentialsNeverSync() throws {
        // 세션 카테고리로 projects/ 아래 자격증명·계정 파일이 절대 넘어가지 않는지
        let projects = claudeDir.appendingPathComponent("projects")
        try write(projects, "proj/.credentials.json", "SECRET")
        try write(projects, "proj/accounts.json", "ACCOUNTS")
        try write(projects, "secrets/x.json", "TOKEN")
        try write(projects, "proj/normal.jsonl", "ok",
                  mtime: Date(timeIntervalSinceNow: -300))
        let r = engine().sync(categories: [.sessions], claudeDir: claudeDir,
                              syncRoot: syncRoot, propagateDeletes: false)
        XCTAssertEqual(r.uploaded, 1) // normal.jsonl만
        let remote = syncRoot.appendingPathComponent("sessions")
        XCTAssertTrue(fm.fileExists(atPath: remote.appendingPathComponent("proj/normal.jsonl").path))
        XCTAssertFalse(fm.fileExists(atPath: remote.appendingPathComponent("proj/.credentials.json").path))
        XCTAssertFalse(fm.fileExists(atPath: remote.appendingPathComponent("proj/accounts.json").path))
        XCTAssertFalse(fm.fileExists(atPath: remote.appendingPathComponent("secrets/x.json").path))
    }

    func testDeleteNotPropagatedByDefault() throws {
        let e = engine()
        try write(plansLocal, "keep.md", "v1", mtime: Date(timeIntervalSinceNow: -600))
        _ = e.sync(categories: [.plans], claudeDir: claudeDir,
                   syncRoot: syncRoot, propagateDeletes: false)
        // 로컬에서 삭제 → 미전파 모드에서는 원격 사본이 되살려 준다(다운로드)
        try fm.removeItem(at: plansLocal.appendingPathComponent("keep.md"))
        let r = e.sync(categories: [.plans], claudeDir: claudeDir,
                       syncRoot: syncRoot, propagateDeletes: false)
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(read(plansLocal, "keep.md"), "v1")
        XCTAssertEqual(r.trashedRemote, 0)
    }

    func testDeletePropagatesViaTrash() throws {
        let a = engine(id: "mac-a")
        try write(plansLocal, "gone.md", "v1", mtime: Date(timeIntervalSinceNow: -600))
        _ = a.sync(categories: [.plans], claudeDir: claudeDir,
                   syncRoot: syncRoot, propagateDeletes: true)
        // mac-a에서 삭제 → 원격 사본이 휴지통으로 + tombstone
        try fm.removeItem(at: plansLocal.appendingPathComponent("gone.md"))
        let r1 = a.sync(categories: [.plans], claudeDir: claudeDir,
                        syncRoot: syncRoot, propagateDeletes: true)
        XCTAssertEqual(r1.trashedRemote, 1)
        XCTAssertFalse(fm.fileExists(atPath: plansRemote.appendingPathComponent("gone.md").path))

        // mac-b (다른 로컬)에는 파일이 있음 → tombstone을 보고 로컬 휴지통으로
        let claudeB = tmp.appendingPathComponent("claude-b")
        let trashB = tmp.appendingPathComponent("trash-b")
        let b = SyncEngine(machineID: "mac-b", localTrashDir: trashB, busyWindow: 0)
        try write(claudeB.appendingPathComponent("plans"), "gone.md", "v1",
                  mtime: Date(timeIntervalSinceNow: -600))
        let r2 = b.sync(categories: [.plans], claudeDir: claudeB,
                        syncRoot: syncRoot, propagateDeletes: true)
        XCTAssertEqual(r2.trashedLocal, 1)
        XCTAssertFalse(fm.fileExists(
            atPath: claudeB.appendingPathComponent("plans/gone.md").path))
        // 휴지통에 보관됐는지 (즉시 삭제 금지)
        let trashed = try fm.subpathsOfDirectory(atPath: trashB.path)
        XCTAssertTrue(trashed.contains { $0.hasSuffix("gone.md") })
    }

    func testDeleteCancelledByNewerEdit() throws {
        let a = engine(id: "mac-a")
        try write(plansLocal, "doc.md", "v1", mtime: Date(timeIntervalSinceNow: -600))
        _ = a.sync(categories: [.plans], claudeDir: claudeDir,
                   syncRoot: syncRoot, propagateDeletes: true)
        try fm.removeItem(at: plansLocal.appendingPathComponent("doc.md"))
        _ = a.sync(categories: [.plans], claudeDir: claudeDir,
                   syncRoot: syncRoot, propagateDeletes: true) // tombstone 생성

        // mac-b에서 tombstone 이후에 다시 수정 → 삭제 취소, 재업로드
        let claudeB = tmp.appendingPathComponent("claude-b")
        let b = SyncEngine(machineID: "mac-b",
                           localTrashDir: tmp.appendingPathComponent("trash-b"), busyWindow: 0)
        try write(claudeB.appendingPathComponent("plans"), "doc.md", "v2-edited",
                  mtime: Date(timeIntervalSinceNow: 3600)) // tombstone보다 미래
        let r = b.sync(categories: [.plans], claudeDir: claudeB,
                       syncRoot: syncRoot, propagateDeletes: true)
        XCTAssertEqual(r.uploaded, 1)
        XCTAssertEqual(read(plansRemote, "doc.md"), "v2-edited")
    }

    func testConflictBacksUpLoser() throws {
        let e = engine()
        try write(plansLocal, "c.md", "base", mtime: Date(timeIntervalSinceNow: -600))
        _ = e.sync(categories: [.plans], claudeDir: claudeDir,
                   syncRoot: syncRoot, propagateDeletes: false)
        // 양쪽 모두 base 이후 수정 (원격이 더 최신)
        try write(plansLocal, "c.md", "local-edit", mtime: Date(timeIntervalSinceNow: -120))
        try write(plansRemote, "c.md", "remote-edit", mtime: Date(timeIntervalSinceNow: -30))
        let r = e.sync(categories: [.plans], claudeDir: claudeDir,
                       syncRoot: syncRoot, propagateDeletes: false)
        XCTAssertEqual(r.conflicts, 1)
        XCTAssertEqual(read(plansLocal, "c.md"), "remote-edit") // 최신 승
        // 진 쪽(local-edit)이 conflicts 백업에 존재
        let conflictsDir = syncRoot.appendingPathComponent(".mobius-sync/conflicts")
        let backups = (try? fm.subpathsOfDirectory(atPath: conflictsDir.path)) ?? []
        XCTAssertTrue(backups.contains { $0.contains("c.md") })
    }

    func testSingleFileCategoryRoundtrip() throws {
        try write(claudeDir, "CLAUDE.md", "글로벌 메모리",
                  mtime: Date(timeIntervalSinceNow: -300))
        let r = engine().sync(categories: [.globalMemory], claudeDir: claudeDir,
                              syncRoot: syncRoot, propagateDeletes: false)
        XCTAssertEqual(r.uploaded, 1)
        XCTAssertEqual(read(syncRoot.appendingPathComponent("globalMemory"), "CLAUDE.md"),
                       "글로벌 메모리")
        // 플러그인 목록 파일만 올라가고 cache는 대상 아님을 겸사 확인
        try write(claudeDir.appendingPathComponent("plugins"), "installed_plugins.json", "{}",
                  mtime: Date(timeIntervalSinceNow: -300))
        try write(claudeDir.appendingPathComponent("plugins"), "cache/big.bin", "XXXX",
                  mtime: Date(timeIntervalSinceNow: -300))
        let r2 = engine().sync(categories: [.pluginConfig], claudeDir: claudeDir,
                               syncRoot: syncRoot, propagateDeletes: false)
        XCTAssertEqual(r2.uploaded, 1)
        XCTAssertFalse(fm.fileExists(atPath: syncRoot
            .appendingPathComponent("pluginConfig/cache/big.bin").path))
    }
}
