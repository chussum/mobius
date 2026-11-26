import Foundation

// MARK: - 응답 해석 (설계 4.3)

/// `fetchAvailableModels` 응답의 모델 한 줄.
public struct AntigravityModelQuota: Equatable, Sendable {
    public let id: String
    public let displayName: String?
    /// nil = **값 모름**(resetTime 은 있는데 remainingFraction 이 빠짐). proto3 JSON 이 기본값 0 을
    /// 내보내지 않아 소진이 이 모양으로 올 수 있지만(추정, 2.1 미확인 3), 확인 전에는 판정 근거로
    /// 삼지 않는다.
    public let remainingFraction: Double?
    public let resetTime: Date

    public init(id: String, displayName: String?, remainingFraction: Double?, resetTime: Date) {
        self.id = id; self.displayName = displayName
        self.remainingFraction = remainingFraction; self.resetTime = resetTime
    }

    /// 명시적인 0 (판정에 쓰는 "소진")
    public var isExplicitlyExhausted: Bool { remainingFraction == 0 }
    /// 명시적으로 0 보다 크다 (판정에 쓰는 "여유")
    public var hasExplicitHeadroom: Bool { (remainingFraction ?? 0) > 0 }
    /// 1 = 아직 사용 안 함 — 이때 resetTime 은 "요청 시각 + 창 길이"라 표시에 쓰지 않는다.
    public var isUnused: Bool { remainingFraction == 1 }

    /// 모델 ID 의 계열 라벨: gemini- → "Gemini", claude- → "Claude", 그 밖은 nil.
    public var family: String? { AntigravityQuotaReport.family(ofModelID: id) }
}

/// 한 번의 조회 결과. 판정(4.7)은 모델 ID 단위로, 게이지는 버킷 줄로 쓴다.
public struct AntigravityQuotaReport: Equatable, Sendable {
    public let models: [AntigravityModelQuota]
    /// `remainingFraction` 이 빠진 모델이 있었는가(처음 보면 로그 한 줄 — 실측 근거 수집).
    public let hasUnknownFraction: Bool
    public let fetchedAt: Date

    public init(models: [AntigravityModelQuota], hasUnknownFraction: Bool, fetchedAt: Date) {
        self.models = models; self.hasUnknownFraction = hasUnknownFraction; self.fetchedAt = fetchedAt
    }

    public func model(_ id: String) -> AntigravityModelQuota? { models.first { $0.id == id } }

    public static func family(ofModelID id: String) -> String? {
        if id.hasPrefix("gemini-") { return "Gemini" }
        if id.hasPrefix("claude-") { return "Claude" }
        return nil
    }

    /// 모델 집합의 표시 라벨 — 계열이 둘 이상이면 "Gemini·Claude" 처럼 잇는다.
    public static func label(forModelIDs ids: [String], displayNames: [String: String] = [:]) -> String {
        var seen: [String] = []
        for id in ids {
            let name = family(ofModelID: id) ?? displayNames[id] ?? id
            if !seen.contains(name) { seen.append(name) }
        }
        return seen.joined(separator: "·")
    }

