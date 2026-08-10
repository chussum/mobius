import XCTest
@testable import MobiusCore

final class KeychainClientTests: XCTestCase {
    func testInMemoryRoundtrip() throws {
        let kc = InMemoryKeychain()
        XCTAssertNil(try kc.read(service: "s", account: "a"))
        try kc.write(service: "s", account: "a", data: Data("v1".utf8))
        XCTAssertEqual(try kc.read(service: "s", account: "a"), Data("v1".utf8))
        try kc.write(service: "s", account: "a", data: Data("v2".utf8)) // 덮어쓰기
        XCTAssertEqual(try kc.read(service: "s", account: "a"), Data("v2".utf8))
        try kc.delete(service: "s", account: "a")
        XCTAssertNil(try kc.read(service: "s", account: "a"))
    }

    func testFailureInjection() {
        let kc = InMemoryKeychain()
        kc.failNextWrite = true
        XCTAssertThrowsError(try kc.write(service: "s", account: "a", data: Data()))
        // 실패는 1회성
        XCTAssertNoThrow(try kc.write(service: "s", account: "a", data: Data()))
    }

    func testServiceTargetedFailureInjectionIsConsumedOnFirstMatch() throws {
        let kc = InMemoryKeychain()
        kc.failWritesForService = "target"
        // 다른 service로의 write는 영향 없음 (주입도 소모되지 않음)
        XCTAssertNoThrow(try kc.write(service: "other", account: "a", data: Data("o".utf8)))
        XCTAssertNotNil(kc.failWritesForService)
        // 첫 매칭 write가 실패하며 주입이 소모됨
        XCTAssertThrowsError(try kc.write(service: "target", account: "a", data: Data("t1".utf8)))
        XCTAssertNil(kc.failWritesForService)
        XCTAssertNil(try kc.read(service: "target", account: "a")) // 실패한 write는 반영 안 됨
        // 같은 service로의 후속 write(롤백 시나리오)는 통과
        XCTAssertNoThrow(try kc.write(service: "target", account: "a", data: Data("t2".utf8)))
        XCTAssertEqual(try kc.read(service: "target", account: "a"), Data("t2".utf8))
    }

    // MARK: - security -i 명령줄 길이 가드
    //
    // 한계를 넘으면 명령이 잘린 채 실행되어 항목에 truncated 값이 기록된다(실측).
    // 즉 실패가 곧 손상이므로 보내기 전에 막아야 한다.

    private let service = "Claude Code-credentials"
    private let account = "tester"

    /// 값을 뺀 명령 자체의 길이(개행 제외).
    private var commandOverhead: Int {
        SystemKeychain.interactiveWriteCommand(
            service: service, account: account, value: ""
        ).utf8.count - 1
    }

    func testTypicalCredentialBlobFitsInteractiveCommand() {
        // MCP 등록이 없는 계정의 실제 blob 크기(실측 486 B)
        let blob = String(repeating: "a", count: 486)
        XCTAssertTrue(SystemKeychain.fitsInteractiveCommand(
            service: service, account: account, value: blob))
    }

    func testBlobBloatedByMCPRegistrationsDoesNotFit() {
        // MCP 플러그인 OAuth 등록이 쌓인 계정의 실제 blob 크기(실측 8,071 B).
        // 이 경우가 막히지 않으면 잘린 값이 키체인에 기록된다.
        let blob = String(repeating: "a", count: 8071)
        XCTAssertFalse(SystemKeychain.fitsInteractiveCommand(
            service: service, account: account, value: blob))
    }

    func testInteractiveCommandLimitBoundary() {
        let exact = String(repeating: "x",
                           count: SystemKeychain.interactiveCommandLimit - commandOverhead)
        XCTAssertTrue(SystemKeychain.fitsInteractiveCommand(
            service: service, account: account, value: exact),
            "명령줄 정확히 \(SystemKeychain.interactiveCommandLimit) B는 통과해야 한다")
        XCTAssertFalse(SystemKeychain.fitsInteractiveCommand(
            service: service, account: account, value: exact + "x"),
            "1 B만 넘어도 막아야 한다 — 넘기면 잘린 값이 기록된다")
    }

    func testEscapingCountsTowardTheLimit() {
        // 따옴표·역슬래시는 이스케이프되어 2배가 되므로, 원문 길이가 아니라
        // 이스케이프 후 길이로 판정해야 한다.
        let budget = SystemKeychain.interactiveCommandLimit - commandOverhead
        let quotes = String(repeating: "\"", count: budget / 2)
        XCTAssertTrue(SystemKeychain.fitsInteractiveCommand(
            service: service, account: account, value: quotes))
        XCTAssertFalse(SystemKeychain.fitsInteractiveCommand(
            service: service, account: account, value: quotes + "\""))
    }

    func testNewlineIsRejectedRegardlessOfLength() {
        // 개행이 있으면 짧아도 명령이 두 줄로 쪼개져 뒷부분이 별도 명령이 된다.
        XCTAssertFalse(SystemKeychain.fitsInteractiveCommand(
            service: service, account: account, value: "short\nvalue"))
    }

    func testInteractiveCommandEscapesQuotesAndBackslashes() {
        let command = SystemKeychain.interactiveWriteCommand(
            service: "s", account: "a", value: #"q"b\c"#)
        XCTAssertTrue(command.contains(#"-w "q\"b\\c""#), command)
        XCTAssertTrue(command.hasSuffix("\n"))
    }
}
