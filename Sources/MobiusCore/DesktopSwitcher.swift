import Foundation

public enum DesktopSwitcherError: Error, Equatable {
    case desktopNotInstalled
    case noSnapshot
}

/// Claude Desktop(Electron)의 신원 저장소 파일을 프로필별로 보관/복원한다.
/// 주의: 반드시 Desktop 앱이 종료된 상태에서 호출할 것 (종료/재실행은 앱 계층 담당).
/// Cookies는 원본부터 safeStorage(Keychain 키)로 암호화되어 있다 — 같은 머신에서만 유효.
public final class DesktopSwitcher: Sendable {
    let env: MobiusEnvironment
    /// 로그인 신원을 담는 항목들 (캐시류는 제외 — 클수록 스왑이 느려지고 불필요)
    static let identityItems = ["Cookies", "Cookies-journal",
                                "Local Storage", "Session Storage", "IndexedDB"]

    public init(env: MobiusEnvironment) { self.env = env }

    public var isDesktopInstalled: Bool {
        FileManager.default.fileExists(atPath: env.desktopDataDir.path)
    }

    private func snapshotDir(for id: UUID) -> URL {
        env.desktopProfilesDir.appendingPathComponent(id.uuidString)
    }

    public func hasSnapshot(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: snapshotDir(for: id).path)
    }

    /// desktop-profiles 상위 디렉토리를 0700으로 보장 (이미 있어도 권한 재적용)
    private func ensureProfilesDir() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: env.desktopProfilesDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700],
                             ofItemAtPath: env.desktopProfilesDir.path)
    }

    /// 현재 Desktop 로그인 상태를 해당 프로필의 스냅샷으로 저장.
    /// 같은 볼륨의 temp 디렉토리에 복사를 마친 뒤 기존 스냅샷과 교체(remove+rename) —
    /// 복사 도중 실패해도 기존 스냅샷은 온전히 보존된다.
    public func capture(for id: UUID) throws {
        guard isDesktopInstalled else { throw DesktopSwitcherError.desktopNotInstalled }
        let fm = FileManager.default
        try ensureProfilesDir()
        let dir = snapshotDir(for: id)
        let tmp = env.desktopProfilesDir
            .appendingPathComponent("\(id.uuidString).tmp-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        do {
            for item in Self.identityItems {
                let src = env.desktopDataDir.appendingPathComponent(item)
                guard fm.fileExists(atPath: src.path) else { continue }
                try fm.copyItem(at: src, to: tmp.appendingPathComponent(item))
            }
            try? fm.removeItem(at: dir)
            try fm.moveItem(at: tmp, to: dir) // 같은 볼륨 rename — 부분 스냅샷이 남지 않음
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// 스냅샷을 Desktop 데이터 디렉토리로 복원 (Desktop 종료 상태 전제).
    /// 1단계: 스냅샷 전체를 스테이징으로 복사 — 여기서 실패하면 라이브 데이터 무손상.
    /// 2단계: 항목별 remove + rename만 수행해 실패 창을 복사가 아닌 rename 수준으로 축소.
    /// 한계: 항목 간 원자성은 없다 — 2단계 도중 실패하면 혼합 상태가 될 수 있다.
    /// (데이터 디렉토리 전체 스왑은 Desktop의 설정 등 비신원 파일까지 바꿔버리므로 불가.)
    public func restore(for id: UUID) throws {
        guard hasSnapshot(for: id) else { throw DesktopSwitcherError.noSnapshot }
        let fm = FileManager.default
        let dir = snapshotDir(for: id)
        try ensureProfilesDir()
        let staging = env.desktopProfilesDir
            .appendingPathComponent(".restore-tmp-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        do {
            for item in Self.identityItems {
                let src = dir.appendingPathComponent(item)
                guard fm.fileExists(atPath: src.path) else { continue }
                try fm.copyItem(at: src, to: staging.appendingPathComponent(item))
            }
            for item in Self.identityItems {
                let dst = env.desktopDataDir.appendingPathComponent(item)
                let src = staging.appendingPathComponent(item)
                try? fm.removeItem(at: dst)
                if fm.fileExists(atPath: src.path) {
                    try fm.moveItem(at: src, to: dst)
                }
            }
            try? fm.removeItem(at: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    public func deleteSnapshot(for id: UUID) {
        try? FileManager.default.removeItem(at: snapshotDir(for: id))
    }

    /// 강제 로그아웃: 현재 Desktop 신원 파일들을 임시 보관소로 옮겨(=로그아웃 상태로 만들고)
    /// 나중에 취소 시 되돌릴 수 있게 보관소 URL을 반환한다. Desktop 종료 상태에서 호출할 것.
    /// 옮길 게 없으면(이미 로그아웃) nil.
    @discardableResult
    public func stashLiveIdentity() throws -> URL? {
        guard isDesktopInstalled else { throw DesktopSwitcherError.desktopNotInstalled }
        let fm = FileManager.default
        try ensureProfilesDir()
        let stash = env.desktopProfilesDir
            .appendingPathComponent(".stash-\(UUID().uuidString)")
        try fm.createDirectory(at: stash, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var moved = false
        for item in Self.identityItems {
            let src = env.desktopDataDir.appendingPathComponent(item)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.moveItem(at: src, to: stash.appendingPathComponent(item))
            moved = true
        }
        if !moved { try? fm.removeItem(at: stash); return nil }
        return stash
    }

    /// 보관해둔 신원(강제 로그아웃 전 상태)을 Desktop으로 되돌린다. Desktop 종료 상태 전제.
    public func restoreStashedIdentity(from stash: URL) throws {
        let fm = FileManager.default
        for item in Self.identityItems {
            let src = stash.appendingPathComponent(item)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = env.desktopDataDir.appendingPathComponent(item)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
        }
        try? fm.removeItem(at: stash)
    }

    public func discardStash(_ stash: URL) {
        try? FileManager.default.removeItem(at: stash)
    }

    /// 신원 저장소 파일들(하위 파일 포함)의 가장 최근 수정 시각.
    /// 가이드형 자동 캡처의 로그인 완료 감지 신호로 쓴다 (없으면 nil).
    public func identityLastModified() -> Date? {
        let fm = FileManager.default
        var latest: Date?
        func note(_ url: URL) {
            guard let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate]
                as? Date else { return }
            if latest == nil || mtime > latest! { latest = mtime }
        }
        for item in Self.identityItems {
            let url = env.desktopDataDir.appendingPathComponent(item)
            guard fm.fileExists(atPath: url.path) else { continue }
            note(url)
            if let sub = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let child as URL in sub { note(child) }
            }
        }
        return latest
    }
}
