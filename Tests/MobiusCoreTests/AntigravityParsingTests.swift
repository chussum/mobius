import XCTest
@testable import MobiusCore

/// 설계 7.1: 어댑터 형태 검증·바이트 이메일, 게이지 파서, fetch 전송 경로·UA, client secret 실행 중 읽기.
final class AntigravityParsingTests: XCTestCase {

    // MARK: 형태 검증 (설계 4.1)

    func testRecognizesMeasuredShape() throws {
        let data = AgyFixtures.secret("me@gmail.com")
        let cred = try XCTUnwrap(AntigravitySecret.parse(data))
        XCTAssertEqual(cred.email, "me@gmail.com")
        XCTAssertEqual(cred.refreshToken, "rt")
        XCTAssertEqual(cred.topLevelKeys, ["token", "auth_method", "id_token_email"])
    }

    func testExpiryAcceptsWithAndWithoutFraction() {
        XCTAssertNotNil(AntigravitySecret.parse(AgyFixtures.secret("a@b.c", expiry: "2026-11-19T23:11:25Z")))
        XCTAssertNotNil(AntigravitySecret.parse(AgyFixtures.secret("a@b.c", expiry: "2026-11-19T23:11:25.245645+09:00")))
        XCTAssertNotNil(AntigravitySecret.parse(AgyFixtures.secret("a@b.c", expiry: "2026-11-19T23:11:25.1Z")))
        XCTAssertNil(AntigravitySecret.parse(AgyFixtures.secret("a@b.c", expiry: "tomorrow")))
    }

    func testRFC3339FractionIsAdded() {
        let whole = RFC3339.date(from: "2026-11-19T14:11:25Z")!
        let frac = RFC3339.date(from: "2026-11-19T23:11:25.5+09:00")!
        XCTAssertEqual(frac.timeIntervalSince(whole), 0.5, accuracy: 0.001)
        XCTAssertEqual(RFC3339.date(from: "2026-11-19T14:11:25.245645Z")!.timeIntervalSince(whole),
                       0.245645, accuracy: 0.0001)
    }

    func testRejectsShapesWeHaveNotMeasured() {
        // 접두사 없음
        let raw = String(decoding: AgyFixtures.secret("a@b.c"), as: UTF8.self)
        XCTAssertNil(AntigravitySecret.parse(Data(raw.dropFirst(AntigravitySecret.prefix.count).utf8)))
        // auth_method 가 consumer 가 아님
        XCTAssertNil(AntigravitySecret.parse(AntigravitySecret.make(email: "a@b.c", authMethod: "workspace")))
        // 이메일에 @ 없음
        XCTAssertNil(AntigravitySecret.parse(AntigravitySecret.make(email: "nobody")))
        // 빈 refresh 토큰
        XCTAssertNil(AntigravitySecret.parse(AntigravitySecret.make(email: "a@b.c", refreshToken: "")))
        // expires_in 이 문자열
        let bad: [String: Any] = ["token": ["access_token": "a", "token_type": "Bearer", "refresh_token": "r",
                                            "expiry": "2026-11-19T23:11:25Z", "expires_in": "3599"],
                                  "auth_method": "consumer", "id_token_email": "a@b.c"]
        let body = try! JSONSerialization.data(withJSONObject: bad)
        XCTAssertNil(AntigravitySecret.parse(Data((AntigravitySecret.prefix + body.base64EncodedString()).utf8)))
        // Claude·Codex secret 은 agy 로 보지 않는다
        XCTAssertNil(AntigravitySecret.parse(CodexFixtures.authJSON(email: "x@y.z")))
    }

