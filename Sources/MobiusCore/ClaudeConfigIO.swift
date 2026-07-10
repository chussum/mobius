import Foundation

public enum ClaudeConfigError: Error { case malformedClaudeJSON }

/// Claude Code 자격증명 3곳(Keychain / .credentials.json / ~/.claude.json oauthAccount)의 읽기·쓰기.
public struct ClaudeConfigIO: Sendable {
    let env: MobiusEnvironment
    let keychain: KeychainClient

    public init(env: MobiusEnvironment, keychain: KeychainClient) {
        self.env = env
        self.keychain = keychain
    }

    // MARK: 읽기

    /// 현재 로그인 상태의 스냅샷. Keychain 항목이 없으면(로그아웃 상태) nil.
    public func readLiveSnapshot() throws -> CredentialsSnapshot? {
        guard let blob = try keychain.read(service: env.claudeKeychainService,
                                           account: env.claudeKeychainAccount) else { return nil }
        let fileData = (try? Data(contentsOf: env.credentialsFile)) ?? blob
        var oauthJSON: Data?
        if let block = try readOAuthAccountDict() {
            oauthJSON = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
        }
        return CredentialsSnapshot(keychainBlob: blob, credentialsFileData: fileData,
                                   oauthAccountJSON: oauthJSON)
    }

    public func readOAuthAccountDict() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: env.claudeJSON) else { return nil }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConfigError.malformedClaudeJSON
        }
        return dict["oauthAccount"] as? [String: Any]
    }

    public func liveEmail() throws -> String? {
        try readOAuthAccountDict()?["emailAddress"] as? String
    }

    // MARK: 쓰기

    public func writeLiveSnapshot(_ snap: CredentialsSnapshot) throws {
        try keychain.write(service: env.claudeKeychainService,
                           account: env.claudeKeychainAccount, data: snap.keychainBlob)
        try writeAtomic(snap.credentialsFileData, to: env.credentialsFile, mode: 0o600)
        try patchOAuthAccount(snap.oauthAccountJSON)
    }

    private func patchOAuthAccount(_ oauthJSON: Data?) throws {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: env.claudeJSON) {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ClaudeConfigError.malformedClaudeJSON }
            dict = existing
        }
        if let oauthJSON,
           let block = try JSONSerialization.jsonObject(with: oauthJSON) as? [String: Any] {
            dict["oauthAccount"] = block
        } else {
            dict.removeValue(forKey: "oauthAccount")
        }
        let out = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try writeAtomic(out, to: env.claudeJSON, mode: 0o600)
    }

    func writeAtomic(_ data: Data, to url: URL, mode: Int16) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
