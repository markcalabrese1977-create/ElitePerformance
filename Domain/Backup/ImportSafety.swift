import Foundation
import SwiftData
import Combine

/// What a backup (a file, or the live store) holds, for the import confirmation and for verifying a pre-import snapshot.
struct BackupContentSummary: Equatable {
    var exportedAt: Date?
    var sessions: Int
    var completedSessions: Int
    var lastCompletedDate: Date?
    var sessionHistory: Int
    var customExercises: Int
    var mesoBlocks: Int
    /// The id of the latest completed session (file: among those it holds; store: the latest on this device). nil when it has none or no id.
    var lastCompletedSessionId: UUID? = nil
    /// Ids of every completed session (a file's only; used to see whether the file contains this device's latest session).
    var completedSessionIds: Set<UUID> = []
    /// A file's build identity ("Backup from 1.2.2 (1) · abc1234"); nil for a store or a file from an older build.
    var buildIdentity: String? = nil
    /// The backup format version the file's writer used (nil = not stated).
    var fileSchemaVersion: Int? = nil

    /// Set when the file was written by a newer backup format than this app reads.
    var newerFormatWarning: String? {
        guard let v = fileSchemaVersion, v > BackupMetadataDTO.currentSchemaVersion else { return nil }
        return "This backup was made by a newer version of the app (backup format \(v); this app reads up to \(BackupMetadataDTO.currentSchemaVersion)). Some of its data may not be restored. Update the app first."
    }

    var isEmpty: Bool { sessions == 0 && sessionHistory == 0 && customExercises == 0 && mesoBlocks == 0 }

    /// The four counts a snapshot must reproduce exactly.
    var verifiedCounts: [Int] { [sessions, sessionHistory, customExercises, mesoBlocks] }

    static func of(file url: URL) throws -> BackupContentSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(BackupSnapshotV1.self, from: Data(contentsOf: url))
        let completed = snap.sessions.filter { $0.statusRaw == SessionStatus.completed.rawValue }
        return BackupContentSummary(
            exportedAt: snap.exportedAt, sessions: snap.sessions.count, completedSessions: completed.count,
            lastCompletedDate: completed.map(\.date).max(), sessionHistory: snap.sessionHistory.count,
            customExercises: snap.customExercises.count, mesoBlocks: snap.mesoBlocks.count,
            lastCompletedSessionId: completed.max(by: { $0.date < $1.date })?.id,
            completedSessionIds: Set(completed.compactMap(\.id)),
            buildIdentity: snap.metadata?.summaryText,
            fileSchemaVersion: snap.metadata?.schemaVersion ?? (snap.version > 1 ? snap.version : nil))
    }

    static func of(store context: ModelContext) throws -> BackupContentSummary {
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let completed = sessions.filter { $0.status == .completed }
        return BackupContentSummary(
            exportedAt: nil, sessions: sessions.count, completedSessions: completed.count,
            lastCompletedDate: completed.map(\.date).max(),
            sessionHistory: try context.fetchCount(FetchDescriptor<SessionHistory>()),
            customExercises: try context.fetchCount(FetchDescriptor<CustomExercise>()),
            mesoBlocks: try context.fetchCount(FetchDescriptor<MesoBlock>()),
            lastCompletedSessionId: completed.max(by: { $0.date < $1.date })?.id)
    }
}

struct PreImportSnapshot: Equatable {
    let url: URL
    let date: Date
}

enum ImportSafetyError: LocalizedError {
    case snapshotFailed(String)
    case snapshotMismatch(String)

    var errorDescription: String? {
        switch self {
        case .snapshotFailed(let m): return "Import cancelled: could not save a copy of your current data first (\(m)). Nothing was changed."
        case .snapshotMismatch(let m): return "Import cancelled: the safety copy of your current data did not verify (\(m)). Nothing was changed."
        }
    }
}

