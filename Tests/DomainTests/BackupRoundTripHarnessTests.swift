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
        "prIndexRuleVersion", "prIndexTwelveRepRule.v1.completed",
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
        "prescribedSetsBackfill.v1.completed",
        "plannedDateBackfill.v1.completed",
        "customExerciseIdRepairMigration.v1.completed",
        "sessionHistoryBlockBackfill.v1.completed",
        "exerciseNameSnapshotRepair.v6.completed",
        "twelveWeekMesoConversion.v1.completed",
        "twelveWeekMesoConversion.v1.dryRunLogged.v2",
        "twelveWeekMesoConversion.v1.shapeWarned"
    ]

    /// Field names whose values are safe to show in the report (no health data,
    /// no free text).
    private static let sampleAllowlist: Set<String> = [
        "weekInMeso", "readinessRaw", "planEdited", "exerciseNameSnapshot", "dayLabel",
        "statusRaw", "exerciseId", "mesoBlockId", "isMaintenance", "totalWeeks",
        "isBodyweight", "dayLabelSnapshot", "mesoBlockNameSnapshot", "name",
        "programIndex", "isPR", "isCompleted", "primaryMuscle",
        "primaryMuscleRaw", "sessionId", "weekIndex", "order", "waveRaw", "priorityRaw",
        "intensifierRaw", "loadOverrideReasonRaw", "title", "subtitle"
    ]

    private static let migrationList: [(String, (ModelContext) -> Void)] = [
        ("ExerciseNameSnapshotBackfill", { ExerciseNameSnapshotBackfill.runIfNeeded(in: $0) }),
        ("CanonicalExerciseIdMigration", { CanonicalExerciseIdMigration.runIfNeeded(in: $0) }),
        ("CustomExerciseDedupMigration", { CustomExerciseDedupMigration.runIfNeeded(in: $0) }),
        ("SessionHistoryBlockBackfill", { SessionHistoryBlockBackfill.runIfNeeded(in: $0) }),
        ("MechanicalLoadRecoveryMigration", { MechanicalLoadRecoveryMigration.runIfNeeded(in: $0) }),
        ("CustomExerciseStoreMigration", { CustomExerciseStoreMigration.runIfNeeded(in: $0) }),
        ("CustomExerciseUserDefaultsSyncRepair", { CustomExerciseUserDefaultsSyncRepair.runIfNeeded(in: $0) }),
        ("MesoBlockIsMaintenanceBackfill", { MesoBlockIsMaintenanceBackfill.runIfNeeded(in: $0) }),
        ("BodyweightPhantomLoadMigration", { BodyweightPhantomLoadMigration.runIfNeeded(in: $0) }),
        ("PrescribedSetsBackfill", { PrescribedSetsBackfill.runIfNeeded(in: $0) }),
        ("PlannedDateBackfill", { PlannedDateBackfill.runIfNeeded(in: $0) }),
    ]


    private static let flagOwner: [(String, String)] = [
        ("ExerciseNameSnapshotBackfill", "exerciseNameSnapshotBackfill.v1.completed"),
        ("CanonicalExerciseIdMigration", "canonicalExerciseIdMigration.v1.completed"),
        ("CustomExerciseDedupMigration", "customExerciseDedupMigration.v1.completed"),
        ("SessionHistoryBlockBackfill", "sessionHistoryBlockBackfill.v1.completed"),
        ("MechanicalLoadRecoveryMigration", "mechanicalLoadRecovery.v1.completed"),
        ("CustomExerciseStoreMigration", "customExerciseStoreMigration.v1.completed"),
        ("CustomExerciseUserDefaultsSyncRepair", "customExerciseUserDefaultsSync.v1.completed"),
        ("MesoBlockIsMaintenanceBackfill", "mesoBlockIsMaintenanceBackfill.v1.completed"),
        ("BodyweightPhantomLoadMigration", "bodyweightPhantomLoadMigration.v1.completed"),
        ("PrescribedSetsBackfill", "prescribedSetsBackfill.v1.completed"),
        ("PlannedDateBackfill", "plannedDateBackfill.v1.completed"),
        ("(not in runStartupBackfills) CustomExerciseIdRepairMigration", "customExerciseIdRepairMigration.v1.completed")
    ]

    // MARK: - Container / defaults helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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

// MARK: - Another user's store: startup repairs must leave it byte-identical

/// A store that carries every shape the retired one-user repairs used to look for. The registered
/// `StartupBackfills` must leave it untouched.
final class OtherUsersStoreStartupTests: XCTestCase {

    /// The effort-mode one-shot gives a profile with no stored mode its resolved one; the export carries it under userProfile.
    static func dropOneShotEffortMode(_ json: inout [String: Any]) {
        guard var profile = json["userProfile"] as? [String: Any] else { return }
        if let raw = profile["effortModeRaw"] as? String { XCTAssertTrue(["simple", "detailed"].contains(raw), "the one-shot writes Simple or Detailed, never Off") }
        profile.removeValue(forKey: "effortModeRaw")
        json["userProfile"] = profile
    }

    private var container: ModelContainer!

