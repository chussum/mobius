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

    // MARK: - `-w` 출력의 hex 인코딩 판별
    //
    // `security find-generic-password -w`는 값에 비출력 바이트가 하나라도 있으면
    // 원본이 아니라 소문자 16진수 문자열을 출력한다(실측 2026-08-10). 그대로 반환하면
    // hex ASCII가 자격증명 blob으로 들어가 다음 전환에서 라이브 로그인을 파괴한다.
    // 아래 fixture는 전부 이 환경의 실제 `security` 출력이다.

    func testTypicalCredentialBlobIsNotHexShaped() {
        // 흔한 경로: 출력 가능한 JSON blob은 `{`·`"`·`:` 때문에 hex 모양일 수 없다
        // → 확인용 `-g` 호출 없이 그대로 반환된다.
        let blob = Data(#"{"accessToken":"sk-ant-oat01-abc","expiresAt":1754800000}"#.utf8)
        XCTAssertFalse(SystemKeychain.isHexShaped(blob))
    }

    func testHexEncodedOutputIsDetected() {
        // 실측: {"a":"한"} 을 쓰면 -w가 이 hex 문자열을 준다.
        XCTAssertTrue(SystemKeychain.isHexShaped(Data("7b2261223a22ed959c227d".utf8)))
    }

    func testOddLengthAndEmptyOutputAreNotHexShaped() {
        // hex 인코딩은 항상 짝수 길이 — 홀수면 평문이 확정이다.
        XCTAssertFalse(SystemKeychain.isHexShaped(Data("abc".utf8)))
        XCTAssertFalse(SystemKeychain.isHexShaped(Data()))
    }

    func testAsciiThatLooksLikeHexIsAmbiguousAndResolvedByDump() {
        // ★ 값이 진짜 "deadbeef"여도 -w 출력은 hex 인코딩과 구별되지 않는다(실측).
        //   그래서 모양만으로 디코드하면 평문 "deadbeef"가 4바이트 이진값으로 손상된다.
        XCTAssertTrue(SystemKeychain.isHexShaped(Data("deadbeef".utf8)))
        // -g가 0x 없이 인용 형식으로 주면 평문 확정 → nil(원문 그대로 쓰라는 뜻).
        XCTAssertNil(SystemKeychain.binaryPasswordFromSecurityDump("password: \"deadbeef\"\n"))
    }

    func testBinaryPasswordDecodedFromSecurityDump() {
        // 실측 -g stderr 형식: 0x<대문자 HEX> 뒤에 공백 2개 + 이스케이프된 인용 표현.
        let dump = "password: 0x7B2261223A22ED959C227D  \"{\"a\":\"\\355\\225\\234\"}\"\n"
        XCTAssertEqual(SystemKeychain.binaryPasswordFromSecurityDump(dump),
                       Data(#"{"a":"한"}"#.utf8))
    }

    func testBinaryPasswordWithoutTrailingQuotedForm() {
        // 실측: 값이 단일 고바이트면 인용 부분 없이 `password: 0xFF ` 로만 온다.
        XCTAssertEqual(SystemKeychain.binaryPasswordFromSecurityDump("password: 0xFF \n"),
                       Data([0xFF]))
    }

    func testPlainDumpFormsYieldNil() {
        // 평문(0x 없음)·빈 값·password 줄 없음 → 전부 nil = 원문 유지.
        XCTAssertNil(SystemKeychain.binaryPasswordFromSecurityDump("password: \"ab\"\n"))
        XCTAssertNil(SystemKeychain.binaryPasswordFromSecurityDump("password: \n"))
        XCTAssertNil(SystemKeychain.binaryPasswordFromSecurityDump("keychain: \"login\"\n"))
    }

    func testDumpMarkerMustAnchorAtLineStart() {
        // 평문 값 안에 같은 문자열이 들어 있어도 오독하면 안 된다.
        XCTAssertNil(SystemKeychain.binaryPasswordFromSecurityDump(
            "password: \"literal password: 0xdeadbeef\"\n"))
    }

    func testDecodeHexRejectsMalformedInput() {
        XCTAssertNil(SystemKeychain.decodeHex("abc"))   // 홀수 길이
        XCTAssertNil(SystemKeychain.decodeHex("zz"))    // hex 아님
        XCTAssertNil(SystemKeychain.decodeHex(""))
        XCTAssertEqual(SystemKeychain.decodeHex("00ff"), Data([0x00, 0xFF]))
    }
}