    /// 응답 JSON → 보고서. `quotaInfo` 가 없거나 `resetTime` 이 없는 모델(`tab_*`)은 뺀다.
    public static func parse(_ data: Data, now: Date = Date()) -> AntigravityQuotaReport? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = obj["models"] as? [String: Any] else { return nil }
        var out: [AntigravityModelQuota] = []
        var unknown = false
        for (id, raw) in models {
            guard let m = raw as? [String: Any],
                  let quota = m["quotaInfo"] as? [String: Any],
                  let resetText = quota["resetTime"] as? String,
                  let reset = RFC3339.date(from: resetText) else { continue }
            let fraction: Double?
            if let n = quota["remainingFraction"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                fraction = n.doubleValue
            } else {
                fraction = nil
                unknown = true
            }
            out.append(AntigravityModelQuota(id: id, displayName: m["displayName"] as? String,
                                             remainingFraction: fraction, resetTime: reset))
        }
        out.sort { $0.id < $1.id }
        return AntigravityQuotaReport(models: out, hasUnknownFraction: unknown, fetchedAt: now)
    }

    // MARK: 게이지 줄 (표시 전용)

    /// 같은 응답 안에서 `(remainingFraction, resetTime)` 이 같은 모델을 한 버킷으로 묶은 줄들.
    /// - 라벨은 버킷 첫 모델 ID 의 계열(Gemini/Claude), 그 밖은 첫 모델의 표시명. 같은 라벨이 둘
    ///   이상이면 뒤에 번호를 붙인다(카드가 라벨을 줄 ID 로 쓴다).
    /// - 값 모름 모델은 `unverified` 줄로, 다 쓴 것처럼(percent 100) 보인다.
    /// - 사용 전 모델(1)은 묶지 않고, 같은 계열의 버킷 줄이 없을 때만 "아직 사용 안 함" 줄 하나
    ///   (`resetsAt == nil`)로 보인다. 계열이 없는 모델의 사용 전 줄은 보이지 않는다(Gemini/Claude
    ///   두 줄 결정 — 설계 0절).
    /// - percent 는 **사용한 비율**(100 × (1 − remainingFraction)) — Claude·Codex 게이지와 같은 방향.
    public func gaugeLines() -> [ScopedUsageLimit] {
        struct Key: Hashable { let fraction: Double?; let reset: Date }
        var buckets: [Key: [AntigravityModelQuota]] = [:]
        var unusedFamilies: [String] = []
        for m in models {
            if m.isUnused {
                if let f = m.family, !unusedFamilies.contains(f) { unusedFamilies.append(f) }
                continue
            }
            buckets[Key(fraction: m.remainingFraction, reset: m.resetTime), default: []].append(m)
        }
        func baseLabel(_ ms: [AntigravityModelQuota]) -> String {
            let first = ms[0]
            return first.family ?? first.displayName ?? first.id
        }
        let ordered = buckets.sorted { a, b in
            let la = baseLabel(a.value), lb = baseLabel(b.value)
            if la != lb { return Self.labelOrder(la) < Self.labelOrder(lb) || (Self.labelOrder(la) == Self.labelOrder(lb) && la < lb) }
            return a.key.reset < b.key.reset
        }
        var lines: [ScopedUsageLimit] = []
        var labelCount: [String: Int] = [:]
        var bucketFamilies = Set<String>()
        for (key, ms) in ordered {
            let base = baseLabel(ms)
            bucketFamilies.insert(base)
            labelCount[base, default: 0] += 1
            let n = labelCount[base]!
            let label = n == 1 ? base : "\(base) \(n)"
            if let f = key.fraction {
                lines.append(ScopedUsageLimit(label: label, percent: max(0, min(100, (1 - f) * 100)),
                                              resetsAt: key.reset))
            } else {
                lines.append(ScopedUsageLimit(label: label, percent: 100, resetsAt: key.reset,
                                              unverified: true))
            }
        }
        for f in unusedFamilies.sorted(by: { Self.labelOrder($0) < Self.labelOrder($1) })
            where !bucketFamilies.contains(f) {
            lines.append(ScopedUsageLimit(label: f, percent: 0, resetsAt: nil))
        }
        return lines
    }

    private static func labelOrder(_ label: String) -> Int {
        label == "Gemini" ? 0 : label == "Claude" ? 1 : 2
    }

    public func usageSnapshot() -> UsageSnapshot {
        UsageSnapshot(fiveHourPercent: nil, fiveHourResetsAt: nil,
                      sevenDayPercent: nil, sevenDayResetsAt: nil,
                      scopedLimits: gaugeLines(), fetchedAt: fetchedAt)
    }
}

// MARK: - 조회 (설계 4.3)

public enum AntigravityUsageError: Error, Equatable {
    /// 401/403 — 토큰 거부(만료 등). 게이지만 비우고 아무것도 마킹하지 않는다.
    case unauthorized
    case http(Int)
    case malformed
}

/// `fetchAvailableModels` 조회. 자격증명이 실리므로 **ephemeral 세션**을 쓰고(실패 기록 18),
/// User-Agent 는 세션 `httpAdditionalHeaders` 로 싣는다(실패 기록 14 — 없으면 403 실측).
public enum AntigravityUsageFetcher {
    public static let endpoint =
        URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
    /// 실측 버전. 설치된 agy 의 버전을 못 얻으면 이 값을 쓴다.
    public static let fallbackVersion = "1.5.12"

    public static func userAgent(version: String?) -> String {
        "antigravity-cli/\(version ?? fallbackVersion)"
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: URLSession] = [:]

    /// UA 별 ephemeral 세션 (디스크 캐시 없음).
    static func session(userAgent: String) -> URLSession {
        sessionLock.withLock {
            if let s = sessions[userAgent] { return s }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.urlCache = nil
            cfg.httpAdditionalHeaders = ["User-Agent": userAgent]
            let s = URLSession(configuration: cfg)
            sessions[userAgent] = s
            return s
        }
    }

    public static func defaultTransport(userAgent: String) -> Transport {
        let s = session(userAgent: userAgent)
        return { try await s.data(for: $0) }
    }

