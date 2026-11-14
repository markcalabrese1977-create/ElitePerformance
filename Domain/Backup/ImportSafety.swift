import Foundation
import SwiftData

/// What a backup (a file, or the live store) holds, for the import confirmation and for verifying a pre-import snapshot.
struct BackupContentSummary: Equatable {
    var exportedAt: Date?
    var sessions: Int
    var completedSessions: Int
    var lastCompletedDate: Date?
    var sessionHistory: Int
    var customExercises: Int
    var mesoBlocks: Int

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
            customExercises: snap.customExercises.count, mesoBlocks: snap.mesoBlocks.count)
    }

    static func of(store context: ModelContext) throws -> BackupContentSummary {
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let completed = sessions.filter { $0.status == .completed }
        return BackupContentSummary(
            exportedAt: nil, sessions: sessions.count, completedSessions: completed.count,
            lastCompletedDate: completed.map(\.date).max(),
            sessionHistory: try context.fetchCount(FetchDescriptor<SessionHistory>()),
            customExercises: try context.fetchCount(FetchDescriptor<CustomExercise>()),
            mesoBlocks: try context.fetchCount(FetchDescriptor<MesoBlock>()))
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

/// THE import path. Settings' import and "Restore pre-import state" both go through it, so both snapshot first.
enum BackupRestoreCoordinator {
    typealias Importer = (URL, ModelContainer) throws -> BackupSnapshotImportResult

    /// `importer` is the real importer; tests substitute one that fails after it has changed the store.
    @discardableResult
    static func restore(from url: URL, container: ModelContainer, snapshotDirectory: URL = PreImportSnapshots.defaultDirectory(),
                        now: Date = Date(),
                        importer: Importer = { try BackupSnapshotImporter.importFullBackupJSON(from: $0, modelContainer: $1) }) throws -> BackupSnapshotImportResult {
        let context = ModelContext(container)
        let snapshot = try PreImportSnapshots.take(from: context, in: snapshotDirectory, now: now)   // throws: import never starts
        do {
            return try importer(url, container)
        } catch {
            // The importer may have changed the store before it failed; put the old data back from the snapshot.
            // The snapshot file is never deleted here, whatever happens.
            guard let snapshot else { throw error }
            do {
                _ = try importer(snapshot.url, container)
            } catch let recoveryError {
                throw NSError(domain: "BackupRestore", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "\(error.localizedDescription) Putting your previous data back also failed (\(recoveryError.localizedDescription)). It is saved: restore it from Settings → Restore pre-import state."])
            }
            throw NSError(domain: "BackupRestore", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(error.localizedDescription) Your previous data was put back."])
        }
    }
}
