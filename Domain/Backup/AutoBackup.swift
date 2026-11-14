import Foundation
import SwiftData
import Combine

// MARK: - Destination

/// Where automatic backups are written. iCloud Drive (the app's ubiquity container) is off-device; the fallback is a local folder.
enum AutoBackupDestination: Equatable {
    case iCloud(URL)
    case local(URL)

    var directory: URL { switch self { case .iCloud(let u), .local(let u): return u } }
    var isOffDevice: Bool { if case .iCloud = self { return true } else { return false } }

    static let containerIdentifier = "iCloud.com.markcalabrese.ElitePerformance"

    /// Looks up the ubiquity container (this can block; call it OFF the main thread). Without iCloud (signed out, disabled,
    /// no network identity) it falls back to Application Support/AutoBackups and says so: not off-device.
    static func resolve() -> AutoBackupDestination {
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) {
            return .iCloud(container.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Backups", isDirectory: true))
        }
        return .local(localFallbackDirectory())
    }

    static func localFallbackDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AutoBackups", isDirectory: true)
    }
}

struct AutoBackupFile: Equatable, Identifiable {
    let url: URL
    let date: Date
    var id: URL { url }
}

enum AutoBackupError: LocalizedError {
    case emptyStore
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyStore: return "There is nothing to back up yet."
        case .verifyFailed(let m): return "The backup did not verify (\(m)); the previous backup was kept."
        }
    }
}

// MARK: - Engine (synchronous, no UI, testable)

enum AutoBackupEngine {
    static let prefix = "ElitePerformance_AutoBackup_"

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
        return f
    }()

    static func fileName(for date: Date) -> String { prefix + stamp.string(from: date) + ".json" }

    /// Newest first. Only files this service wrote (by name) are listed, and so ever pruned.
    static func list(in directory: URL) -> [AutoBackupFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { u -> AutoBackupFile? in
            let n = u.lastPathComponent
            guard n.hasPrefix(prefix), n.hasSuffix(".json") else { return nil }
            guard let d = stamp.date(from: String(n.dropFirst(prefix.count).dropLast(5))) else { return nil }
            return AutoBackupFile(url: u, date: d)
        }.sorted { $0.date > $1.date }
    }

    /// Verify-then-move. `temp` is an export written to a temporary file; it is decoded and its counts (sessions, history,
    /// custom exercises, mesos) compared with `live`. Only then is it placed (copied with file coordination into `directory`
    /// under a NEW name, so an existing backup is never overwritten) and the placed copy verified again. Any failure removes
    /// what this call wrote and throws: a failed verify can never replace or damage a good backup.
    static func place(temp: URL, live: BackupContentSummary, into directory: URL, now: Date, coordinated: Bool) throws -> AutoBackupFile {
        let fm = FileManager.default
        let tempSummary: BackupContentSummary
        do { tempSummary = try BackupContentSummary.of(file: temp) } catch { throw AutoBackupError.verifyFailed("unreadable: \(error.localizedDescription)") }
        guard tempSummary.verifiedCounts == live.verifiedCounts else {
            throw AutoBackupError.verifyFailed("counts differ from your data: \(tempSummary.verifiedCounts) vs \(live.verifiedCounts)")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(fileName(for: now))
        do {
            if coordinated {
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dest, options: .forReplacing, error: &coordinationError) { url in
                    do {
                        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                        try fm.copyItem(at: temp, to: url)
                    } catch { copyError = error }
                }
                if let e = coordinationError ?? copyError { throw e }
            } else {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: temp, to: dest)
            }
            let placed = try BackupContentSummary.of(file: dest)
            guard placed.verifiedCounts == live.verifiedCounts else { throw AutoBackupError.verifyFailed("the copy in place differs") }
        } catch {
            try? fm.removeItem(at: dest)
            if let e = error as? AutoBackupError { throw e }
            throw AutoBackupError.verifyFailed(error.localizedDescription)
        }
        return AutoBackupFile(url: dest, date: now)
    }

    // MARK: Retention

    /// The dates to keep: the newest backup always, the newest of each of the 7 most recent days, 8 most recent weeks and
    /// 12 most recent months that have one.
    static func keepSet(_ dates: [Date], calendar: Calendar = Calendar(identifier: .gregorian)) -> Set<Date> {
        let sorted = dates.sorted(by: >)
        guard let newest = sorted.first else { return [] }
        var keep: Set<Date> = [newest]
        func newestPerBucket(_ key: (Date) -> DateComponents, limit: Int) {
            var seen: [DateComponents] = []
            for d in sorted {
                let k = key(d)
                if seen.contains(k) { continue }
                if seen.count == limit { break }
                seen.append(k); keep.insert(d)
            }
        }
        newestPerBucket({ calendar.dateComponents([.year, .month, .day], from: $0) }, limit: 7)
        newestPerBucket({ calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0) }, limit: 8)
        newestPerBucket({ calendar.dateComponents([.year, .month], from: $0) }, limit: 12)
        return keep
    }

    @discardableResult
    static func prune(in directory: URL, calendar: Calendar = Calendar(identifier: .gregorian)) -> [AutoBackupFile] {
        let files = list(in: directory)
        let keep = keepSet(files.map(\.date), calendar: calendar)
        var removed: [AutoBackupFile] = []
        for f in files where !keep.contains(f.date) {
            if (try? FileManager.default.removeItem(at: f.url)) != nil { removed.append(f) }
        }
        return removed
    }
}

