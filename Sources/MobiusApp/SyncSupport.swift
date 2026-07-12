import AppKit
import MobiusCore

/// 클라우드 동기화 보관 위치(iCloud Drive / Google Drive / 사용자 지정 폴더) 감지·해석.
/// 두 서비스 모두 데스크톱 클라이언트가 로컬 폴더를 동기화하므로,
/// Mobius는 그 폴더에 파일을 읽고 쓸 뿐 별도 API·로그인이 필요 없다.
enum SyncSupport {
    static func icloudRoot() -> URL? {
        // 폴더 존재만으로는 부족 — 로그아웃 후에도 잔존할 수 있다.
        // ubiquityIdentityToken == nil 이면 iCloud 계정 미로그인 (실측: 무서명 앱에서도 동작).
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func gdriveRoot() -> URL? {
        let fm = FileManager.default
        let cs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let mounts = try? fm.contentsOfDirectory(at: cs, includingPropertiesForKeys: nil),
              let mount = mounts.first(where: { $0.lastPathComponent.hasPrefix("GoogleDrive-") })
        else { return nil }
        // "My Drive"는 시스템 언어에 따라 "내 드라이브" 등으로 현지화됨.
        // ★ 마운트 루트 폴백 금지: 루트에 쓴 파일은 Google Drive가 클라우드로 올리지
        //   않아 "로컬엔 있는데 웹엔 안 보이는" 무음 실패가 된다 — 못 찾으면 실패가 낫다.
        if let children = try? fm.contentsOfDirectory(at: mount,
                                                      includingPropertiesForKeys: [.isDirectoryKey]) {
            let dirs = children.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    && !$0.lastPathComponent.hasPrefix(".")
            }
            let known = ["my drive", "내 드라이브", "マイドライブ"]
            if let myDrive = dirs.first(where: { known.contains($0.lastPathComponent.lowercased()) }) {
                return myDrive
            }
            // 이름 매칭 실패 시: 공유 드라이브류만 배제하고 남은 유일한 후보일 때만 사용
            let candidates = dirs.filter {
                let n = $0.lastPathComponent.lowercased()
                return !n.contains("shared") && !n.contains("공유") && !n.contains("共有")
            }
            if candidates.count == 1 { return candidates[0] }
        }
        return nil
    }

    /// UserDefaults의 설정으로 실제 동기화 루트(<보관 위치>/MobiusSync/claude)를 해석.
    /// 보관 위치가 없으면(서비스 미설치·폴더 삭제) nil — 호출자가 실패 안내.
    static func resolvedSyncRoot() -> URL? {
        let d = UserDefaults.standard
        let base: URL?
        switch d.string(forKey: "syncProvider") ?? "icloud" {
        case "gdrive": base = gdriveRoot()
        case "custom":
            let p = d.string(forKey: "syncCustomPath") ?? ""
            base = p.isEmpty ? nil : URL(fileURLWithPath: p)
        default: base = icloudRoot()
        }
        guard let base, FileManager.default.fileExists(atPath: base.path) else { return nil }
        return base.appendingPathComponent("MobiusSync/claude")
    }

    /// 디렉토리 총 용량 (사용자 안내용 — "대화 기록 · 849MB")
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
