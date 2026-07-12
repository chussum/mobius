import Foundation

/// OAuth refresh 토큰으로 새 access 토큰을 발급받아 **폴백(비활성) 계정의 로그인 생사를
/// 미리 판정**하고, 성공 시 사용량 게이지까지 살린다. 활성(라이브) 계정은 claude가 직접
/// 관리하므로 **절대 이 경로로 refresh하지 않는다**(동시 로테이션 = 세션 파괴).
///
/// 상수·요청 형식은 claude 2.1.207 바이너리에서 정적 확인한 실측값이다(추측 아님):
///   POST https://platform.claude.com/v1/oauth/token
///   Content-Type: application/json
///   { grant_type:"refresh_token", refresh_token, client_id:CLIENT_ID, scope:"<scopes 공백조인>" }
///   200 → { access_token, refresh_token(회전됨), expires_in, refresh_token_expires_in?, scope? }
/// claude의 refresh 함수와 동일하게 맞춰 정상 클라이언트와 구분되지 않게 한다(계정 리스크 최소화).

public struct RefreshedTokens: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String          // 회전된 새 refresh 토큰 — 반드시 저장해야 함
    public let expiresAtMs: Int               // epoch ms
    public let refreshTokenExpiresAtMs: Int?   // epoch ms (응답이 주면)
    public let scopes: [String]?
    public init(accessToken: String, refreshToken: String, expiresAtMs: Int,
                refreshTokenExpiresAtMs: Int?, scopes: [String]?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAtMs = expiresAtMs; self.refreshTokenExpiresAtMs = refreshTokenExpiresAtMs
        self.scopes = scopes
    }
}

public enum TokenRefresherError: Error, Equatable {
    case invalidGrant   // refresh 토큰 폐기/만료 → 진짜 재로그인 필요 (확정 신호)
    case transient      // 네트워크/5xx/기타 4xx → 일시적, 다음에 재시도 (죽음으로 단정 금지)
    case malformed      // 200인데 응답 파싱 실패
}

public protocol TokenRefresher: Sendable {
    /// now는 expiresAt(절대 epoch) 계산용 — 테스트 주입 가능.
    func refresh(refreshToken: String, scopes: [String], now: Date) async throws -> RefreshedTokens
}

public struct OAuthTokenRefresher: TokenRefresher {
    public static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// ★ 필수: 이 UA가 없으면 서버가 "invalid_request_format"(400)로 거부하고, 기본 UA는
    /// Cloudflare가 봇으로 차단(403 code 1010)한다(실측). claude CLI와 동일 UA로 맞춰
    /// 서버가 받아들이게 하고, 동시에 정상 클라이언트와 구분되지 않게 한다(블락 위험 최소화).
    /// dfe() 실측 포맷: "claude-cli/<version> (external, cli)".
    public static let userAgent = "claude-cli/2.1.207 (external, cli)"

    /// HTTP 전송(주입식) — 테스트는 캐닝된 응답을 넣는다.
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// UA를 **세션 레벨**에서 못박는 전용 세션. URLRequest.setValue("User-Agent")만으로는
    /// URLSession이 무시하고 CFNetwork 기본 UA를 보내는 경우가 있어(실측: 서버가
    /// invalid_request_format 400) httpAdditionalHeaders로 강제한다.
    public static let uaSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["User-Agent": OAuthTokenRefresher.userAgent]
        return URLSession(configuration: cfg)
    }()

    public init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
                = { try await OAuthTokenRefresher.uaSession.data(for: $0) }) {
        self.transport = transport
    }

    /// claude와 동일한 refresh 요청을 만든다(순수 — 테스트로 형식 검증).
    public static func buildRequest(refreshToken: String, scopes: [String]) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scopes.joined(separator: " "),
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 응답 판정(순수 — 테스트로 회전/invalid_grant/5xx 검증).
    public static func parseResponse(status: Int, data: Data, now: Date) throws -> RefreshedTokens {
        if status == 200 {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let at = obj["access_token"] as? String,
                  let rt = obj["refresh_token"] as? String
            else { throw TokenRefresherError.malformed }
            let nowMs = Int(now.timeIntervalSince1970 * 1000)
            let expiresAtMs = nowMs + (intValue(obj["expires_in"]) ?? 3600) * 1000
            let rteMs = intValue(obj["refresh_token_expires_in"]).map { nowMs + $0 * 1000 }
            let scopes = (obj["scope"] as? String)?
                .split(separator: " ").map(String.init)
            return RefreshedTokens(accessToken: at, refreshToken: rt, expiresAtMs: expiresAtMs,
                                   refreshTokenExpiresAtMs: rteMs, scopes: scopes)
        }
        // invalid_grant = refresh 토큰 폐기 → 확정 죽음. 그 외 오류는 오탐 방지 위해 transient.
        if (400...499).contains(status) {
            let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if err == "invalid_grant" { throw TokenRefresherError.invalidGrant }
            throw TokenRefresherError.transient
        }
        throw TokenRefresherError.transient
    }

    public func refresh(refreshToken: String, scopes: [String], now: Date) async throws -> RefreshedTokens {
        let req = Self.buildRequest(refreshToken: refreshToken, scopes: scopes)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await transport(req) }
        catch { throw TokenRefresherError.transient } // 네트워크 실패 = 일시적
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.parseResponse(status: status, data: data, now: now)
    }

    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}

