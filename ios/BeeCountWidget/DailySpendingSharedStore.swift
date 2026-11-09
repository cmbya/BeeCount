import Foundation

// Shared by Runner and its widget extension. Only a disposable summary snapshot
// lives here; the main ledger database is never moved or opened by the widget.
struct DailySpendingDay: Codable {
    let date: String
    let weekday: Int
    let total: Double
}

struct DailySpendingSnapshot: Codable {
    let schemaVersion: Int
    let ledgerId: Int
    let currency: String
    let currencySymbol: String
    let locale: String
    let generatedAtMs: Double
    let dayStartMs: Double
    let dayEndMs: Double
    let periodStartMs: Double
    let periodEndMs: Double
    let todayExpense: Double
    let monthExpense: Double
    let budgetRemaining: Double?
    let days: [DailySpendingDay]

    var valid: Bool {
        schemaVersion == 1 && days.count == 7 &&
        Set(days.map(\.date)).count == 7 &&
        days.allSatisfy({ (1...7).contains($0.weekday) && $0.total.isFinite }) &&
        [generatedAtMs, dayStartMs, dayEndMs, periodStartMs, periodEndMs,
         todayExpense, monthExpense].allSatisfy(\.isFinite) &&
        budgetRemaining?.isFinite != false && dayEndMs > dayStartMs &&
        periodEndMs > periodStartMs && generatedAtMs >= dayStartMs && generatedAtMs < dayEndMs
    }

    func isCurrent(at date: Date, calendar: Calendar = .current) -> Bool {
        let ms = date.timeIntervalSince1970 * 1000
        let localStart = calendar.startOfDay(for: date).timeIntervalSince1970 * 1000
        return valid && abs(localStart - dayStartMs) < 1000 &&
            ms >= dayStartMs && ms < dayEndMs && ms >= periodStartMs && ms < periodEndMs &&
            generatedAtMs <= ms + 1000
    }
}

enum DailySpendingStorageError: String, Error {
    case noAccess, chooseGroup, conflictingGroups, missingSnapshot, invalidSnapshot, writeFailed

    var message: String {
        switch self {
        case .noAccess: return "共享权限不可用，请检查主 App 和组件的 App Groups 签名"
        case .chooseGroup: return "请到 App 的桌面组件设置中选择共享组"
        case .conflictingGroups: return "共享组选择冲突，请到 App 检查；未改动账本"
        case .missingSnapshot: return "尚未生成数据，请打开 App 并刷新桌面组件"
        case .invalidSnapshot: return "组件数据无效，请到 App 重新刷新"
        case .writeFailed: return "共享数据写入校验失败，请检查签名权限"
        }
    }
}

enum DailySpendingSharedStore {
    static let defaultGroup = "group.com.tntlikely.beecount"
    static let kind = "BeeCountDailySpendingWidget"
    private static let folder = "BeeCountDailySpending"
    private static let snapshotName = "snapshot-v1.json"
    private static let selectionName = "selected-group-v1.json"

    struct Candidate {
        let id: String
        let url: URL
        let selected: Bool
        let hasSnapshot: Bool
    }

    // Provisioning profiles supply candidate IDs, not permission. Every actual
    // access still goes through the operating system's containerURL API.
    static func profileGroups(_ data: Data) -> [String] {
        guard data.count < 8_000_000,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return (entitlements["com.apple.security.application-groups"] as? [String] ?? [])
            .filter { $0.hasPrefix("group.") && !$0.contains("*") }
    }

    private static func groups(in bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let bytes = try? Data(contentsOf: url) else { return [] }
        return profileGroups(bytes)
    }

