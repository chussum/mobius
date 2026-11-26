import XCTest
@testable import MobiusCore

/// 설계 7.1: `CLIKeychain`(네이티브 호출 0회, `-i` 길이 가드, 제한 시간)과 어댑터의 변화 감지·"모름" 상태.
final class AntigravityKeychainTests: XCTestCase {
    let s = AntigravitySecret.keychainService, a = AntigravitySecret.keychainAccount

    // MARK: CLIKeychain

    func testReadFailureAndTimeoutThrowWithoutNativeFallback() {
        let fake = FakeSecurity()
        let native = Box<Int>(0)
        let kc = CLIKeychain(runner: fake, attributeReader: { _, _ in native.value! += 1; return .notFound })
        fake.nextReadResult = .exited(status: 51, stdout: Data(), stderr: Data())
        XCTAssertThrowsError(try kc.read(service: s, account: a)) {
            XCTAssertEqual($0 as? CLIKeychainError, .failed(status: 51))
        }
        fake.nextReadResult = .timedOut
        XCTAssertThrowsError(try kc.read(service: s, account: a)) {
            XCTAssertEqual($0 as? CLIKeychainError, .timedOut)
        }
        fake.nextWriteResult = .timedOut
        XCTAssertThrowsError(try kc.write(service: s, account: a, data: AgyFixtures.secret("x@y.z")))
        XCTAssertEqual(native.value, 0, "값 읽기·쓰기는 실패해도 네이티브 키체인 API 로 떨어지지 않는다")
        XCTAssertThrowsError(try kc.delete(service: s, account: a)) {
            XCTAssertEqual($0 as? CLIKeychainError, .unsupported)
        }
    }

    func testWriteGoesThroughInteractiveStdinOnly() throws {
        let fake = FakeSecurity()
        let kc = CLIKeychain(runner: fake, attributeReader: fake.attributeReader)
        let value = AgyFixtures.secret("x@y.z")
        try kc.write(service: s, account: a, data: value)
        XCTAssertEqual(fake.calls.last, ["-i"], "비밀은 argv 가 아니라 표준 입력으로만 간다")
        XCTAssertEqual(try kc.read(service: s, account: a), value)
        XCTAssertEqual(fake.attributeReads, 0)
    }

    func testInteractiveLengthGuardRefusesWithoutRunning() {
        let fake = FakeSecurity()
        let kc = CLIKeychain(runner: fake, attributeReader: fake.attributeReader)
        let huge = Data(String(repeating: "x", count: SystemKeychain.interactiveCommandLimit).utf8)
        XCTAssertThrowsError(try kc.write(service: s, account: a, data: huge)) {
            XCTAssertEqual($0 as? CLIKeychainError, .valueNotSendable)
        }
        XCTAssertTrue(fake.calls.isEmpty, "잘린 값이 기록되는 -i 는 아예 부르지 않는다(argv 경로도 없다)")
    }

    func testHexShapedOutputIsConfirmedWithDump() throws {
        // -w 가 hex 모양을 주면 -g 로 되묻는다(기존 판별 경로 재사용).
        final class HexRunner: SecurityCLIRunning, @unchecked Sendable {
            func run(_ args: [String], stdin: Data?, timeout: TimeInterval) -> SecurityCLIResult {
                if args.contains("-w") { return .exited(status: 0, stdout: Data("7b7d\n".utf8), stderr: Data()) }
                return .exited(status: 0, stdout: Data(), stderr: Data("password: 0x7B7D  \"{}\"\n".utf8))
            }
        }
        let kc = CLIKeychain(runner: HexRunner(), attributeReader: { _, _ in .notFound })
        XCTAssertEqual(try kc.read(service: s, account: a), Data("{}".utf8))
    }

