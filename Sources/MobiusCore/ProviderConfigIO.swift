import Foundation

/// 프로바이더 계정의 표시용 신원. 등록/adopt 시 프로필 메타데이터가 된다.
public struct ProviderIdentity: Equatable, Sendable {
    public var emailAddress: String
    public var organizationName: String
    public var tierDescription: String

    public init(emailAddress: String, organizationName: String, tierDescription: String) {
        self.emailAddress = emailAddress
        self.organizationName = organizationName
        self.tierDescription = tierDescription
    }
}

/// 프로바이더별 라이브 자격증명 읽기/쓰기의 공통 계약. Switcher가 이 프로토콜만 보고
/// 전환/되저장/adopt/reconcile을 수행한다.
///
/// secret data는 프로바이더가 정한 직렬화 바이트다 — Claude는 CredentialsSnapshot JSON,
/// Codex는 auth.json 원본 바이트. AccountStore의 계정별 비밀 파일에 그대로 저장되고,
/// writeLiveSecretData가 같은 바이트를 받아 라이브에 반영한다 (해석은 어댑터만 한다).
public protocol ProviderConfigIO: Sendable {
    var provider: Provider { get }

    /// 현재 로그인 스냅샷의 직렬화 바이트. 로그아웃 상태면 nil.
    func readLiveSecretData() throws -> Data?

    /// 계정 식별 이메일. 주기 틱마다 호출되므로 승인창/네트워크 없는 값싼 경로여야 한다.
    func liveEmail() throws -> String?

    /// 표시용 메타데이터를 포함한 신원 (등록/adopt 시). 로그아웃 상태면 nil.
    func liveIdentity() throws -> ProviderIdentity?

    /// 라이브 상태(비밀+이메일)를 간격을 두고 두 번 읽어 값이 일치할 때만 반환한다.
    /// 로그인/전환/토큰 리프레시 도중의 불일치 상태를 배제한다 (mtime 신호는 쓰지 않는다 —
    /// 두 프로바이더 모두 자격증명 파일이 "바쁜 파일"임이 실측됐다).
    func readStableLiveSecretData(gap: Duration) async -> (data: Data, email: String)?

    /// 저장된 secret data를 라이브에 반영한다. 원자적이어야 하며 실패 시 throw.
    func writeLiveSecretData(_ data: Data) throws

    /// 주어진 secret 바이트가 이 프로바이더의 자격증명 형태인가. 구버전 바이너리가
    /// accounts.json을 저장하며 per-account `provider`를 드롭해도(구 구조체엔 필드 없음)
    /// secret 파일은 그대로 남으므로, secret 형태가 진짜 provider의 authority다 —
    /// Switcher.healMisassignedProviders가 소실된 provider를 이걸로 재도출한다.
    func recognizesSecret(_ data: Data) -> Bool
}

extension ProviderConfigIO {
    public func readStableLiveSecretData() async -> (data: Data, email: String)? {
        await readStableLiveSecretData(gap: .milliseconds(700))
    }
}

/// 원자적 파일 쓰기 + 퍼미션 — 자격증명류 파일의 공통 쓰기 경로.
func writeAtomic(_ data: Data, to url: URL, mode: Int16) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

/// epoch 초/밀리초 겸용 해석 — 1e12 초과면 밀리초로 본다
/// (실측: Codex resets_at은 초, Claude expiresAt은 밀리초).
func dateFromEpochSecondsOrMillis(_ raw: Double) -> Date {
    Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
}
