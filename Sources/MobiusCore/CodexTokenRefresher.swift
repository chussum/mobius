import Foundation

/// codex OAuth refresh 토큰으로 새 access/refresh/id 토큰을 발급받아 **비활성 codex 계정의 게이지
/// 조회 토큰을 되살린다**. Claude의 `OAuthTokenRefresher`/`FallbackAuthChecker`와 대칭이되, Codex는
/// 재인증 자동 감지 경로가 없으므로(CLAUDE.md) **게이지 전용 방화벽** 안에서만 쓴다 — 성공하면
/// 회전 토큰을 원자 저장해 usage 게이지를 살리고, 죽은 토큰(refresh_token_invalidated/invalid_grant)은
/// 엔진/persisted needsReauth를 절대 건드리지 않고 stale로 둔다.
///
/// ★ **활성(라이브) codex 계정은 절대 이 경로로 refresh하지 않는다** — 실행 중 codex 세션들이
///   시작 시점 토큰을 메모리에 들고 있어, 서버에서 refresh 토큰을 회전시키면 그 세션들의
///   in-memory 토큰이 무효화된다(클로버 → 세션 파괴, CLAUDE.md Codex 실패 기록). 호출측(AppState)이
///   `id != activeByProvider[.codex]`로 차단하고, 저장 직전 credential lock 안에서 다시 확인한다.
///
/// ★ **원자 capture-or-nothing**: 200은 refresh 토큰을 서버에서 **회전**시킨다(구 토큰 소비됨).
///   회전본을 저장하지 못하면 저장 스냅샷의 구 refresh 토큰이 죽어 그 계정이 벽돌이 된다. 따라서
///   200이면 auth.json 바이트를 재구성해 반환하고(호출측이 원자 저장), 그 외에는 **아무것도 반환하지
///   않는다**(.invalidated/.transient — 기존 스냅샷 보존).
///
/// 상수·요청 형식은 이 머신에서 실측 확인했다(추측 아님):
///   POST https://auth.openai.com/oauth/token
///   Content-Type: application/json
///   { client_id, grant_type:"refresh_token", refresh_token, scope:"openid profile email offline_access" }
///   200 → { access_token, refresh_token(회전 — 다를 수 있음), id_token, expires_in, ... }
///   401/400 { "error": { "code":"refresh_token_invalidated"|"invalid_grant", "type":"invalid_request_error" } }
///     → refresh 토큰 폐기(세션 종료) → 재로그인 필요, refresh로 되살릴 수 없음.
public enum CodexRefreshOutcome: Equatable, Sendable {
    /// 200 — 회전된 토큰을 반영한 새 auth.json 바이트. 호출측이 (활성 재확인+검증 후) 원자 저장한다.
    case refreshed(Data)
    /// refresh_token_invalidated / invalid_grant — 죽은 토큰. 게이지 전용이라 아무것도 마킹하지
    /// 않고(엔진/persisted reauth 미접촉), 호출측은 게이지를 stale로 두고 긴 쿨다운으로 물러난다.
    case invalidated
    /// 네트워크/5xx/기타 4xx/파싱 실패 — 일시적. 죽음으로 단정하지 않고 다음 기회에 재시도.
    case transient
}

public struct CodexTokenRefresher: Sendable {
    public static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!

    /// ★ 진실의 원천: codex `id_token`(JWT) payload의 `aud` 클레임 = 이 client_id,
    ///   `iss` 클레임 = 아래 issuer. 실측 id_token에서 정적 추출했다(스파이크가 이 요청 형식으로
    ///   정확한 OAuth 에러를 받아 형식이 맞음을 확인). 정상 codex CLI와 구분되지 않게 맞춘다.
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let issuer = "https://auth.openai.com"
    /// codex CLI가 refresh에 쓰는 스코프 세트(실측). offline_access가 회전된 refresh 토큰을 받는 조건.
    public static let scope = "openid profile email offline_access"