    func testByteEmailFromAdapterAndOtherProviders() {
        let io = FakeSecurity().makeIO()
        XCTAssertEqual(io.email(fromSecret: AgyFixtures.secret("p@gmail.com")), "p@gmail.com")
        XCTAssertNil(io.email(fromSecret: Data("garbage".utf8)))
        XCTAssertTrue(io.identityIsInSecret)
        XCTAssertFalse(io.rollsBackFailedSwitch)
        let codex = CodexConfigIO(env: AgyFixtures.tempEnv())
        XCTAssertEqual(codex.email(fromSecret: CodexFixtures.authJSON(email: "c@x.com")), "c@x.com")
        XCTAssertTrue(codex.identityIsInSecret)
    }

    // MARK: 게이지 파서 (설계 4.3)

    func testParseExcludesTabModelsAndMarksUnknownFraction() {
        let r = AgyFixtures.report([
            ("gemini-3-flash", 0.4, "2026-11-19T18:18:20Z"),
            ("tab_flash_lite_preview", 1, nil),            // resetTime 없음 → 제외
            ("claude-sonnet-4-6", nil, "2026-11-26T13:18:20Z"), // 값 모름
        ])
        XCTAssertEqual(r.models.map(\.id), ["claude-sonnet-4-6", "gemini-3-flash"])
        XCTAssertTrue(r.hasUnknownFraction)
        XCTAssertNil(r.model("claude-sonnet-4-6")?.remainingFraction)
        XCTAssertFalse(r.model("claude-sonnet-4-6")!.isExplicitlyExhausted)
        XCTAssertFalse(r.model("claude-sonnet-4-6")!.hasExplicitHeadroom)
    }

    func testGaugeLinesGroupBucketsAndLabelByFamily() {
        let r = AgyFixtures.report([
            ("gemini-3-flash", 0.25, "2026-11-19T18:18:20Z"),
            ("gemini-2.5-pro", 0.25, "2026-11-19T18:18:20Z"),   // 같은 버킷
            ("claude-sonnet-4-6", 1, "2026-11-26T13:18:20Z"),  // 사용 전 → "아직 사용 안 함"
            ("claude-opus-4-6-thinking", 1, "2026-11-26T13:18:20Z"),
            ("gpt-oss-120b-medium", 1, "2026-11-26T13:18:20Z"), // 계열 없음, 사용 전 → 안 보임
        ])
        let lines = r.gaugeLines()
        XCTAssertEqual(lines.map(\.label), ["Gemini", "Claude"])
        XCTAssertEqual(lines[0].percent, 75, accuracy: 0.001)   // 사용한 비율
        XCTAssertNotNil(lines[0].resetsAt)
        XCTAssertNil(lines[1].resetsAt)                         // 아직 사용 안 함
        XCTAssertEqual(lines[1].percent, 0)
    }

    func testGaugeLinesNumberDuplicateLabelsAndShowUnknown() {
        let r = AgyFixtures.report([
            ("gemini-3-flash", 0.5, "2026-11-19T18:18:20Z"),
            ("gemini-3.1-flash-image", 0.9, "2026-11-26T13:18:20Z"), // 다른 버킷, 같은 계열
            ("claude-sonnet-4-6", nil, "2026-11-26T13:18:20Z"),
            ("gemini-2.5-pro", 1, "2026-11-19T18:18:20Z"),           // Gemini 버킷이 있으니 안 보임
        ])
        let lines = r.gaugeLines()
        XCTAssertEqual(Set(lines.map(\.label)), ["Gemini", "Gemini 2", "Claude"])
        XCTAssertEqual(Set(lines.map(\.label)).count, lines.count, "줄 ID 가 겹치면 안 된다")
        let claude = lines.first { $0.label == "Claude" }!
        XCTAssertEqual(claude.unverified, true)
        XCTAssertEqual(claude.percent, 100)
    }

    func testUsageSnapshotKeepsCacheShape() throws {
        let snap = AgyFixtures.report([("gemini-3-flash", 0.5, "2026-11-19T18:18:20Z")]).usageSnapshot()
        XCTAssertNil(snap.fiveHourPercent)
        // usageCacheV1 호환: 새 옵셔널 필드가 없는 구버전 캐시도 그대로 읽힌다.
        let old = #"{"label":"Fable","percent":12,"resetsAt":800000000}"#
        XCTAssertNoThrow(try JSONDecoder().decode(ScopedUsageLimit.self, from: Data(old.utf8)))
        let round = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(round, snap)
    }

