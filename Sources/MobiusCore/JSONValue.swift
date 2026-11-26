import Foundation

/// 해석하지 않고 보존만 하는 JSON 값. accounts.json 의 **모르는 provider 항목**과 프로바이더
/// 맵의 **모르는 키**를 원본 그대로 다시 쓰는 데 쓴다(설계 4.4-3). 미래 버전이 더한 프로바이더를
/// 이 버전이 읽고 저장해도 그 계정이 사라지지 않게 한다.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// 객체의 문자열 필드 (없거나 문자열이 아니면 nil)
    func stringField(_ key: String) -> String? {
        guard case .object(let o) = self, case .string(let s)? = o[key] else { return nil }
        return s
    }
}