/// Pre-import snapshots: Application Support/Backups/pre-import-<ISO timestamp>.json, the last 5 kept.
enum PreImportSnapshots {
    static let keepCount = 5
    static let undoWindowDays = 30

    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Backups", isDirectory: true)
    }

    private static let prefix = "pre-import-"

    private static func fileName(for date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // ':' is not filename-safe everywhere
        return prefix + f.string(from: date).replacingOccurrences(of: ":", with: "-") + ".json"
    }

    /// Exports the live store into `directory`, decodes it back and compares session / sessionHistory / customExercise /
    /// mesoBlock counts with the live store. Returns nil for an EMPTY store (nothing to protect; a snapshot of nothing would
    /// only evict a real one). Throws, leaving no file behind, when writing or verifying fails.
    @discardableResult
    static func take(from context: ModelContext, in directory: URL = defaultDirectory(), now: Date = Date()) throws -> PreImportSnapshot? {
        let live = try BackupContentSummary.of(store: context)
        if live.isEmpty { return nil }
        let fm = FileManager.default
        let dest = directory.appendingPathComponent(fileName(for: now))
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let export = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: context)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: export.url, to: dest)
            try? fm.removeItem(at: export.url)
        } catch {
            try? fm.removeItem(at: dest)
            throw ImportSafetyError.snapshotFailed(error.localizedDescription)
        }
        do {
            let written = try BackupContentSummary.of(file: dest)
            guard written.verifiedCounts == live.verifiedCounts else {
                throw ImportSafetyError.snapshotMismatch(
                    "sessions \(written.sessions)/\(live.sessions), history \(written.sessionHistory)/\(live.sessionHistory), custom exercises \(written.customExercises)/\(live.customExercises), blocks \(written.mesoBlocks)/\(live.mesoBlocks)")
            }
        } catch let e as ImportSafetyError {
            try? fm.removeItem(at: dest); throw e
        } catch {
            try? fm.removeItem(at: dest)
            throw ImportSafetyError.snapshotFailed("could not read it back: \(error.localizedDescription)")
        }
        prune(in: directory)
        return PreImportSnapshot(url: dest, date: now)
    }

    /// Newest first.
    static func list(in directory: URL = defaultDirectory()) -> [PreImportSnapshot] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return urls.compactMap { u -> PreImportSnapshot? in
            let n = u.lastPathComponent
            guard n.hasPrefix(prefix), n.hasSuffix(".json") else { return nil }
            var stamp = String(n.dropFirst(prefix.count).dropLast(5))
            // restore the time colons: ...THH-mm-ss.SSSZ -> ...THH:mm:ss.SSSZ
            if let t = stamp.firstIndex(of: "T") {
                let head = stamp[..<t], tail = stamp[t...].replacingOccurrences(of: "-", with: ":")
                stamp = String(head) + tail
            }
            guard let d = f.date(from: stamp) else { return nil }
            return PreImportSnapshot(url: u, date: d)
        }.sorted { $0.date > $1.date }
    }

    static func prune(in directory: URL = defaultDirectory(), keeping: Int = keepCount) {
        for old in list(in: directory).dropFirst(keeping) { try? FileManager.default.removeItem(at: old.url) }
    }

    /// The snapshot "Restore pre-import state" offers: the newest one, while it is under 30 days old.
    static func undoCandidate(in directory: URL = defaultDirectory(), now: Date = Date()) -> PreImportSnapshot? {
        guard let s = list(in: directory).first,
              now.timeIntervalSince(s.date) < Double(undoWindowDays) * 86_400 else { return nil }
        return s
    }
}

/// Written before an import wipes the store, deleted only once the import has fully succeeded (or was recovered in-process).
/// A marker found at launch means the app was killed mid-import.
struct InterruptedImportMarker: Codable, Equatable {
    var snapshotPath: String
    var startedAt: Date

    static let fileName = "import-in-progress.json"