    private static let completionKeys = [
        "exerciseNameSnapshotBackfill.v1.completed", "exerciseNameSnapshotRepair.v6.completed",
        "canonicalExerciseIdMigration.v1.completed", "customExerciseDedupMigration.v1.completed",
        "d5ExerciseIdRepairMigration.v3.completed", "apr21SessionHistoryRepairMigration.v3.completed",
        "sessionHistoryBlockBackfill.v1.completed", "mechanicalLoadRecovery.v1.completed",
        "sessionDayLabelBackfill.v1.completed", "customExerciseStoreMigration.v1.completed",
        "customExerciseUserDefaultsSync.v1.completed", "mesoBlockIsMaintenanceBackfill.v1.completed",
        "bodyweightPhantomLoadMigration.v1.completed", "prescriptionNotesClear.v1.completed",
        "prescribedSetsBackfill.v1.completed", "plannedDateBackfill.v1.completed",
        "week6UpperBCleanupMigration.v1.completed", "custom_exercises_v2",
        // SessionHistoryExerciseOrderBackfill: it rewrites history exercises' `order` from 0 to their relationship
        // position. It was missing here, so whether it had already run on the simulator (a leftover key from an earlier
        // test or run) decided whether these tests saw an extra change to the store. Now it is cleared and restored like
        // the rest, and its one known change is scoped out of the comparisons with `withoutHistoryOrder`.
        "sessionHistoryExerciseOrder.v1.completed",
    ]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for k in Self.completionKeys {
            if let v = UserDefaults.standard.object(forKey: k) { savedDefaults[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in Self.completionKeys { UserDefaults.standard.removeObject(forKey: k) }
        for (k, v) in savedDefaults { UserDefaults.standard.set(v, forKey: k) }
        super.tearDown()
    }

    private func clearKeys() { for k in Self.completionKeys { UserDefaults.standard.removeObject(forKey: k) } }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func item(_ order: Int, _ id: String, name: String, notes: String? = nil) -> SessionItem {
        let i = SessionItem(order: order, exerciseId: id, exerciseNameSnapshot: name, targetReps: 8, targetSets: 3,
                            targetRIR: 2, suggestedLoad: 0, prescriptionNotes: notes,
                            plannedRepsBySet: [8, 8, 8], plannedLoadsBySet: [0, 0, 0], plannedRIRsBySet: [2, 2, 2])
        return i
    }

    /// Fresh in-memory store holding the synthetic non-Mark user.
    private func makeStore() throws -> ModelContext {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, 
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container = c
        let ctx = ModelContext(c)
        ctx.insert(User(units: .lb, progressionEnabled: true))
        ctx.insert(UserProfile())
        let meso = MesoBlock(name: "Jess's Upper/Lower", startDate: day(2026, 3, 30), status: .active, totalWeeks: 8)
        ctx.insert(meso)

        // A finished session on 2026-04-21 with its history row (already linked to the block).
        let apr21Items = [item(1, "bench_press", name: "Bench Press"), item(2, "barbell_row", name: "Barbell Row")]
        apr21Items.forEach { $0.actualReps = [8, 8, 8]; $0.actualLoads = [135, 135, 135]; $0.isCompleted = true }
        let apr21 = Session(date: day(2026, 4, 21), status: .completed, weekIndex: 4, dayLabel: "Upper", items: apr21Items)
        apr21.meso = meso
        ctx.insert(apr21)
        let hist = SessionHistory(
            date: day(2026, 4, 21), weekIndex: 4, title: "Upper", subtitle: "Week 4", totalExercises: 2, totalSets: 6,
            totalVolume: 6480, sessionId: apr21.id, dayLabelSnapshot: "Upper", mechanicalLoad: 6480,
            mesoBlockId: meso.id, mesoBlockNameSnapshot: meso.name,
            exercises: [SessionHistoryExercise(name: "Bench Press", primaryMuscle: "Chest", sets: 3, reps: 24, volume: 3240),
                        SessionHistoryExercise(name: "Barbell Row", primaryMuscle: "Back", sets: 3, reps: 24, volume: 3240)]
        )
        ctx.insert(hist)

        // A planned session after 2026-04-28 whose first item is a hip thrust (D5's trigger), six items,
        // one with a template note (the notes-wipe trigger) and one with a long spaced snapshot name (Repair's trigger).
        let d5Items = [
            item(1, "machine_hip_thrust", name: "Machine Hip Thrust", notes: "Primary glute work."),
            item(2, "leg_press", name: "Leg Press"),
            item(3, "lying_leg_curl", name: "Lying Leg Curl"),
            item(4, "bench_press", name: "Barbell Bench Press With Long Paused Variation Name"),
            item(5, "cable_crunch", name: "Cable Crunch"),
            item(6, "plank", name: "Plank"),
        ]
        let d5 = Session(date: day(2026, 5, 12), status: .planned, weekIndex: 7, dayLabel: "Lower", items: d5Items)
        d5.meso = meso
        ctx.insert(d5)

        // A session with no dayLabel but free-text notes (the dayLabel backfill's trigger).
        let noLabel = Session(date: day(2026, 5, 14), status: .planned,
                              sessionNotes: "Felt strong · heavy day", weekIndex: 7, items: [item(1, "bench_press", name: "Bench Press")])
        noLabel.meso = meso
        ctx.insert(noLabel)

        // A week-6 "Upper B" day (Week 6's names, but not its UUIDs).
        let upperB = Session(date: day(2026, 5, 5), status: .planned, weekIndex: 6, dayLabel: "Upper B",
                             items: [item(1, "pull_up", name: "Pull-Up"), item(2, "seated_cable_row", name: "Seated Cable Row")])
        upperB.meso = meso
        ctx.insert(upperB)

        // A custom exercise with a long spaced name.
        ctx.insert(CustomExercise(id: "custom_\(UUID().uuidString.lowercased())",
                                  name: "Single Arm Overhead Dumbbell Triceps Extension", primaryMuscleRaw: "triceps", isCompound: false))
        // An in-progress session (a logged first set): its targetSets may already carry an Add Set.
        let live = item(1, "overhead_press", name: "Overhead Press")
        live.actualReps = [8, 0, 0]; live.actualLoads = [95, 0, 0]
        let inProgress = Session(date: day(2026, 5, 7), status: .inProgress, weekIndex: 6, dayLabel: "Upper", items: [live])
        inProgress.meso = meso
        ctx.insert(inProgress)

        // The store as it was before `prescribedSets` existed: no item carries it.
        for s in try ctx.fetch(FetchDescriptor<Session>()) { for i in s.items { i.prescribedSets = nil } }
        // ... and before `plannedDate` existed: no session carries it.
        for s in try ctx.fetch(FetchDescriptor<Session>()) { s.plannedDate = nil; s.plannedDateExact = nil }
        try ctx.save()
        return ctx
    }

    /// `data` (a sorted-keys backup snapshot) with every history exercise's `order` removed: the order backfill's own,
    /// documented change, which these "nothing else changed" comparisons must not count.
    private func withoutHistoryOrder(_ data: Data) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object = try withoutHistoryOrder(object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func withoutHistoryOrder(_ object: [String: Any]) throws -> [String: Any] {
        var object = object
        var histories = try XCTUnwrap(object["sessionHistory"] as? [[String: Any]])
        for h in histories.indices {
            var exercises = try XCTUnwrap(histories[h]["exercises"] as? [[String: Any]])
            for e in exercises.indices { exercises[e].removeValue(forKey: "order") }
            histories[h]["exercises"] = exercises
        }
        object["sessionHistory"] = histories
        return object
    }

    /// The whole store, as the backup exporter sees it, without its export timestamp.
    private func snapshot(_ ctx: ModelContext) throws -> Data {
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        defer { try? FileManager.default.removeItem(at: result.url) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        object.removeValue(forKey: "exportedAt")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Every startup backfill logs EXACTLY ONE line, "<TypeName>: <result>", in registered order, and the names logged are the
    /// registered list (the harness's own list included). A second launch (all done) reports "not needed" for each.
    func test_everyStartupBackfill_logsExactlyOneLine_withItsTypeNameAndResult() throws {
        let c = try BackupTestSupport.makeContainer()
        var lines: [String] = []
        BackfillLog.lineSink = { lines.append($0) }
        defer { BackfillLog.lineSink = nil }
        clearKeys()
        StartupBackfills.run(using: c)
        let firstLaunch = lines; lines = []
        StartupBackfills.run(using: c)
        let secondLaunch = lines
        let registered = StartupBackfills.registered.map(\.name)
        XCTAssertEqual(registered, [
            "ExerciseNameSnapshotBackfill", "CanonicalExerciseIdMigration", "CustomExerciseDedupMigration", "SessionHistoryBlockBackfill",
            "MechanicalLoadRecoveryMigration", "CustomExerciseStoreMigration", "CustomExerciseUserDefaultsSyncRepair",
            "MesoBlockIsMaintenanceBackfill", "BodyweightPhantomLoadMigration", "PrescribedSetsBackfill", "PlannedDateBackfill",
            "LegacyExerciseNotesBackfill", "SessionHistoryExerciseOrderBackfill", "CustomExerciseCompoundBackfill", "RIRUnsetBackfill", "MesoStartDateResync", "CustomExerciseMergeBackfill", "LoadEverWrittenBackfill", "PlannedSetRepairBackfill", "PlaceholderRefreshBackfill"], "the registered list, in order")
        XCTAssertEqual(registered.count, 20)
        for launch in [firstLaunch, secondLaunch] {
            XCTAssertEqual(launch.count, registered.count, "exactly one line per backfill")
            for (line, name) in zip(launch, registered) {
                XCTAssertTrue(line.hasPrefix("ℹ️ Backfill \(name): "), line)
                XCTAssertFalse(line.dropFirst("ℹ️ Backfill \(name): ".count).isEmpty, "a result: \(line)")
                XCTAssertFalse(line.contains("\n"))
            }
        }
        // after the first launch every flag-gated backfill is done; an empty store leaves the data-dependent ones waiting
        let notNeeded = secondLaunch.filter { $0.hasSuffix(": not needed") }.count
        XCTAssertGreaterThanOrEqual(notNeeded, 8, "second launch: \(secondLaunch)")
        print("BACKFILL LOG (first launch on an empty store):\n" + firstLaunch.joined(separator: "\n"))
        print("BACKFILL LOG (second launch):\n" + secondLaunch.joined(separator: "\n"))
    }

    /// Every registered backfill but PrescribedSetsBackfill and PlannedDateBackfill leaves the store byte-identical;
    /// those two add `prescribedSets` (= targetSets) to PLANNED items and `plannedDate` (= date) to PLANNED sessions
    /// and change nothing else. The comparison removes exactly those keys from planned rows (and requires them to be
    /// absent everywhere else) and requires everything else to be unchanged.
    func test_registeredStartupBackfills_leaveAnotherUsersStoreUnchanged_exceptPlannedRowKeys() throws {
        let ctx = try makeStore()
        let before = try snapshot(ctx)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("prescribedSets"), "precondition: a pre-key store")
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("plannedDate"), "precondition: a pre-plannedDate store")

        clearKeys()
        StartupBackfills.run(using: container)

        ctx.rollback()
        let afterData = try snapshot(ModelContext(container))
        var after = try XCTUnwrap(JSONSerialization.jsonObject(with: afterData) as? [String: Any])
        var sessions = try XCTUnwrap(after["sessions"] as? [[String: Any]])
        var plannedItems = 0, otherItems = 0, plannedSessions = 0, otherSessions = 0
        for s in sessions.indices {
            let status = sessions[s]["statusRaw"] as? String
            if status == "planned" {
                XCTAssertEqual(sessions[s]["plannedDate"] as? String, sessions[s]["date"] as? String,
                               "planned session: plannedDate == date")
                sessions[s].removeValue(forKey: "plannedDate")
                XCTAssertNil(sessions[s]["plannedDateExact"], "a backfilled date is never marked exact")
                plannedSessions += 1
            } else {
                XCTAssertNil(sessions[s]["plannedDate"], "\(status ?? "?") sessions keep no plannedDate (unknown, never guessed)")
                otherSessions += 1
            }
            var items = try XCTUnwrap(sessions[s]["items"] as? [[String: Any]])
            for i in items.indices {
                if status == "planned" {
                    XCTAssertEqual(items[i]["prescribedSets"] as? Int, items[i]["targetSets"] as? Int,
                                   "planned item: prescribedSets == targetSets")
                    items[i].removeValue(forKey: "prescribedSets")
                    plannedItems += 1
                } else {
                    XCTAssertNil(items[i]["prescribedSets"], "\(status ?? "?") sessions are never touched")
                    otherItems += 1
                }
            }
            sessions[s]["items"] = items
        }
        after["sessions"] = sessions
        // The effort-mode one-shot writes the resolved mode onto a profile that never stored one: the only profile change.
        Self.dropOneShotEffortMode(&after)
        XCTAssertGreaterThan(plannedItems, 0)
        XCTAssertGreaterThan(otherItems, 0, "the store has completed and in-progress items too")
        XCTAssertGreaterThan(plannedSessions, 0)
        XCTAssertGreaterThan(otherSessions, 0)
        let scoped = try JSONSerialization.data(withJSONObject: after, options: [.sortedKeys])
        XCTAssertEqual(try withoutHistoryOrder(scoped), try withoutHistoryOrder(before), "every other byte is unchanged")
    }

    func test_prescribedSetsBackfill_isIdempotent_andWaitsForSessions() throws {
        // An empty store: nothing to do and NOT marked done, so it still runs after a restore.
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, 
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let empty = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container = empty
        clearKeys()
        PrescribedSetsBackfill.runIfNeeded(in: ModelContext(empty))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "prescribedSetsBackfill.v1.completed"))

        let ctx = try makeStore()
        clearKeys()
        PrescribedSetsBackfill.runIfNeeded(in: ctx)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "prescribedSetsBackfill.v1.completed"))
        let once = try snapshot(ctx)
        PrescribedSetsBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(try snapshot(ctx), once, "a second run changes nothing")
        for s in try ctx.fetch(FetchDescriptor<Session>()) {
            for i in s.items {
                if s.status == .planned { XCTAssertEqual(i.prescribedSets, i.targetSets) }
                else { XCTAssertNil(i.prescribedSets, "\(s.status) sessions are untouched") }
            }
        }
        // An item that already carries the key is never overwritten.
        let planned = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Session>()).first { $0.status == .planned })
        let keep = try XCTUnwrap(planned.items.first)
        keep.prescribedSets = 2; keep.targetSets = 3
        try ctx.save()
        UserDefaults.standard.removeObject(forKey: "prescribedSetsBackfill.v1.completed")
        PrescribedSetsBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(keep.prescribedSets, 2)
    }

    func test_plannedDateBackfill_isIdempotent_waitsForSessions_andNeverOverwrites() throws {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, 
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let empty = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container = empty
        clearKeys()
        PlannedDateBackfill.runIfNeeded(in: ModelContext(empty))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "plannedDateBackfill.v1.completed"), "empty store: not marked done")

        let ctx = try makeStore()
        clearKeys()
        PlannedDateBackfill.runIfNeeded(in: ctx)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "plannedDateBackfill.v1.completed"))
        let once = try snapshot(ctx)
        PlannedDateBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(try snapshot(ctx), once, "a second run changes nothing")
        for s in try ctx.fetch(FetchDescriptor<Session>()) {
            if s.status == .planned { XCTAssertEqual(s.plannedDate, s.date) }
            else { XCTAssertNil(s.plannedDate, "\(s.status) sessions are untouched") }
        }
        // A planned session that already carries a plannedDate (moved by Rest today) is never overwritten.
        let planned = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Session>()).first { $0.status == .planned })
        let moved = planned.date.addingTimeInterval(-86_400 * 3)
        planned.plannedDate = moved
        try ctx.save()
        UserDefaults.standard.removeObject(forKey: "plannedDateBackfill.v1.completed")
        PlannedDateBackfill.runIfNeeded(in: ctx)
        XCTAssertEqual(planned.plannedDate, moved)
    }

    /// Legacy exerciseNotes.v1.* keys are moved into ExerciseNote rows by the startup backfills, and that is the
    /// ONLY change to the store (prescribedSets on planned items is the other backfill's separate, known change).
    func test_legacyNotesBackfill_addsOnlyExerciseNoteRows() throws {
        let legacy = ["bench_press": "pause the first rep", "plank": "squeeze glutes"]
        defer { legacy.keys.forEach { ExerciseNotesStore.clear(exerciseId: $0) } }
        let ctx = try makeStore()
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot(ctx)) as? [String: Any])
        XCTAssertEqual((before["exerciseNotes"] as? [Any])?.count, 0, "precondition: the store has no notes")
        for (id, note) in legacy { ExerciseNotesStore.save(exerciseId: id, note: note) }

        clearKeys()
        StartupBackfills.run(using: container)
        ctx.rollback()
        var after = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot(ModelContext(container))) as? [String: Any])

        let added = try XCTUnwrap(after["exerciseNotes"] as? [[String: Any]])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: added.map { ($0["exerciseId"] as! String, $0["note"] as! String) }), legacy)

        // Scope the comparison: drop the notes and the other backfills' prescribedSets / plannedDate, require the rest identical.
        after["exerciseNotes"] = before["exerciseNotes"]
        var sessions = try XCTUnwrap(after["sessions"] as? [[String: Any]])
        for s in sessions.indices {
            var items = try XCTUnwrap(sessions[s]["items"] as? [[String: Any]])
            for i in items.indices { items[i].removeValue(forKey: "prescribedSets") }
            sessions[s]["items"] = items
            sessions[s].removeValue(forKey: "plannedDate")
            XCTAssertNil(sessions[s]["plannedDateExact"], "a backfill never marks a date exact")
        }
        after["sessions"] = sessions
        Self.dropOneShotEffortMode(&after)   // the effort-mode one-shot's write onto the profile
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: try withoutHistoryOrder(after), options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: try withoutHistoryOrder(before), options: [.sortedKeys]),
                       "nothing but ExerciseNote rows was added from the legacy keys")
        XCTAssertTrue(ExerciseNotesStore.legacyEntries().isEmpty)
    }
}