// MARK: - Device state (not part of a backup)

/// Status of automatic backups. This is DEVICE state: it describes this device's backup history, so it is registered in
/// PersistedKeyRegistry and excluded from a restore (restoring an old backup must not claim "backed up just now").
struct AutoBackupStatusStore {
    var defaults: UserDefaults = .standard

    var lastSuccess: Date? {
        get { (defaults.object(forKey: "autoBackup.lastSuccess") as? Double).map { Date(timeIntervalSince1970: $0) } }
        nonmutating set { defaults.set(newValue?.timeIntervalSince1970, forKey: "autoBackup.lastSuccess") }
    }
    /// The last success that reached iCloud (the banner is about this one).
    var lastOffDeviceSuccess: Date? {
        get { (defaults.object(forKey: "autoBackup.lastOffDeviceSuccess") as? Double).map { Date(timeIntervalSince1970: $0) } }
        nonmutating set { defaults.set(newValue?.timeIntervalSince1970, forKey: "autoBackup.lastOffDeviceSuccess") }
    }
    var lastWasOffDevice: Bool {
        get { defaults.bool(forKey: "autoBackup.lastWasOffDevice") }
        nonmutating set { defaults.set(newValue, forKey: "autoBackup.lastWasOffDevice") }
    }
    var lastVerified: Bool {
        get { defaults.bool(forKey: "autoBackup.lastVerified") }
        nonmutating set { defaults.set(newValue, forKey: "autoBackup.lastVerified") }
    }
    var lastLaunchCommit: String? {
        get { defaults.string(forKey: "autoBackup.lastLaunchCommit") }
        nonmutating set { defaults.set(newValue, forKey: "autoBackup.lastLaunchCommit") }
    }
    var lastForegroundDay: String? {
        get { defaults.string(forKey: "autoBackup.lastForegroundDay") }
        nonmutating set { defaults.set(newValue, forKey: "autoBackup.lastForegroundDay") }
    }
    var bannerDismissedDay: String? {
        get { defaults.string(forKey: "autoBackup.bannerDismissedDay") }
        nonmutating set { defaults.set(newValue, forKey: "autoBackup.bannerDismissedDay") }
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func recordSuccess(at date: Date, offDevice: Bool) {
        lastSuccess = date
        lastWasOffDevice = offDevice
        lastVerified = true
        if offDevice { lastOffDeviceSuccess = date }
    }

    /// FF: no verified off-device backup for 7 days (or ever), and not dismissed today.
    func shouldShowBanner(now: Date, hasData: Bool, calendar: Calendar = .current) -> Bool {
        guard hasData else { return false }
        if bannerDismissedDay == Self.dayString(now, calendar: calendar) { return false }
        guard let last = lastOffDeviceSuccess else { return true }
        return now.timeIntervalSince(last) > 7 * 86_400
    }
    func dismissBannerForToday(now: Date, calendar: Calendar = .current) { bannerDismissedDay = Self.dayString(now, calendar: calendar) }
}

// MARK: - Verify (Settings → Verify latest backup)

struct AutoBackupVerification: Equatable {
    let file: String
    let backup: [Int]
    let live: [Int]
    var matches: Bool { backup == live }
    var summary: String {
        func f(_ c: [Int]) -> String { "\(c[0]) sessions · \(c[1]) history · \(c[2]) custom exercises · \(c[3]) blocks" }
        return matches ? "Verified: \(f(backup))" : "Does not match. Backup: \(f(backup)). This device: \(f(live))."
    }

    /// Decodes `file` into a SCRATCH in-memory container through the real importer (without the device side effects) and
    /// compares what ended up in it with the live store.
    static func verify(file: URL, against live: ModelContext) throws -> AutoBackupVerification {
        let scratch = try ModelContainer(
            for: AppSchema.makeSchema(),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        try BackupSnapshotImporter.importFullBackupJSON(from: file, modelContainer: scratch, applyingDeviceSideEffects: false)
        return AutoBackupVerification(
            file: file.lastPathComponent,
            backup: try BackupContentSummary.of(store: ModelContext(scratch)).verifiedCounts,
            live: try BackupContentSummary.of(store: live).verifiedCounts)
    }
}

// MARK: - Service

@MainActor
final class AutoBackupService: ObservableObject {
    static let shared = AutoBackupService()

