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
}