    private static func fileURL(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    static func write(snapshot: URL, startedAt: Date, in directory: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try enc.encode(InterruptedImportMarker(snapshotPath: snapshot.path, startedAt: startedAt)).write(to: fileURL(in: directory), options: .atomic)
    }

    static func read(in directory: URL = PreImportSnapshots.defaultDirectory()) -> InterruptedImportMarker? {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(InterruptedImportMarker.self, from: data)
    }

    static func exists(in directory: URL = PreImportSnapshots.defaultDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(in: directory).path)
    }

    static func clear(in directory: URL = PreImportSnapshots.defaultDirectory()) {
        try? FileManager.default.removeItem(at: fileURL(in: directory))
    }

    /// The snapshot file: the recorded path, or (an app update can move the container) the same file name in `directory`.
    func resolvedSnapshotURL(in directory: URL) -> URL? {
        let recorded = URL(fileURLWithPath: snapshotPath)
        if FileManager.default.fileExists(atPath: recorded.path) { return recorded }
        let moved = directory.appendingPathComponent(recorded.lastPathComponent)
        return FileManager.default.fileExists(atPath: moved.path) ? moved : nil
    }
}

/// THE import path. Settings' import and "Restore pre-import state" both go through it, so both snapshot first.
enum BackupRestoreCoordinator {
    private static func recordSentinel(_ sentinel: DataSentinelStore, _ container: ModelContainer) {
        if let count = try? BackupContentSummary.of(store: ModelContext(container)).completedSessions { sentinel.record(count) }
    }

    typealias Importer = (URL, ModelContainer) throws -> BackupSnapshotImportResult

    /// `importer` is the real importer; tests substitute one that fails after it has changed the store.
    @discardableResult
    static func restore(from url: URL, container: ModelContainer, snapshotDirectory: URL = PreImportSnapshots.defaultDirectory(),
                        now: Date = Date(), preserveExistingMarker: Bool = false, sentinel: DataSentinelStore = DataSentinelStore(),
                        importer: Importer = { try BackupSnapshotImporter.importFullBackupJSON(from: $0, modelContainer: $1) }) throws -> BackupSnapshotImportResult {
        let context = ModelContext(container)
        let snapshot = try PreImportSnapshots.take(from: context, in: snapshotDirectory, now: now)   // throws: import never starts
        // Marker: present for the whole import, removed only after it (PR rebuild and final save included) succeeded or the
        // old data was put back in-process. A kill in between leaves it for the next launch to find.
        if let snapshot, !preserveExistingMarker {
            do { try InterruptedImportMarker.write(snapshot: snapshot.url, startedAt: now, in: snapshotDirectory) }
            catch { throw ImportSafetyError.snapshotFailed("could not write the import marker: \(error.localizedDescription)") }
        }
        do {
            let result = try importer(url, container)
            InterruptedImportMarker.clear(in: snapshotDirectory)
            recordSentinel(sentinel, container)          // a legitimate import: the new store is the baseline
            return result
        } catch {
            // The importer may have changed the store before it failed; put the old data back from the snapshot.
            // The snapshot file is never deleted here, whatever happens.
            guard let snapshot else { throw error }
            do {
                _ = try importer(snapshot.url, container)
            } catch let recoveryError {
                throw NSError(domain: "BackupRestore", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "\(error.localizedDescription) Putting your previous data back also failed (\(recoveryError.localizedDescription)). It is saved: restore it from Settings → Backup & Restore → Restore → Restore pre-import state."])
            }
            // recovered in-process (not when this restore is itself the answer to an older interrupted import: that marker
            // points at the good snapshot, and the store was only put back to the half-imported state)
            if !preserveExistingMarker { InterruptedImportMarker.clear(in: snapshotDirectory) }
            recordSentinel(sentinel, container)
            throw NSError(domain: "BackupRestore", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(error.localizedDescription) Your previous data was put back."])
        }
    }
}

/// Launch gate: backfills run only once any interrupted restore has been answered.
@MainActor
final class StartupGate: ObservableObject {
    static let shared = StartupGate()

