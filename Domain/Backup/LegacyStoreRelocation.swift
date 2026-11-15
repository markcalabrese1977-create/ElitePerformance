import Foundation
import SwiftData
import Combine

/// One-time, verified relocation of data left in an OLDER store file.
///
/// Builds before the one-way store opener could have kept their data in a store other than the one the app opens now
/// (`default.store` in the app-group container): a store named by the old "pin" (`ElitePerformanceStore.store`,
/// `ElitePerformanceStore_v2.store`), or a store in the app's own sandbox from before the app-group entitlement. Nothing
/// ever read those files again, and the missing-data sentinel cannot see this case (old builds never wrote it).
///
/// The rule: look at every such file READ-ONLY (a copy is opened, never the file), and when one holds STRICTLY MORE completed
/// sessions than the store the app opened, OFFER to bring its data over. The data moves the safe way: export the copy to a
/// backup file, then restore it through `BackupRestoreCoordinator` (snapshot first, marker, sentinel). The original file is
/// never deleted, moved or modified. Whatever the lifter answers is remembered, so it is asked at most once per file.
enum LegacyStoreRelocation {

    static let storeNames = ["default.store", "ElitePerformanceStore.store", "ElitePerformanceStore_v2.store"]
    enum Location: String { case sandbox, appGroup }

    struct Candidate: Equatable {
        let url: URL
        let location: Location
        let completedSessions: Int
        let sessions: Int
        let lastCompletedDate: Date?
        /// True when the released build's pin named this file.
        let wasPinned: Bool

        var name: String { url.lastPathComponent }
    }

    /// What the lifter is asked about.
    struct Finding: Equatable {
        let candidate: Candidate
        let currentCompletedSessions: Int

        var message: String {
            let last = candidate.lastCompletedDate.map { " (last session \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? ""
            return "An older copy of your data was found on this device: \(candidate.completedSessions) completed sessions\(last), "
                + "against \(currentCompletedSessions) in the data the app opened. Bring the older data over? "
                + "A copy of what you have now is saved first, and the older file is left untouched."
        }
    }

    // MARK: Detection (read-only)

    /// The store files that may hold older data: every known name in the sandbox and in the app-group Application Support
    /// folder, except the store the app is using. Pure file-system look, nothing is opened.
    static func candidateFiles(currentStore: URL, sandboxSupport: URL, fileManager: FileManager = .default) -> [(url: URL, location: Location)] {
        let appGroupSupport = currentStore.deletingLastPathComponent()
        var seen = Set<String>(), out: [(URL, Location)] = []
        for (dir, location) in [(appGroupSupport, Location.appGroup), (sandboxSupport, Location.sandbox)] {
            for name in storeNames {
                let u = dir.appendingPathComponent(name)
                guard u.standardizedFileURL != currentStore.standardizedFileURL, fileManager.fileExists(atPath: u.path),
                      seen.insert(u.standardizedFileURL.path).inserted else { continue }
                out.append((u, location))
            }
        }
        return out
    }

    /// Opens a COPY of `store` (with its -wal and -shm) and returns its content summary; the original is never opened.
    static func summary(ofCopyOf store: URL) -> BackupContentSummary? {
        guard let (container, cleanup) = try? openCopy(of: store) else { return nil }
        defer { cleanup() }
        return try? BackupContentSummary.of(store: ModelContext(container))
    }

