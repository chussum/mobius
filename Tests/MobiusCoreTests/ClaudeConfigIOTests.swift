import XCTest
@testable import MobiusCore

final class ClaudeConfigIOTests: XCTestCase {
    var tmp: URL!
    var env: MobiusEnvironment!
    var kc: InMemoryKeychain!
    var io: ClaudeConfigIO!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-test-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        try FileManager.default.createDirectory(at: env.claudeDir,
                                                withIntermediateDirectories: true)
        kc = InMemoryKeychain()
        io = ClaudeConfigIO(env: env, keychain: kc)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func seedLive(email: String = "p@x.com") throws {
        try kc.write(service: env.claudeKeychainService, account: env.claudeKeychainAccount,
                     data: Data(#"{"tok":"secret-A"}"#.utf8))
        try Data(#"{"tok":"secret-A"}"#.utf8).write(to: env.credentialsFile)
        let claudeJSON = #"{"otherKey":42,"oauthAccount":{"emailAddress":"\#(email)","organizationName":"Org"}}"#
        try Data(claudeJSON.utf8).write(to: env.claudeJSON)
    }

    func testReadLiveSnapshot() throws {
        try seedLive()
        let snap = try XCTUnwrap(io.readLiveSnapshot())
        XCTAssertEqual(snap.keychainBlob, Data(#"{"tok":"secret-A"}"#.utf8))
        XCTAssertEqual(snap.credentialsFileData, Data(#"{"tok":"secret-A"}"#.utf8))
        XCTAssertEqual(try io.liveEmail(), "p@x.com")
    }

    func testReadReturnsNilWithoutKeychain() throws {
        XCTAssertNil(try io.readLiveSnapshot())
    }

    func testWritePreservesOtherKeys() throws {
        try seedLive()
        var snap = try XCTUnwrap(io.readLiveSnapshot())
        snap.keychainBlob = Data(#"{"tok":"secret-B"}"#.utf8)
        snap.credentialsFileData = Data(#"{"tok":"secret-B"}"#.utf8)
        snap.oauthAccountJSON = Data(#"{"emailAddress":"w@x.com"}"#.utf8)
        try io.writeLiveSnapshot(snap)

        XCTAssertEqual(try kc.read(service: env.claudeKeychainService,
                                   account: env.claudeKeychainAccount),
                       Data(#"{"tok":"secret-B"}"#.utf8))
        XCTAssertEqual(try Data(contentsOf: env.credentialsFile),
                       Data(#"{"tok":"secret-B"}"#.utf8))
        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: env.claudeJSON)) as! [String: Any]
        XCTAssertEqual(dict["otherKey"] as? Int, 42) // 다른 키 보존
        XCTAssertEqual((dict["oauthAccount"] as? [String: Any])?["emailAddress"] as? String,
                       "w@x.com")
        XCTAssertEqual(try io.liveEmail(), "w@x.com")
    }
}
