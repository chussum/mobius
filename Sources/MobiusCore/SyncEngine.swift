import Foundation

/// 동기화 대상 카테고리. rawValue가 동기화 루트의 하위 폴더 이름이 된다.
public enum SyncCategory: String, CaseIterable, Codable, Sendable {
    case sessions      // ~/.claude/projects/ (프로젝트별 memory 포함 → 학습 공유)
    case plans         // ~/.claude/plans/
    case skills        // ~/.claude/skills/
    case globalMemory  // ~/.claude/CLAUDE.md (단일 파일)
    case pluginConfig  // ~/.claude/plugins/installed_plugins.json 등 목록만 (cache 470MB 제외)

    /// 로컬 위치. 파일 단위 카테고리는 (부모 dir, 파일명 필터)로 표현해 dir 동기화와 통일한다.
    /// 실측(2026-07-12): 플러그인 목록은 installed_plugins.json + known_marketplaces.json.
    public func localBase(claudeDir: URL) -> (dir: URL, only: [String]?) {
        switch self {
        case .sessions: return (claudeDir.appendingPathComponent("projects"), nil)
        case .plans: return (claudeDir.appendingPathComponent("plans"), nil)
        case .skills: return (claudeDir.appendingPathComponent("skills"), nil)
        case .globalMemory: return (claudeDir, ["CLAUDE.md"])
        case .pluginConfig: return (claudeDir.appendingPathComponent("plugins"),
                                    ["installed_plugins.json", "known_marketplaces.json"])
        }
    }
}

/// 세션 슬러그의 홈 경로 부분을 머신 중립 토큰으로 치환한다.
/// 로컬  : projects/-Users-hyungjoo-Projects-x/세션.jsonl
/// 클라우드: projects/~-Projects-x/세션.jsonl   ← 사용자명이 달라도 공유 가능
/// 홈 밖 경로(-private-tmp-… 등)는 그대로 둔다 — 그런 프로젝트는 경로가 같아야 이어진다.
struct SlugRemapper {
    static let token = "~"
    let localPrefix: String // 예: "-Users-hyungjoo" (홈 절대경로의 / → - 치환)

    init(home: URL) {
        localPrefix = home.path.replacingOccurrences(of: "/", with: "-")
    }

    private func mapFirst(_ rel: String, _ transform: (String) -> String?) -> String {
        var parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let mapped = transform(first) else { return rel }
        parts[0] = mapped
        return parts.joined(separator: "/")
    }

    /// 로컬 relpath → 클라우드(portable) relpath
    func toPortable(_ rel: String) -> String {
        mapFirst(rel) { first in
            first.hasPrefix(localPrefix)
                ? SlugRemapper.token + first.dropFirst(localPrefix.count) : nil
        }
    }

    /// 클라우드(portable) relpath → 로컬 relpath
    func toLocal(_ rel: String) -> String {
        mapFirst(rel) { first in
            first.hasPrefix(SlugRemapper.token)
                ? localPrefix + first.dropFirst(SlugRemapper.token.count) : nil
        }
    }
}

public struct SyncReport: Equatable, Sendable {
    public var uploaded = 0      // 로컬 → 원격 복사
    public var downloaded = 0    // 원격 → 로컬 복사
    public var trashedLocal = 0  // 다른 Mac의 삭제를 이어받아 로컬 파일을 휴지통으로
    public var trashedRemote = 0 // 내 삭제를 원격에 반영 (원격 사본을 휴지통으로)
    public var conflicts = 0     // 양쪽 동시 수정 — 진 쪽 백업됨
    public var skippedBusy = 0   // 최근 수정/다운로드 중이라 이번 라운드 건너뜀
    public var errors: [String] = []
    public init() {}
}

/// 클라우드 동기화 폴더(iCloud/Google Drive/임의 폴더)를 경유한 ~/.claude 데이터 양방향 미러.
///
/// 원칙:
/// - 자격증명·계정 정보는 어떤 경우에도 넘기지 않는다 (하드코딩 제외 목록 — 테스트로 보증).
/// - 비교는 mtime(±2초)+size, 다르면 최신이 이긴다. 복사는 tmp+rename 원자적, mtime 보존.
/// - 최근 60초 내 수정된 파일은 건너뛴다 (실행 중 claude가 쓰는 파일 — 실패 기록 9 교훈).
/// - 삭제는 즉시 지우지 않는다: 전파 모드에서도 휴지통 폴더로 이동해 30일 보관.
public final class SyncEngine {
    let fm = FileManager.default
    let machineID: String
    let localTrashDir: URL
    let now: () -> Date
    let busyWindow: TimeInterval
    static let mtimeTolerance: TimeInterval = 2
    static let retention: TimeInterval = 30 * 24 * 3600 // 휴지통/tombstone 보관 30일

    /// 카테고리와 무관하게 절대 동기화하지 않는 이름들 (자격증명·계정 정보 원천 차단)
    static func isExcluded(name: String) -> Bool {
        let lower = name.lowercased()
        return name == ".DS_Store"
            || lower.contains("credential")
            || name == "accounts.json"
            || name == "secrets"
            || name == ".mobius-sync"
            || name == ".mobius-trash"
            || name.hasPrefix(".tmp-mobius-")
    }

