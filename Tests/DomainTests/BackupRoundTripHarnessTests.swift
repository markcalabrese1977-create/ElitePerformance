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
        "programIndex", "appModeRaw", "isPR", "isCompleted", "primaryMuscle",
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
        ("BodyweightPhantomLoadMigration", { BodyweightPhantomLoadMigration.runIfNeeded(in: $0) })
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

// MARK: - Another user's store: startup repairs must leave it byte-identical

/// A store that carries every shape the retired one-user repairs used to look for. The registered
/// `StartupBackfills` must leave it untouched.
final class OtherUsersStoreStartupTests: XCTestCase {

    private var container: ModelContainer!

    private static let completionKeys = [
        "exerciseNameSnapshotBackfill.v1.completed", "exerciseNameSnapshotRepair.v6.completed",
        "canonicalExerciseIdMigration.v1.completed", "customExerciseDedupMigration.v1.completed",
        "d5ExerciseIdRepairMigration.v3.completed", "apr21SessionHistoryRepairMigration.v3.completed",
        "sessionHistoryBlockBackfill.v1.completed", "mechanicalLoadRecovery.v1.completed",
        "sessionDayLabelBackfill.v1.completed", "customExerciseStoreMigration.v1.completed",
        "customExerciseUserDefaultsSync.v1.completed", "mesoBlockIsMaintenanceBackfill.v1.completed",
        "bodyweightPhantomLoadMigration.v1.completed", "prescriptionNotesClear.v1.completed",
        "week6UpperBCleanupMigration.v1.completed", "custom_exercises_v2",
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
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, PRIndex.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
        try ctx.save()
        return ctx
    }

    /// The whole store, as the backup exporter sees it, without its export timestamp.
    private func snapshot(_ ctx: ModelContext) throws -> Data {
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        defer { try? FileManager.default.removeItem(at: result.url) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        object.removeValue(forKey: "exportedAt")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func test_registeredStartupBackfills_leaveAnotherUsersStoreByteIdentical() throws {
        let ctx = try makeStore()
        let before = try snapshot(ctx)

        clearKeys()
        StartupBackfills.run(using: container)

        ctx.rollback()
        XCTAssertEqual(try snapshot(ModelContext(container)), before, "no model changed")
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

    private func scan() throws -> [Hit] {
        var hits: [Hit] = []
        let compiled = try Self.patterns.map { ($0.name, try NSRegularExpression(pattern: $0.regex)) }
        for src in try productionSources() {
            for (idx, line) in src.text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                for (name, re) in compiled {
                    for m in re.matches(in: line, range: range) {
                        hits.append(Hit(file: src.path, name: src.name, line: idx + 1, pattern: name,
                                        text: (line as NSString).substring(with: m.range)))
                    }
                }
            }
        }
        return hits
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
            PRIndex.self, SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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

/// Imports the backup named by EP_BACKUP_FIXTURE, plans the next meso from its active block (ending the old one
/// now, starting tomorrow), PRINTS the preview, applies it, and checks the result: one active block, an archived
/// old one, clean items, contiguous weeks and programIndex, one weekday per day type, no date collisions, chains
/// inside the new meso, and every completed session of the backup byte-identical. Then exports, imports that
/// export into a fresh store and exports again: the round trip may not differ from the same round trip taken
/// before the apply. Skips without the fixture. The file holds personal data and is never copied.
final class NextMesoRealBackupTests: XCTestCase {

    private typealias Service = SessionItemEditService
    private let lifecycleKeys = ["meso.scheduledStartDateEpoch", "meso.activeStartDateEpoch", "meso.promptSnoozeEpoch",
                                 "meso.anchorDate", "meso.anchorDayNumber"]

    private func out(_ s: String = "") { print("NMR| \(s)") }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            PRIndex.self, SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func export(_ ctx: ModelContext) throws -> (json: [String: Any], url: URL) {
        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ctx)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.url)) as? [String: Any])
        json.removeValue(forKey: "exportedAt")
        return (json, result.url)
    }