    public static func request(accessToken: String) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = 15
        return req
    }

    public static func fetch(accessToken: String, transport: Transport,
                             now: Date = Date()) async throws -> AntigravityQuotaReport {
        let (data, resp) = try await transport(request(accessToken: accessToken))
        guard let http = resp as? HTTPURLResponse else { throw AntigravityUsageError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw AntigravityUsageError.unauthorized }
        guard http.statusCode == 200 else { throw AntigravityUsageError.http(http.statusCode) }
        guard let report = AntigravityQuotaReport.parse(data, now: now) else {
            throw AntigravityUsageError.malformed
        }
        return report
    }
}

// MARK: - 설치된 agy 바이너리 (설계 4.3 「client secret 은 저장소에 넣지 않는다」)

/// 설치된 agy 의 실제 바이너리 위치와 그 안의 값들. **agy 를 실행하지 않는다** — 파일만 읽는다
/// (agy 실행 위치를 래퍼로 제한한 환경이 있다 — 설치 확인·버전·secret 읽기에 agy 를 띄우지 않는다).
public enum AntigravityInstall {
    /// 런처(`agy` 명령 경로)에서 실제 바이너리까지 따라간다. 심볼릭 링크와, `exec` 로 다른
    /// 실행 파일을 부르는 셸 래퍼(Homebrew cask 래퍼, 사용자의 `~/bin/agy` 같은 가드 래퍼)를
    /// 차례로 따라간다. 따라갈 수 없으면 nil.
    public static func resolveBinary(from launcher: URL, maxDepth: Int = 6) -> URL? {
        var current = launcher.resolvingSymlinksInPath()
        for _ in 0..<maxDepth {
            guard let head = try? FileHandle(forReadingFrom: current).read(upToCount: 2),
                  head == Data("#!".utf8) else { return current }   // 스크립트가 아니면 바이너리
            guard let text = try? String(contentsOf: current, encoding: .utf8),
                  let next = execTarget(inScript: text, home: FileManager.default.homeDirectoryForCurrentUser.path)
            else { return nil }
            current = URL(fileURLWithPath: next).resolvingSymlinksInPath()
        }
        return nil
    }

    /// 셸 스크립트에서 `exec` 대상 경로를 찾는다. `NAME="${X:-기본값}"` 같은 할당은 기본값으로,
    /// `$HOME`·`~` 는 홈으로 바꾼다. 실행 가능한 절대 경로가 나오는 첫 `exec` 를 쓴다.
    static func execTarget(inScript text: String, home: String) -> String? {
        var vars: [String: String] = ["HOME": home]
        func expand(_ s: String) -> String {
            var t = s
            if t.hasPrefix("~/") { t = home + t.dropFirst(1) }
            // ${NAME:-default}
            while let r = t.range(of: #"\$\{([A-Za-z_][A-Za-z0-9_]*):-([^}]*)\}"#, options: .regularExpression) {
                let inner = String(t[r].dropFirst(2).dropLast())
                let parts = inner.components(separatedBy: ":-")
                t.replaceSubrange(r, with: vars[parts[0]] ?? parts.dropFirst().joined(separator: ":-"))
            }
            while let r = t.range(of: #"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"#, options: .regularExpression) {
                let name = String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: "${}"))
                t.replaceSubrange(r, with: vars[name] ?? "")
            }
            return t
        }
        func unquote(_ s: Substring) -> String {
            String(s).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if let eq = line.firstIndex(of: "="), !line.contains(" "),
               line[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                vars[String(line[..<eq])] = expand(unquote(line[line.index(after: eq)...]))
                continue
            }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let i = tokens.firstIndex(of: "exec"), i + 1 < tokens.count else { continue }
            let target = expand(unquote(tokens[i + 1]))
            if target.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: target) { return target }
        }
        return nil
    }

    /// 바이너리 안의 Google desktop client secret 후보(`GOCSPX-` + 28자). 값은 메모리에만 둔다.
    public static func clientSecretCandidates(inBinary url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        return clientSecretCandidates(in: data)
    }

    static func clientSecretCandidates(in data: Data) -> [String] {
        let marker = Data("GOCSPX-".utf8)
        let allowed = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".utf8))
        var found: [String] = []
        var start = data.startIndex
        while let r = data.range(of: marker, in: start..<data.endIndex) {
            let tailEnd = data.index(r.upperBound, offsetBy: 28, limitedBy: data.endIndex) ?? data.endIndex
            let tail = data[r.upperBound..<tailEnd]
            if tail.count == 28, tail.allSatisfy({ allowed.contains($0) }) {
                let s = "GOCSPX-" + String(decoding: tail, as: UTF8.self)
                if !found.contains(s) { found.append(s) }
            }
            start = r.upperBound
        }
        return found
    }

    /// Caskroom 경로(`…/Caskroom/antigravity-cli/<버전>[,빌드]/antigravity`)에서 버전을 읽는다.
    public static func version(fromBinaryPath path: String) -> String? {
        let comps = path.split(separator: "/")
        guard let i = comps.firstIndex(of: "antigravity-cli"), i + 1 < comps.count else { return nil }
        let v = comps[i + 1].split(separator: ",").first.map(String.init) ?? ""
        return v.isEmpty ? nil : v
    }
}