    // MARK: fetch 전송 경로·UA (실패 기록 14·18)

    func testFetchUsesInjectedTransportWithPostAndBearer() async throws {
        let seen = Box<URLRequest>()
        let body = AgyFixtures.quotaJSON([("gemini-3-flash", 0.5, "2026-11-19T18:18:20Z")])
        let transport: AntigravityUsageFetcher.Transport = { req in
            seen.value = req
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let report = try await AntigravityUsageFetcher.fetch(accessToken: "tok", transport: transport)
        XCTAssertEqual(report.models.count, 1)
        let req = try XCTUnwrap(seen.value)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.httpBody, Data("{}".utf8))
        XCTAssertEqual(req.url, AntigravityUsageFetcher.endpoint)
    }

    func testFetchMaps403ToUnauthorized() async {
        let transport: AntigravityUsageFetcher.Transport = { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await AntigravityUsageFetcher.fetch(accessToken: "tok", transport: transport)
            XCTFail("throw 해야 한다")
        } catch {
            XCTAssertEqual(error as? AntigravityUsageError, .unauthorized)
        }
    }

    func testSessionIsEphemeralWithUserAgentHeader() {
        let ua = AntigravityUsageFetcher.userAgent(version: "1.5.12")
        XCTAssertEqual(ua, "antigravity-cli/1.5.12")
        XCTAssertEqual(AntigravityUsageFetcher.userAgent(version: nil), "antigravity-cli/1.5.12")
        let s = AntigravityUsageFetcher.session(userAgent: ua)
        XCTAssertNil(s.configuration.urlCache, "자격증명이 실리는 요청은 디스크 캐시를 쓰지 않는다")
        XCTAssertEqual(s.configuration.httpAdditionalHeaders?["User-Agent"] as? String, ua)
    }

    // MARK: 설치된 바이너리에서 실행 중에 읽기 (설계 4.3)

    func testFindsClientSecretCandidatesInBinaryBytes() {
        let a = "GOCSPX-" + String(repeating: "A", count: 28)
        let b = "GOCSPX-" + String(repeating: "b", count: 27) + "_"
        let short = "GOCSPX-tooShort"
        var bytes = Data([0, 1, 2])
        for s in [a, short, b, a] { bytes += Data(s.utf8) + Data([0]) }
        XCTAssertEqual(AntigravityInstall.clientSecretCandidates(in: bytes), [a, b])
    }

