import XCTest
@testable import MobiusCore

final class DesktopSwitcherTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var sw: DesktopSwitcher!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-dt-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        sw = DesktopSwitcher(env: env)
        // 가짜 Desktop 데이터 구성
        try FileManager.default.createDirectory(
            at: env.desktopDataDir.appendingPathComponent("Local Storage"),
            withIntermediateDirectories: true)
        try Data("cookie-A".utf8).write(to: env.desktopDataDir.appendingPathComponent("Cookies"))
        try Data("ls-A".utf8).write(
            to: env.desktopDataDir.appendingPathComponent("Local Storage/data.ldb"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testCaptureRestoreRoundtrip() throws {
        let idA = UUID(); let idB = UUID()
        try sw.capture(for: idA)                       // A 상태 저장
        // Desktop 데이터가 B 계정으로 바뀌었다고 가정
        try Data("cookie-B".utf8).write(to: env.desktopDataDir.appendingPathComponent("Cookies"))
        try sw.capture(for: idB)
        try sw.restore(for: idA)                       // A로 복원
        XCTAssertEqual(try String(contentsOf: env.desktopDataDir.appendingPathComponent("Cookies")),
                       "cookie-A")
        XCTAssertEqual(try String(contentsOf: env.desktopDataDir
            .appendingPathComponent("Local Storage/data.ldb")), "ls-A")
        XCTAssertTrue(sw.hasSnapshot(for: idA))
        XCTAssertFalse(sw.hasSnapshot(for: UUID()))
    }

    func testRestoreWithoutSnapshotThrows() {
        XCTAssertThrowsError(try sw.restore(for: UUID()))
    }

    func testDeleteSnapshot() throws {
        let id = UUID()
        try sw.capture(for: id)
        try sw.deleteSnapshot(for: id)
        XCTAssertFalse(sw.hasSnapshot(for: id))
    }

    /// 가이드 캡처의 변경 감지 신호: 신원 파일 mtime이 최신값으로 집계되는지
    func testIdentityLastModifiedTracksWrites() throws {
        let before = sw.identityLastModified()
        XCTAssertNotNil(before)
        // 파일 시스템 mtime 해상도 이상으로 진행시켜 확실히 갱신
        let future = Date().addingTimeInterval(10)
        try FileManager.default.setAttributes(
            [.modificationDate: future],
            ofItemAtPath: env.desktopDataDir.appendingPathComponent("Local Storage/data.ldb").path)
        let after = sw.identityLastModified()
        XCTAssertNotNil(after)
        XCTAssertGreaterThan(after!, before!)
    }
}
