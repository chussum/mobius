import Foundation
@testable import MobiusCore

/// 실측 auth.json 구조의 테스트 fixture. id_token은 (헤더).(payload).(서명) 형태로
/// 직접 조립한다 — 서명 검증을 하지 않으므로 유효한 서명이 필요 없다.
enum CodexFixtures {
    static func authJSON(email: String = "dev@corp.com", plan: String = "pro",
                         accessToken: String = "at-1") -> Data {
        func b64url(_ obj: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload: [String: Any] = [
            "email": email,
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": plan,
                "chatgpt_account_id": "acct-123",
            ],
        ]
        let jwt = "\(b64url(["alg": "RS256"])).\(b64url(payload)).fakesig"
        let auth: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": ["id_token": jwt, "access_token": accessToken,
                       "refresh_token": "rt-1", "account_id": "acct-123"],
            "last_refresh": "2026-07-12T10:00:00Z",
            "OPENAI_API_KEY": NSNull(),
        ]
        return try! JSONSerialization.data(withJSONObject: auth)
    }
}