    struct Interrupted: Equatable {
        let snapshotURL: URL
        let snapshotDate: Date
        var message: String { "A restore was interrupted. Restore your data from \(snapshotDate.formatted(date: .abbreviated, time: .shortened))?" }
    }

    @Published private(set) var interrupted: Interrupted?
    @Published private(set) var errorMessage: String?

    /// The store opened with no completed sessions although the last successful launch had some.
    struct MissingData: Equatable { let expectedSessions: Int }
    @Published private(set) var missingData: MissingData?
    @Published private(set) var newestBackup: AutoBackupFile?
    @Published private(set) var newestBackupSummary: BackupContentSummary?
    @Published private(set) var backupLookupDone = false
    @Published private(set) var missingDataError: String?
    static let missingDataMessage = "Your training data wasn't found. Nothing has been changed."
    /// Set once when a marker's safety copy is missing; the app carries on and shows a one-time, non-blocking alert.
    @Published var showsMissingSnapshotNotice = false
    static let missingSnapshotMessage = "A restore was interrupted and its safety copy is missing. Your data may be incomplete — import your latest export from Files."
    private var container: ModelContainer?
    private let directory: URL
    private let backfills: @MainActor (ModelContainer) -> Void
    private let backupFirst: (@MainActor (ModelContainer) async -> Result<AutoBackupFile?, Error>)?
    /// Holds an upgrade launch back until its pre-backfill backup is verified, or the lifter types CONTINUE.
    let startupGuard: SeedBackupGuard
    /// True from the moment the launch work starts until the backfills have run (the app shows a wait screen, not data).
    @Published private(set) var launching = false
    private let onContinueWithoutBackup: @MainActor () -> Void

    /// An older store file holds more completed sessions than the store the app opened: asked once, never silently moved.
    @Published private(set) var legacyOffer: LegacyStoreRelocation.Finding?
    @Published private(set) var legacyError: String?
    private let legacyFinder: (@MainActor (ModelContainer, Int) -> LegacyStoreRelocation.Finding?)?
    private let offered: LegacyStoreRelocation.OfferedStore

    /// The default look (see `LegacyStoreRelocation.defaultFinder`).
    static let defaultLegacyFinder: @MainActor (ModelContainer, Int) -> LegacyStoreRelocation.Finding? = LegacyStoreRelocation.defaultFinder
    private let sentinel: DataSentinelStore
    private let findBackups: @Sendable () -> [AutoBackupFile]
    private let log: (String) -> Void

    /// `backupFirst` runs after the interrupted-import check has been answered and BEFORE any backfill, and the backfills wait
    /// for it: the automatic backup for a new build is exported, verified and placed here, of the data as it was before the
    /// backfills touch it. If it fails the backfills are held behind a prompt (Back up now / type CONTINUE). nil = no backup
    /// step (tests that only look at the order of the rest).
    init(directory: URL = PreImportSnapshots.defaultDirectory(),
         sentinel: DataSentinelStore = DataSentinelStore(),
         backupFirst: (@MainActor (ModelContainer) async -> Result<AutoBackupFile?, Error>)? = { await AutoBackupService.shared.backUpIfBuildChanged(container: $0) },
         onContinueWithoutBackup: @escaping @MainActor () -> Void = { AutoBackupService.shared.recordLaunchWithoutBackup() },
         legacyFinder: (@MainActor (ModelContainer, Int) -> LegacyStoreRelocation.Finding?)? = StartupGate.defaultLegacyFinder,
         offered: LegacyStoreRelocation.OfferedStore = LegacyStoreRelocation.OfferedStore(),
         runBackfills: @escaping @MainActor (ModelContainer) -> Void = { StartupBackfills.run(using: $0) },
         findBackups: @escaping @Sendable () -> [AutoBackupFile] = StartupGate.defaultFindBackups,
         log: @escaping (String) -> Void = { print($0) }) {
        self.log = log
        self.sentinel = sentinel
        self.findBackups = findBackups
        self.directory = directory
        self.backupFirst = backupFirst
        self.legacyFinder = legacyFinder
        self.offered = offered
        self.onContinueWithoutBackup = onContinueWithoutBackup
        self.startupGuard = SeedBackupGuard(backup: backupFirst ?? { _ in .success(nil) })
        self.backfills = runBackfills
    }