/// Claude 자격증명 blob(JSON) 읽기·재구성. blob은 `{claudeAiOauth:{...}}`(실측) 또는 평면 형태
/// 둘 다 허용한다(UsageFetcher와 동일 관용성).
public enum CredentialBlob {
    private static func tokenDict(_ obj: [String: Any]) -> [String: Any]? {
        (obj["claudeAiOauth"] as? [String: Any]) ?? obj
    }
    private static func msDate(_ raw: Any?) -> Date? {
        let n: Double
        if let d = raw as? Double { n = d } else if let i = raw as? Int { n = Double(i) } else { return nil }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }

    public static func refreshToken(from blob: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let rt = tokenDict(obj)?["refreshToken"] as? String, !rt.isEmpty else { return nil }
        return rt   // 빈 문자열은 손상/미완성 스냅샷 → 없음(nil)으로 취급 → 재로그인 유도
    }
    public static func scopes(from blob: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let sc = tokenDict(obj)?["scopes"] as? [String] else { return [] }
        return sc
    }
    public static func refreshTokenExpiresAt(from blob: Data) -> Date? {
        guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] else { return nil }
        return msDate(tokenDict(obj)?["refreshTokenExpiresAt"])
    }
    /// 네트워크 0 로컬 선검사: refresh 토큰이 **확실히** 만료됐는가.
    /// 값이 없거나 미래면 false(죽었다고 단정하지 않음 — 오탐 방지).
    public static func isRefreshTokenExpired(blob: Data, now: Date) -> Bool {
        guard let exp = refreshTokenExpiresAt(from: blob) else { return false }
        return exp < now
    }

    /// 갱신된 토큰을 blob에 반영해 새 blob을 만든다(다른 필드는 보존).
    public static func rebuild(blob: Data, applying t: RefreshedTokens) -> Data? {
        guard var obj = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any] else { return nil }
        if var oauth = obj["claudeAiOauth"] as? [String: Any] {
            apply(&oauth, t); obj["claudeAiOauth"] = oauth
        } else {
            apply(&obj, t)
        }
        return try? JSONSerialization.data(withJSONObject: obj)
    }
    private static func apply(_ d: inout [String: Any], _ t: RefreshedTokens) {
        d["accessToken"] = t.accessToken
        d["refreshToken"] = t.refreshToken
        d["expiresAt"] = t.expiresAtMs
        if let rte = t.refreshTokenExpiresAtMs { d["refreshTokenExpiresAt"] = rte }
        if let sc = t.scopes, !sc.isEmpty { d["scopes"] = sc }
    }
}

public extension CredentialsSnapshot {
    /// 갱신된 토큰을 keychainBlob·credentialsFileData 양쪽에 일관되게 반영한 새 스냅샷.
    /// oauthAccountJSON(이메일/조직 메타)은 토큰과 무관하므로 그대로 둔다.
    /// keychainBlob 재구성 실패면 nil(원자 저장 실패로 처리 — 절대 반쪽 저장 안 함).
    func applyingRefreshedTokens(_ t: RefreshedTokens) -> CredentialsSnapshot? {
        guard let newBlob = CredentialBlob.rebuild(blob: keychainBlob, applying: t) else { return nil }
        let newFile = CredentialBlob.rebuild(blob: credentialsFileData, applying: t) ?? newBlob
        return CredentialsSnapshot(keychainBlob: newBlob, credentialsFileData: newFile,
                                   oauthAccountJSON: oauthAccountJSON)
    }
}
