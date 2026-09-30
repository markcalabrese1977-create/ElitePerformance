import XCTest
import SwiftData
@testable import ElitePerformance

/// Backup round-trip harness (test-only; no app code touched).
///
/// Reads a real backup from the path in EP_BACKUP_FIXTURE (xcodebuild:
/// TEST_RUNNER_EP_BACKUP_FIXTURE). The file holds personal health data and is
/// never copied into the repo; the report contains field names, counts and
/// diffs only, with sample values limited to an allowlist of non-health fields.
///
/// One serial test: step 1 (import -> export diff), step 4 (App Group state),
/// step 2 (fresh-device simulation on the test host's UserDefaults.standard,
/// with the whole app defaults domain and the App Group mechanicalLoad.* keys
/// snapshotted and restored in a defer).
final class BackupRoundTripHarnessTests: XCTestCase {

    // MARK: - Report sink

    private var lines: [String] = []

    private func log(_ s: String = "") {
        lines.append(s)
        print("RTH| \(s)")
    }

    private func flushReport() {
        guard let path = ProcessInfo.processInfo.environment["EP_REPORT_PATH"], !path.isEmpty else { return }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Keys

    private static let completionKeys = [
        "sessionDayLabelBackfill.v1.completed",
        "d5ExerciseIdRepairMigration.v3.completed",
        "exerciseNameSnapshotBackfill.v1.completed",
        "customExerciseDedupMigration.v1.completed",
        "customExerciseUserDefaultsSync.v1.completed",
        "prescriptionNotesClear.v1.completed",
        "apr21SessionHistoryRepairMigration.v3.completed",
        "mechanicalLoadRecovery.v1.completed",
        "customExerciseStoreMigration.v1.completed",
        "bodyweightPhantomLoadMigration.v1.completed",
        "canonicalExerciseIdMigration.v1.completed",
        "week6UpperBCleanupMigration.v1.completed",
        "mesoBlockIsMaintenanceBackfill.v1.completed",
        "customExerciseIdRepairMigration.v1.completed",
        "sessionHistoryBlockBackfill.v1.completed",
        "exerciseNameSnapshotRepair.v6.completed"
    ]

    /// Field names whose values are safe to show in the report (no health data,
    /// no free text).
    private static let sampleAllowlist: Set<String> = [
        "weekInMeso", "readinessRaw", "planEdited", "exerciseNameSnapshot", "dayLabel",
        "statusRaw", "exerciseId", "mesoBlockId", "isMaintenance", "totalWeeks",
        "isBodyweight", "dayLabelSnapshot", "mesoBlockNameSnapshot", "name",
        "programIndex", "appModeRaw", "isPR", "isCompleted", "primaryMuscle",
        "primaryMuscleRaw", "sessionId", "weekIndex", "order", "waveRaw", "priorityRaw",
        "intensifierRaw", "loadOverrideReasonRaw", "title", "subtitle"
    ]

    private static let migrationList: [(String, (ModelContext) -> Void)] = [
        ("ExerciseNameSnapshotBackfill", { ExerciseNameSnapshotBackfill.runIfNeeded(in: $0) }),
        ("ExerciseNameSnapshotRepair", { ExerciseNameSnapshotRepair.runIfNeeded(in: $0) }),
        ("CanonicalExerciseIdMigration", { CanonicalExerciseIdMigration.runIfNeeded(in: $0) }),
        ("CustomExerciseDedupMigration", { CustomExerciseDedupMigration.runIfNeeded(in: $0) }),
        ("D5ExerciseIdRepairMigration", { D5ExerciseIdRepairMigration.runIfNeeded(in: $0) }),
        ("Apr21SessionHistoryRepairMigration", { Apr21SessionHistoryRepairMigration.runIfNeeded(in: $0) }),
        ("SessionHistoryBlockBackfill", { SessionHistoryBlockBackfill.runIfNeeded(in: $0) }),
        ("MechanicalLoadRecoveryMigration", { MechanicalLoadRecoveryMigration.runIfNeeded(in: $0) }),
        ("SessionDayLabelBackfill", { SessionDayLabelBackfill.runIfNeeded(in: $0) }),
        ("CustomExerciseStoreMigration", { CustomExerciseStoreMigration.runIfNeeded(in: $0) }),
        ("CustomExerciseUserDefaultsSyncRepair", { CustomExerciseUserDefaultsSyncRepair.runIfNeeded(in: $0) }),
        ("MesoBlockIsMaintenanceBackfill", { MesoBlockIsMaintenanceBackfill.runIfNeeded(in: $0) }),
        ("BodyweightPhantomLoadMigration", { BodyweightPhantomLoadMigration.runIfNeeded(in: $0) }),
        ("PrescriptionNotesClearMigration", { PrescriptionNotesClearMigration.runIfNeeded(in: $0) }),
        ("Week6UpperBCleanupMigration", { Week6UpperBCleanupMigration.runIfNeeded(in: $0) })
    ]


    private static let flagOwner: [(String, String)] = [
        ("ExerciseNameSnapshotBackfill", "exerciseNameSnapshotBackfill.v1.completed"),
        ("ExerciseNameSnapshotRepair", "exerciseNameSnapshotRepair.v6.completed"),
        ("CanonicalExerciseIdMigration", "canonicalExerciseIdMigration.v1.completed"),
        ("CustomExerciseDedupMigration", "customExerciseDedupMigration.v1.completed"),
        ("D5ExerciseIdRepairMigration", "d5ExerciseIdRepairMigration.v3.completed"),
        ("Apr21SessionHistoryRepairMigration", "apr21SessionHistoryRepairMigration.v3.completed"),
        ("SessionHistoryBlockBackfill", "sessionHistoryBlockBackfill.v1.completed"),
        ("MechanicalLoadRecoveryMigration", "mechanicalLoadRecovery.v1.completed"),
        ("SessionDayLabelBackfill", "sessionDayLabelBackfill.v1.completed"),
        ("CustomExerciseStoreMigration", "customExerciseStoreMigration.v1.completed"),
        ("CustomExerciseUserDefaultsSyncRepair", "customExerciseUserDefaultsSync.v1.completed"),
        ("MesoBlockIsMaintenanceBackfill", "mesoBlockIsMaintenanceBackfill.v1.completed"),
        ("BodyweightPhantomLoadMigration", "bodyweightPhantomLoadMigration.v1.completed"),
        ("PrescriptionNotesClearMigration", "prescriptionNotesClear.v1.completed"),
        ("Week6UpperBCleanupMigration", "week6UpperBCleanupMigration.v1.completed"),
        ("(not in runStartupBackfills) CustomExerciseIdRepairMigration", "customExerciseIdRepairMigration.v1.completed")
    ]

    // MARK: - Container / defaults helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            PRIndex.self, SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private var appDomain: String { Bundle.main.bundleIdentifier ?? "" }

    private func appDomainSnapshot() -> [String: Any] {
        UserDefaults.standard.persistentDomain(forName: appDomain) ?? [:]
    }

    private func restoreAppDomain(_ saved: [String: Any]) {
        UserDefaults.standard.removePersistentDomain(forName: appDomain)
        UserDefaults.standard.setPersistentDomain(saved, forName: appDomain)
    }

    private func groupLoadKeys() -> [String: Double] {
        guard let d = UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID) else { return [:] }
        var out: [String: Double] = [:]
        for (k, v) in d.dictionaryRepresentation() where k.hasPrefix(MechanicalLoadSharedStore.keyPrefix) {
            if let n = v as? Double { out[k] = n }
        }
        return out
    }