// MARK: - Universality guard (C5)

/// Production code must not hard-code one user's data or training rules. Mark's choices live in his
/// profile and data; one-shot repairs for his data are unregistered developer tools. This scans the
/// production sources (never Tests/) for the shapes of user-specific literals.
///
/// Comments are stripped first (they don't execute), string contents are kept.
final class UniversalityGuardTests: XCTestCase {

    /// Files allowed to carry user-specific literals. Empty: the one-shot repairs that needed entries were
    /// removed. Each entry would be: file name (no extension) -> why it may carry user-specific literals.
    static let allowlist: [String: String] = [:]

    /// Names of the removed one-shot repairs, plus the catalog's legacy alias table. The only names that may
    /// ever appear in `allowlist`; registering any of the repairs in `StartupBackfills` fails the registration test.
    static let permittedForAllowlist: Set<String> = [
        "SameLetterTargetCatchUpMigration", "TwelveWeekMesoConversionMigration", "V52AlignmentRepair",
        "V53AlignmentRepair", "ExerciseNameSnapshotRepair", "D5ExerciseIdRepairMigration",
        "Apr21SessionHistoryRepairMigration", "SessionDayLabelBackfill", "PrescriptionNotesClearMigration",
        "Week6UpperBCleanupMigration", "ExerciseCatalog",
    ]

