import CryptoKit
import Foundation

/// agy 키체인 값에서 꺼낸 자격증명. 실측(agy 1.5.12, 2026-11-19) 형태:
/// `go-keyring-base64:` + base64(JSON)
/// `{"token":{"access_token","token_type","refresh_token","expiry"(RFC3339),"expires_in"},
///   "auth_method":"consumer","id_token_email":"…"}`
public struct AntigravityCredential: Equatable, Sendable {
    public let email: String
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    public let expiry: Date
    /// JSON 최상위 키 집합 — 설치 전 라이브 값과 형식이 같은지 비교하는 데 쓴다(설계 5절).
    public let topLevelKeys: Set<String>
}

/// agy 키체인 값의 형태 검증과 해석(순수 함수). 저장·조회·설치가 모두 이 함수를 쓴다(설계 4.1).
/// **실측한 형태만 받는다** — 다른 값이 나오면 등록하지 않고, 실측 뒤에 넓힌다.
public enum AntigravitySecret {
    public static let prefix = "go-keyring-base64:"
    public static let keychainService = "gemini"
    public static let keychainAccount = "antigravity"

    public static func parse(_ data: Data) -> AntigravityCredential? {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(prefix),
              let decoded = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let obj = (try? JSONSerialization.jsonObject(with: decoded)) as? [String: Any],
              let token = obj["token"] as? [String: Any],
              let access = token["access_token"] as? String, !access.isEmpty,
              let refresh = token["refresh_token"] as? String, !refresh.isEmpty,
              let type = token["token_type"] as? String, !type.isEmpty,
              let expiryText = token["expiry"] as? String,
              let expiry = RFC3339.date(from: expiryText),
              let email = obj["id_token_email"] as? String, email.contains("@"),
              obj["auth_method"] as? String == "consumer"
        else { return nil }
        // expires_in 은 있으면 숫자여야 한다(Bool 이 NSNumber 로 오는 것은 거른다).
        if let raw = token["expires_in"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        }
        return AntigravityCredential(email: email, accessToken: access, refreshToken: refresh,
                                     tokenType: type, expiry: expiry,
                                     topLevelKeys: Set(obj.keys))
    }

    public static func recognizes(_ data: Data) -> Bool { parse(data) != nil }

    /// 라이브 값과 설치할 값의 형식이 같은가 — 접두사와 최상위 키 집합 비교.
    /// agy 업데이트로 값 형식이 바뀌었으면 설치를 멈춘다(설계 5절 마지막 행).
    public static func sameShape(_ a: Data, _ b: Data) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        return x.topLevelKeys == y.topLevelKeys
    }

    /// 값 비교용 지문(SHA-256). 메모리에만 두고 출력하지 않는다.
    public static func fingerprint(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// 테스트·격리 환경용 값 생성기 (실측 형태 그대로).
    public static func make(email: String, accessToken: String = "at", refreshToken: String = "rt",
                            expiry: String = "2026-11-19T23:11:25.245645+09:00",
                            authMethod: String = "consumer") -> Data {
        let json: [String: Any] = [
            "token": ["access_token": accessToken, "token_type": "Bearer",
                      "refresh_token": refreshToken, "expiry": expiry, "expires_in": 3599],
            "auth_method": authMethod,
            "id_token_email": email,
        ]
        let body = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return Data((prefix + body.base64EncodedString()).utf8)
    }
}

/// RFC3339 시각 해석 — 소수부가 있는 형태(자릿수 무관)와 없는 형태를 모두 받는다.
/// `ISO8601DateFormatter` 하나로는 둘 다 읽지 못하고, 6자리 소수부(실측 `.245645`)도 옵션에 따라
/// 실패한다. 소수부를 떼어 정수 초로 해석한 뒤 더한다(설계 4.3 「시각 해석」).
public enum RFC3339 {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func date(from text: String) -> Date? {
        guard let tIndex = text.firstIndex(where: { $0 == "T" || $0 == "t" }),
              let dot = text[tIndex...].firstIndex(of: ".") else {
            return formatter.date(from: text)
        }
        let afterDot = text.index(after: dot)
        let digitsEnd = text[afterDot...].firstIndex(where: { !$0.isNumber }) ?? text.endIndex
        let digits = text[afterDot..<digitsEnd]
        guard !digits.isEmpty, let fraction = Double("0." + digits) else { return nil }
        let whole = String(text[..<dot]) + String(text[digitsEnd...])
        return formatter.date(from: whole)?.addingTimeInterval(fraction)
    }
}