    /// 방어적 UA — codex CLI와 동일 형태. URLRequest.setValue만으로는 CFNetwork가 무시할 수 있어
    /// (TokenRefresher 실패 기록 14: Claude refresh UA 400) 세션 `httpAdditionalHeaders`로 못박는다.
    public static let userAgent = "codex_cli_rs/0.144.6 (macOS)"
    public static let uaSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["User-Agent": CodexTokenRefresher.userAgent]
        return URLSession(configuration: cfg)
    }()

    /// HTTP 전송(주입식) — 테스트는 캐닝된 응답을 넣는다(네트워크 0).
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
                = { try await CodexTokenRefresher.uaSession.data(for: $0) }) {
        self.transport = transport
    }

    /// 저장된 auth.json 스냅샷 바이트로 refresh를 시도한다. 저장/회전 판단은 하지 않는다 —
    /// 200이면 재구성 바이트를 `.refreshed`로 돌려주고, 원자 저장·활성 재확인은 호출측의 몫이다.
    public func refresh(authJSON: Data) async -> CodexRefreshOutcome {
        guard let rt = Self.refreshToken(fromAuthJSON: authJSON), !rt.isEmpty else {
            // refresh 토큰이 없으면 시도 불가. 게이지 방화벽상 죽음으로 단정하지 않고 물러난다.
            return .transient
        }
        let req = Self.buildRequest(refreshToken: rt)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await transport(req) }
        catch { return .transient }   // 네트워크 실패 = 일시적
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            guard let rebuilt = Self.rebuildAuthJSON(old: authJSON, response: data) else {
                return .transient     // 200인데 재구성 실패(빈 토큰/파싱) → 저장 안 함
            }
            return .refreshed(rebuilt)
        }
        return Self.classify(status: status, data: data)
    }

    /// codex refresh 요청(순수 — 테스트로 형식 검증). client_id/scope는 위 실측 상수.
    public static func buildRequest(refreshToken: String) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": scope,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 비-200 응답 판정(순수 — 테스트 대상). error.code가 죽음 코드면 `.invalidated`,
    /// 그 외(다른 4xx/5xx/파싱 실패)는 오탐 방지를 위해 `.transient`.
    public static func classify(status: Int, data: Data) -> CodexRefreshOutcome {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // 실측 형태: { "error": { "code": "...", "type": "invalid_request_error" } }
            // 방어: error가 문자열인 변형({"error":"invalid_grant"})도 함께 인식한다.
            let code: String?
            if let err = obj["error"] as? [String: Any] { code = err["code"] as? String }
            else { code = obj["error"] as? String }
            if code == "refresh_token_invalidated" || code == "invalid_grant" {
                return .invalidated   // refresh 토큰 폐기 확정 — refresh로 되살릴 수 없음
            }
        }
        return .transient
    }

    /// 회전된 토큰을 기존 auth.json에 병합해 새 바이트를 만든다(**순수 — 유닛 테스트 대상**).
    /// - access_token / id_token은 응답 값으로 갱신, refresh_token은 회전됐으면 새 값·아니면 기존 유지.
    /// - `last_refresh`를 현재 시각으로 갱신(codex 실측 형식 ISO8601).
    /// - account_id / auth_mode / OPENAI_API_KEY 등 나머지 필드는 그대로 보존한다.
    /// 응답에 access_token이 없거나 최종 refresh_token이 비면 nil(원자 저장 실패로 처리 — 반쪽 저장 금지).
    public static func rebuildAuthJSON(old: Data, response: Data, now: Date = Date()) -> Data? {
        guard var obj = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any],
              var tokens = obj["tokens"] as? [String: Any],
              let resp = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
              let at = resp["access_token"] as? String, !at.isEmpty
        else { return nil }
        // refresh_token은 회전될 수 있다(구 토큰 소비). 응답에 있으면 새 값, 없으면 기존 값 유지.
        let rotated = (resp["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rt = rotated ?? (tokens["refresh_token"] as? String)
        guard let rt, !rt.isEmpty else { return nil }   // 빈 refresh_token 저장 금지(brick 방지)
        tokens["access_token"] = at
        tokens["refresh_token"] = rt
        if let idToken = resp["id_token"] as? String, !idToken.isEmpty { tokens["id_token"] = idToken }
        obj["tokens"] = tokens
        obj["last_refresh"] = Self.iso8601.string(from: now)
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    /// tokens.refresh_token 추출(순수). 빈 문자열도 그대로 반환 — 빈/무 판정은 호출측 가드가 한다.
    public static func refreshToken(fromAuthJSON data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any] else { return nil }
        return tokens["refresh_token"] as? String
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
