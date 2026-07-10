import Foundation

public enum DesktopSwitcherError: Error, Equatable {
    case desktopNotInstalled
    case noSnapshot
}

/// Claude Desktop(Electron)의 신원 저장소 파일을 프로필별로 보관/복원한다.
/// 주의: 반드시 Desktop 앱이 종료된 상태에서 호출할 것 (종료/재실행은 앱 계층 담당).
/// Cookies는 원본부터 safeStorage(Keychain 키)로 암호화되어 있다 — 같은 머신에서만 유효.
public final class DesktopSwitcher: @unchecked Sendable {
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

    /// 현재 Desktop 로그인 상태를 해당 프로필의 스냅샷으로 저장
    public func capture(for id: UUID) throws {
        guard isDesktopInstalled else { throw DesktopSwitcherError.desktopNotInstalled }
        let dir = snapshotDir(for: id)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        for item in Self.identityItems {
            let src = env.desktopDataDir.appendingPathComponent(item)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(item))
        }
    }

    /// 스냅샷을 Desktop 데이터 디렉토리로 복원 (Desktop 종료 상태 전제)
    public func restore(for id: UUID) throws {
        guard hasSnapshot(for: id) else { throw DesktopSwitcherError.noSnapshot }
        let dir = snapshotDir(for: id)
        for item in Self.identityItems {
            let dst = env.desktopDataDir.appendingPathComponent(item)
            let src = dir.appendingPathComponent(item)
            try? FileManager.default.removeItem(at: dst)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: dst)
            }
        }
    }

    public func deleteSnapshot(for id: UUID) throws {
        try? FileManager.default.removeItem(at: snapshotDir(for: id))
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