    public init(machineID: String, localTrashDir: URL,
                busyWindow: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.machineID = machineID
        self.localTrashDir = localTrashDir
        self.busyWindow = busyWindow
        self.now = now
    }

    // MARK: 스냅샷

    struct Entry: Codable, Equatable { var m: TimeInterval; var s: Int }

    /// dir 하위 전체(또는 only 단일 파일)의 relpath → (mtime, size).
    /// 제외 목록·심볼릭 링크는 건너뛰고, iCloud 플레이스홀더는 다운로드를 트리거한 뒤 스킵한다.
    func snapshot(of base: URL, only: [String]?, report: inout SyncReport) -> [String: Entry] {
        var out: [String: Entry] = [:]
        func note(_ url: URL, rel: String) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let type = attrs[.type] as? FileAttributeType, type == .typeRegular,
                  let mtime = attrs[.modificationDate] as? Date else { return }
            let size = (attrs[.size] as? Int) ?? 0
            out[rel] = Entry(m: mtime.timeIntervalSince1970, s: size)
        }
        if let only {
            for name in only {
                let url = base.appendingPathComponent(name)
                if !SyncEngine.isExcluded(name: name), fm.fileExists(atPath: url.path) {
                    note(url, rel: name)
                }
            }
            return out
        }
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil,
                                     options: [.producesRelativePathURLs]) else { return out }
        for case let url as URL in en {
            let name = url.lastPathComponent
            if SyncEngine.isExcluded(name: name) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    en.skipDescendants()
                }
                continue
            }
            if name.hasSuffix(".icloud") { // 축출된 iCloud 파일 — 받아두고 이번엔 스킵
                try? fm.startDownloadingUbiquitousItem(at: url)
                report.skippedBusy += 1
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                en.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            note(url, rel: url.relativePath)
        }
        return out
    }

    // MARK: 원자적 복사 (mtime 보존)

    func copyPreservingMtime(from src: URL, to dst: URL) throws {
        try fm.createDirectory(at: dst.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(".tmp-mobius-\(UUID().uuidString)")
        try fm.copyItem(at: src, to: tmp)
        if let mtime = (try? fm.attributesOfItem(atPath: src.path))?[.modificationDate] {
            try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: tmp.path)
        }
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: tmp, to: dst)
    }

    func moveToTrash(_ url: URL, trashRoot: URL, rel: String, ts: TimeInterval) {
        let dst = trashRoot.appendingPathComponent(String(Int(ts)))
            .appendingPathComponent(rel)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.moveItem(at: url, to: dst)
    }

    // MARK: manifest / tombstone

    struct Tombstone: Codable, Equatable { var ts: TimeInterval; var machine: String }

    func metaDir(_ syncRoot: URL) -> URL { syncRoot.appendingPathComponent(".mobius-sync") }

    func loadManifest(_ syncRoot: URL) -> [String: Entry] {
        let url = metaDir(syncRoot).appendingPathComponent("manifest-\(machineID).json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    func saveManifest(_ m: [String: Entry], _ syncRoot: URL) {
        let dir = metaDir(syncRoot)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: dir.appendingPathComponent("manifest-\(machineID).json"),
                            options: .atomic)
        }
    }

    func loadTombstones(_ syncRoot: URL) -> [String: Tombstone] {
        let url = metaDir(syncRoot).appendingPathComponent("tombstones.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Tombstone].self, from: data)) ?? [:]
    }

    func saveTombstones(_ t: [String: Tombstone], _ syncRoot: URL) {
        let dir = metaDir(syncRoot)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 30일 지난 tombstone 정리
        let cutoff = now().timeIntervalSince1970 - SyncEngine.retention
        let pruned = t.filter { $0.value.ts > cutoff }
        if let data = try? JSONEncoder().encode(pruned) {
            try? data.write(to: dir.appendingPathComponent("tombstones.json"), options: .atomic)
        }
    }

    // MARK: 본체

    /// 선택된 카테고리들을 syncRoot와 양방향 동기화한다.
    public func sync(categories: [SyncCategory], claudeDir: URL, syncRoot: URL,
                     propagateDeletes: Bool) -> SyncReport {
        var report = SyncReport()
        var manifest = loadManifest(syncRoot)
        var tombstones = propagateDeletes ? loadTombstones(syncRoot) : [:]
        var tombstonesDirty = false
        let nowTs = now().timeIntervalSince1970

        for cat in categories {
            let (localBase, only) = cat.localBase(claudeDir: claudeDir)
            let remoteBase = syncRoot.appendingPathComponent(cat.rawValue)
            try? fm.createDirectory(at: localBase, withIntermediateDirectories: true)
            try? fm.createDirectory(at: remoteBase, withIntermediateDirectories: true)

            // 세션 슬러그의 홈 부분은 클라우드에서 머신 중립 토큰(~)으로 — 사용자명이
            // 달라도 이어 쓰기가 되도록. 비교·manifest·tombstone 키는 전부 portable 기준.
            let remapper: SlugRemapper? = cat == .sessions
                ? SlugRemapper(home: claudeDir.deletingLastPathComponent()) : nil

            var local = snapshot(of: localBase, only: only, report: &report)
            if let remapper {
                local = Dictionary(uniqueKeysWithValues:
                    local.map { (remapper.toPortable($0.key), $0.value) })
            }
            let remote = snapshot(of: remoteBase, only: only, report: &report)

            for rel in Set(local.keys).union(remote.keys).sorted() {
                let key = "\(cat.rawValue)/\(rel)"
                let L = local[rel], R = remote[rel]
                let localURL = localBase.appendingPathComponent(remapper?.toLocal(rel) ?? rel)
                let remoteURL = remoteBase.appendingPathComponent(rel)

                // 실행 중인 claude가 쓰는 중일 수 있는 파일 — 이번 라운드 건너뜀.
                // 미래 mtime은 busy가 아니다 (다른 머신과의 시계 오차로 흔히 생기며,
                // busy로 오판하면 그 파일이 영원히 동기화되지 않는다).
                if let L, nowTs - L.m >= 0, nowTs - L.m < busyWindow {
                    report.skippedBusy += 1; continue
                }

                // 삭제 이어받기 (전파 모드): tombstone이 이 파일을 가리키면
                if propagateDeletes, let t = tombstones[key] {
                    if let L, L.m > t.ts + SyncEngine.mtimeTolerance {
                        // 삭제 이후 수정됨 = 삭제 취소 — tombstone 제거하고 평소처럼 진행
                        tombstones.removeValue(forKey: key)
                        tombstonesDirty = true
                    } else {
                        if fm.fileExists(atPath: localURL.path) {
                            moveToTrash(localURL, trashRoot: localTrashDir, rel: key, ts: t.ts)
                            report.trashedLocal += 1
                        }
                        manifest.removeValue(forKey: key)
                        continue
                    }
                }

                switch (L, R) {
                case let (l?, nil):
                    _ = l
                    do { try copyPreservingMtime(from: localURL, to: remoteURL)
                         report.uploaded += 1 }
                    catch { report.errors.append("\(key): \(error.localizedDescription)") }

                case (nil, _?):
                    if propagateDeletes, manifest[key] != nil {
                        // 이전엔 내 로컬에 있었는데 사라짐 = 내가 지움 → 원격도 휴지통으로
                        tombstones[key] = Tombstone(ts: nowTs, machine: machineID)
                        tombstonesDirty = true
                        moveToTrash(remoteURL, trashRoot: metaDir(syncRoot)
                            .appendingPathComponent("trash"), rel: key, ts: nowTs)
                        report.trashedRemote += 1
                        manifest.removeValue(forKey: key)
                    } else {
                        do { try copyPreservingMtime(from: remoteURL, to: localURL)
                             report.downloaded += 1 }
                        catch { report.errors.append("\(key): \(error.localizedDescription)") }
                    }

                case let (l?, r?):
                    if abs(l.m - r.m) <= SyncEngine.mtimeTolerance && l.s == r.s { break }
                    let prev = manifest[key]
                    let bothChanged = prev != nil
                        && l.m > prev!.m + SyncEngine.mtimeTolerance
                        && r.m > prev!.m + SyncEngine.mtimeTolerance
                    let localWins = l.m >= r.m
                    if bothChanged {
                        report.conflicts += 1
                        let loserURL = localWins ? remoteURL : localURL
                        let backup = metaDir(syncRoot).appendingPathComponent("conflicts")
                            .appendingPathComponent(machineID)
                            .appendingPathComponent("\(key).\(Int(nowTs))")
                        try? fm.createDirectory(at: backup.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                        try? fm.copyItem(at: loserURL, to: backup)
                    }
                    do {
                        if localWins {
                            try copyPreservingMtime(from: localURL, to: remoteURL)
                            report.uploaded += 1
                        } else {
                            try copyPreservingMtime(from: remoteURL, to: localURL)
                            report.downloaded += 1
                        }
                    } catch { report.errors.append("\(key): \(error.localizedDescription)") }

                case (nil, nil):
                    break
                }
            }

            // manifest 갱신: 동기화 후 로컬 상태 재스캔 (키는 portable 기준)
            var post = SyncReport()
            let after = snapshot(of: localBase, only: only, report: &post)
            manifest = manifest.filter { !$0.key.hasPrefix("\(cat.rawValue)/") }
            for (rel, e) in after {
                manifest["\(cat.rawValue)/\(remapper?.toPortable(rel) ?? rel)"] = e
            }
        }

        saveManifest(manifest, syncRoot)
        if propagateDeletes || tombstonesDirty { saveTombstones(tombstones, syncRoot) }
        pruneTrash(metaDir(syncRoot).appendingPathComponent("trash"))
        pruneTrash(localTrashDir)
        return report
    }

    /// 휴지통의 30일 지난 항목 정리 (최상위 <epoch> 디렉토리 이름 기준)
    func pruneTrash(_ root: URL) {
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        let cutoff = now().timeIntervalSince1970 - SyncEngine.retention
        for item in items {
            if let ts = TimeInterval(item.lastPathComponent), ts < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }
}