    static let patterns: [(name: String, regex: String)] = [
        ("custom exercise id", #"custom_[0-9a-fA-F]{8}"#),
        ("ISO date literal 2025+", #"\b20(2[5-9]|[3-9][0-9])-[01][0-9]-[0-3][0-9]\b"#),
        // DateComponents(year: 2026, ...) and any labeled `year: 2026` argument.
        ("date construction, labeled year >= 2025", #"\byear:\s*20(2[5-9]|[3-9][0-9])\b"#),
        // Helper-style construction: date(2026, 9, 4).
        ("date construction, helper call", #"\bdate\(\s*20(2[5-9]|[3-9][0-9])\s*,"#),
        // components.year = 2026
        ("date construction, .year assignment", #"\.year\s*=\s*20(2[5-9]|[3-9][0-9])\b"#),
        ("personal name Mark", #"\bMark\b"#),
        ("personal name Angela", #"\bAngela\b"#),
        ("birth year", #"\b1977\b"#),
        // Lowercase forms of the two names, as enum cases, raw values or key fragments. Each is anchored so it cannot
        // hit markdown, bookmark, remark, Marker, mark(x) or `let mark = 1`.
        ("lowercase name, enum case", #"(?i)\bcase\s+(?:mark|angela)\b"#),
        ("lowercase name, whole string literal", #"(?i)"(?:mark|angela)""#),
        ("lowercase name, key fragment", #"(?i)(?<![A-Za-z0-9])(?:mark|angela)(?=_v\d|_)"#),
        ("lowercase name, bare angela", #"(?i)(?<![A-Za-z0-9])angela(?![A-Za-z0-9])"#),
    ]

    /// Exact string literals (quoted, whole) that may contain the names. Everything else that matches fails. A literal
    /// listed here that no longer appears in production code fails the stale check.
    static let literalExemptions: [String: String] = [
        "custom_exercises_mark_v1": "legacy migration input for old installs; read-only",
        "custom_exercises_angela_v1": "legacy migration input for old installs; read-only",
    ]

    // MARK: Source access

    private func sourceRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/" {
            let hasAll = ["App", "Domain", "Features"].allSatisfy {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: dir.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue
            }
            if hasAll { return dir }
            dir.deleteLastPathComponent()
        }
        XCTFail("source root (the folder containing App/, Domain/, Features/) not found from \(file)")
        throw CocoaError(.fileNoSuchFile)
    }

    /// Every production .swift file: (path relative to the root, file name without extension, stripped text).
    private func productionSources() throws -> [(path: String, name: String, text: String)] {
        let root = try sourceRoot()
        var out: [(String, String, String)] = []
        for folder in ["App", "Domain", "Features"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                XCTFail("cannot enumerate \(base.path)"); continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let raw = try String(contentsOf: url, encoding: .utf8)
                let rel = String(url.path.dropFirst(root.path.count + 1))
                out.append((rel, url.deletingPathExtension().lastPathComponent, Self.strippingComments(raw)))
            }
        }
        XCTAssertGreaterThan(out.count, 50, "scanned suspiciously few production files")
        return out.sorted { $0.0 < $1.0 }
    }

    /// Removes // and /* */ comments (block comments nest), leaving string literals and newlines intact so
    /// line numbers still match the file. Understands "...", """...""" and #"..."# strings.
    static func strippingComments(_ source: String) -> String {
        let s = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func peek(_ k: Int) -> Unicode.Scalar? { i + k < s.count ? s[i + k] : nil }
        while i < s.count {
            let c = s[i]
            // Raw / multi-line / plain strings: copy through verbatim.
            if c == "\"" || (c == "#" && { var k = 0; while peek(k) == "#" { k += 1 }; return peek(k) == "\"" }()) {
                var hashes = 0
                while s[i] == "#" { hashes += 1; out.append(s[i]); i += 1 }
                let multiline = peek(0) == "\"" && peek(1) == "\"" && peek(2) == "\""
                let quote = multiline ? 3 : 1
                for _ in 0..<quote { out.append(s[i]); i += 1 }
                while i < s.count {
                    if s[i] == "\\" && hashes == 0, i + 1 < s.count { out.append(s[i]); out.append(s[i + 1]); i += 2; continue }
                    var closes = true
                    for q in 0..<quote where peek(q) != "\"" { closes = false }
                    if closes {
                        var h = 0
                        while h < hashes, peek(quote + h) == "#" { h += 1 }
                        if h == hashes {
                            for _ in 0..<(quote + hashes) { out.append(s[i]); i += 1 }
                            break
                        }
                    }
                    if !multiline && s[i] == "\n" { break }   // unterminated: bail to avoid swallowing the file
                    out.append(s[i]); i += 1
                }
                continue
            }
            if c == "/" && peek(1) == "/" {
                while i < s.count && s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && peek(1) == "*" {
                var depth = 0
                while i < s.count {
                    if s[i] == "/" && peek(1) == "*" { depth += 1; i += 2; continue }
                    if s[i] == "*" && peek(1) == "/" { depth -= 1; i += 2; if depth == 0 { break }; continue }
                    if s[i] == "\n" { out.append(s[i]) }
                    i += 1
                }
                continue
            }
            out.append(c); i += 1
        }
        return String(out)
    }

    struct Hit: CustomStringConvertible {
        let file: String, name: String, line: Int, pattern: String, text: String
        var description: String { "\(file):\(line) [\(pattern)] \(text)" }
    }

    /// Pattern hits in comment-stripped `text`, minus matches that sit entirely inside an exempt quoted literal.
    /// `used` collects the exemptions that suppressed a match.
    static func hits(in text: String, file: String, name: String, used: inout Set<String>) throws -> [Hit] {
        let compiled = try patterns.map { ($0.name, try NSRegularExpression(pattern: $0.regex)) }
        var hits: [Hit] = []
        for (idx, line) in text.components(separatedBy: "\n").enumerated() {
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            var exempt: [(range: NSRange, literal: String)] = []
            for literal in literalExemptions.keys {
                var from = 0
                while from < ns.length {
                    let r = ns.range(of: "\"\(literal)\"", range: NSRange(location: from, length: ns.length - from))
                    if r.location == NSNotFound { break }
                    exempt.append((r, literal))
                    from = r.location + r.length
                }
            }
            for (patternName, re) in compiled {
                for m in re.matches(in: line, range: whole) {
                    if let e = exempt.first(where: { m.range.location >= $0.range.location
                        && m.range.location + m.range.length <= $0.range.location + $0.range.length }) {
                        used.insert(e.literal)
                        continue
                    }
                    hits.append(Hit(file: file, name: name, line: idx + 1, pattern: patternName, text: ns.substring(with: m.range)))
                }
            }
        }
        return hits
    }

    private func scan() throws -> [Hit] {
        var used = Set<String>()
        return try productionSources().flatMap { try Self.hits(in: $0.text, file: $0.path, name: $0.name, used: &used) }
    }

    // MARK: Tests

    func test_productionCode_containsNoUserSpecificLiterals() throws {
        let hits = try scan()
        let offending = hits.filter { Self.allowlist[$0.name] == nil }
        XCTAssertTrue(offending.isEmpty,
                      "user-specific literals in production code:\n" + offending.map(\.description).joined(separator: "\n"))
    }

    func test_allowlist_isEmpty_andRetiredRepairsStayOut() throws {
        XCTAssertTrue(Self.allowlist.isEmpty, "no production file may carry user-specific literals: \(Self.allowlist.keys.sorted())")
        let sources = try productionSources()
        for name in Self.permittedForAllowlist where name != "ExerciseCatalog" {
            XCTAssertFalse(sources.contains { $0.name == name }, "\(name) was removed from the app; do not re-add it")
        }
        let matched = Set(try scan().map(\.name))
        for name in Self.allowlist.keys {
            XCTAssertTrue(matched.contains(name), "\(name) is allowlisted but no longer matches any pattern: remove it")
        }
        let permitted = Self.permittedForAllowlist
        for name in Self.allowlist.keys {
            XCTAssertTrue(permitted.contains(name), "\(name) may not be allowlisted")
            XCTAssertFalse((Self.allowlist[name] ?? "").isEmpty, "\(name) needs a reason")
        }
    }

    /// An allowlisted one-shot repair must not run: it is not registered at startup and nothing else in
    /// production code refers to it (comments excluded).
    func test_noAllowlistedMigration_isRegisteredOrReferenced() throws {
        let sources = try productionSources()
        let app = try XCTUnwrap(sources.first { $0.name == "ElitePerformanceApp" }, "App/ElitePerformanceApp.swift not found")
        let start = try XCTUnwrap(app.text.range(of: "enum StartupBackfills"), "StartupBackfills not found")
        let registered = app.text[start.upperBound...]
        // Every permitted one-shot (allowlisted or not) stays unregistered: registering any of them fails here.
        for name in Self.permittedForAllowlist where name != "ExerciseCatalog" {
            XCTAssertFalse(registered.contains(name), "\(name) is a one-shot repair yet registered in StartupBackfills")
        }
        for name in Self.allowlist.keys where name != "ExerciseCatalog" {
            // One-shot repairs may refer to each other (V53 builds on V52); nothing else may refer to them.
            for src in sources where src.name != name && !(Self.permittedForAllowlist.contains(src.name) && src.name != "ExerciseCatalog") {
                XCTAssertFalse(src.text.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil,
                               "\(name) is allowlisted yet referenced from \(src.path)")
            }
        }
    }

    func test_literalExemptions_areEachUsedAndNotStale() throws {
        let sources = try productionSources()
        for (literal, reason) in Self.literalExemptions {
            XCTAssertFalse(reason.isEmpty, "\(literal) needs a reason")
            XCTAssertTrue(sources.contains { $0.text.contains("\"\(literal)\"") },
                          "stale exemption: \"\(literal)\" no longer appears in production code")
        }
        var used = Set<String>()
        for src in sources { _ = try Self.hits(in: src.text, file: src.path, name: src.name, used: &used) }
        XCTAssertEqual(used, Set(Self.literalExemptions.keys), "every exemption should be suppressing a real match")
    }

    // MARK: Mutation checks: each shape must fail the guard

    private func offending(_ snippet: String) throws -> [Hit] {
        var used = Set<String>()
        return try Self.hits(in: snippet, file: "Probe.swift", name: "Probe", used: &used)
    }

    func test_mutation_newEnumCaseNamedAngelaOrMark_fails() throws {
        XCTAssertFalse(try offending("enum Probe { case angela }").isEmpty)
        XCTAssertFalse(try offending("enum Probe: String {\n    case mark\n}").isEmpty)
        XCTAssertFalse(try offending("switch x { case .a: break; case Mark: break }").isEmpty)
    }

    func test_mutation_newWholeLiteralMarkOrAngela_fails() throws {
        XCTAssertFalse(try offending("let k = \"mark\"").isEmpty)
        XCTAssertFalse(try offending("let k = \"Angela\"").isEmpty)
        XCTAssertFalse(try offending("let k = \"ANGELA\"").isEmpty)
    }

    func test_mutation_newPerNameKeyFragment_fails() throws {
        XCTAssertFalse(try offending("let k = \"custom_exercises_mark_v2\"").isEmpty)
        XCTAssertFalse(try offending("let k = \"custom_exercises_angela_v2\"").isEmpty)
        // The exemption is for the exact legacy literals only, even on the same line.
        let both = try offending("[\"custom_exercises_mark_v1\", \"custom_exercises_mark_v2\"]")
        XCTAssertFalse(both.isEmpty)
        XCTAssertTrue(both.allSatisfy { $0.text.contains("mark") })
    }

    func test_exemptLegacyLiterals_doNotFail_andOnlyThoseExactLiterals() throws {
        XCTAssertTrue(try offending("private static let legacyCustomKeys = [\"custom_exercises_mark_v1\", \"custom_exercises_angela_v1\"]").isEmpty)
        XCTAssertFalse(try offending("let k = \"custom_exercises_mark_v1_copy\"").isEmpty)
        XCTAssertFalse(try offending("let k = \"x_custom_exercises_mark_v1\"").isEmpty)
    }

    func test_lowercaseNamePatterns_doNotHitOrdinaryWords() throws {
        for ok in ["markdown", "bookmark", "remark", "Marker", "landmark_v1", "trademark_v2", "let mark = 1", "mark(x)",
                   "case markdown", "case marker", "\"markdown\"", "\"bookmark\"", "\"remark\"", "\"Marker\"", "\"a mark\"",
                   "someAngelaHelper", "x.mark", "AppMode.mark"] {
            XCTAssertTrue(try offending(ok).isEmpty, "false positive: \(ok)")
        }
    }

    func test_commentStripper_keepsStringsAndLineNumbers() {
        let src = "let a = \"https://x.test/custom_1234abcd\" // Mark\nlet b = 1 /* Angela\nstill */ let c = #\"2026-01-01\"#\n"
        let out = Self.strippingComments(src)
        XCTAssertTrue(out.contains("https://x.test/custom_1234abcd"), "// inside a string is not a comment")
        XCTAssertFalse(out.contains("Mark"))
        XCTAssertFalse(out.contains("Angela"))
        XCTAssertTrue(out.contains("#\"2026-01-01\"#"), "raw strings are kept")
        XCTAssertEqual(out.components(separatedBy: "\n").count, src.components(separatedBy: "\n").count, "line count preserved")
    }
}


// MARK: - Insert / remove deload on a real backup

/// Imports the backup named by EP_BACKUP_FIXTURE into an in-memory store, previews and applies an inserted
/// deload week, then removes it and requires the export to match the one taken before the insert (excluding
/// `exportedAt`). Skips without the fixture. Prints what it would do; the file holds personal data and is never copied.
final class InsertDeloadRealBackupTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private let scheduledKey = "meso.scheduledStartDateEpoch"
    private let snoozeKey = "meso.promptSnoozeEpoch"

    private func out(_ s: String = "") { print("IDR| \(s)") }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// Export, parsed, with `exportedAt` removed.
    private func exportJSON(_ ctx: ModelContext) throws -> [String: Any] {
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        json.removeValue(forKey: "exportedAt")
        return json
    }

    private func canonical(_ json: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    /// Paths where two JSON values differ (sessions/items matched by id so one insertion doesn't shift every row).
    private func diff(_ a: Any, _ b: Any, path: String = "$", into lines: inout [String]) {
        guard lines.count < 40 else { return }
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            for k in Set(x.keys).union(y.keys).sorted() {
                switch (x[k], y[k]) {
                case (let l?, let r?): diff(l, r, path: "\(path).\(k)", into: &lines)
                case (nil, _): lines.append("\(path).\(k): only after")
                default: lines.append("\(path).\(k): only before")
                }
            }
        } else if let x = a as? [Any], let y = b as? [Any] {
            func key(_ v: Any) -> String? { (v as? [String: Any])?["id"] as? String }
            if x.allSatisfy({ key($0) != nil }) && y.allSatisfy({ key($0) != nil }) {
                let xs = Dictionary(x.map { (key($0)!, $0) }, uniquingKeysWith: { f, _ in f })
                let ys = Dictionary(y.map { (key($0)!, $0) }, uniquingKeysWith: { f, _ in f })
                for k in Set(xs.keys).union(ys.keys).sorted() {
                    switch (xs[k], ys[k]) {
                    case (let l?, let r?): diff(l, r, path: "\(path)[\(k.prefix(8))]", into: &lines)
                    case (nil, _): lines.append("\(path)[\(k.prefix(8))]: only after")
                    default: lines.append("\(path)[\(k.prefix(8))]: only before")
                    }
                }
                if x.map({ key($0)! }) != y.map({ key($0)! }), lines.count < 40 { lines.append("\(path): same rows, different order") }
            } else if x.count != y.count {
                lines.append("\(path): count \(x.count) vs \(y.count)")
            } else {
                for (i, pair) in zip(x, y).enumerated() { diff(pair.0, pair.1, path: "\(path)[\(i)]", into: &lines) }
            }
        } else if "\(a)" != "\(b)" {
            lines.append("\(path): \(a) vs \(b)")
        }
    }

    private func day(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "EEE yyyy-MM-dd"
        return f.string(from: d)
    }

    func testInsertThenRemoveDeloadOnARealBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("EP_BACKUP_FIXTURE not set")
        }
        let savedNext = UserDefaults.standard.object(forKey: scheduledKey)
        let savedSnooze = UserDefaults.standard.object(forKey: snoozeKey)
        defer {
            for (k, v) in [(scheduledKey, savedNext), (snoozeKey, savedSnooze)] {
                if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }

        let container = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let blocks = try ctx.fetch(FetchDescriptor<MesoBlock>()).filter { $0.status == .active }
        let block = try XCTUnwrap(blocks.max { $0.sessions.count < $1.sessions.count }, "no active block in the backup")
        let now = Date()
        let calendar = Calendar.current

        // Next-meso date: use the backup's if the app restored one, else a sentinel so the shift is visible.
        var nextSource = "restored from the backup"
        if MesoLifecycle.scheduledStartDate == nil {
            MesoLifecycle.scheduleNextMeso(on: calendar.date(byAdding: .day, value: 14, to: block.sessions.map(\.date).max() ?? now)!)
            nextSource = "sentinel (none in the backup): block end + 14 days"
        }
        let nextBefore = MesoLifecycle.scheduledStartDate

        let exportBefore = try exportJSON(ctx)
        let bytesBefore = try canonical(exportBefore)

        // --- Preview ---
        let plan = Service.planInsertDeloadWeek(meso: block, context: ctx, now: now)
        out("== PREVIEW: insert deload week into \"\(block.name)\" (\(block.sessions.count) sessions, totalWeeks \(block.totalWeeks.map(String.init) ?? "nil")) ==")
        out("today \(day(now)); eligible weeks \(Service.eligibleDeloadWeeks(meso: block, now: now)); refusal \(plan.refusal.map { "\($0)" } ?? "none")")
        XCTAssertNil(plan.refusal, "the backup's block should accept a deload: \(plan.refusal.map { "\($0)" } ?? "")")
        let week = try XCTUnwrap(plan.weekIndex)
        let profile = try? ctx.fetch(FetchDescriptor<UserProfile>()).first
        let custom = (try? ctx.fetch(FetchDescriptor<CustomExercise>())) ?? []
        out("inserted as week \(week)")
        for s in plan.deloadSessions {
            out("  \(day(s.date))  \(s.dayLabel ?? "?")")
            for i in s.items {
                let source: String
                if ExerciseCatalog.isBodyweight(exerciseId: i.exerciseId, customExercises: custom) { source = "bodyweight" }
                else if UserProfile.isProgressionExempt(exerciseId: i.exerciseId, profile: profile) { source = i.load > 0 ? "fixed-load hold" : "fixed-load hold (no history)" }
                else { source = i.load > 0 ? "history seed" : "none" }
                out("    \(ExerciseCatalog.displayName(for: i.exerciseId)): \(i.prescription), start \(LoadFormatter.number(i.load)) \(LoadFormatter.unitLabel) [\(source)]")
            }
        }
        out("sessions shifted one week later: \(plan.shifted.count)")
        out("block end: \(plan.blockEndBefore.map(day) ?? "?") -> \(plan.blockEndAfter.map(day) ?? "?")")

        // --- Before-state for the assertions ---
        let allBefore = try ctx.fetch(FetchDescriptor<Session>())
        let weeksBefore = Set(block.sessions.map(\.weekIndex))
        let totalBefore = block.totalWeeks
        let sources = block.sessions.filter { $0.status == .completed }
            .flatMap { s in s.items.filter { $0.waveRaw?.lowercased() != "deload" }.map { (s, $0) } }
        let chainsBefore = sources.map { PlanMemoryEngine.nextTargetItem(for: $0.1, after: $0.0, in: allBefore)?.persistentModelID }
        let completedBefore = (exportBefore["sessions"] as? [[String: Any]] ?? []).filter { $0["statusRaw"] as? String == "completed" }

        // --- Apply ---
        let result = try Service.insertDeloadWeek(plan, in: ctx)
        let nextAfter = MesoLifecycle.scheduledStartDate
        out("== APPLIED: \(result.deloadSessionsCreated) deload sessions created, \(result.sessionsShifted) shifted ==")
        out("next-meso date (\(nextSource)): \(nextBefore.map(day) ?? "none") -> \(nextAfter.map(day) ?? "none")")
        XCTAssertEqual(result.deloadSessionsCreated, plan.deloadSessions.count)
        XCTAssertEqual(result.sessionsShifted, plan.shifted.count)

        let allAfter = try ctx.fetch(FetchDescriptor<Session>())
        let chainsAfter = sources.map { PlanMemoryEngine.nextTargetItem(for: $0.1, after: $0.0, in: allAfter) }
        XCTAssertEqual(chainsBefore.count, chainsAfter.count)
        var changed = 0
        for (b, a) in zip(chainsBefore, chainsAfter) {
            if b != a?.persistentModelID { changed += 1 }
            XCTAssertNotEqual(a?.waveRaw?.lowercased(), "deload", "a completed source must never resolve to a deload item")
        }
        XCTAssertEqual(changed, 0, "every completed source resolves to the same target as before")
        out("chains checked: \(sources.count) completed items, \(changed) changed, 0 to a deload item")

        let weeksAfter = Set(block.sessions.map(\.weekIndex))
        if let lo = weeksAfter.min(), let hi = weeksAfter.max() {
            XCTAssertEqual(weeksAfter, Set(lo...hi), "weekInMeso contiguous")
        }
        if let before = weeksBefore.min().flatMap({ lo in weeksBefore.max().map { Set(lo...$0) } }) {
            XCTAssertEqual(weeksBefore, before, "sanity: contiguous before as well")
        }
        XCTAssertEqual(block.totalWeeks, totalBefore.map { $0 + 1 })

        let moved = Set(block.sessions.map(\.persistentModelID))
        let outside = allAfter.filter { !moved.contains($0.persistentModelID) }
        let outsideDays = Set(outside.map { calendar.startOfDay(for: $0.date) })
        for s in block.sessions where s.insertedDeload == true || plan.shifted.contains(where: { $0.session === s }) {
            XCTAssertFalse(outsideDays.contains(calendar.startOfDay(for: s.date)), "date collision on \(day(s.date))")
        }
        out("weeks now \(weeksAfter.min() ?? 0)...\(weeksAfter.max() ?? 0), totalWeeks \(block.totalWeeks.map(String.init) ?? "nil"), no date collisions")

        let exportApplied = try exportJSON(ctx)
        let completedApplied = (exportApplied["sessions"] as? [[String: Any]] ?? []).filter { $0["statusRaw"] as? String == "completed" }
        XCTAssertEqual(try canonical(completedBefore), try canonical(completedApplied), "completed sessions byte-identical")
        out("completed sessions byte-identical: \(completedBefore.count)")

        // --- Remove ---
        let removePlan = Service.planRemoveInsertedDeloadWeek(meso: block, context: ctx, now: now)
        XCTAssertNil(removePlan.refusal)
        let removed = try Service.removeInsertedDeloadWeek(removePlan, in: ctx)
        out("== REMOVED: \(removed.deloadSessionsRemoved) deload sessions, \(removed.sessionsShifted) shifted back ==")
        out("next-meso date after remove: \(MesoLifecycle.scheduledStartDate.map(day) ?? "none")")
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, nextBefore)

        let exportAfter = try exportJSON(ctx)
        let bytesAfter = try canonical(exportAfter)
        if bytesAfter != bytesBefore {
            var lines: [String] = []
            diff(exportBefore, exportAfter, into: &lines)
            lines.forEach { out("DIFF \($0)") }
            XCTFail("export after insert+remove differs from the export before (\(lines.count) differences); see IDR| DIFF lines")
        } else {
            out("export after insert + remove is byte-identical to the export before (excluding exportedAt): \(bytesBefore.count) bytes")
        }
    }
}


// MARK: - Top-set fields round trip

final class TopSetBackupTests: XCTestCase {

    private static var parked: [AnyObject] = []
    static func keepAlive(_ c: AnyObject) { parked.append(c) }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        Self.parked.append(c)
        return c
    }

    private func seed(_ ctx: ModelContext, withTop: Bool) throws {
        let item = SessionItem(
            order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 290,
            repMin: 6, repMax: 8,
            plannedRepsBySet: [7, 7, 7] + (withTop ? [5] : []),
            plannedLoadsBySet: [290, 290, 290] + (withTop ? [315] : []),
            plannedRIRsBySet: [2, 2, 2] + (withTop ? [2] : []),
            actualReps: [8, 7, 6] + (withTop ? [5] : []),
            actualLoads: [290, 290, 290] + (withTop ? [315] : []),
            actualRIRs: [2, 2, 2] + (withTop ? [2] : [])
        )
        if withTop {
            item.setRolesBySet = SessionItem.roles(backOffs: 3, tops: 1)
            item.topRepMin = 4; item.topRepMax = 6; item.topRIR = 2
        }
        let session = Session(date: Date(), status: .completed, weekIndex: 1, items: [item])
        ctx.insert(session)
        try ctx.save()
    }

    private func exportItemJSON(_ container: ModelContainer) throws -> (url: URL, item: [String: Any]) {
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ModelContext(container))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        let items = try XCTUnwrap(sessions.first?["items"] as? [[String: Any]])
        return (result.url, try XCTUnwrap(items.first))
    }

    func test_topSetFields_roundTrip() throws {
        let a = try makeContainer()
        try seed(ModelContext(a), withTop: true)
        let (url, itemJSON) = try exportItemJSON(a)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(itemJSON["setRolesBySet"] as? [String], ["", "", "", "top"])
        XCTAssertEqual(itemJSON["topRepMin"] as? Int, 4)
        XCTAssertEqual(itemJSON["topRepMax"] as? Int, 6)
        XCTAssertEqual(itemJSON["topRIR"] as? Int, 2)

        let b = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: b)
        let item = try XCTUnwrap(try ModelContext(b).fetch(FetchDescriptor<SessionItem>()).first)
        XCTAssertEqual(item.setRolesBySet, ["", "", "", "top"])
        XCTAssertEqual(item.topCount, 1)
        XCTAssertEqual(item.topRowIndices, [3])
        XCTAssertEqual([item.topRepMin, item.topRepMax, item.topRIR], [4, 6, 2])
        XCTAssertEqual(item.actualLoads, [290, 290, 290, 315])
    }

    func test_itemWithoutTopSet_writesNoKeys_andOldBackupsDecodeNil() throws {
        let a = try makeContainer()
        try seed(ModelContext(a), withTop: false)
        let (url, itemJSON) = try exportItemJSON(a)
        defer { try? FileManager.default.removeItem(at: url) }
        for key in ["setRolesBySet", "topRepMin", "topRepMax", "topRIR"] {
            XCTAssertNil(itemJSON[key], "\(key) must be absent for an item with no top set (same bytes as an old backup)")
        }
        let b = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: b)
        let item = try XCTUnwrap(try ModelContext(b).fetch(FetchDescriptor<SessionItem>()).first)
        XCTAssertNil(item.setRolesBySet)
        XCTAssertNil(item.topRepMin); XCTAssertNil(item.topRepMax); XCTAssertNil(item.topRIR)
        XCTAssertEqual(item.topCount, 0)
        XCTAssertFalse(item.hasTopSet)
        XCTAssertFalse(item.isTopRow(0))
    }
}

extension TopSetBackupTests {
    func test_prescribedSets_roundTrip_andOldBackupsDecodeNil() throws {
        let a = try makeContainerForPrescribed()
        let ctx = ModelContext(a)
        let item = SessionItem(order: 1, exerciseId: "bench_press", targetReps: 8, targetSets: 4, targetRIR: 2, suggestedLoad: 100,
                               prescribedSets: 3)
        ctx.insert(Session(date: Date(), status: .completed, weekIndex: 1, items: [item]))
        try ctx.save()
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ModelContext(a))
        defer { try? FileManager.default.removeItem(at: result.url) }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        let exported = try XCTUnwrap(((json["sessions"] as? [[String: Any]])?.first?["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(exported["prescribedSets"] as? Int, 3)
        XCTAssertEqual(exported["targetSets"] as? Int, 4)
        let b = try makeContainerForPrescribed()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: result.url, modelContainer: b)
        let back = try XCTUnwrap(try ModelContext(b).fetch(FetchDescriptor<SessionItem>()).first)
        XCTAssertEqual(back.prescribedSets, 3)
        XCTAssertEqual(back.targetSets, 4)

        // An old backup: no key. It must restore as nil, not as the init default.
        var old = json
        var sessions = try XCTUnwrap(old["sessions"] as? [[String: Any]])
        var items = try XCTUnwrap(sessions[0]["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "prescribedSets")
        sessions[0]["items"] = items
        old["sessions"] = sessions
        let oldURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: old).write(to: oldURL)
        defer { try? FileManager.default.removeItem(at: oldURL) }
        let c = try makeContainerForPrescribed()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: oldURL, modelContainer: c)
        let restored = try XCTUnwrap(try ModelContext(c).fetch(FetchDescriptor<SessionItem>()).first)
        XCTAssertNil(restored.prescribedSets)
        XCTAssertEqual(restored.effectivePrescribedSets, restored.targetSets)
    }

    fileprivate func makeContainerForPrescribed() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        TopSetBackupTests.keepAlive(c)
        return c
    }
}

// MARK: - Deload rule dry run (report only)

/// For each backup in EP_DELOAD_BACKUPS (comma-separated paths): every deload item already in the plan (scheduled) and the
/// items an Insert deload would write at the first eligible week, with the load before and after `DeloadRule`, the working
/// load, and which side of the min the new load landed on. Skips without the variable; writes EP_DELOAD_REPORT when set.
final class DeloadRuleDryRunTests: XCTestCase {

    func test_dryRun_everyDeloadItemBeforeAndAfter() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_DELOAD_BACKUPS"], !list.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_DELOAD_BACKUPS to comma-separated backup paths")
        }
        var lines: [String] = []
        func out(_ s: String = "") { lines.append(s); print("DLD| \(s)") }
        defer {
            if let p = ProcessInfo.processInfo.environment["EP_DELOAD_REPORT"], !p.isEmpty {
                try? lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)
            }
        }
        func pad(_ x: String, _ n: Int) -> String { x.padding(toLength: n, withPad: " ", startingAt: 0) }
        func pct(_ a: Double, _ b: Double?) -> String { guard let b, b > 0 else { return "-" }; return String(format: "%.0f%%", a / b * 100) }