    private func canonical(_ json: Any) throws -> Data { try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) }

    /// Paths where two JSON values differ (rows matched by id).
    private func diff(_ a: Any, _ b: Any, path: String = "$", into lines: inout [String]) {
        guard lines.count < 400 else { return }
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
            } else if x.count != y.count {
                lines.append("\(path): count \(x.count) vs \(y.count)")
            } else {
                for (i, pair) in zip(x, y).enumerated() { diff(pair.0, pair.1, path: "\(path)[\(i)]", into: &lines) }
            }
        } else if "\(a)" != "\(b)" {
            lines.append("\(path): \(a) vs \(b)")
        }
    }

    private func normalized(_ json: [String: Any]) -> [String: Any] {
        var out = json
        func byID(_ rows: [[String: Any]]) -> [[String: Any]] { rows.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") } }
        if let history = json["sessionHistory"] as? [[String: Any]] {
            out["sessionHistory"] = byID(history).map { row -> [String: Any] in
                var r = row
                if let ex = row["exercises"] as? [[String: Any]] {
                    r["exercises"] = ex.sorted { ((try? canonical($0)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
                                                  < ((try? canonical($1)).flatMap { String(data: $0, encoding: .utf8) } ?? "") }
                }
                return r
            }
        }
        for key in ["exerciseNotes", "sessions", "mesoBlocks", "customExercises"] {
            if let rows = json[key] as? [[String: Any]] { out[key] = byID(rows) }
        }
        return out
    }

    /// export -> import into a fresh store -> export; the differences between the first and last export.
    private func roundTripDiff(_ url: URL, _ first: [String: Any]) throws -> [String] {
        let fresh = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: url, modelContainer: fresh)
        let second = try export(ModelContext(fresh)).json
        // Sessions, blocks, history rows and notes. SessionHistory rows are compared sorted by id, and the
        // exercises inside a row sorted by content (they carry no id and come back in import order).
        var lines: [String] = []
        let n1 = normalized(first), n2 = normalized(second)
        for key in ["sessions", "mesoBlocks", "sessionHistory", "exerciseNotes", "customExercises"] {
            diff(n1[key] ?? [], n2[key] ?? [], path: "$.\(key)", into: &lines)
        }
        return lines
    }

    private func day(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "EEE yyyy-MM-dd"
        return f.string(from: d)
    }

    func testNextMesoOnARealBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("EP_BACKUP_FIXTURE not set")
        }
        let defaults = UserDefaults.standard
        let saved = lifecycleKeys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (k, v) in saved { if let v { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) } } }

        let container = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        let calendar = Calendar.current
        let blocks = try ctx.fetch(FetchDescriptor<MesoBlock>())
        let old = try XCTUnwrap(blocks.filter { $0.status == .active }.max { $0.sessions.count < $1.sessions.count }
                                    ?? blocks.max { $0.sessions.count < $1.sessions.count }, "no meso in the backup")
        let now = Date()
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))

        let before = try export(ctx)
        let baseline = try roundTripDiff(before.url, before.json)
        out("baseline round trip (before apply): \(baseline.count) differences")

        // --- Preview ---
        let plan = Service.planNextMeso(meso: old, name: "Next meso", startDate: tomorrow, endOldMesoNow: true, context: ctx, now: now)
        out("== PREVIEW: next meso from \"\(old.name)\" (\(old.sessions.count) sessions, \(old.status.rawValue), "
            + "totalWeeks \(old.totalWeeks.map(String.init) ?? "nil")); today \(day(now)); start \(day(tomorrow)) ==")
        out("refusals: \(plan.refusals); collisions: \(plan.collisions.count); remaining old sessions: \(plan.remainingOldSessions.count)")
        plan.previewLines().forEach { out($0) }
        out("first week:")
        for s in plan.firstWeek { out("  \(day(s.date)) \(s.dayLabel ?? "?") [\(s.letter.isEmpty ? "-" : s.letter)]: " + s.items.map { ExerciseCatalog.displayName(for: $0.exerciseId) }.joined(separator: ", ")) }
        let sources = Dictionary(grouping: plan.sessions.flatMap(\.items), by: { $0.seedSource.rawValue }).mapValues(\.count)
        out("seed sources across all items: \(sources.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        // Condensed: one line per exercise (peak e1RM or source, seed per letter).
        do {
            let fixed = (try? ctx.fetch(FetchDescriptor<UserProfile>()).first)?.exemptExerciseIds ?? []
            var order: [String] = []
            var rows: [String: [String: (Double, String)]] = [:]
            for s in plan.sessions {
                for i in s.items {
                    let id = ExerciseCatalog.canonicalExerciseId(for: i.exerciseId)
                    if rows[id] == nil { order.append(id) }
                    let key = s.letter.isEmpty ? "-" : s.letter.uppercased()
                    if rows[id, default: [:]][key] == nil { rows[id, default: [:]][key] = (i.seed, i.seedSource.rawValue) }
                }
            }
            out("== CONDENSED: exercise | peak e1RM or source | seed A / B / C ==")
            for id in order {
                let peak = HistorySeedLoad.peakE1RM(for: id, in: old.sessions)
                let r = rows[id] ?? [:]
                let sources = Set(r.values.map(\.1))
                let head = peak.map { "peak e1RM \(Int($0.rounded()))" } ?? (sources.count == 1 ? sources.first! : sources.sorted().joined(separator: "/"))
                let seeds = ["A", "B", "C", "DELOAD", "-"].compactMap { k in r[k].map { "\(k == "DELOAD" ? "D" : k) \(LoadFormatter.number($0.0))" } }
                let tag = fixed.contains(where: { ExerciseCatalog.canonicalExerciseId(for: $0) == id }) ? " (fixed-load)" : ""
                out("  \(ExerciseCatalog.displayName(for: id))\(tag) | \(head) | \(seeds.joined(separator: " / "))")
            }
            out("== HISTORY FALLBACK: no qualifying completed old-meso working set ==")
            for id in order where rows[id]?.values.contains(where: { $0.1 == "history" }) == true {
                var withExercise = 0, completed = 0, deloadOnly = 0, noSets = 0
                for s in old.sessions {
                    guard let m = s.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == id }) else { continue }
                    withExercise += 1
                    if s.status != .completed { continue }
                    completed += 1
                    if m.waveRaw?.lowercased() == "deload" { deloadOnly += 1 }
                    else if !m.actualLoads.contains(where: { $0 > 0 }) || !m.actualReps.contains(where: { $0 > 0 }) { noSets += 1 }
                }
                out("  \(ExerciseCatalog.displayName(for: id)): in \(withExercise) old-meso sessions, \(completed) completed (\(deloadOnly) deload, \(noSets) with no logged load x reps); "
                    + "the history seed used earlier mesos")
            }
        }
        XCTAssertTrue(plan.isApplicable, "the backup's meso should plan cleanly: \(plan.refusals)")

        // --- Apply ---
        let completedBefore = (before.json["sessions"] as? [[String: Any]] ?? []).filter { $0["statusRaw"] as? String == "completed" }
        let result = try Service.startNextMeso(plan, in: ctx)
        out("== APPLIED: \(result.sessionsCreated) sessions created, \(result.sessionsDeleted) removed from the old meso ==")

        let blocksAfter = try ctx.fetch(FetchDescriptor<MesoBlock>())
        XCTAssertEqual(blocksAfter.filter { $0.status == .active }.count, 1)
        XCTAssertEqual(old.status, .archived)
        let new = result.meso
        XCTAssertEqual(new.status, .active)
        XCTAssertEqual(new.sessions.count, plan.sessions.count)
        XCTAssertEqual(Set(new.sessions.map(\.weekIndex)), Set(1...plan.weeks), "weeks contiguous")
        XCTAssertEqual(new.sessions.compactMap(\.programIndex).sorted(), Array(1...plan.sessions.count), "programIndex contiguous")
        var weekdays: [String: Set<Int>] = [:]
        for s in new.sessions { weekdays[s.dayLabel ?? "", default: []].insert(calendar.component(.weekday, from: s.date)) }
        XCTAssertTrue(weekdays.values.allSatisfy { $0.count == 1 }, "one weekday per day type: \(weekdays)")
        for s in new.sessions {
            XCTAssertTrue(s.date >= tomorrow)
            XCTAssertNotEqual(s.insertedDeload, true)
            for i in s.items {
                XCTAssertFalse(i.planEdited)
                XCTAssertFalse(SessionEditSafety.hasLoggedData(i))
                XCTAssertEqual(i.plannedLoadsBySet.count, i.targetSets)
            }
        }
        let allSessions = try ctx.fetch(FetchDescriptor<Session>())
        let newIDs = Set(new.sessions.map(\.persistentModelID))
        let otherDays = Set(allSessions.filter { !newIDs.contains($0.persistentModelID) }.map { calendar.startOfDay(for: $0.date) })
        XCTAssertTrue(new.sessions.allSatisfy { !otherDays.contains(calendar.startOfDay(for: $0.date)) }, "no date collisions")
        XCTAssertEqual(Set(new.sessions.map { calendar.startOfDay(for: $0.date) }).count, new.sessions.count, "one session per day")
        var chains = 0
        for s in new.sessions {
            for i in s.items where WavePrescriptionGuard.isWaveLetter(i.waveRaw) {
                chains += 1
                if let t = PlanMemoryEngine.nextTargetItem(for: i, after: s, in: allSessions) {
                    let owner = allSessions.first { $0.items.contains { $0 === t } }
                    XCTAssertTrue(owner?.meso === new, "chain leaves the new meso")
                    XCTAssertEqual(owner?.dayLabel, s.dayLabel)
                    XCTAssertEqual(t.waveRaw?.lowercased(), i.waveRaw?.lowercased())
                }
            }
        }
        out("chains checked: \(chains) wave items, all inside the new meso; weeks 1...\(plan.weeks); end \(plan.endDate.map(day) ?? "?")")

        let after = try export(ctx)
        let completedAfter = (after.json["sessions"] as? [[String: Any]] ?? []).filter { $0["statusRaw"] as? String == "completed" }
        XCTAssertEqual(try canonical(completedBefore), try canonical(completedAfter), "completed sessions byte-identical")
        out("completed sessions byte-identical: \(completedBefore.count)")

        // --- Round trip ---
        let lines = try roundTripDiff(after.url, after.json)
        let extra = Set(lines).subtracting(baseline)
        out("round trip after apply: \(lines.count) differences (\(baseline.count) already in the baseline); new: \(extra.count)")
        extra.sorted().prefix(30).forEach { out("DIFF \($0)") }
        XCTAssertTrue(extra.isEmpty, "export -> import -> export differs for the new meso: \(extra.sorted().prefix(5))")
        XCTAssertEqual(MesoLifecycle.scheduledStartDate, nil)
        XCTAssertEqual(calendar.startOfDay(for: MesoLifecycle.activeStartDate), tomorrow)
    }
}
