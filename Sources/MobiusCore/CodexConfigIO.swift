import Foundation

/// codex CLI 자격증명(~/.codex/auth.json 단일 파일, 0600)의 읽기·쓰기.
///
/// 실측(2026-07-12, codex-cli 0.144.1):
/// - auth.json이 유일한 자격증명 저장소 — Keychain 무관 (승인창 이슈 자체가 없다).
///   `.codex-global-state.json`은 데스크톱 앱 UI 상태로 자격증명과 무관.
/// - 구조: `auth_mode`, `tokens{id_token, access_token, refresh_token, account_id}`,
///   `last_refresh`, `OPENAI_API_KEY`(null 가능).
/// - 계정 신원은 tokens.id_token(JWT) payload에서 로컬 추출 — `email`,
///   `https://api.openai.com/auth`.chatgpt_plan_type. 서명 검증 불필요(표시용).
/// - ★ 바쁜 파일: 실행 중인 codex 세션들이 토큰 리프레시로 수시로 다시 쓴다 —
///   mtime을 안정성 신호로 쓰지 말 것(값 이중 읽기로 판정).
/// - secret data = auth.json 원본 바이트 그대로. 해석 없이 통째로 스왑하는 것이
///   로그인 시점 상태를 정확히 복원하는 가장 안전한 방법이다.
public enum CodexConfigError: Error {
    /// 저장된 비밀에서 계정 신원(id_token 이메일)을 못 읽음 — 라이브에 쓰기 전에 거부한다
    /// (빈 파일/손상/타 프로바이더 바이트가 auth.json을 덮어써 로그인을 파괴하는 것 방지).
    case unrecognizedSecret
}

public struct CodexConfigIO: ProviderConfigIO {
    let env: MobiusEnvironment

    public init(env: MobiusEnvironment) { self.env = env }

    public var provider: Provider { .codex }

    /// 파일에 내용이 있으면 신원 유무와 무관하게 바이트를 돌려준다 — 전환 실패 시
    /// 롤백은 신원 없는 상태(API 키 전용 등)도 원복해야 하기 때문. 계정 식별이 필요한
    /// 경로(adopt/reconcile/되저장)는 liveEmail/liveIdentity의 nil로 걸러진다.
    public func readLiveSecretData() throws -> Data? {
        guard let data = try? Data(contentsOf: env.codexAuthFile), !data.isEmpty else { return nil }
        return data
    }

    public func liveEmail() throws -> String? {
        guard let data = try? Data(contentsOf: env.codexAuthFile) else { return nil }
        return Self.email(fromAuthJSON: data)
    }

    public func liveIdentity() throws -> ProviderIdentity? {
        guard let data = try? Data(contentsOf: env.codexAuthFile),
              let payload = Self.idTokenPayload(fromAuthJSON: data),
              let email = payload["email"] as? String else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let plan = (auth?["chatgpt_plan_type"] as? String) ?? ""
        return ProviderIdentity(emailAddress: email,
                                organizationName: "",
                                tierDescription: plan.capitalized)
    }

    public func readStableLiveSecretData(gap: Duration) async -> (data: Data, email: String)? {
        guard let d1 = try? readLiveSecretData() else { return nil }
        try? await Task.sleep(for: gap)
        guard let d2 = try? readLiveSecretData(), d1 == d2,
              let email = Self.email(fromAuthJSON: d2) else { return nil }
        return (d2, email)
    }

    /// 쓰기 전 형태 검증 — Claude 경로가 CredentialsSnapshot 디코드로 하는 것과 같은 가드.
    /// auth.json의 실측 최상위 키(auth_mode/tokens/OPENAI_API_KEY) 중 하나는 있어야 한다.
    /// 빈 파일·손상·타 프로바이더 바이트(Claude 스냅샷 JSON)는 여기서 거부되고,
    /// 신원 없는 원본(API 키 전용)의 롤백 원복은 통과한다.
    public func writeLiveSecretData(_ data: Data) throws {
        guard recognizesSecret(data) else { throw CodexConfigError.unrecognizedSecret }
        try writeAtomic(data, to: env.codexAuthFile, mode: 0o600)
    }

    /// auth.json의 실측 최상위 키(auth_mode/tokens/OPENAI_API_KEY) 중 하나라도 있으면 Codex 형태.
    /// Claude secret(CredentialsSnapshot JSON)엔 이 키들이 없어 확실히 구분된다.
    public func recognizesSecret(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return obj["tokens"] != nil || obj["auth_mode"] != nil || obj["OPENAI_API_KEY"] != nil
    }

    // MARK: 신원 추출 (auth.json → id_token JWT payload)

    static func email(fromAuthJSON data: Data) -> String? {
        idTokenPayload(fromAuthJSON: data)?["email"] as? String
    }

    static func idTokenPayload(fromAuthJSON data: Data) -> [String: Any]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        return jwtPayload(idToken)
    }

    /// JWT 2번째 세그먼트(base64url)를 디코드한다. 서명 검증은 하지 않는다 —
    /// 로컬 파일에서 표시용 신원을 읽는 것뿐이고, 진위는 codex 자신이 판정한다.
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