        for path in list.split(separator: ",").map(String.init) {
            let schema = Schema([User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, 
                                 SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
                                 MesoBlock.self, UserProfile.self, CustomExercise.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            let ctx = ModelContext(container)
            let all = try ctx.fetch(FetchDescriptor<Session>())
            let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
            let custom = try ctx.fetch(FetchDescriptor<CustomExercise>())
            let unit = profile?.loadUnit ?? .lb
            let now = Date()
            out("================ \(URL(fileURLWithPath: path).lastPathComponent)  (unit \(unit), \(all.count) sessions)")

            // 1. Deload items already in the plan.
            out("-- scheduled deload items (waveRaw == deload, not logged)")
            let scheduled = all.filter { $0.status != .completed }.sorted { $0.date < $1.date }
            var n = 0
            for s in scheduled {
                for i in s.items.sorted(by: { $0.order < $1.order }) where i.waveRaw?.lowercased() == "deload" {
                    n += 1
                    let repMin = i.repMin ?? i.targetReps
                    let z = DeloadRule.sizing(exerciseId: i.exerciseId, repMin: repMin, in: all, profile: profile, unit: unit, customExercises: custom, referenceDate: now)
                    let flat = z.workingLoad.map { UnitAwareRounding.round($0 * 0.6, increment: UserProfile.loadStep(for: i.exerciseId, profile: profile, unit: unit), unit: unit) }
                    out(pad("W\(s.weekIndex) \(s.dayLabel ?? "?") \(s.insertedDeload == true ? "(inserted)" : "")", 22) + pad(ExerciseCatalog.displayName(for: i.exerciseId), 34)
                        + "reps \(repMin)-\(i.repMax ?? i.targetReps) sets \(i.targetSets)  stored \(LoadFormatter.number(i.suggestedLoad))  0.6x-branch \(flat.map { LoadFormatter.number($0) } ?? "-")  -> NEW \(LoadFormatter.number(z.load))"
                        + "  working \(z.workingLoad.map { LoadFormatter.number($0) } ?? "-")  new/working \(pct(z.load, z.workingLoad))  stored/working \(pct(i.suggestedLoad, z.workingLoad))  rir@repMin \(z.rirLoad.map { LoadFormatter.number($0) } ?? "-") cap \(z.capLoad.map { LoadFormatter.number($0) } ?? "-")  [\(z.basis.rawValue)]")
                }
            }
            if n == 0 { out("(none)") }

            // 2. The deload an Insert deload would write now.
            for block in try ctx.fetch(FetchDescriptor<MesoBlock>()).filter({ $0.status == .active }) {
                let plan = SessionItemEditService.planInsertDeloadWeek(meso: block, context: ctx, now: now)
                out("-- Insert deload into \"\(block.name)\": week \(plan.weekIndex.map(String.init) ?? "-"), refusal \(plan.refusal.map { "\($0)" } ?? "none")")
                for s in plan.deloadSessions {
                    for ip in s.items {
                        let old: Double
                        if ExerciseCatalog.isBodyweight(exerciseId: ip.exerciseId, customExercises: custom) { old = 0 }
                        else if UserProfile.isProgressionExempt(exerciseId: ip.exerciseId, profile: profile) { old = SessionItemEditService.lastCompletedLoad(for: ip.exerciseId, in: all) ?? 0 }
                        else {
                            old = UserProfile.clampedLoad(HistorySeedLoad.load(
                                for: ip.exerciseId, goalReps: ip.repMax, targetRIR: 4, in: all,
                                loadIncrement: UserProfile.loadStep(for: ip.exerciseId, profile: profile, unit: unit), unit: unit,
                                bodyWeight: profile?.bodyWeight, customExercises: custom, referenceDate: now) ?? 0,
                                exerciseId: ip.exerciseId, profile: profile, customExercises: custom)
                        }
                        let z = ip.sizing
                        out(pad("\(s.dayLabel ?? "?")", 18) + pad(ExerciseCatalog.displayName(for: ip.exerciseId), 34)
                            + "\(ip.sets)x\(ip.repMin)-\(ip.repMax)  OLD(repMax) \(LoadFormatter.number(old)) \(pct(old, z.workingLoad)) -> NEW \(LoadFormatter.number(ip.load)) \(pct(ip.load, z.workingLoad))"
                            + "  working \(z.workingLoad.map { LoadFormatter.number($0) } ?? "-")  rir@repMin \(z.rirLoad.map { LoadFormatter.number($0) } ?? "-") cap \(z.capLoad.map { LoadFormatter.number($0) } ?? "-")  [\(z.basis.rawValue)]")
                    }
                }
            }
        }
    }
}

// MARK: - Dry-run: scheduled deload weeks through PlaceholderRefresh (report only)

@MainActor
final class ScheduledDeloadDryRunTests: XCTestCase {
    func test_dryRun_everyScheduledDeloadItemBeforeAndAfter() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_DELOAD_BACKUPS"], !list.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_DELOAD_BACKUPS to comma-separated backup paths")
        }
        var lines: [String] = []
        func out(_ s: String = "") { lines.append(s); print("SDR| \(s)") }
        defer { if let p = ProcessInfo.processInfo.environment["EP_DELOAD_REPORT"], !p.isEmpty { try? lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) } }
        func pad(_ x: String, _ n: Int) -> String { x.padding(toLength: n, withPad: " ", startingAt: 0) }
        for path in list.split(separator: ",").map(String.init) {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            FixtureClock.pin(path, in: self)
            let ctx = ModelContext(container)
            let all = try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
            let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
            let unit = profile?.loadUnit ?? .lb
            let changes = PlaceholderRefresh.plan(in: ctx)
            var byItem: [PersistentIdentifier: PlaceholderRefresh.Change] = [:]
            for c in changes { byItem[c.item.persistentModelID] = c }
            out("================ \(URL(fileURLWithPath: path).lastPathComponent)  (\(all.count) sessions, \(changes.count) planned changes in all)")
            let deloadSessions = all.filter { $0.status == .planned && $0.insertedDeload != true && $0.items.contains { $0.waveRaw?.lowercased() == "deload" } }
            if deloadSessions.isEmpty { out("(no scheduled deload sessions)") }
            for s in deloadSessions {
                out("-- week \(s.weekIndex) \(s.dayLabel ?? "?")  \(s.date.formatted(.dateTime.month().day().year()))  meso \(s.meso?.name ?? "-") (\(s.meso?.status.rawValue ?? "-"))")
                for i in s.items.sorted(by: { $0.order < $1.order }) {
                    let name = pad(ExerciseCatalog.displayName(for: i.exerciseId), 32)
                    let before = LoadFormatter.number(i.suggestedLoad)
                    if let c = byItem[i.persistentModelID] {
                        guard case .scheduledDeload(let z) = c.reason else { out(name + "(other change: \(c.reason.text))"); continue }
                        let share = z.workingLoad.map { String(format: "%.0f%%", z.load / $0 * 100) } ?? "-"
                        out(name + "sets \(i.targetSets) reps \(i.repMin ?? i.targetReps)-\(i.repMax ?? i.targetReps)  \(before) -> \(LoadFormatter.number(z.load))  working \(z.workingLoad.map { LoadFormatter.number($0) } ?? "-") (\(share))  rir@repMin \(z.rirLoad.map { LoadFormatter.number($0) } ?? "-") cap \(z.capLoad.map { LoadFormatter.number($0) } ?? "-")  [\(z.basis.rawValue)]")
                    } else {
                        let why = i.targetSets == 0 ? "0 sets" : i.planEdited ? "planEdited" : ExerciseCatalog.isBodyweight(exerciseId: i.exerciseId, customExercises: []) ? "bodyweight" : "no change (no history, or already holds the rule's load)"
                        let z = DeloadRule.sizing(exerciseId: i.exerciseId, repMin: i.repMin ?? i.targetReps, in: all, profile: profile, unit: unit, customExercises: [], referenceDate: Date())
                        let done = all.filter { $0.status == .completed }.flatMap(\.items).filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == ExerciseCatalog.canonicalExerciseId(for: i.exerciseId) }
                        out(name + "sets \(i.targetSets)  \(before) -> \(before)  (\(why)) basis \(z.basis.rawValue) repMin \(i.repMin ?? i.targetReps) completed items \(done.count) logged \(done.filter { $0.actualReps.contains { $0 > 0 } }.count) waves \(Set(done.map { $0.waveRaw ?? "-" }).sorted())")
                    }
                }
            }
            _ = unit
        }
    }
}

