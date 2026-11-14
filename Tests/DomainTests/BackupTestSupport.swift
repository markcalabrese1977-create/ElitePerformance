import XCTest
import SwiftData
@testable import ElitePerformance

/// Shared plumbing for the backup tests: an in-memory store built from the app's own model list, export/import
/// helpers, and a sandbox that puts UserDefaults (and the App Group load keys) back after a test.
enum BackupTestSupport {

    /// Containers stay alive for the whole run (same reason the older backup tests park theirs).
    private static var parked: [ModelContainer] = []

    static func makeContainer() throws -> ModelContainer {
        let c = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        parked.append(c)
        return c
    }

    /// Exports `ctx` to a temp file; the caller owns (and should remove) the file.
    static func exportFile(_ ctx: ModelContext) throws -> URL {
        try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx).url
    }

    /// Parsed export with `exportedAt` removed.
    static func exportJSON(_ ctx: ModelContext) throws -> [String: Any] {
        let url = try exportFile(ctx)
        defer { try? FileManager.default.removeItem(at: url) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "exportedAt")
        return json
    }

    /// Export `source`, then import that file into `target`.
    @discardableResult
    static func restore(from source: ModelContext, into target: ModelContainer) throws -> BackupSnapshotImportResult {
        let url = try exportFile(source)
        defer { try? FileManager.default.removeItem(at: url) }
        return try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: target)
    }

    static func date(_ secondsSinceEpoch: TimeInterval) -> Date { Date(timeIntervalSince1970: secondsSinceEpoch) }

    static func item(_ order: Int, _ id: String, name: String, reps: [Int] = [], loads: [Double] = []) -> SessionItem {
        let i = SessionItem(order: order, exerciseId: id, exerciseNameSnapshot: name, targetReps: 8, targetSets: 3,
                            targetRIR: 2, suggestedLoad: 0,
                            plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [0, 0, 0], plannedRIRsBySet: [2, 2, 2])
        i.actualReps = reps
        i.actualLoads = loads
        i.isCompleted = !reps.isEmpty
        return i
    }
}

/// Snapshots the app's UserDefaults domain and the App Group mechanicalLoad.* keys; `restore()` puts them back.
final class DefaultsSandbox {
    private let domain = Bundle.main.bundleIdentifier ?? ""
    private let saved: [String: Any]
    private let savedGroup: [String: Any]

    init() {
        saved = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        savedGroup = Self.groupLoadValues()
    }

    func restore() {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.setPersistentDomain(saved, forName: domain)
        guard let group = UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID) else { return }
        for key in Self.groupLoadValues().keys { group.removeObject(forKey: key) }
        for (key, value) in savedGroup { group.set(value, forKey: key) }
    }

    private static func groupLoadValues() -> [String: Any] {
        guard let group = UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID) else { return [:] }
        return group.dictionaryRepresentation().filter { $0.key.hasPrefix(MechanicalLoadSharedStore.keyPrefix) }
    }
}