    /// 응답하지 않는 `security`(승인 대기)를 진짜 프로세스로 흉내 낸다 — 제한 시간이 지나면
    /// 프로세스를 끝내고 timedOut 을 돌려줘야 한다(설계 4.1).
    func testProcessRunnerKillsHungProcessAtTimeout() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = ProcessSecurityRunner(executable: script)
        let start = Date()
        XCTAssertEqual(runner.run(["find-generic-password"], stdin: nil, timeout: 0.5), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    // MARK: 어댑터 변화 감지 (설계 4.2)

    func testLiveEmailReadsValueOnlyWhenMdatChanges() throws {
        let fake = FakeSecurity()
        fake.set(AgyFixtures.secret("one@gmail.com"))
        let io = fake.makeIO()
        XCTAssertEqual(try io.liveEmail(), "one@gmail.com")
        XCTAssertEqual(fake.valueReads, 1)
        for _ in 0..<5 { XCTAssertEqual(try io.liveEmail(), "one@gmail.com") }
        XCTAssertEqual(fake.valueReads, 1, "mdat 이 같으면 값을 다시 읽지 않는다(실패 기록 3)")
        fake.now += 2
        fake.set(AgyFixtures.secret("two@gmail.com"))
        XCTAssertEqual(try io.liveEmail(), "two@gmail.com")
        XCTAssertEqual(fake.valueReads, 2)
        fake.set(nil)
        XCTAssertNil(try io.liveEmail())
        XCTAssertNil(io.liveFingerprint, "로그아웃은 지문 nil")
    }

    func testUnrecognizedValueIsTreatedAsNoIdentity() throws {
        let fake = FakeSecurity()
        fake.set(Data("go-keyring-base64:bm90LWpzb24=".utf8))
        let io = fake.makeIO()
        XCTAssertNil(try io.liveEmail())
        XCTAssertNil(try io.liveIdentity())
    }

    func testReadFailureBacksOffForSameMdat() {
        let fake = FakeSecurity()
        fake.set(AgyFixtures.secret("one@gmail.com"))
        let io = fake.makeIO()
        fake.nextReadResult = .exited(status: 1, stdout: Data(), stderr: Data())
        XCTAssertThrowsError(try io.liveEmail())
        XCTAssertThrowsError(try io.liveEmail()) {
            XCTAssertEqual($0 as? AntigravityConfigError, .valueReadBackingOff)
        }
        XCTAssertEqual(fake.valueReads, 1, "같은 mdat 의 실패는 5분 동안 되풀이하지 않는다")
        fake.now += AntigravityConfigIO.failedReadRetry + 1
        XCTAssertEqual(try io.liveEmail(), "one@gmail.com")
    }

    func testLockedKeychainIsNoChange() throws {
        let fake = FakeSecurity()
        fake.set(AgyFixtures.secret("one@gmail.com"))
        var locked = false
        let kc = CLIKeychain(runner: fake, attributeReader: { s, a in
            locked ? .unavailable : fake.attributeReader(s, a)
        })
        let io = AntigravityConfigIO(keychain: kc, clock: { fake.now })
        XCTAssertEqual(try io.liveEmail(), "one@gmail.com")
        locked = true
        XCTAssertEqual(try io.liveEmail(), "one@gmail.com")
        XCTAssertEqual(fake.valueReads, 1)
    }

    // MARK: 쓰기와 "모름" 상태 (설계 4.1 · 4.5)

    func testWriteFailureEntersUnknownAndBacksOffConfirmation() throws {
        let fake = FakeSecurity()
        fake.set(AgyFixtures.secret("one@gmail.com"))
        let io = fake.makeIO()
        _ = try io.liveEmail()
        fake.nextWriteResult = .timedOut
        fake.writeAppliesEvenWhenFailing = true      // 실제로는 쓰였을 수 있다
        XCTAssertThrowsError(try io.writeLiveSecretData(AgyFixtures.secret("two@gmail.com")))
        XCTAssertTrue(io.isLiveStateUnknown)
        // 모르는 동안은 쓰지 않는다
        XCTAssertThrowsError(try io.writeLiveSecretData(AgyFixtures.secret("one@gmail.com"))) {
            XCTAssertEqual($0 as? AntigravityConfigError, .liveStateUnknown)
        }
        // 1분 전에는 확인 읽기도 하지 않는다
        let reads = fake.valueReads
        XCTAssertThrowsError(try io.liveEmail())
        XCTAssertEqual(fake.valueReads, reads)
        // 1분 뒤 확인 읽기가 실패하면 5분으로 늘린다
        fake.now += 61
        fake.nextReadResult = .timedOut
        XCTAssertThrowsError(try io.liveEmail())
        fake.now += 120
        XCTAssertThrowsError(try io.liveEmail())
        XCTAssertEqual(fake.valueReads, reads + 1, "5분 전에는 다시 읽지 않는다(승인창을 쌓지 않는다)")
        fake.now += 5 * 60
        XCTAssertEqual(try io.liveEmail(), "two@gmail.com", "읽어서 확인되면 모름이 풀린다")
        XCTAssertFalse(io.isLiveStateUnknown)
    }

    /// 리뷰 1회차 Codex P2-4: 확인 일정은 `liveEmail` 만이 아니라 모든 라이브 읽기(수동 전환의 되저장,
    /// 팝오버·자동 전환의 작업 시작 확인)에 적용된다.
    func testUnknownScheduleAppliesToDirectReadsToo() throws {
        let fake = FakeSecurity()
        fake.set(AgyFixtures.secret("one@gmail.com"))
        let io = fake.makeIO()
        fake.nextWriteResult = .timedOut
        XCTAssertThrowsError(try io.writeLiveSecretData(AgyFixtures.secret("two@gmail.com")))
        let reads = fake.valueReads
        XCTAssertThrowsError(try io.readLiveSecretData()) {
            XCTAssertEqual($0 as? AntigravityConfigError, .liveStateUnknown)
        }
        XCTAssertThrowsError(try io.liveIdentity())
        XCTAssertEqual(fake.valueReads, reads, "예정 시각 전에는 어느 경로로도 읽지 않는다")
        XCTAssertTrue(io.isLiveStateUnknown)
        fake.now += 61
        fake.nextReadResult = .timedOut
        XCTAssertThrowsError(try io.readLiveSecretData()) {
            XCTAssertEqual($0 as? AntigravityConfigError, .liveStateUnknown)
        }
        fake.now += 120
        XCTAssertThrowsError(try io.readLiveSecretData())
        XCTAssertEqual(fake.valueReads, reads + 1, "실패하면 직접 읽기도 5분 간격을 따른다")
        fake.now += 5 * 60
        XCTAssertEqual(try io.readLiveSecretData(), AgyFixtures.secret("one@gmail.com"))
        XCTAssertFalse(io.isLiveStateUnknown)
    }

    /// 리뷰 2회차 Codex P2-1: 쓰기 실패 **전에** 시작한 읽기가 끝나면서 새로 켜진 "모름"을 풀지 않는다.
    func testReadStartedBeforeWriteFailureDoesNotClearUnknown() throws {
        let fake = FakeSecurity()
        fake.set(AgyFixtures.secret("one@gmail.com"))
        let io = fake.makeIO()
        _ = try io.readLiveSecretData()
        // 대사의 읽기가 값을 얻은 뒤 돌려주기 전에, 자동 전환의 쓰기가 시간 초과로 끝난다
        fake.afterValueReadOnce = {
            fake.nextWriteResult = .timedOut
            _ = try? io.writeLiveSecretData(AgyFixtures.secret("two@gmail.com"))
        }
        _ = try? io.readLiveSecretData()
        XCTAssertTrue(io.isLiveStateUnknown, "확인 일정은 쓰기 실패를 기준으로 남는다")
    }

    /// 리뷰 3회차 Codex P2-2: 겹친 확인 읽기 가운데 늦게 돌아온 것이 새 쓰기 실패의 재시도 일정을 바꾸지 않는다.
    func testStaleConfirmReadDoesNotRescheduleNewWriteFailure() throws {
        let fake = FakeSecurity()
        fake.set(AgyFixtures.secret("one@gmail.com"))
        let io = fake.makeIO()
        fake.nextWriteResult = .timedOut
        XCTAssertThrowsError(try io.writeLiveSecretData(AgyFixtures.secret("two@gmail.com")))
        fake.now += 61   // 첫 확인 읽기 예정 시각이 지났다
        // 확인 읽기 R1 이 값을 얻은 뒤 돌아오기 전에: 다른 확인 읽기 R2 가 "모름"을 풀고, 새 쓰기가 다시 실패한다
        fake.afterValueReadOnce = {
            _ = try? io.readLiveSecretData()
            fake.nextWriteResult = .timedOut
            _ = try? io.writeLiveSecretData(AgyFixtures.secret("one@gmail.com"))
        }
        XCTAssertThrowsError(try io.readLiveSecretData())   // R1 — 늦게 돌아와 거부된다
        XCTAssertTrue(io.isLiveStateUnknown)
        // 새 실패의 일정은 1분 뒤 첫 확인이다(R1 이 5분으로 밀어내면 안 된다)
        let reads = fake.valueReads
        fake.now += 61
        _ = try? io.readLiveSecretData()
        XCTAssertEqual(fake.valueReads, reads + 1, "새 실패 기준 1분 뒤에 확인 읽기를 한다")
    }

    /// 리뷰 1회차 Codex P1-3: 쓰기 직전에 읽은 라이브 값이 기대한 지문이 아니면 쓰지 않는다.
    func testGuardedWriteRefusesWhenLiveChanged() throws {
        let fake = FakeSecurity()
        let a = AgyFixtures.secret("one@gmail.com")
        fake.set(a)
        let io = fake.makeIO()
        fake.set(AgyFixtures.secret("new@gmail.com"))   // 기대 확인 뒤에 끝난 agy 로그인
        let writes = fake.writes
        XCTAssertThrowsError(try io.writeLiveSecretData(AgyFixtures.secret("two@gmail.com"),
                                                        ifLiveFingerprint: AntigravitySecret.fingerprint(a))) {
            XCTAssertEqual($0 as? AntigravityConfigError, .liveChangedBeforeWrite)
        }
        XCTAssertEqual(fake.writes, writes)
        XCTAssertEqual(fake.value(), AgyFixtures.secret("new@gmail.com"))
        XCTAssertFalse(io.isLiveStateUnknown, "쓰지 않았으므로 모름이 아니다")
        // 같은 지문이면 쓴다
        try io.writeLiveSecretData(AgyFixtures.secret("two@gmail.com"),
                                   ifLiveFingerprint: AntigravitySecret.fingerprint(AgyFixtures.secret("new@gmail.com")))
        XCTAssertEqual(fake.value(), AgyFixtures.secret("two@gmail.com"))
    }

    func testNonTimeoutWriteFailureAlsoBecomesUnknown() {
        let fake = FakeSecurity()
        fake.set(AgyFixtures.secret("one@gmail.com"))
        let io = fake.makeIO()
        fake.nextWriteResult = .exited(status: 1, stdout: Data(), stderr: Data())
        XCTAssertThrowsError(try io.writeLiveSecretData(AgyFixtures.secret("two@gmail.com")))
        XCTAssertTrue(io.isLiveStateUnknown, "실패해도 항목이 바뀌지 않았다고 가정하지 않는다")
    }

    func testRefusesUnrecognizedOrDifferentlyShapedValues() {
        let fake = FakeSecurity()
        let io = fake.makeIO()
        XCTAssertThrowsError(try io.writeLiveSecretData(Data("nope".utf8))) {
            XCTAssertEqual($0 as? AntigravityConfigError, .unrecognizedSecret)
        }
        // 라이브 값의 최상위 키가 다르면(agy 업데이트) 전환을 멈춘다
        let newer: [String: Any] = ["token": ["access_token": "a", "token_type": "Bearer", "refresh_token": "r",
                                              "expiry": "2026-11-19T23:11:25Z"],
                                    "auth_method": "consumer", "id_token_email": "n@b.c", "new_key": 1]
        let body = try! JSONSerialization.data(withJSONObject: newer)
        fake.set(Data((AntigravitySecret.prefix + body.base64EncodedString()).utf8))
        XCTAssertThrowsError(try io.writeLiveSecretData(AgyFixtures.secret("x@y.z"))) {
            XCTAssertEqual($0 as? AntigravityConfigError, .liveFormatChanged)
        }
        XCTAssertEqual(fake.writes, 0)
    }

    func testFingerprintAndChangedValueReporting() throws {
        let fake = FakeSecurity()
        fake.set(AgyFixtures.secret("one@gmail.com", refresh: "r1"))
        let io = fake.makeIO()
        _ = try io.liveEmail()
        let fp1 = io.liveFingerprint
        XCTAssertNotNil(io.takeChangedLiveValue())
        XCTAssertNil(io.takeChangedLiveValue(), "한 번 넘기면 비운다")
        // 같은 이메일로 다시 로그인 — 바이트가 바뀐다
        fake.now += 2
        fake.set(AgyFixtures.secret("one@gmail.com", refresh: "r2"))
        _ = try io.liveEmail()
        XCTAssertNotEqual(io.liveFingerprint, fp1)
        XCTAssertEqual(io.takeChangedLiveValue(), AgyFixtures.secret("one@gmail.com", refresh: "r2"))
        // 자기 쓰기는 지문을 맞추고 "바뀐 값"으로 보고하지 않는다
        try io.writeLiveSecretData(AgyFixtures.secret("two@gmail.com"))
        XCTAssertEqual(io.liveFingerprint, AntigravitySecret.fingerprint(AgyFixtures.secret("two@gmail.com")))
    }
}