// MARK: - Dry run: planned-set repair and the re-add load (report only)

@MainActor
final class PlannedSetRepairDryRunTests: XCTestCase {
    func test_dryRun_everyItemTheRepairWouldChange_andTheReAddExample() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_REPAIR_BACKUPS"], !list.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_REPAIR_BACKUPS to comma-separated backup paths")
        }
        var lines: [String] = []
        func out(_ s: String = "") { lines.append(s); print("PSR| \(s)") }
        defer { if let p = ProcessInfo.processInfo.environment["EP_REPAIR_REPORT"], !p.isEmpty { try? lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) } }
        func n(_ x: Double) -> String { LoadFormatter.number(x) }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        for path in list.split(separator: ",").map(String.init) {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            let ctx = ModelContext(container)
            let all = try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
            let custom = try ctx.fetch(FetchDescriptor<CustomExercise>())
            out("================ \(URL(fileURLWithPath: path).lastPathComponent)")
            let fixes = PlannedSetRepair.plan(sessions: all, customExercises: custom)
            out("-- planned-set repair: \(fixes.count) empty planned set(s) on \(Set(fixes.map { $0.item.persistentModelID }).count) item(s)")
            for fx in fixes {
                let name = fx.item.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: fx.item.exerciseId)
                out("\(f.string(from: fx.session.date)) \(fx.session.dayLabel ?? "?") (wk \(fx.session.weekIndex), \((fx.item.waveRaw ?? "-").uppercased())) \(name): set \(fx.index + 1) of \(fx.item.targetSets)  load \(n(fx.oldLoad)) -> \(n(fx.newLoad))  reps \(fx.oldReps) -> \(fx.newReps)  RIR \(fx.oldRIR) -> \(fx.newRIR)  planEdited \(fx.item.planEdited)")
            }

            // The re-add example: Nov 23 Push B Cable Tricep Rope Pushdown, removed and re-added the way the Program tab does it.
            guard let s = all.first(where: { f.string(from: $0.date) == "Nov 23" && $0.dayLabel == "Push B" && $0.status == .planned }),
                  let old = s.items.first(where: { $0.exerciseId == "cable_tricep_rope_pushdown" }) else { out("(example session not in this backup)"); continue }
            out("-- re-add example: Nov 23 Push B Cable Tricep Rope Pushdown (week \(s.weekIndex), \((old.waveRaw ?? "-").uppercased()))")
            out("before (as in the backup): suggested \(n(old.suggestedLoad)) planned \(old.plannedLoadsBySet.map(n)) sets \(old.targetSets) reps \(old.repMin ?? 0)-\(old.repMax ?? 0)")
            s.items.removeAll { $0.persistentModelID == old.persistentModelID }
            let new = SessionItem(order: (s.items.map(\.order).max() ?? 0) + 1, exerciseId: old.exerciseId, targetReps: 10, targetSets: 3, targetRIR: 2, suggestedLoad: 0)
            new.plannedRepsBySet = [10, 10, 10, 10]; new.plannedLoadsBySet = [0, 0, 0, 0]; new.plannedRIRsBySet = [2, 2, 2, 2]
            new.actualReps = [0, 0, 0, 0]; new.actualLoads = [0, 0, 0, 0]; new.actualRIRs = RIREntry.unsetArray(count: 4)
            let restored = WaveSlotRestore.restore(new, in: s, allSessions: all, entry: "dry run")
            s.items.append(new); ctx.insert(new)
            out("after restore: restored \(restored) letter \((new.waveRaw ?? "-").uppercased()) sets \(new.targetSets) reps \(new.repMin ?? 0)-\(new.repMax ?? 0) suggested \(n(new.suggestedLoad))")
            let ch = PlaceholderRefresh.refreshNewItem(new, in: ctx)
            out("after refresh (\(ch.count) change): suggested \(n(new.suggestedLoad)) planned \(new.plannedLoadsBySet.map(n))  note: \(new.coachNote ?? "-") | \(new.prescriptionNotes ?? "-")")
            for c in ch { out("   reason: \(c.reason.text)") }
        }
    }
}

// MARK: - Dry run: the coach's decision for every completed compound item of the active blocks (report only)

@MainActor
final class ProgressionDecisionDryRunTests: XCTestCase {

    struct Row: Codable {
        var key: String, date: String, day: String, wave: String, name: String, sets: Int, planned: String
        var reps: [Int], loads: [Double], rirs: [Int]
        var baseLoad: Double, kind: String, next: Double?, nextTop: Double?, message: String
        var presc: Int = 0, setMax: Int = 0, setMin: Int = 0, lastCounted: Double = 0
    }

