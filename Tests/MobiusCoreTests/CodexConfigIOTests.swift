import XCTest
@testable import MobiusCore

final class CodexConfigIOTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var io: CodexConfigIO!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-codex-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        io = CodexConfigIO(env: env)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func authJSON(email: String = "dev@corp.com", plan: String = "pro") -> Data {
        CodexFixtures.authJSON(email: email, plan: plan)
    }

    func writeAuthFile(_ data: Data) throws {
        try FileManager.default.createDirectory(at: env.codexDir, withIntermediateDirectories: true)
        try data.write(to: env.codexAuthFile)
    }

    func testIdentityFromJWTPayload() throws {
        try writeAuthFile(authJSON(email: "dev@corp.com", plan: "pro"))
        XCTAssertEqual(try io.liveEmail(), "dev@corp.com")
        let identity = try XCTUnwrap(try io.liveIdentity())
        XCTAssertEqual(identity.emailAddress, "dev@corp.com")
        XCTAssertEqual(identity.tierDescription, "Pro")
    }

    func testLoggedOutStates() throws {
        // 파일 없음
        XCTAssertNil(try io.readLiveSecretData())
        XCTAssertNil(try io.liveEmail())
        // 파일은 있지만 tokens 없음 (API 키 전용) — 신원은 없지만(관리 대상 아님)
        // 바이트는 돌려준다: 전환 실패 롤백이 이 상태도 원복해야 하기 때문.
        let apiKeyOnly = Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x","tokens":null}"#.utf8)
        try writeAuthFile(apiKeyOnly)
        XCTAssertEqual(try io.readLiveSecretData(), apiKeyOnly)
        XCTAssertNil(try io.liveEmail())
        XCTAssertNil(try io.liveIdentity())
        // 신원이 없으므로 안정 읽기(adopt/reconcile 경로)는 nil
    }

    func testWriteRejectsNonAuthJSONBytes() throws {
        try writeAuthFile(authJSON(email: "a@x.com"))
        let before = try io.readLiveSecretData()
        // 빈 데이터 / 손상 JSON / 타 프로바이더(Claude 스냅샷) 바이트는 거부 — auth.json 보존
        XCTAssertThrowsError(try io.writeLiveSecretData(Data()))
        XCTAssertThrowsError(try io.writeLiveSecretData(Data("garbage".utf8)))
        let claudeSnapshot = Data(
            #"{"keychainBlob":"YQ==","credentialsFileData":"YQ==","oauthAccountJSON":null}"#.utf8)
        XCTAssertThrowsError(try io.writeLiveSecretData(claudeSnapshot))
        XCTAssertEqual(try io.readLiveSecretData(), before) // 원본 무손상
        // API 키 전용(신원 없음) 원본의 롤백 원복은 통과
        let apiKeyOnly = Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x"}"#.utf8)
        XCTAssertNoThrow(try io.writeLiveSecretData(apiKeyOnly))
        XCTAssertEqual(try io.readLiveSecretData(), apiKeyOnly)
    }

    func testWriteThenReadRoundtripPreservesBytes() throws {
        let original = authJSON(email: "a@x.com")
        try io.writeLiveSecretData(original)
        // 통째 스왑 — 바이트가 정확히 보존돼야 한다
        XCTAssertEqual(try io.readLiveSecretData(), original)
        XCTAssertEqual(try io.liveEmail(), "a@x.com")
        // 0600 퍼미션
        let attrs = try FileManager.default.attributesOfItem(atPath: env.codexAuthFile.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
        // 다른 계정으로 재스왑
        let other = authJSON(email: "b@y.com")
        try io.writeLiveSecretData(other)
        XCTAssertEqual(try io.liveEmail(), "b@y.com")
    }

    func testReadStableRejectsMidSwapMutation() async throws {
        // 읽기 사이에 파일이 바뀌면(리프레시/전환 중) nil — 값 이중 읽기 판정
        try writeAuthFile(authJSON(email: "a@x.com"))
        let first = try io.readLiveSecretData()
        let swapped = authJSON(email: "b@y.com")
        // gap 동안 파일 교체를 시뮬레이션: 별도 태스크가 50ms 후 교체
        let env = self.env!
        Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            try? swapped.write(to: env.codexAuthFile)
        }
        let stable = await io.readStableLiveSecretData(gap: .milliseconds(300))
        // 교체가 gap 안에 일어났으므로 두 읽기가 불일치 → nil
        XCTAssertNil(stable)
        XCTAssertNotEqual(try io.readLiveSecretData(), first)

        // 안정 상태에서는 (bytes, email) 반환
        let settled = await io.readStableLiveSecretData(gap: .milliseconds(10))
        XCTAssertEqual(settled?.email, "b@y.com")
        XCTAssertEqual(settled?.data, swapped)
    }

    func testMalformedJWTIsNil() throws {
        try writeAuthFile(Data(#"{"tokens":{"id_token":"garbage-not-a-jwt"}}"#.utf8))
        XCTAssertNil(try io.liveEmail())
        try writeAuthFile(Data(#"{"tokens":{"id_token":"a.!!!invalid-base64!!!.c"}}"#.utf8))
        XCTAssertNil(try io.liveEmail())
    }
}