    /// A scratch copy of the store files, opened with the app's schema (never CloudKit). `cleanup` removes the scratch.
    static func openCopy(of store: URL) throws -> (ModelContainer, cleanup: () -> Void) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("ep_legacy_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: store.path + suffix)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: scratch.appendingPathComponent(store.lastPathComponent + suffix)) }
        }
        let copy = scratch.appendingPathComponent(store.lastPathComponent)
        let schema = AppSchema.makeSchema()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: copy, cloudKitDatabase: .none))
        return (container, { try? fm.removeItem(at: scratch) })
    }

    /// The finding to offer, or nil. `offered` = file paths already answered. Only a candidate with STRICTLY more completed
    /// sessions than the current store is offered; of several, the one with the most (ties: the pinned one, then newest).
    static func find(currentStore: URL, currentCompleted: Int, sandboxSupport: URL, pinLabel: String?, offered: Set<String>,
                     summarize: (URL) -> BackupContentSummary? = summary(ofCopyOf:),
                     log: (String) -> Void = { print($0) }) -> Finding? {
        var best: Candidate?
        for (url, location) in candidateFiles(currentStore: currentStore, sandboxSupport: sandboxSupport) {
            guard !offered.contains(url.standardizedFileURL.path) else { continue }
            guard let s = summarize(url) else { log("ℹ️ Legacy store \(url.lastPathComponent) (\(location.rawValue)): could not be read; ignored"); continue }
            let pinned = pinLabel.map { $0 != "DEFAULT" && url.lastPathComponent == $0 + ".store" } ?? false
            log("ℹ️ Legacy store \(url.lastPathComponent) (\(location.rawValue)\(pinned ? ", pinned by the released build" : "")): completed=\(s.completedSessions) sessions=\(s.sessions); current store: completed=\(currentCompleted)")
            guard s.completedSessions > currentCompleted else { continue }
            let c = Candidate(url: url, location: location, completedSessions: s.completedSessions, sessions: s.sessions,
                              lastCompletedDate: s.lastCompletedDate, wasPinned: pinned)
            if let b = best {
                let better = (c.completedSessions, c.wasPinned ? 1 : 0, c.lastCompletedDate ?? .distantPast)
                    > (b.completedSessions, b.wasPinned ? 1 : 0, b.lastCompletedDate ?? .distantPast)
                if better { best = c }
            } else { best = c }
        }
        return best.map { Finding(candidate: $0, currentCompletedSessions: currentCompleted) }
    }

    // MARK: Moving the data (export the copy, restore through the coordinator)

    /// Exports the candidate (through a scratch copy) to a backup JSON file in a temp location.
    static func export(_ candidate: Candidate) throws -> URL {
        let (container, cleanup) = try openCopy(of: candidate.url)
        defer { cleanup() }
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ModelContext(container))
        let unique = FileManager.default.temporaryDirectory.appendingPathComponent("ep_legacy_export_\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: result.url, to: unique)
        return unique
    }

    /// Exports the candidate, checks the export holds what the candidate holds, restores it into `container` through the
    /// coordinator (snapshot first), and checks the store now holds those counts. The candidate file is never touched.
    @discardableResult
    static func relocate(_ finding: Finding, into container: ModelContainer, snapshotDirectory: URL, sentinel: DataSentinelStore) throws -> BackupContentSummary {
        let file = try export(finding.candidate)
        defer { try? FileManager.default.removeItem(at: file) }
        let exported = try BackupContentSummary.of(file: file)
        guard exported.completedSessions == finding.candidate.completedSessions else {
            throw NSError(domain: "LegacyStoreRelocation", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The older data did not export completely (\(exported.completedSessions) of \(finding.candidate.completedSessions) completed sessions). Nothing was changed."])
        }
        _ = try BackupRestoreCoordinator.restore(from: file, container: container, snapshotDirectory: snapshotDirectory, sentinel: sentinel)
        let now = try BackupContentSummary.of(store: ModelContext(container))
        guard now.completedSessions == exported.completedSessions, now.verifiedCounts == exported.verifiedCounts else {
            throw NSError(domain: "LegacyStoreRelocation", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "After bringing the older data over, the counts do not match. Your previous data is saved: restore it from Settings → Backup & Restore → Restore → Restore pre-import state."])
        }
        return now
    }

    /// The default look: the store the container opened, the sandbox's Application Support, and the released build's pin
    /// ("activeSwiftDataStoreLabel.v1", read only).
    static let defaultFinder: @MainActor (ModelContainer, Int) -> Finding? = { container, completed in
        guard let current = container.configurations.first?.url,
              let sandbox = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return find(currentStore: current, currentCompleted: completed, sandboxSupport: sandbox,
                    pinLabel: UserDefaults.standard.string(forKey: "activeSwiftDataStoreLabel.v1"), offered: OfferedStore().paths)
    }

    // MARK: "Offered" marker (device state, excluded from backups)

    struct OfferedStore {
        var defaults: UserDefaults = .standard
        var paths: Set<String> {
            get { Set(defaults.stringArray(forKey: "legacyStore.offered") ?? []) }
            nonmutating set { defaults.set(Array(newValue).sorted(), forKey: "legacyStore.offered") }
        }
        func markOffered(_ url: URL) { paths = paths.union([url.standardizedFileURL.path]) }
    }
}