    /// Writes one JSON array per backup to EP_PROG_OUT (a path prefix); the old and the new code each write theirs, and a diff lists the changes.
    func test_dump_everyCompletedCompoundItemDecision() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_PROG_BACKUPS"], !list.isEmpty,
              let outPrefix = ProcessInfo.processInfo.environment["EP_PROG_OUT"], !outPrefix.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_PROG_BACKUPS (comma-separated) and TEST_RUNNER_EP_PROG_OUT (output path prefix)")
        }
        EffortTracking.mode = .detailed
        let allHistory = ProcessInfo.processInfo.environment["EP_PROG_ALL"] == "1"
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        for (n, path) in list.split(separator: ",").map(String.init).enumerated() {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            let ctx = ModelContext(container)
            let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
            let sessions = try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
            var rows: [Row] = []
            for s in sessions where s.status == .completed && (allHistory || s.meso?.status == .active) && s.meso?.isMaintenance != true {
                for i in s.items where RIREntry.isCompound(i.exerciseId) && i.waveRaw?.lowercased() != "deload" {
                    let working = CoachingEngine.workingSetIndices(for: i)
                    guard !working.isEmpty else { continue }
                    let rec = CoachingEngine.recommend(for: i, profile: profile)
                    let base = working.map { i.actualLoads[$0] }.last ?? 0
                    let kind: String
                    if let next = rec?.nextSuggestedLoad ?? rec?.nextTopLoad {
                        kind = next > base + 0.001 ? "increase" : (next < base - 0.001 ? "lower" : "hold")
                    } else { kind = rec == nil ? "none" : "no-write" }
                    rows.append(Row(key: "\(f.string(from: s.date))|\(s.dayLabel ?? "?")|\(i.exerciseId)|\(i.waveRaw ?? "-")", date: f.string(from: s.date), day: s.dayLabel ?? "?",
                                    wave: (i.waveRaw ?? "-").uppercased(), name: i.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: i.exerciseId), sets: i.targetSets,
                                    planned: "\(i.repMin ?? i.targetReps)-\(i.repMax ?? i.targetReps) @ \(i.targetRIR) RIR",
                                    reps: working.map { i.actualReps[$0] }, loads: working.map { i.actualLoads[$0] }, rirs: working.map { i.actualRIRs.indices.contains($0) ? i.actualRIRs[$0] : -1 },
                                    baseLoad: base, kind: kind, next: rec?.nextSuggestedLoad, nextTop: rec?.nextTopLoad, message: rec?.message ?? "", presc: i.effectivePrescribedSets, setMax: i.setMax ?? 0, setMin: i.setMin ?? 0, lastCounted: CoachingEngine.countedSets(for: i, minLoadIncrement: profile.map { UserProfile.loadStep(for: i.exerciseId, profile: $0, unit: $0.loadUnit) } ?? nil, unit: profile?.loadUnit ?? .lb).rows.last.map { i.actualLoads[$0] } ?? 0))
                }
            }
            let data = try JSONEncoder().encode(rows)
            try data.write(to: URL(fileURLWithPath: "\(outPrefix)_\(n).json"))
            print("PROG| \(URL(fileURLWithPath: path).lastPathComponent): \(rows.count) rows")
        }
    }
}

// MARK: - Dry run: the meso verdict per exercise (report only)

@MainActor
final class MesoVerdictDryRunTests: XCTestCase {

    struct Row: Codable { var meso: String, status: String, exercise: String, verdict: String, change: Double?, basis: String, exposures: Int, series: [Double]; var blockChange: Double? = nil; var flatFor: Int? = nil; var line: String? = nil }

    func test_dump_everyExerciseVerdictOfEveryBlock() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_VERDICT_BACKUPS"], !list.isEmpty,
              let outPrefix = ProcessInfo.processInfo.environment["EP_VERDICT_OUT"], !outPrefix.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_VERDICT_BACKUPS and TEST_RUNNER_EP_VERDICT_OUT")
        }
        for (n, path) in list.split(separator: ",").map(String.init).enumerated() {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            let ctx = ModelContext(container)
            let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
            let sessions = try ctx.fetch(FetchDescriptor<Session>())
            var rows: [Row] = []
            for meso in try ctx.fetch(FetchDescriptor<MesoBlock>()) {
                let prior = sessions.filter { $0.meso?.persistentModelID != meso.persistentModelID }
                guard let a = MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: prior, bodyWeight: profile?.bodyWeight) else { continue }
                for e in a.exerciseSummaries {
                    rows.append(Row(meso: meso.name, status: meso.status.rawValue, exercise: e.exerciseName, verdict: "\(e.verdict)", change: e.trendChange,
                                    basis: "\(e.trendBasis)", exposures: e.e1rmBySession.count, series: e.e1rmBySession.map { ($0.e1rm * 10).rounded() / 10 },
                                    blockChange: e.blockChange, flatFor: e.flatForLast, line: e.changeLine(basisLabel: "e1RM")))
                }
                rows.append(Row(meso: meso.name, status: meso.status.rawValue, exercise: "** OVERALL **", verdict: "\(a.overallVerdict)", change: nil, basis: "", exposures: a.exerciseSummaries.count, series: []))
            }
            try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: "\(outPrefix)_\(n).json"))
            print("VERDICT| \(URL(fileURLWithPath: path).lastPathComponent): \(rows.count) rows")
        }
    }
}

// MARK: - Dry run: what the placeholder refresh would change on a first launch (report only; compiles on the code before and after 1.4)

@MainActor
final class RefreshChangesDryRunTests: XCTestCase {

    struct Row: Codable { var item: String, date: String, day: String, wave: String, name: String, oldLoad: Double, newLoad: Double, noteOnly: Bool, reason: String, note: String }

    func test_dump_theRefreshPlanAfterEveryOtherStartupBackfill() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_REFRESH_BACKUPS"], !list.isEmpty,
              let outPrefix = ProcessInfo.processInfo.environment["EP_REFRESH_OUT"], !outPrefix.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_REFRESH_BACKUPS and TEST_RUNNER_EP_REFRESH_OUT")
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        for (n, path) in list.split(separator: ",").map(String.init).enumerated() {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            FixtureClock.pin(path, in: self)
            let ctx = ModelContext(container)
            var saved: [String: Any] = [:]
            for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasSuffix(".completed") { saved[k] = v; UserDefaults.standard.removeObject(forKey: k) }
            defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
            for b in StartupBackfills.registered where !b.name.contains("PlaceholderRefresh") { b.run(ctx) }
            let changes = PlaceholderRefresh.plan(in: ctx)
            let rows = changes.map { c in
                Row(item: c.item.id?.uuidString ?? "\(c.item.persistentModelID)", date: f.string(from: c.session.date), day: c.session.dayLabel ?? "?", wave: (c.item.waveRaw ?? "-").uppercased(),
                    name: c.item.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: c.item.exerciseId), oldLoad: c.oldLoad, newLoad: c.newLoad, noteOnly: c.noteOnly,
                    reason: c.reason.text, note: c.note ?? "")
            }.sorted { ($0.date, $0.day, $0.name, $0.item) < ($1.date, $1.day, $1.name, $1.item) }
            try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: "\(outPrefix)_\(n).json"))
            print("REFRESH| \(URL(fileURLWithPath: path).lastPathComponent): \(rows.count) planned changes")
        }
    }
}

// MARK: - Dry run: compound holds caused ONLY by the RIR adjustment (report only)

@MainActor
final class RIRAdjustmentHoldReportTests: XCTestCase {

    func test_report_everyCompoundHoldThatRepsAloneWouldHaveIncreased() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_RIRHOLD_BACKUPS"], !list.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_RIRHOLD_BACKUPS (comma-separated); optional TEST_RUNNER_EP_RIRHOLD_REPORT")
        }
        var lines: [String] = []
        func out(_ s: String = "") { lines.append(s); print("RIRH| \(s)") }
        defer { if let p = ProcessInfo.processInfo.environment["EP_RIRHOLD_REPORT"], !p.isEmpty { try? lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) } }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        func n(_ x: Double) -> String { LoadFormatter.number(x) }
        defer { EffortTracking.clearMirror() }

        for path in list.split(separator: ",").map(String.init) {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            let ctx = ModelContext(container)
            let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
            let sessions = try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)]))
            out("================ \(URL(fileURLWithPath: path).lastPathComponent)")
            var count = 0, compoundItems = 0, releasedOnNext = 0, nextCompleted = 0, releasedOnTheHoldItself = 0, firstExposures = 0, firstExposuresReleased = 0
            for s in sessions where s.status == .completed && s.meso?.isMaintenance != true {
                for i in s.items where RIREntry.isCompound(i.exerciseId) && i.waveRaw?.lowercased() != "deload" {
                    let working = CoachingEngine.workingSetIndices(for: i)
                    guard !working.isEmpty else { continue }
                    compoundItems += 1
                    let base = working.map { i.actualLoads[$0] }.last ?? 0
                    func kind(_ mode: EffortMode) -> String {
                        EffortTracking.mode = mode
                        guard let rec = CoachingEngine.recommend(for: i, profile: profile), let next = rec.nextSuggestedLoad ?? rec.nextTopLoad else { return "none" }
                        return next > base + 0.001 ? "increase" : (next < base - 0.001 ? "lower" : "hold")
                    }
                    let repsOnly = kind(.off), withEffort = kind(.detailed)
                    guard repsOnly == "increase", withEffort != "increase" else { continue }
                    EffortTracking.mode = .detailed
                    let rec = CoachingEngine.recommend(for: i, profile: profile)
                    count += 1
                    let letter = (i.waveRaw ?? "-").uppercased()
                    out("\(f.string(from: s.date)) \(s.dayLabel ?? "?") (\(s.meso?.name ?? "-"), wk \(s.weekIndex), \(letter)) \(i.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: i.exerciseId))  [\(i.repMin ?? i.targetReps)-\(i.repMax ?? i.targetReps) @ \(i.targetRIR) RIR]")
                    out("   done   \(n(base)) x \(working.map { String(i.actualReps[$0]) }.joined(separator: ","))  RIR \(working.map { i.actualRIRs.indices.contains($0) ? (i.actualRIRs[$0] >= 0 ? String(i.actualRIRs[$0]) : "-") : "-" }.joined(separator: ","))  -> \(withEffort) (reps-only: \(repsOnly))")
                    out("   coach  \(rec?.message ?? "-")")
                    // The valve on this very exposure: the previous exposure of the lift (same letter) decides whether it applies at all.
                    func increases(_ r: CoachingRecommendation?, base: Double) -> Bool { (r?.nextSuggestedLoad ?? r?.nextTopLoad).map { $0 > base + 0.001 } ?? false }
                    EffortTracking.mode = .detailed
                    let priorHold = CoachingEngine.priorExposureWasRIRHold(for: i, in: s, allSessions: sessions)
                    let releasedHere = priorHold && increases(CoachingEngine.recommend(for: i, priorExposureWasRIRHold: true, ignoreEffort: false), base: base)
                    if releasedHere { releasedOnTheHoldItself += 1 }
                    if !priorHold { firstExposures += 1; if releasedHere { firstExposuresReleased += 1 } }
                    out("   valve  on this exposure: previous exposure was an RIR hold = \(priorHold); released = \(releasedHere)")
                    // The next exposure of the same lift on the same letter, same block and day type.
                    let canonical = ExerciseCatalog.canonicalExerciseId(for: i.exerciseId)
                    let next = sessions.first { t in
                        t.date > s.date && t.meso?.persistentModelID == s.meso?.persistentModelID && SessionDayLabelMatcher.matches(t.dayLabel, s.dayLabel)
                            && t.items.contains { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && $0.waveRaw?.lowercased() == i.waveRaw?.lowercased() }
                    }
                    if let t = next, let ni = t.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical && $0.waveRaw?.lowercased() == i.waveRaw?.lowercased() }) {
                        let nw = CoachingEngine.workingSetIndices(for: ni)
                        if t.status == .completed, !nw.isEmpty {
                            let nb = nw.map { ni.actualLoads[$0] }.last ?? 0
                            nextCompleted += 1
                            EffortTracking.mode = .detailed
                            let without = increases(CoachingEngine.recommend(for: ni), base: nb)
                            let withValve = increases(CoachingEngine.recommend(for: ni, priorExposureWasRIRHold: true), base: nb)
                            let released = withValve && !without
                            if released { releasedOnNext += 1 }
                            out("   valve  on the next exposure (previous = this hold): \(released ? "RELEASES the increase" : (without ? "not needed (already earns)" : "no release"))")
                            out("   next   \(f.string(from: t.date)) (wk \(t.weekIndex)): \(n(nb)) x \(nw.map { String(ni.actualReps[$0]) }.joined(separator: ","))  RIR \(nw.map { ni.actualRIRs.indices.contains($0) ? (ni.actualRIRs[$0] >= 0 ? String(ni.actualRIRs[$0]) : "-") : "-" }.joined(separator: ","))  (\(nb > base + 0.001 ? "load up" : (nb < base - 0.001 ? "load down" : "same load")))")
                        } else {
                            out("   next   \(f.string(from: t.date)) (wk \(t.weekIndex)) \(t.status.rawValue): planned \(n(ni.suggestedLoad)) x \(ni.plannedRepsBySet.first.map(String.init) ?? "-") @ \(ni.targetRIR) RIR")
                        }
                    } else { out("   next   (no later exposure of this lift on this letter in the block)") }
                }
            }
            out("-- \(count) of \(compoundItems) completed compound items are holds caused only by the RIR adjustment")
            out("-- valve: \(releasedOnNext) of the \(nextCompleted) holds with a completed next exposure are released at that next exposure")
            out("-- first exposures (previous exposure not an RIR hold): \(firstExposures), released: \(firstExposuresReleased). Holds that were themselves a repeat exposure: \(count - firstExposures), released: \(releasedOnTheHoldItself)")
        }
    }
}