    private func finishLaunch(_ container: ModelContainer, completed: Int) {
        backfills(container)
        if completed >= 0 {
            sentinel.record(completed)                        // after a successful launch
            log("ℹ️ Data sentinel: wrote \(completed), reads back \(sentinel.completedSessions)")
        }
        launching = false
    }

    /// Automatic backups, newest first: the iCloud folder and the local fallback folder.
    static let defaultFindBackups: @Sendable () -> [AutoBackupFile] = {
        let primary = AutoBackupDestination.resolve().directory
        let local = AutoBackupDestination.localFallbackDirectory()
        var files = AutoBackupEngine.list(in: primary)
        if local != primary { files += AutoBackupEngine.list(in: local) }
        return files.sorted { $0.date > $1.date }
    }

    /// Everything that starts the app's work goes through here. A store that opened with 0 completed sessions after a launch that
    /// had some is treated as missing data: NO backfills and NO automatic backup run until the user answers.
    private func proceed(_ container: ModelContainer) {
        let completed = (try? BackupContentSummary.of(store: ModelContext(container)).completedSessions) ?? -1
        let stored = sentinel.completedSessions
        log("ℹ️ Data sentinel: read stored=\(stored) (\(sentinel.describeSource)), store holds \(completed) completed sessions")
        if completed == 0, stored > 0 {
            log("🛑 Data sentinel: BLOCKING (store has 0 completed sessions, last launch had \(stored)); no backfills, no automatic backup")
            missingData = MissingData(expectedSessions: stored)
            backupLookupDone = false
            Task { await loadNewestBackup() }
            return
        }
        if let finding = legacyFinder?(container, completed) {
            log("ℹ️ Legacy store: offering \(finding.candidate.name) (\(finding.candidate.location.rawValue)): \(finding.candidate.completedSessions) completed sessions vs \(completed) in the current store")
            legacyOffer = finding
            return
        }
        startLaunchWork(container) { [weak self] in self?.finishLaunch(container, completed: completed) }
    }

    /// "Bring it over": export the older store's copy and restore it through the coordinator (snapshot first); the file stays.
    func relocateLegacyStore() {
        guard let finding = legacyOffer, let container else { return }
        do {
            try LegacyStoreRelocation.relocate(finding, into: container, snapshotDirectory: directory, sentinel: sentinel)
            offered.markOffered(finding.candidate.url)
            legacyOffer = nil; legacyError = nil
            log("✅ Legacy store: brought \(finding.candidate.name) over")
            NotificationCenter.default.post(name: .didRestoreBackup, object: nil)
            continueAfterLegacyAnswer(container)
        } catch {
            legacyError = "Couldn't bring the older data over: \(error.localizedDescription) Nothing was changed; you can keep using the data you have."
        }
    }

    /// "Not now": remembered, so it is not asked again for this file; the app carries on with the data it opened.
    func declineLegacyStore() {
        guard let finding = legacyOffer, let container else { return }
        offered.markOffered(finding.candidate.url)
        legacyOffer = nil; legacyError = nil
        log("ℹ️ Legacy store: \(finding.candidate.name) declined; not offered again")
        continueAfterLegacyAnswer(container)
    }

    private func continueAfterLegacyAnswer(_ container: ModelContainer) {
        let completed = (try? BackupContentSummary.of(store: ModelContext(container)).completedSessions) ?? -1
        startLaunchWork(container) { [weak self] in self?.finishLaunch(container, completed: completed) }
    }

    /// The pre-backfill backup (awaited), then `work`. Without a backup step `work` runs at once.
    private func startLaunchWork(_ container: ModelContainer, then work: @escaping @MainActor () -> Void) {
        guard backupFirst != nil else { work(); return }
        launching = true
        startupGuard.run(container: container, onContinueWithoutBackup: onContinueWithoutBackup, proceed: work)
    }