    static func candidates() throws -> [Candidate] {
        let bundle = Bundle.main
        var ids = Set(groups(in: bundle))
        // Inspect the paired target's profile as well, when present. Do not
        // choose a group that only the host profile authorizes.
        let peer: Bundle?
        if bundle.bundleURL.pathExtension == "appex" {
            peer = Bundle(url: bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent())
        } else {
            let plugins = bundle.bundleURL.appendingPathComponent("PlugIns")
            let urls = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
            peer = urls.compactMap { Bundle(url: $0) }.first {
                ($0.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension"
            }
        }
        if let peer = peer {
            let peerGroups = Set(groups(in: peer))
            if !peerGroups.isEmpty { ids = ids.isEmpty ? peerGroups : ids.intersection(peerGroups) }
        }
        // Original development installs may not embed a provisioning profile.
        ids.insert(defaultGroup)
        return try ids.sorted().compactMap { id -> Candidate? in
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
            let directory = url.appendingPathComponent(folder, isDirectory: true)
            let marker = directory.appendingPathComponent(selectionName)
            var selected = false
            if FileManager.default.fileExists(atPath: marker.path) {
                guard let data = try? Data(contentsOf: marker),
                      let value = try? JSONDecoder().decode(String.self, from: data), value == id else {
                    throw DailySpendingStorageError.conflictingGroups
                }
                selected = true
            }
            return Candidate(id: id, url: url, selected: selected,
                hasSnapshot: FileManager.default.fileExists(atPath: directory.appendingPathComponent(snapshotName).path))
        }
    }

    static func select(_ items: [Candidate]) throws -> Candidate {
        let marked = items.filter(\.selected)
        if marked.count > 1 { throw DailySpendingStorageError.conflictingGroups }
        if let item = marked.first { return item }
        if let original = items.first(where: { $0.id == defaultGroup }) { return original }
        if items.count == 1 { return items[0] }
        throw items.isEmpty ? DailySpendingStorageError.noAccess : DailySpendingStorageError.chooseGroup
    }

    static func choose(_ id: String) throws {
        let items = try candidates()
        guard let item = items.first(where: { $0.id == id }) else { throw DailySpendingStorageError.noAccess }
        guard items.filter(\.selected).allSatisfy({ $0.id == id }) else {
            throw DailySpendingStorageError.conflictingGroups
        }
        let directory = item.url.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(id).write(to: directory.appendingPathComponent(selectionName), options: .atomic)
    }

    static func write(_ raw: String) throws -> String {
        let item = try select(candidates())
        let bytes = Data(raw.utf8)
        // An explicit unavailable-ledger envelope invalidates previous values.
        let snapshot = try? JSONDecoder().decode(DailySpendingSnapshot.self, from: bytes)
        let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard snapshot?.valid == true || object?["status"] as? String == "noLedger" else {
            throw DailySpendingStorageError.invalidSnapshot
        }
        let directory = item.url.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(snapshotName)
        try bytes.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == bytes else { throw DailySpendingStorageError.writeFailed }
        return item.id
    }

    static func read() throws -> DailySpendingSnapshot {
        let item = try select(candidates())
        let url = item.url.appendingPathComponent(folder).appendingPathComponent(snapshotName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DailySpendingStorageError.missingSnapshot }
        guard let bytes = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(DailySpendingSnapshot.self, from: bytes), snapshot.valid else {
            throw DailySpendingStorageError.invalidSnapshot
        }
        return snapshot
    }

    static func diagnostics() -> [String: Any] {
        do {
            let items = try candidates()
            let options = items.map { $0.id }
            do {
                let selected = try select(items)
                return ["available": true, "group": selected.id, "candidates": options,
                        "hasSnapshot": selected.hasSnapshot,
                        "message": "共享容器可访问；主 App 与组件仍须获得相同的签名授权"]
            } catch let error as DailySpendingStorageError {
                return ["available": false, "candidates": options, "code": error.rawValue, "message": error.message]
            }
        } catch let error as DailySpendingStorageError {
            return ["available": false, "candidates": [String](), "code": error.rawValue, "message": error.message]
        } catch {
            return ["available": false, "candidates": [String](), "code": "readFailed", "message": "共享容器检查失败，未改动账本"]
        }
    }
}
