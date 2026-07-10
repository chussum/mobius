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
}