    /// The newest backup that decodes and holds completed sessions.
    func loadNewestBackup() async {
        let finder = findBackups
        let files = await Task.detached(priority: .utility) { finder() }.value
        newestBackup = nil; newestBackupSummary = nil
        for f in files {
            if let s = try? BackupContentSummary.of(file: f.url), s.completedSessions > 0 { newestBackup = f; newestBackupSummary = s; break }
        }
        backupLookupDone = true
    }

    /// The one option: restore the newest verified backup through the coordinator (snapshot, marker and sentinel included).
    func restoreNewestBackup() {
        guard let container, let backup = newestBackup else { return }
        do {
            try BackupRestoreCoordinator.restore(from: backup.url, container: container, snapshotDirectory: directory, sentinel: sentinel)
            missingData = nil; missingDataError = nil
            NotificationCenter.default.post(name: .didRestoreBackup, object: nil)
            startLaunchWork(container) { [weak self] in self?.backfills(container); self?.launching = false }
        } catch {
            missingDataError = "Restore failed: \(error.localizedDescription) Nothing was changed."
        }
    }

    static let continueWord = "CONTINUE"
    static func acceptsContinue(typed: String) -> Bool { typed.trimmingCharacters(in: .whitespaces) == continueWord }

    /// Only offered when there is no backup to restore (the data is already gone and there is no other way forward), and only
    /// after the word CONTINUE has been typed: the app then treats the empty store as the real one.
    @discardableResult
    func continueWithEmptyData(typed: String) -> Bool {
        guard Self.acceptsContinue(typed: typed), let container, backupLookupDone, newestBackup == nil else { return false }
        sentinel.record(0)
        missingData = nil
        startLaunchWork(container) { [weak self] in self?.backfills(container); self?.launching = false }
        return true
    }

    /// Called where the app used to run its backfills. With an interrupted-import marker it holds them back and raises the prompt.
    func begin(container: ModelContainer) {
        self.container = container
        guard let marker = InterruptedImportMarker.read(in: directory) else { proceed(container); return }
        guard let snapshot = marker.resolvedSnapshotURL(in: directory) else {
            // nothing to restore from: tell the user once (the marker is deleted, so this never repeats), do not block the app
            InterruptedImportMarker.clear(in: directory)
            showsMissingSnapshotNotice = true
            proceed(container)
            return
        }
        let date = PreImportSnapshots.list(in: directory).first { $0.url.lastPathComponent == snapshot.lastPathComponent }?.date ?? marker.startedAt
        interrupted = Interrupted(snapshotURL: snapshot, snapshotDate: date)
    }

    /// "Restore": the coordinator restores from the marker's snapshot (snapshotting the half-imported state first).
    func restore() {
        guard let pending = interrupted, let container else { return }
        do {
            try BackupRestoreCoordinator.restore(from: pending.snapshotURL, container: container, snapshotDirectory: directory,
                                                 preserveExistingMarker: true)
            // the coordinator cleared the marker on success
            interrupted = nil
            NotificationCenter.default.post(name: .didRestoreBackup, object: nil)
            proceed(container)
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription) Your data is saved and the prompt will appear again on the next launch."
            // the marker stays; the app stays blocked on this answer until the user keeps current data or restore succeeds
        }
    }

    /// "Keep current data": drops the marker and carries on.
    func keepCurrentData() {
        InterruptedImportMarker.clear(in: directory)
        interrupted = nil
        if let container { proceed(container) }
    }

    func dismissError() { errorMessage = nil }
}


/// True while Settings is restoring a backup. The root view is rebuilt twice (before and after the data lands); while this is
/// set, a rebuilt root that sees the still-empty store must not present the first-run welcome sheet.
@MainActor
enum RestoreActivity {
    static var inProgress = false
}
