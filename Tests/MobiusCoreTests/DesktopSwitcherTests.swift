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

    func testStashLogsOutAndRestoreBringsBack() throws {
        let cookies = env.desktopDataDir.appendingPathComponent("Cookies")
        // 강제 로그아웃: 신원 파일이 라이브에서 사라져야 함
        let stash = try XCTUnwrap(try sw.stashLiveIdentity())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cookies.path))
        XCTAssertNil(sw.identityLastModified()) // 로그아웃 상태 = 신원 없음
        // 취소 복원: 원래 세션이 되돌아와야 함
        try sw.restoreStashedIdentity(from: stash)
        XCTAssertEqual(try String(contentsOf: cookies), "cookie-A")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stash.path)) // 보관소 정리됨
    }

    func testStashReturnsNilWhenAlreadyLoggedOut() throws {
        _ = try sw.stashLiveIdentity() // 한 번 치우면
        XCTAssertNil(try sw.stashLiveIdentity()) // 더 치울 게 없음
    }

    func testLogoutClearsIdentityAndConfigAuth() throws {
        // 로그인 상태: 신원 파일 + config.json 로그인 키 존재
        try JSONSerialization.data(withJSONObject: ["oauth:tokenCache": "X", "locale": "ko"])
            .write(to: env.desktopConfigFile)
        XCTAssertTrue(sw.hasLiveLogin())
        try sw.logout()
        // 신원 파일 제거 + 로그인 키 제거, 앱 설정(locale)은 보존
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: env.desktopDataDir.appendingPathComponent("Cookies").path))
        XCTAssertFalse(sw.hasLiveLogin())
        let cfg = try JSONSerialization.jsonObject(
            with: Data(contentsOf: env.desktopConfigFile)) as! [String: Any]
        XCTAssertEqual(cfg["locale"] as? String, "ko")       // 앱 설정 보존
        XCTAssertNil(cfg["oauth:tokenCache"])                // 로그인 제거
    }

    private func writeConfig(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: env.desktopConfigFile)
    }
    private func readConfig() throws -> [String: Any] {
        try JSONSerialization.jsonObject(
            with: Data(contentsOf: env.desktopConfigFile)) as! [String: Any]
    }

    func testConfigAuthSwappedButAppSettingsPreserved() throws {
        let idA = UUID(); let idB = UUID()
        // A 로그인 상태: 로그인 키 + 앱 설정
        try writeConfig(["oauth:tokenCache": "A-token",
                         "lastKnownAccountUuid": "uuid-A",
                         "locale": "ko", "userThemeMode": "dark"])
        try sw.capture(for: idA)
        // B 로그인 상태로 바뀜 (앱 설정 locale도 사용자가 바꿈)
        try writeConfig(["oauth:tokenCache": "B-token",
                         "lastKnownAccountUuid": "uuid-B",
                         "locale": "en", "userThemeMode": "dark"])
        try sw.capture(for: idB)
        // A로 복원 → 로그인 키는 A, 앱 설정(locale=en)은 현재 값 보존
        try sw.restore(for: idA)
        let cfg = try readConfig()
        XCTAssertEqual(cfg["oauth:tokenCache"] as? String, "A-token")     // 로그인은 A로
        XCTAssertEqual(cfg["lastKnownAccountUuid"] as? String, "uuid-A")
        XCTAssertEqual(cfg["locale"] as? String, "en")                     // 앱 설정 보존
        XCTAssertEqual(cfg["userThemeMode"] as? String, "dark")
    }

    func testDeleteSnapshot() throws {
        let id = UUID()
        try sw.capture(for: id)
        sw.deleteSnapshot(for: id)
        XCTAssertFalse(sw.hasSnapshot(for: id))
    }

    /// 재캡처는 기존 스냅샷을 통째로 교체한다 — 이전 캡처의 잔재 항목이나
    /// temp/스테이징 디렉토리가 남지 않아야 한다 (원자적 교체 검증).
    func testRecaptureReplacesSnapshotWholesale() throws {
        let fm = FileManager.default
        let id = UUID()
        // 1차 캡처: Session Storage 포함
        try Data("ss-old".utf8).write(
            to: env.desktopDataDir.appendingPathComponent("Session Storage"))
        try sw.capture(for: id)
        let snapDir = env.desktopProfilesDir.appendingPathComponent(id.uuidString)
        XCTAssertTrue(fm.fileExists(
            atPath: snapDir.appendingPathComponent("Session Storage").path))

        // 라이브에서 Session Storage 제거 + Cookies 갱신 후 재캡처
        try fm.removeItem(at: env.desktopDataDir.appendingPathComponent("Session Storage"))
        try Data("cookie-2".utf8).write(to: env.desktopDataDir.appendingPathComponent("Cookies"))
        try sw.capture(for: id)

        // 이전 스냅샷 잔재(Session Storage)가 남아 있으면 부분 병합 — 실패
        XCTAssertFalse(fm.fileExists(
            atPath: snapDir.appendingPathComponent("Session Storage").path))
        XCTAssertEqual(try String(contentsOf: snapDir.appendingPathComponent("Cookies")),
                       "cookie-2")
        // temp/스테이징 잔재 없음
        let leftovers = try fm.contentsOfDirectory(atPath: env.desktopProfilesDir.path)
            .filter { $0.contains(".tmp-") || $0.hasPrefix(".restore-tmp-") }
        XCTAssertEqual(leftovers, [])
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