    private func restoreGroupLoadKeys(_ saved: [String: Double]) {
        guard let d = UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID) else { return }
        for k in groupLoadKeys().keys { d.removeObject(forKey: k) }
        for (k, v) in saved { d.set(v, forKey: k) }
    }

    private func exportJSON(_ container: ModelContainer) throws -> [String: Any] {
        let ctx = ModelContext(container)
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let data = try Data(contentsOf: result.url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Diff engine

    private struct Entry {
        var count = 0
        var records: [String] = []
        var samples: [String] = []
    }

    private final class Collector {
        var entries: [String: Entry] = [:]
        var orderDiffs: [String: Int] = [:]
        var precisionNormalized = 0
        func add(_ kind: String, _ path: String, record: String?, sample: String? = nil, n: Int = 1) {
            let key = "\(kind)\t\(path)"
            var e = entries[key] ?? Entry()
            e.count += n
            if let r = record, e.records.count < 3, !e.records.contains(r) { e.records.append(r) }
            if let s = sample, e.samples.count < 3, !e.samples.contains(s) { e.samples.append(s) }
            entries[key] = e
        }
    }

    private static let iso = ISO8601DateFormatter()

    private func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    private func idsOf(_ arr: [Any]) -> [String]? {
        var ids: [String] = []
        for el in arr {
            guard let d = el as? [String: Any], let id = d["id"] as? String else { return nil }
            ids.append(id)
        }
        return Set(ids).count == ids.count ? ids : nil
    }

    private func diff(_ a: Any?, _ b: Any?, path: String, record: String?, key: String, into c: Collector) {
        switch (a, b) {
        case let (x as [String: Any], y as [String: Any]):
            let rec = (x["id"] as? String) ?? record
            for k in Set(x.keys).union(y.keys).sorted() {
                let p = path.isEmpty ? k : "\(path).\(k)"
                if x[k] == nil {
                    c.add("extraInExport", p, record: rec)
                } else if y[k] == nil {
                    c.add("missingInExport", p, record: rec)
                } else {
                    diff(x[k], y[k], path: p, record: rec, key: k, into: c)
                }
            }
        case let (x as [Any], y as [Any]):
            let p = path + "[]"
            if let xi = idsOf(x), let yi = idsOf(y) {
                let xs = Set(xi), ys = Set(yi)
                for id in xs.subtracting(ys) { c.add("recordMissingInExport", p, record: id) }
                for id in ys.subtracting(xs) { c.add("recordExtraInExport", p, record: id) }
                let common = xs.intersection(ys)
                if xi.filter({ common.contains($0) }) != yi.filter({ common.contains($0) }) {
                    c.orderDiffs[p, default: 0] += 1
                }
                let yMap = Dictionary(uniqueKeysWithValues: zip(yi, y))
                for (id, el) in zip(xi, x) where ys.contains(id) {
                    diff(el, yMap[id], path: p, record: id, key: key, into: c)
                }
            } else {
                if x.count != y.count {
                    c.add("arrayLengthChanged", p, record: record,
                          sample: "\(x.count)->\(y.count)")
                }
                for i in 0..<min(x.count, y.count) {
                    diff(x[i], y[i], path: p, record: record, key: key, into: c)
                }
            }
        case let (x as NSNumber, y as NSNumber):
            if isBool(x) != isBool(y) {
                c.add("typeChanged", path, record: record)
            } else if abs(x.doubleValue - y.doubleValue) > 1e-9 {
                c.add("valueChanged", path, record: record,
                      sample: Self.allowSample(key) ? "\(x)->\(y)" : nil)
            }
        case let (x as String, y as String):
            if x != y {
                if let dx = Self.iso.date(from: x), let dy = Self.iso.date(from: y),
                   floor(dx.timeIntervalSince1970) == floor(dy.timeIntervalSince1970) {
                    c.precisionNormalized += 1
                } else {
                    c.add("valueChanged", path, record: record,
                          sample: Self.allowSample(key) ? "\(x.prefix(60))->\(y.prefix(60))" : nil)
                }
            }
        case (is NSNull, is NSNull):
            break
        default:
            c.add("typeChanged", path, record: record)
        }
    }

    private static func allowSample(_ key: String) -> Bool { sampleAllowlist.contains(key) }

    private func render(_ c: Collector, indent: String = "  ") {
        if c.entries.isEmpty && c.orderDiffs.isEmpty {
            log("\(indent)(no differences)")
        }
        for key in c.entries.keys.sorted() {
            let e = c.entries[key]!
            let parts = key.split(separator: "\t").map(String.init)
            var s = "\(indent)\(parts[0]): \(parts[1])  x\(e.count)"
            if !e.samples.isEmpty { s += "  samples=\(e.samples)" }
            if !e.records.isEmpty { s += "  records=\(e.records)" }
            log(s)
        }
        for (p, n) in c.orderDiffs.sorted(by: { $0.key < $1.key }) {
            log("\(indent)orderDiffers: \(p)  (\(n) array instance(s) reordered among common ids)")
        }
        if c.precisionNormalized > 0 {
            log("\(indent)[normalized] timestamp-precision-only differences: \(c.precisionNormalized)")
        }
    }


    /// Order-insensitive view of sessionHistory[].exercises[] and customExercises[] ids,
    /// so a reorder can be told apart from a content change. Counts only.
    private func orderReport(_ a: [String: Any], _ b: [String: Any], label: String) {
        func canon(_ e: [String: Any]) -> String {
            "\(e["name"] ?? "")|\(e["primaryMuscle"] ?? "")|\(e["sets"] ?? "")|\(e["reps"] ?? "")|\(e["volume"] ?? "")"
        }
        let ha = (a["sessionHistory"] as? [[String: Any]]) ?? []
        let hb = (b["sessionHistory"] as? [[String: Any]]) ?? []
        var contentDiff = 0, orderOnly = 0
        for (x, y) in zip(ha, hb) {
            let ex = ((x["exercises"] as? [[String: Any]]) ?? []).map(canon)
            let ey = ((y["exercises"] as? [[String: Any]]) ?? []).map(canon)
            if ex == ey { continue }
            if ex.sorted() == ey.sorted() { orderOnly += 1 } else { contentDiff += 1 }
        }
        log("   [\(label)] sessionHistory rows: order-only exercise diffs=\(orderOnly), content diffs (multiset)=\(contentDiff), rowCount \(ha.count)->\(hb.count)")
        func ids(_ j: [String: Any]) -> [String] { ((j["customExercises"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String } }
        let ia = ids(a), ib = ids(b)
        log("   [\(label)] customExercises: count \(ia.count)->\(ib.count); duplicate ids a=\(ia.count - Set(ia).count) b=\(ib.count - Set(ib).count); ids only in a=\(Set(ia).subtracting(ib).count) only in b=\(Set(ib).subtracting(ia).count)")
        let na = ((a["customExercises"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        let nb = ((b["customExercises"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        log("   [\(label)] customExercises names: duplicate names a=\(na.count - Set(na).count) b=\(nb.count - Set(nb).count); names only in a=\(Set(na).subtracting(nb).sorted()) only in b=\(Set(nb).subtracting(na).sorted())")
    }

    private func counts(_ j: [String: Any]) -> String {
        let sessions = (j["sessions"] as? [[String: Any]]) ?? []
        let items = sessions.flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
        let logs = items.flatMap { ($0["logs"] as? [[String: Any]]) ?? [] }
        func n(_ k: String) -> Int { (j[k] as? [Any])?.count ?? 0 }
        return "mesoBlocks=\(n("mesoBlocks")) sessions=\(sessions.count) items=\(items.count) setLogs=\(logs.count) "
            + "sessionHistory=\(n("sessionHistory")) exerciseNotes=\(n("exerciseNotes")) customExercises=\(n("customExercises")) "
            + "appState=\(j["appState"] == nil ? 0 : 1) userProfile=\(j["userProfile"] == nil ? 0 : 1) user=\(j["user"] == nil ? 0 : 1)"
    }

    // MARK: - The harness

    func testBackupRoundTripHarness() throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !fixturePath.isEmpty else {
            throw XCTSkip("EP_BACKUP_FIXTURE not set")
        }
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let originalData = try Data(contentsOf: fixtureURL)
        let original = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]

        // Snapshot everything the importer/migrations can touch; restore on any exit.
        let savedDomain = appDomainSnapshot()
        let savedGroup = groupLoadKeys()
        defer {
            restoreAppDomain(savedDomain)
            restoreGroupLoadKeys(savedGroup)
            flushReport()
        }

        log("== FIXTURE ==")
        log("version=\(original["version"] ?? "nil")  \(counts(original))")

        // ---------- Step 4 pre-state (before import) + sentinel ----------
        let preGroupCount = groupLoadKeys().count
        let sentinelKey = MechanicalLoadSharedStore.keyPrefix + "1900-01-01"
        let group = UserDefaults(suiteName: MechanicalLoadSharedStore.appGroupID)
        group?.set(12345.0, forKey: sentinelKey)
        let sentinelWritable = (group?.double(forKey: sentinelKey) == 12345.0)

        // ---------- Step 1: import -> export ----------
        let container = try makeContainer()
        let importResult = try BackupSnapshotImporter.importFullBackupJSON(from: fixtureURL, modelContainer: container)
        log("")
        log("== STEP 1: import -> export vs original ==")
        log("importer reported: mesoBlocks=\(importResult.mesoBlockCount) sessions=\(importResult.sessionCount) "
            + "history=\(importResult.sessionHistoryCount) notes=\(importResult.exerciseNoteCount) custom=\(importResult.customExerciseCount)")
        let export1 = try exportJSON(container)
        log("original: \(counts(original))")
        log("export1 : \(counts(export1))")
        let c1 = Collector()
        diff(original, export1, path: "", record: nil, key: "", into: c1)
        render(c1)
        orderReport(original, export1, label: "step1")

        // Targeted relink checks
        let origSessions = (original["sessions"] as? [[String: Any]]) ?? []
        let expSessions = (export1["sessions"] as? [[String: Any]]) ?? []
        let origMeso = origSessions.filter { $0["mesoBlockId"] != nil }.count
        let expMeso = expSessions.filter { $0["mesoBlockId"] != nil }.count
        let origNoWeek = origSessions.filter { $0["weekInMeso"] == nil }.count
        let expNoWeek = expSessions.filter { $0["weekInMeso"] == nil }.count
        let mesoIds = Set(((original["mesoBlocks"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
        let dangling = origSessions.filter {
            if let m = $0["mesoBlockId"] as? String { return !mesoIds.contains(m) }
            return false
        }.count
        log("  [relink] sessions with mesoBlockId: original=\(origMeso) export=\(expMeso); dangling mesoBlockId in original=\(dangling)")
        log("  [relink] sessions with no weekInMeso: original=\(origNoWeek) export=\(expNoWeek)")

        // ---------- Step 4: MechanicalLoadSharedStore after import ----------
        log("")
        log("== STEP 4: MechanicalLoadSharedStore after import ==")
        let postImportGroup = groupLoadKeys()
        log("group keys before import (pre-sentinel): \(preGroupCount); after import: \(postImportGroup.count) (includes sentinel if retained)")
        log("sentinel written & readable in group defaults: \(sentinelWritable)")
        log("sentinel (mechanicalLoad.1900-01-01) still present after import: \(postImportGroup[sentinelKey] != nil)")
        do {
            let ctx = ModelContext(container)
            let histories = try ctx.fetch(FetchDescriptor<SessionHistory>())
            let cal = Calendar.current
            var expected: [Date: Double] = [:]
            for h in histories { expected[cal.startOfDay(for: h.date), default: 0] += (h.mechanicalLoad ?? 0) }
            let expectedPositive = expected.filter { $0.value > 0 }
            var match = 0, mismatch = 0, absent = 0
            for (day, total) in expectedPositive {
                let actual = MechanicalLoadSharedStore.read(for: day)
                if actual == 0 { absent += 1 } else if abs(actual - total) < 1e-6 { match += 1 } else { mismatch += 1 }
            }
            let expectedKeys = Set(expectedPositive.keys.map { MechanicalLoadSharedStore.keyPrefix + Self.dateKey($0) })
            let extras = postImportGroup.keys.filter { !expectedKeys.contains($0) && $0 != sentinelKey }.count
            log("SessionHistory rows=\(histories.count); days with expected load>0=\(expectedPositive.count)")
            log("store vs expected: matching=\(match) mismatched=\(mismatch) absent-from-store=\(absent) extra-keys-not-in-history=\(extras)")
        }
        group?.removeObject(forKey: sentinelKey)

        // ---------- Step 2: fresh-device simulation ----------
        log("")
        log("== STEP 2: startup migrations with completion flags cleared (test-host defaults) ==")
        let flagsBefore = Self.completionKeys.filter { UserDefaults.standard.bool(forKey: $0) }
        log("flags true on host before clearing: \(flagsBefore.count)/\(Self.completionKeys.count)")
        for k in Self.completionKeys { UserDefaults.standard.removeObject(forKey: k) }

        let migrations = Self.migrationList
        // Same context the app uses for the whole sequence.
        let migCtx = ModelContext(container)
        var prev = export1
        for (name, run) in migrations {
            let domainBefore = appDomainSnapshot()
            run(migCtx)
            try? migCtx.save()
            let domainAfter = appDomainSnapshot()
            let changedKeys = Set(domainBefore.keys).union(domainAfter.keys).filter {
                !((domainBefore[$0] as? NSObject)?.isEqual(domainAfter[$0]) ?? (domainAfter[$0] == nil))
            }.sorted()
            let now = try exportJSON(container)
            let c = Collector()
            diff(prev, now, path: "", record: nil, key: "", into: c)
            log("-- \(name): defaults keys changed=\(changedKeys)")
            render(c, indent: "   ")
            orderReport(prev, now, label: name)
            prev = now
        }
        log("-- cumulative (all migrations) vs step-1 export:")
        let cAll = Collector()
        diff(export1, prev, path: "", record: nil, key: "", into: cAll)
        render(cAll, indent: "   ")
        log("flags true after run: \(Self.completionKeys.filter { UserDefaults.standard.bool(forKey: $0) }.count)/\(Self.completionKeys.count)")

        let groupAfterMig = groupLoadKeys()
        log("group mechanicalLoad.* keys after migrations: \(groupAfterMig.count) (was \(postImportGroup.count - (postImportGroup[sentinelKey] != nil ? 1 : 0)) right after import)")
    }

    // MARK: - Realistic order: fresh install first launch -> restore -> next launch

    func testFreshInstallThenRestoreOrder() throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !fixturePath.isEmpty else {
            throw XCTSkip("EP_BACKUP_FIXTURE not set")
        }
        let fixtureURL = URL(fileURLWithPath: fixturePath)

        let savedDomain = appDomainSnapshot()
        let savedGroup = groupLoadKeys()
        defer {
            restoreAppDomain(savedDomain)
            restoreGroupLoadKeys(savedGroup)
            flushReport()
        }

        // Fresh device: no completion flags, no custom-exercise mirror/legacy keys, no meso.* keys,
        // no App Group load keys. (All inside the snapshot/restore above.)
        let freshClear = Self.completionKeys + [
            "custom_exercises_v2", "custom_exercises_mark_v1", "custom_exercises_angela_v1",
            "meso.activeStartDateEpoch", "meso.scheduledStartDateEpoch", "meso.promptSnoozeEpoch",
            "meso.anchorDate", "meso.anchorDayNumber"
        ]
        for k in freshClear { UserDefaults.standard.removeObject(forKey: k) }
        restoreGroupLoadKeys([:])

        log("== REALISTIC ORDER: first launch (empty store) -> restore -> next launch ==")
        let container = try makeContainer()

        // Phase A: first launch on an empty store.
        let ctxA = ModelContext(container)
        for (_, run) in Self.migrationList { run(ctxA) }
        try? ctxA.save()
        log("")
        log("-- FLAG TABLE after first launch on an EMPTY store (nothing to migrate) --")
        var unsetAfterEmpty: [String] = []
        for (owner, key) in Self.flagOwner {
            let on = UserDefaults.standard.bool(forKey: key)
            if !on { unsetAfterEmpty.append(owner) }
            log("   \(on ? "SET  " : "unset") \(key)   <- \(owner)")
        }
        log("   set=\(Self.completionKeys.count - unsetAfterEmpty.count)/\(Self.completionKeys.count); unset (will still run after restore): \(unsetAfterEmpty)")
        log("   custom_exercises_v2 present after empty launch: \(UserDefaults.standard.data(forKey: "custom_exercises_v2") != nil)")

        // Phase B: restore the fixture.
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: fixtureURL, modelContainer: container)
        let importOnly = try exportJSON(container)
        log("")
        log("-- after import: \(counts(importOnly))")
        log("   custom_exercises_v2 present after import: \(UserDefaults.standard.data(forKey: "custom_exercises_v2") != nil)")

        // Phase C: next launch — same migrations, flags as left by phase A.
        let flagsBeforeC = Self.completionKeys.filter { UserDefaults.standard.bool(forKey: $0) }
        var prev = importOnly
        for (name, run) in Self.migrationList {
            let ctx = ModelContext(container)
            let domainBefore = appDomainSnapshot()
            run(ctx)
            try? ctx.save()
            let domainAfter = appDomainSnapshot()
            let changedKeys = Set(domainBefore.keys).union(domainAfter.keys).filter {
                !((domainBefore[$0] as? NSObject)?.isEqual(domainAfter[$0]) ?? (domainAfter[$0] == nil))
            }.sorted()
            let now = try exportJSON(container)
            let c = Collector()
            diff(prev, now, path: "", record: nil, key: "", into: c)
            c.entries = c.entries.filter { !$0.key.hasPrefix("valueChanged\texportedAt") }
            if !c.entries.isEmpty || !changedKeys.isEmpty {
                log("-- next launch: \(name): defaults keys changed=\(changedKeys)")
                render(c, indent: "   ")
                orderReport(prev, now, label: name)
            }
            prev = now
        }
        log("")
        log("-- next launch, cumulative vs import-only export (exportedAt ignored):")
        let cAll = Collector()
        diff(importOnly, prev, path: "", record: nil, key: "", into: cAll)
        cAll.entries = cAll.entries.filter { !$0.key.hasPrefix("valueChanged\texportedAt") }
        render(cAll, indent: "   ")
        orderReport(importOnly, prev, label: "cumulative")
        log("   flags set before next launch=\(flagsBeforeC.count)/16, after=\(Self.completionKeys.filter { UserDefaults.standard.bool(forKey: $0) }.count)/16")
        log("   group mechanicalLoad.* keys after next launch: \(groupLoadKeys().count)")
    }

    private static func dateKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