// MARK: - 토큰 (메모리에서만 갱신 — 설계 4.3)

public enum AntigravityTokenResult: Equatable, Sendable {
    case token(String)
    /// 갱신할 수 없다(client secret 을 못 찾음 등). 게이지는 마지막 값을 흐리게, 자동 전환 후보는
    /// "확인 불가".
    case unavailable
    /// refresh 토큰이 거부됨(invalid_grant). 게이지만 비우고 계정별 긴 백오프 — needsReauth·엔진은
    /// 건드리지 않는다(Codex 게이지 방화벽과 같은 계약).
    case invalidGrant
    /// 네트워크·5xx 등 일시 실패.
    case transient
}

/// access 토큰 공급자. 만료된 토큰은 **메모리에서만** 갱신하고 저장본·라이브 키체인을 바꾸지 않는다.
/// agy 의 refresh 토큰은 회전하지 않으므로(실측) 저장할 이유가 없고, 활성 계정의 agy 세션도
/// 망가뜨리지 않는다(설계 4.3).
public final class AntigravityTokenSource: @unchecked Sendable {
    /// 공개 식별자(실측으로 갱신에 성공한 client).
    public static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let transport: Transport
    /// client secret 후보 공급(처음 갱신할 때 한 번 부른다). 바이너리에서 실행 중에 읽는다.
    let secretCandidates: @Sendable () -> [String]

    private let lock = NSLock()
    private var candidatesLoaded = false
    private var candidates: [String] = []
    private var workingSecret: String?
    /// refresh 토큰 지문 → (access 토큰, 만료)
    private var cache: [Data: (String, Date)] = [:]

    public init(transport: @escaping Transport = AntigravityTokenSource.defaultTransport,
                secretCandidates: @escaping @Sendable () -> [String]) {
        self.transport = transport
        self.secretCandidates = secretCandidates
    }

    public static let defaultTransport: Transport = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        let s = URLSession(configuration: cfg)
        return { try await s.data(for: $0) }
    }()

    /// 만료 1분 전부터 갱신 대상으로 본다.
    static let expiryMargin: TimeInterval = 60

    public func accessToken(for cred: AntigravityCredential, now: Date = Date()) async -> AntigravityTokenResult {
        if cred.expiry > now.addingTimeInterval(Self.expiryMargin) { return .token(cred.accessToken) }
        let key = AntigravitySecret.fingerprint(Data(cred.refreshToken.utf8))
        if let (tok, exp) = lock.withLock({ cache[key] }), exp > now.addingTimeInterval(Self.expiryMargin) {
            return .token(tok)
        }
        let (known, pool): (String?, [String]) = lock.withLock {
            if !candidatesLoaded { candidates = secretCandidates(); candidatesLoaded = true }
            return (workingSecret, candidates)
        }
        let order = known.map { [$0] + pool.filter { $0 != known } } ?? pool
        guard !order.isEmpty else { return .unavailable }
        for secret in order {
            switch await refresh(cred.refreshToken, secret: secret) {
            case .ok(let token, let expiresIn):
                lock.withLock {
                    workingSecret = secret
                    cache[key] = (token, now.addingTimeInterval(expiresIn))
                }
                return .token(token)
            case .wrongClient:
                continue      // 이 후보는 아니다 — invalid_client 는 계정에 영향이 없다
            case .invalidGrant:
                return .invalidGrant
            case .transient:
                return .transient
            }
        }
        return .unavailable
    }

    private enum Outcome { case ok(String, TimeInterval), wrongClient, invalidGrant, transient }

    private func refresh(_ refreshToken: String, secret: String) async -> Outcome {
        var req = URLRequest(url: Self.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "client_secret", value: secret),
        ]
        req.httpBody = Data((comps.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B").utf8)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await transport(req),
              let http = resp as? HTTPURLResponse else { return .transient }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 200, let token = obj["access_token"] as? String, !token.isEmpty {
            let expiresIn = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            return .ok(token, expiresIn)
        }
        switch obj["error"] as? String {
        case "invalid_client", "unauthorized_client": return .wrongClient
        case "invalid_grant": return .invalidGrant
        default: return .transient   // 5xx·형식 오류 등 — 계정 상태를 단정하지 않는다
        }
    }
}