    func testFollowsWrapperExecTargets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("Caskroom/antigravity-cli/1.5.12,5281398513336320/antigravity")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: real)   // 스크립트가 아닌 바이너리
        let cask = dir.appendingPathComponent("agy")
        try "#!/bin/bash\nAGY_CLI_DISABLE_AUTO_UPDATE=\"true\" exec \"\(real.path)\"  \"$@\"\n"
            .write(to: cask, atomically: true, encoding: .utf8)
        let guardScript = dir.appendingPathComponent("guard-agy")
        try "#!/bin/bash\nset -u\nREAL_AGY=\"${AGY_REAL:-\(cask.path)}\"\ncase \"$1\" in\n  --version) exec \"$REAL_AGY\" \"$@\" ;;\nesac\nexec \"$REAL_AGY\" \"$@\"\n"
            .write(to: guardScript, atomically: true, encoding: .utf8)
        for f in [real, cask, guardScript] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        let resolved = try XCTUnwrap(AntigravityInstall.resolveBinary(from: guardScript))
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path, real.resolvingSymlinksInPath().path)
        XCTAssertEqual(AntigravityInstall.version(fromBinaryPath: resolved.path), "1.5.12")
    }

    // MARK: 토큰 — 메모리에서만 갱신 (설계 4.3)

    private func cred(expiry: String) -> AntigravityCredential {
        AntigravitySecret.parse(AgyFixtures.secret("a@b.c", expiry: expiry))!
    }

    func testValidTokenNeedsNoNetwork() async {
        let calls = Box<Int>(0)
        let src = AntigravityTokenSource(transport: { _ in calls.value! += 1; throw URLError(.badURL) },
                                         secretCandidates: { ["GOCSPX-x"] })
        let now = RFC3339.date(from: "2026-11-19T10:00:00Z")!
        let r = await src.accessToken(for: cred(expiry: "2026-11-19T12:00:00Z"), now: now)
        XCTAssertEqual(r, .token("at"))
        XCTAssertEqual(calls.value, 0)
    }

    func testNoSecretMeansNoRefresh() async {
        let calls = Box<Int>(0)
        let src = AntigravityTokenSource(transport: { _ in calls.value! += 1; throw URLError(.badURL) },
                                         secretCandidates: { [] })
        let r = await src.accessToken(for: cred(expiry: "2026-11-19T00:00:00Z"),
                                      now: RFC3339.date(from: "2026-11-19T10:00:00Z")!)
        XCTAssertEqual(r, .unavailable)
        XCTAssertEqual(calls.value, 0, "secret 을 못 찾으면 갱신하지 않는다")
    }

    func testTriesCandidatesUntilClientAcceptedAndRemembersIt() async {
        let tried = Box<[String]>([])
        let transport: AntigravityTokenSource.Transport = { req in
            let form = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
            let secret = form.components(separatedBy: "&").first { $0.hasPrefix("client_secret=") }!
                .replacingOccurrences(of: "client_secret=", with: "")
            tried.value!.append(secret)
            let ok = secret == "GOCSPX-good"
            let json = ok ? #"{"access_token":"fresh","expires_in":3599}"# : #"{"error":"invalid_client"}"#
            return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: ok ? 200 : 401,
                                                     httpVersion: nil, headerFields: nil)!)
        }
        let src = AntigravityTokenSource(transport: transport,
                                         secretCandidates: { ["GOCSPX-bad", "GOCSPX-good"] })
        let now = RFC3339.date(from: "2026-11-19T10:00:00Z")!
        let r = await src.accessToken(for: cred(expiry: "2026-11-19T00:00:00Z"), now: now)
        XCTAssertEqual(r, .token("fresh"))
        XCTAssertEqual(tried.value, ["GOCSPX-bad", "GOCSPX-good"])
        // 같은 refresh 토큰은 메모리 캐시, 다른 refresh 토큰은 성공한 secret 부터
        _ = await src.accessToken(for: cred(expiry: "2026-11-19T00:00:00Z"), now: now)
        XCTAssertEqual(tried.value?.count, 2)
        let other = AntigravitySecret.parse(AgyFixtures.secret("o@b.c", refresh: "rt2",
                                                               expiry: "2026-11-19T00:00:00Z"))!
        _ = await src.accessToken(for: other, now: now)
        XCTAssertEqual(tried.value?.last, "GOCSPX-good")
        XCTAssertEqual(tried.value?.count, 3)
    }

    func testInvalidGrantIsReportedNotRetriedWithOtherSecrets() async {
        let count = Box<Int>(0)
        let transport: AntigravityTokenSource.Transport = { req in
            count.value! += 1
            return (Data(#"{"error":"invalid_grant"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        let src = AntigravityTokenSource(transport: transport, secretCandidates: { ["GOCSPX-1", "GOCSPX-2"] })
        let r = await src.accessToken(for: cred(expiry: "2026-11-19T00:00:00Z"),
                                      now: RFC3339.date(from: "2026-11-19T10:00:00Z")!)
        XCTAssertEqual(r, .invalidGrant)
        XCTAssertEqual(count.value, 1)
    }
}

/// 테스트용 가변 상자(클로저에서 기록).
final class Box<T>: @unchecked Sendable {
    var value: T?
    init(_ v: T? = nil) { value = v }
}
