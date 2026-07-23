import Foundation

/// codex `auth.json`(원본 바이트)에서 네트워크 게이지 조회에 필요한 값만 뽑는 순수 판독기.
///
/// CodexConfigIO(자격증명 읽기·쓰기·신원 추출)와 분리한다 — 이쪽은 **읽기 전용 조회용**이고
/// 자격증명을 절대 쓰지 않는다. JWT 파싱은 CodexConfigIO.jwtPayload를 재사용한다.
public enum CodexAuthBlob {
    /// tokens.access_token — usage 엔드포인트 `Authorization: Bearer` 헤더용.
    public static func accessToken(fromAuthJSON data: Data) -> String? {
        tokens(fromAuthJSON: data)?["access_token"] as? String
    }

    /// tokens.account_id — `ChatGPT-Account-Id` 헤더용.
    public static func accountId(fromAuthJSON data: Data) -> String? {
        tokens(fromAuthJSON: data)?["account_id"] as? String
    }

    /// access_token(우선) 또는 id_token JWT의 `exp`(epoch초) 클레임 → 만료 시각.
    /// **최적화 신호일 뿐**: 명백히 만료됐으면 네트워크 호출을 아끼려는 용도다(GET엔 토큰 회전이
    /// 없어 만료 토큰으로 조회하면 401만 받는다). 못 읽으면 nil — 그래도 조회는 허용된다
    /// (401은 게이지 프로브에서 무해). access_token이 불투명(비 JWT) 토큰이면 id_token으로 폴백.
    public static func accessTokenExpiry(fromAuthJSON data: Data) -> Date? {
        guard let tokens = tokens(fromAuthJSON: data) else { return nil }
        for key in ["access_token", "id_token"] {
            guard let jwt = tokens[key] as? String,
                  let payload = CodexConfigIO.jwtPayload(jwt),
                  let exp = payload["exp"] else { continue }
            let secs: Double
            if let d = exp as? Double { secs = d }
            else if let i = exp as? Int { secs = Double(i) }
            else { continue }
            return Date(timeIntervalSince1970: secs)  // JWT exp는 규격상 초 — ms 변환 불필요
        }
        return nil
    }

    static func tokens(fromAuthJSON data: Data) -> [String: Any]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj["tokens"] as? [String: Any]
    }
}