// MARK: - Dry run: the next-meso preview, old single 95% against the verdict-gated start (report only)

@MainActor
final class NextMesoGateDryRunTests: XCTestCase {
    func test_report_everyLiftOldVersusNew() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_GATE_BACKUPS"], !list.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_GATE_BACKUPS (comma-separated); optional TEST_RUNNER_EP_GATE_REPORT")
        }
        var lines: [String] = []
        func out(_ s: String = "") { lines.append(s); print("GATE| \(s)") }
        defer { if let p = ProcessInfo.processInfo.environment["EP_GATE_REPORT"], !p.isEmpty { try? lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) } }
        func n(_ x: Double) -> String { LoadFormatter.number(x) }
        for path in list.split(separator: ",").map(String.init) {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            let ctx = ModelContext(container)
            let blocks = try ctx.fetch(FetchDescriptor<MesoBlock>())
            guard let old = blocks.filter({ $0.status == .active }).max(by: { $0.sessions.count < $1.sessions.count }) ?? blocks.max(by: { $0.sessions.count < $1.sessions.count }) else { out("(no meso)"); continue }
            let now = Date(), start = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
            typealias Svc = SessionItemEditService
            let before = Svc.planNextMeso(meso: old, name: "Next", startDate: start, endOldMesoNow: true, verdictGated: false, context: ctx, now: now)
            let after = Svc.planNextMeso(meso: old, name: "Next", startDate: start, endOldMesoNow: true, context: ctx, now: now)
            out("================ \(URL(fileURLWithPath: path).lastPathComponent): next meso from \"\(old.name)\" (\(old.status.rawValue), \(old.sessions.count) sessions)")
            out("refusals: \(after.refusals)")
            // One line per lift and wave letter (first appearance).
            var rows: [(name: String, letter: String, oldSeed: Double, newSeed: Double, src: String, factor: Double?, reason: String?)] = []
            var seen = Set<String>()
            let oldItems = Dictionary(before.sessions.flatMap { s in s.items.map { ("\(s.letter)|\(s.dayLabel ?? "")|\($0.order)", $0) } }, uniquingKeysWith: { first, _ in first })
            for s in after.sessions {
                for i in s.items {
                    let key = "\(ExerciseCatalog.canonicalExerciseId(for: i.exerciseId))|\(s.letter)"
                    guard seen.insert(key).inserted, let o = oldItems["\(s.letter)|\(s.dayLabel ?? "")|\(i.order)"] else { continue }
                    rows.append((ExerciseCatalog.displayName(for: i.exerciseId), s.letter.isEmpty ? "-" : s.letter.uppercased(), o.seed, i.seed, i.seedSource.rawValue, i.seedFactor, i.seedReason))
                }
            }
            var changed = 0
            for r in rows.sorted(by: { ($0.name, $0.letter) < ($1.name, $1.letter) }) {
                if r.oldSeed != r.newSeed { changed += 1 }
                let pct = r.newSeed > 0 && r.oldSeed > 0 ? String(format: " (%+.1f%%)", (r.newSeed / r.oldSeed - 1) * 100) : ""
                out("\(r.name) [\(r.letter)]: old \(n(r.oldSeed)) -> new \(n(r.newSeed))\(pct)  [\(r.src)\(r.factor.map { " \(Int(($0 * 100).rounded()))%" } ?? "")]  \(r.reason ?? "")")
            }
            out("-- \(rows.count) lift/letter seeds, \(changed) change; peak seeds: \(rows.filter { $0.src == "peak" }.count)")
        }
    }
}

// MARK: - Dry run: custom exercises that duplicate a built-in (report only)

@MainActor
final class CustomExerciseMergeDryRunTests: XCTestCase {
    func test_report_whatTheMergeWouldMove() throws {
        guard let list = ProcessInfo.processInfo.environment["EP_MERGE_BACKUPS"], !list.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_MERGE_BACKUPS (comma-separated); optional TEST_RUNNER_EP_MERGE_REPORT")
        }
        var lines: [String] = []
        func out(_ s: String = "") { lines.append(s); print("MERGE| \(s)") }
        defer { if let p = ProcessInfo.processInfo.environment["EP_MERGE_REPORT"], !p.isEmpty { try? lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) } }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        for path in list.split(separator: ",").map(String.init) {
            let container = try ModelContainer(for: AppSchema.makeSchema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
            let ctx = ModelContext(container)
            out("================ \(URL(fileURLWithPath: path).lastPathComponent): \((try ctx.fetch(FetchDescriptor<CustomExercise>())).count) custom exercises")
            let plans = CustomExerciseMerge.plans(in: ctx)
            if plans.isEmpty { out("(no custom exercise has a built-in's name)") }
            for p in plans {
                out(p.summary)
                for i in p.items.sorted(by: { ($0.exerciseNameSnapshot ?? "") < ($1.exerciseNameSnapshot ?? "") }) {
                    let s = (try ctx.fetch(FetchDescriptor<Session>())).first { $0.items.contains { $0 === i } }
                    out("   \(s.map { f.string(from: $0.date) } ?? "?") \(s?.dayLabel ?? "?") (\(s?.status.rawValue ?? "?"), \((i.waveRaw ?? "-").uppercased())): \(i.targetSets) sets, logged \(zip(i.actualReps, i.actualLoads).filter { $0.0 > 0 }.map { "\(LoadFormatter.number($0.1))x\($0.0)" }.joined(separator: ", "))")
                }
            }
            // Apply to the in-memory copy and check the result.
            let beforeSessions = try ctx.fetch(FetchDescriptor<Session>()).flatMap(\.items).count
            let n = CustomExerciseMerge.apply(plans, in: ctx)
            let left = CustomExerciseMerge.plans(in: ctx).count
            let afterItems = try ctx.fetch(FetchDescriptor<Session>()).flatMap(\.items)
            out("-- applied to a copy: \(n) merged; custom rows now \((try ctx.fetch(FetchDescriptor<CustomExercise>())).count); items total \(beforeSessions) -> \(afterItems.count); remaining duplicates \(left)")
            for p in plans {
                let moved = afterItems.filter { $0.exerciseId == p.builtInId }.count
                let stray = afterItems.filter { $0.exerciseId == p.custom.id }.count
                out("   \(p.builtInId): \(moved) item(s) now on the built-in id; \(stray) still on the custom id")
            }
        }
    }
}

// MARK: - After the 1.4 launch backfills: a backup of the migrated store round-trips (report-only unless it differs)

@MainActor
final class PostMigrationRoundTripTests: XCTestCase {
    private var parked: [ModelContainer] = []

    func test_migratedStore_exportsImportsAndReExportsIdentically() throws {
        // The backups the gate already points at (scripts/full_gate.sh), or an explicit comma-separated list.
        let env = ProcessInfo.processInfo.environment
        let fromGate = ["EP_BACKUP_FIXTURE", "EP_LIVE_BACKUP", "EP_ANGELA_130"].compactMap { env[$0] }.filter { FileManager.default.fileExists(atPath: $0) }
        let list = (env["EP_RT_BACKUPS"].flatMap { $0.isEmpty ? nil : $0 } ?? fromGate.joined(separator: ","))
        guard !list.isEmpty else { throw XCTSkip("set TEST_RUNNER_EP_RT_BACKUPS (comma-separated) or the gate's fixture variables") }
        var saved: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasSuffix(".completed") { saved[k] = v; UserDefaults.standard.removeObject(forKey: k) }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
        for path in list.split(separator: ",").map(String.init) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let c1 = try BackupTestSupport.makeContainer(); parked.append(c1)
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: c1)
            let ctx1 = ModelContext(c1)
            let before = (try ctx1.fetch(FetchDescriptor<Session>()).count, try ctx1.fetch(FetchDescriptor<SessionItem>()).count, try ctx1.fetch(FetchDescriptor<CustomExercise>()).count,
                          try ctx1.fetch(FetchDescriptor<SessionHistory>()).count, try ctx1.fetch(FetchDescriptor<MesoBlock>()).count)
            StartupBackfills.run(using: c1)                                         // the 1.4 launch
            let ctx = ModelContext(c1)
            let after = (try ctx.fetch(FetchDescriptor<Session>()).count, try ctx.fetch(FetchDescriptor<SessionItem>()).count, try ctx.fetch(FetchDescriptor<CustomExercise>()).count,
                         try ctx.fetch(FetchDescriptor<SessionHistory>()).count, try ctx.fetch(FetchDescriptor<MesoBlock>()).count)
            print("RT| \(name): sessions \(before.0)->\(after.0) items \(before.1)->\(after.1) custom \(before.2)->\(after.2) history \(before.3)->\(after.3) blocks \(before.4)->\(after.4)")
            XCTAssertEqual(before.0, after.0); XCTAssertEqual(before.1, after.1); XCTAssertEqual(before.3, after.3); XCTAssertEqual(before.4, after.4)
            XCTAssertLessThanOrEqual(after.2, before.2, "the launch backfills may merge custom exercises into built-ins, never add one")

            let first = try BackupTestSupport.exportJSON(ctx)
            let c2 = try BackupTestSupport.makeContainer(); parked.append(c2)
            _ = try BackupTestSupport.restore(from: ctx, into: c2)
            let ctx2 = ModelContext(c2)
            let second = try BackupTestSupport.exportJSON(ctx2)
            func canon(_ o: [String: Any]) throws -> Data {
                var o = o; o.removeValue(forKey: "exportedAt"); o.removeValue(forKey: "metadata")
                return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
            }
            // Strict: the exporter orders custom exercises by createdAt then id, so even customs created in the same instant keep one order.
            let a = try canon(first), b = try canon(second)
            print("RT| \(name): export bytes \(a.count) vs re-export \(b.count): \(a == b ? "IDENTICAL" : "DIFFERENT")")
            if a != b, let dir = ProcessInfo.processInfo.environment["EP_RT_DUMP"] {
                try a.write(to: URL(fileURLWithPath: dir).appendingPathComponent("first_\(name)")); try b.write(to: URL(fileURLWithPath: dir).appendingPathComponent("second_\(name)"))
            }
            XCTAssertEqual(a, b, "\(name): the migrated store's backup must restore and re-export byte-identically")
            // the 1.4 fields survive the round trip
            let items = try ctx2.fetch(FetchDescriptor<SessionItem>())
            XCTAssertEqual(items.filter { $0.loadEverWritten == nil }.count, 0, "every restored item carries loadEverWritten")
            XCTAssertEqual(items.filter { $0.loadEverWritten == true }.count, try ctx.fetch(FetchDescriptor<SessionItem>()).filter { $0.loadEverWritten == true }.count)
        }
    }
}