    enum Reason: String { case sessionCompleted, buildChanged, daily, manual }

    @Published private(set) var statusRevision = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isRunning = false

    let status: AutoBackupStatusStore
    private let resolveDestination: @Sendable () -> AutoBackupDestination
    private let now: () -> Date
    private let currentCommit: () -> String
    private let calendar: Calendar

    init(status: AutoBackupStatusStore = AutoBackupStatusStore(),
         resolveDestination: @escaping @Sendable () -> AutoBackupDestination = { AutoBackupDestination.resolve() },
         now: @escaping () -> Date = { Date() },
         currentCommit: @escaping () -> String = { BuildInfo.commit },
         calendar: Calendar = .current) {
        self.status = status
        self.resolveDestination = resolveDestination
        self.now = now
        self.currentCommit = currentCommit
        self.calendar = calendar
    }

    // Triggers ---------------------------------------------------------------

    /// (1) A session was marked completed.
    func sessionCompleted(container: ModelContainer) {
        guard let pending = try? export(container: container) else { return }
        finish(pending, reason: .sessionCompleted, container: container)
    }

    /// (2) Launch of a build whose commit differs from the last launch's. Called by `StartupGate` after the interrupted-import
    /// check and BEFORE the backfills: the export (the data as it was before any backfill touches it) is taken synchronously
    /// here; verifying and placing the file continues in the background. Returns whether a backup was started.
    @discardableResult
    func launchBackupIfBuildChanged(container: ModelContainer) -> Bool {
        let commit = currentCommit()
        guard status.lastLaunchCommit != commit else { return false }
        guard let pending = try? export(container: container) else { return false }
        finish(pending, reason: .buildChanged, container: container, launchCommit: commit)
        return true
    }

    /// (3) The app came to the foreground: the first time each day, back up if the last success is more than 24h old.
    @discardableResult
    func foregrounded(container: ModelContainer) -> Bool {
        let today = AutoBackupStatusStore.dayString(now(), calendar: calendar)
        guard status.lastForegroundDay != today else { return false }
        status.lastForegroundDay = today
        if let last = status.lastSuccess, now().timeIntervalSince(last) <= 24 * 3600 { return false }
        guard let pending = try? export(container: container) else { return false }
        finish(pending, reason: .daily, container: container)
        return true
    }

    /// Settings → Back up now.
    func backUpNow(container: ModelContainer) async -> Result<AutoBackupFile, Error> {
        do {
            let pending = try export(container: container)
            return .success(try await place(pending, reason: .manual, launchCommit: nil))
        } catch { lastError = error.localizedDescription; return .failure(error) }
    }

    // Pipeline ---------------------------------------------------------------

    struct Pending { let temp: URL; let live: BackupContentSummary }

    /// The synchronous half: export the live store to a temp file and note its counts.
    func export(container: ModelContainer) throws -> Pending {
        let ctx = ModelContext(container)
        let live = try BackupContentSummary.of(store: ctx)
        if live.isEmpty { throw AutoBackupError.emptyStore }
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        return Pending(temp: result.url, live: live)
    }

    private func finish(_ pending: Pending, reason: Reason, container: ModelContainer, launchCommit: String? = nil) {
        Task { @MainActor in
            do { _ = try await place(pending, reason: reason, launchCommit: launchCommit) }
            catch { lastError = error.localizedDescription }
        }
    }

    /// The asynchronous half: look up the destination off the main thread, verify, place, prune, record.
    func place(_ pending: Pending, reason: Reason, launchCommit: String?) async throws -> AutoBackupFile {
        isRunning = true
        defer { isRunning = false; try? FileManager.default.removeItem(at: pending.temp) }
        let resolver = resolveDestination
        let stamp = now()
        let (file, destination) = try await Task.detached(priority: .utility) { () -> (AutoBackupFile, AutoBackupDestination) in
            let destination = resolver()
            let file = try AutoBackupEngine.place(temp: pending.temp, live: pending.live, into: destination.directory, now: stamp,
                                                  coordinated: destination.isOffDevice)
            AutoBackupEngine.prune(in: destination.directory)
            return (file, destination)
        }.value
        status.recordSuccess(at: stamp, offDevice: destination.isOffDevice)
        if let launchCommit { status.lastLaunchCommit = launchCommit }
        lastError = nil
        statusRevision += 1
        return file
    }

    // Listing for Settings -----------------------------------------------------

    func availableBackups() async -> (files: [AutoBackupFile], destination: AutoBackupDestination) {
        let resolver = resolveDestination
        return await Task.detached(priority: .utility) {
            let d = resolver()
            return (AutoBackupEngine.list(in: d.directory), d)
        }.value
    }
}
