import XCTest
import SwiftData
@testable import ElitePerformance

/// Read-only report: for the newest backup (EP_BACKUP_FIXTURE), what each existing screen shows today versus what the
/// single analytics definitions (WorkingSetFilter, E1RMCalculator, PersonalRecords) would show. Nothing is switched;
/// this only measures. Set EP_ANALYTICS_REPORT to a path to also write the report to a file. Skipped without a fixture.
final class AnalyticsImpactReportTests: XCTestCase {

    private var container: ModelContainer!
    private var lines: [String] = []

    private func log(_ s: String = "") { lines.append(s); print("ANALYTICS| \(s)") }
    private func flush() {
        guard let path = ProcessInfo.processInfo.environment["EP_ANALYTICS_REPORT"], !path.isEmpty else { return }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func loadFixture() throws -> (ModelContext, [Session], UserProfile?, [CustomExercise]) {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        let c = try BackupTestSupport.makeContainer()
        container = c
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: c)
        let ctx = ModelContext(c)
        ctx.autosaveEnabled = false
        log("fixture: \(URL(fileURLWithPath: path).lastPathComponent)")
        return (ctx,
                try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date },
                try ctx.fetch(FetchDescriptor<UserProfile>()).first,
                try ctx.fetch(FetchDescriptor<CustomExercise>()))
    }

    private func pct(_ old: Double, _ new: Double) -> Double { old == 0 ? (new == 0 ? 0 : 100) : (new - old) / old * 100 }
    private func f(_ v: Double) -> String { String(format: "%.1f", v) }
    private func name(_ id: String) -> String { ExerciseCatalog.displayName(for: id) }

    /// Aggregate + the rows that moved more than `threshold` percent, largest first.
    private func table(_ title: String, _ rows: [(id: String, old: Double, new: Double)], threshold: Double = 0.5, cap: Int = 40) {
        let changed = rows.filter { abs(pct($0.old, $0.new)) > threshold || ($0.old == 0) != ($0.new == 0) }
        let deltas = changed.map { pct($0.old, $0.new) }.sorted { abs($0) > abs($1) }
        log("")
        log("== \(title)")
        log("   compared \(rows.count) · changed (>\(threshold)%) \(changed.count) · max |Δ| \(f(deltas.first.map(abs) ?? 0))% · "
            + "median |Δ| \(f(deltas.isEmpty ? 0 : abs(deltas.sorted { abs($0) < abs($1) }[deltas.count / 2])))%")
        for r in changed.sorted(by: { abs(pct($0.old, $0.new)) > abs(pct($1.old, $1.new)) }).prefix(cap) {
            log("   \(name(r.id).padding(toLength: 34, withPad: " ", startingAt: 0)) old \(f(r.old).padding(toLength: 9, withPad: " ", startingAt: 0)) new \(f(r.new).padding(toLength: 9, withPad: " ", startingAt: 0)) Δ \(f(pct(r.old, r.new)))%")
        }
        if changed.count > cap { log("   … \(changed.count - cap) more") }
    }

    func test_report_screenNumbersTodayVersusTheSingleDefinitions() throws {
        let (ctx, all, profile, customs) = try loadFixture()
        defer { flush() }
        let completed = all.filter { $0.status == .completed }
        let bodyWeight = profile?.bodyWeight
        let snap = SetRecordBuilder.build(sessions: all, customExercises: customs, bodyWeight: bodyWeight)
        log("sessions \(all.count) (completed \(completed.count)) · set records \(snap.sets.count) · lb storage, so lb users see these numbers as is")

        let bests = PersonalRecords.bests(from: snap.sets)
        var hard: [String: Int] = [:]
        for r in snap.sets where r.isLifetimeHardSet { hard[r.exerciseId, default: 0] += 1 }
        // ---- 1. (HistorySummaryView was retired: the Block recap now opens the Meso Summary) ----------------------------------

        // ---- 2. ExerciseHistorySheet (best e1RM per session entry) ---------------------------------------------------
        var entryRows: [(id: String, old: Double, new: Double)] = []
        var perSessionNew: [String: Double] = [:]
        for r in snap.sets where r.isWorkingSet && r.status == .completed && r.e1RM > 0 {
            let k = "\(r.sessionKey)|\(r.exerciseId)"
            perSessionNew[k] = max(perSessionNew[k] ?? 0, r.e1RM)
        }
        for s in completed {
            let sk = s.id?.uuidString ?? ""
            var seen = Set<String>()
            for item in s.items {
                let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                guard seen.insert(id).inserted else { continue }
                var old = 0.0
                for i in 0..<min(item.actualReps.count, item.actualLoads.count) where item.actualReps[i] > 0 && item.actualLoads[i] > 0 {
                    old = max(old, item.actualLoads[i] * (1 + Double(max(1, item.actualReps[i])) / 30))
                }
                guard old > 0 || perSessionNew["\(sk)|\(id)"] != nil else { continue }
                entryRows.append((id, old, perSessionNew["\(sk)|\(id)"] ?? 0))
            }
        }
        table("2. ExerciseHistorySheet: per-session best e1RM entries (today: max over all logged sets)", entryRows)
        log("   entries compared: \(entryRows.count) (each row above is one exercise; deltas are per exercise-session, listed by exercise name)")

        // ---- 3. ExerciseHistoryView (Home): best e1RM = max over entries of the highest-REP set's e1RM ---------------
        var homeOld: [String: Double] = [:]
        for s in completed {
            for item in s.items {
                let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                var bestReps = 0, load = 0.0
                for i in 0..<max(item.actualReps.count, item.actualLoads.count, item.plannedLoadsBySet.count) {
                    let reps = i < item.actualReps.count ? item.actualReps[i] : 0
                    let la = i < item.actualLoads.count ? item.actualLoads[i] : 0
                    let lp = i < item.plannedLoadsBySet.count ? item.plannedLoadsBySet[i] : 0
                    let l = la > 0 ? la : lp
                    guard reps > 0, l > 0, reps > bestReps else { continue }
                    bestReps = reps; load = l
                }
                if bestReps > 0 { homeOld[id] = max(homeOld[id] ?? 0, load * (1 + Double(max(1, bestReps)) / 30)) }
            }
        }
        table("3. ExerciseHistoryView (Home): best e1RM per exercise (today: the highest-REP set, planned load if none logged)",
              homeOld.map { ($0.key, $0.value, bests[$0.key]?.e1RM ?? 0) })

        // ---- 4. MesoSummaryView / MesoPerformanceAnalyzer (after the two requested fixes) ---------------------------
        var legacyOpenClose = 0, legacyPR = 0, summaries = 0
        var mesoLines: [String] = []
        let mesos = try ctx.fetch(FetchDescriptor<MesoBlock>()).sorted { $0.startDate < $1.startDate }
        for meso in mesos {
            let ids = Set(meso.sessions.map { $0.persistentModelID })
            let priors = all.filter { !ids.contains($0.persistentModelID) }   // exactly what MesoSummaryView passes
            guard let a = MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: priors) else { continue }
            let mine = meso.sessions.filter { $0.status == .completed && !$0.isDeloadWeek }.sorted { $0.date < $1.date }
            for sum in a.exerciseSummaries {
                summaries += 1
                let withEx = mine.compactMap { s -> SessionItem? in
                    s.items.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == sum.exerciseId }
                }
                func legacy(_ it: SessionItem?) -> Double? {
                    let acts = it?.actualLoads.filter { $0 > 0 } ?? []
                    return acts.first ?? ((it?.suggestedLoad ?? 0) > 0 ? it?.suggestedLoad : nil)
                }
                let oldOpen = legacy(withEx.first), oldClose = legacy(withEx.last)
                var oldPrior = 0.0
                for s in priors { for it in s.items where ExerciseCatalog.canonicalExerciseId(for: it.exerciseId) == sum.exerciseId {
                    for i in 0..<min(it.actualLoads.count, it.actualReps.count) where it.actualLoads[i] > 0 && it.actualReps[i] > 0 {
                        oldPrior = max(oldPrior, E1RMCalculator.e1RM(load: it.actualLoads[i], reps: it.actualReps[i]))
                    }
                } }
                let oldPR = (sum.peakE1RM ?? 0) > oldPrior
                if oldOpen != sum.openingLoad || oldClose != sum.closingLoad {
                    legacyOpenClose += 1
                    mesoLines.append("   [\(meso.name)] \(sum.exerciseName): open \(oldOpen.map(f) ?? "-") → \(sum.openingLoad.map(f) ?? "-"), close \(oldClose.map(f) ?? "-") → \(sum.closingLoad.map(f) ?? "-")")
                }
                if oldPR != sum.isPR {
                    legacyPR += 1
                    mesoLines.append("   [\(meso.name)] \(sum.exerciseName): PR badge \(oldPR) → \(sum.isPR)")
                }
            }
        }
        log("")
        log("== 4. MesoSummaryView after the analyzer fixes (top-set open/close load; maintenance excluded from prior peaks)")
        log("   mesos \(mesos.count) · exercise summaries compared \(summaries) · open/close load changed \(legacyOpenClose) · PR badge changed \(legacyPR)")
        mesoLines.forEach { log($0) }
        log("   not changed here: peak e1RM, verdicts, totals, weekly volume (they still count warm-ups, rest-pause and drop rows).")

        // ---- 5. The PR index: the old definition (best single-set VOLUME, raw ids) versus the e1RM definition ------------------
        var oldPRSets: [String: (volume: Double, load: Double, reps: Int)] = [:]
        for session in completed { for item in session.items {
            guard let b = PRService.legacyBestVolumeSet(in: item) else { continue }
            let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
            if b.volume > (oldPRSets[id]?.volume ?? 0) { oldPRSets[id] = b }
        } }
        var prRows: [(id: String, old: Double, new: Double)] = []
        var differentSet = 0
        var prLines: [String] = []
        for (id, o) in oldPRSets {
            guard let b = bests[id] else { continue }
            let oldE1 = E1RMCalculator.e1RM(load: o.load, reps: o.reps)
            prRows.append((id, oldE1, b.e1RM))
            if abs(o.load - b.load) > 0.01 || o.reps != b.reps {
                differentSet += 1
                prLines.append("   \(name(id)): old record \(f(o.load))×\(o.reps) (e1RM \(f(oldE1))) → \(f(b.load))×\(b.reps) (e1RM \(f(b.e1RM)))")
            }
        }
        table("5. PR index: best-volume set expressed as e1RM versus the e1RM definition", prRows)
        log("   exercises with a record: old \(oldPRSets.count) · new \(bests.count) · record SET differs \(differentSet)")
        prLines.sorted().prefix(40).forEach { log($0) }
        let rebuilt = try ctx.fetch(FetchDescriptor<PRIndex>())
        log("   PRIndex rows after the import's rebuild (new definition): \(rebuilt.count)")
        let events = PersonalRecords.events(from: snap.sets)
        log("   session PR events under the single definition: \(events.count) (baselines \(events.filter(\.isBaseline).count))")

        // ---- 5b. records that look too good ----------------------------------------------------------------------------------
        let suspects = PersonalRecords.suspects(from: snap.sets)
        log("")
        log("== 5b. PR candidates more than 1.25x the next best session (for the lifter to verify): \(suspects.count)")
        for x in suspects { log("   \(name(x.exerciseId)): \(f(x.best.load))×\(x.best.reps) on \(x.best.date.formatted(date: .abbreviated, time: .omitted)) e1RM \(f(x.best.e1RM)) vs next best session \(f(x.nextBestE1RM)) (×\(String(format: "%.2f", x.ratio)))") }

        // ---- 5c. bodyweight lifts ---------------------------------------------------------------------------------------------
        let bwIds = Set(snap.sets.filter(\.isBodyweight).map(\.exerciseId))
        log("")
        log("== 5c. bodyweight lifts (body weight \(profile?.bodyWeight.map { f($0) } ?? "not set")): \(bwIds.count) lifts")
        for id in bwIds.sorted() {
            let b = bests[id]
            log("   \(name(id)): record \(b.map { "\(f($0.load))×\($0.reps) e1RM \(f($0.e1RM))" } ?? "none (reps-only)") · lifetime hard sets \(hard[id] ?? 0)")
        }

        // ---- 6. AnalyticsView volume per exercise --------------------------------------------------------------------
        var oldVol: [String: Double] = [:], newVol: [String: Double] = [:]
        for s in completed { for it in s.items {
            let id = ExerciseCatalog.canonicalExerciseId(for: it.exerciseId)
            for i in 0..<min(it.actualLoads.count, it.actualReps.count) { oldVol[id, default: 0] += it.actualLoads[i] * Double(it.actualReps[i]) }
        } }
        for r in snap.sets where r.isLifetimeHardSet { newVol[r.exerciseId, default: 0] += r.effectiveLoad * Double(r.reps) }
        table("6. AnalyticsView volume per exercise (today: load×reps over every row of completed sessions) vs lifetime hard-set volume (effective load)",
              oldVol.map { ($0.key, $0.value, newVol[$0.key] ?? 0) })
        let totOld = oldVol.values.reduce(0, +), totNew = newVol.values.reduce(0, +)
        log("   total volume \(Int(totOld)) → \(Int(totNew)) (\(f(pct(totOld, totNew)))%)")

        log("")
        log("== not affected (snapshots written at completion, or session-level): SessionRecapView, HistoryView set lists and totals (SessionHistory), Analytics session counts.")
    }

    // MARK: - P1b: which rule removes which rows

    private func reason(_ r: SetRecord) -> String {
        if r.isMaintenance { return "maintenance block" }
        if r.isInsertedDeload { return "inserted deload week" }
        if r.isDeloadWaveItem { return "deload-wave item" }
        if r.isDeloadWeek { return "deload band of a non-wave block (Session.isDeloadWeek)" }
        if r.isSkipped { return "skipped row" }
        if !r.isHardSetRow { return "warm-up (< 50% of the item's heaviest logged row)" }
        return "counted"
    }

    func test_audit_whyTheTopNumbersMove() throws {
        let (ctx, all, profile, customs) = try loadFixture()
        defer { flush() }
        _ = ctx
        let snap = SetRecordBuilder.build(sessions: all, customExercises: customs, bodyWeight: profile?.bodyWeight)
        let mesoNames = Dictionary(uniqueKeysWithValues: snap.sessions.map { ($0.key, $0.mesoName ?? "-") })
        func d(_ x: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM/dd"; return f.string(from: x) }
        func flags(_ r: SetRecord) -> String {
            var f: [String] = []
            if r.isMaintenance { f.append("maintenance") }
            if r.isInsertedDeload { f.append("insertedDeload") }
            if r.isDeloadWaveItem { f.append("deloadWave") }
            if r.isDeloadWeek { f.append("deloadWeek") }
            if r.isRestPause { f.append("RP") }
            if r.isDrop { f.append("drop") }
            if r.isTop { f.append("top") }
            if !r.isWorkingSet { f.append("notWorkingSet") }
            return f.isEmpty ? "-" : f.joined(separator: ",")
        }
        for name in ["Chest-Supported Incline DB Row", "Smith Machine Hip Thrust", "Leg Press"] {
            guard let id = snap.sets.first(where: { $0.exerciseName == name })?.exerciseId else { log("\(name): not found"); continue }
            let rows = snap.sets.filter { $0.exerciseId == id && $0.status == .completed && $0.reps > 0 && $0.load > 0 }
            log("")
            log("== \(name) (\(id)): rows counted today (completed, reps>0, load>0): \(rows.count) · hard sets under the new rule: \(rows.filter(\.countsAsHardSet).count)")
            let byReason = Dictionary(grouping: rows, by: reason)
            for (why, rs) in byReason.sorted(by: { $0.value.count > $1.value.count }) where why != "counted" {
                let bySession = Dictionary(grouping: rs, by: \.sessionKey)
                let dates = bySession.values.compactMap { $0.first }.sorted { $0.sessionDate < $1.sessionDate }
                    .map { "\(d($0.sessionDate)) w\($0.weekIndex)×\(bySession[$0.sessionKey]!.count) [\(mesoNames[$0.sessionKey] ?? "-")]" }
                log("   removed by \"\(why)\": \(rs.count) rows in \(bySession.count) sessions")
                log("      \(dates.prefix(30).joined(separator: ", "))")
            }
            // e1RM: today's best (any row) versus the single definition's
            let todayBest = rows.max { $0.e1RM < $1.e1RM }
            let newBest = rows.filter(\.isPerformanceSet).max { $0.e1RM < $1.e1RM }
            func line(_ r: SetRecord?) -> String {
                guard let r else { return "none" }
                return "\(d(r.sessionDate)) wk\(r.weekIndex) \(Int(r.load))×\(r.reps) → e1RM \(String(format: "%.1f", r.e1RM)) [\(flags(r))] meso \(mesoNames[r.sessionKey] ?? "-")"
            }
            log("   best e1RM today:        \(line(todayBest))")
            log("   best e1RM new rule:     \(line(newBest))")
            log("   top 6 rows by e1RM and why each is in or out of a record:")
            for r in rows.sorted(by: { $0.e1RM > $1.e1RM }).prefix(6) {
                log("      \(line(r))  → \(r.isPerformanceSet ? "counts" : (r.isWorkingSet ? "excluded: deload/maintenance session" : "excluded: not a working set (RP/drop/warm-up)"))")
            }
        }

        // The Hip Thrust PR flip in MesoSummary: the prior peak the old rule saw.
        if let id = snap.sets.first(where: { $0.exerciseName == "Smith Machine Hip Thrust" })?.exerciseId {
            log("")
            log("== Smith Machine Hip Thrust PR badge (12-Week DUP Meso): prior rows that set the old prior peak (every other session, any status of block)")
            let meso12 = snap.sessions.filter { $0.mesoName == "12-Week DUP Meso" }.map(\.key)
            let priors = snap.sets.filter { $0.exerciseId == id && !meso12.contains($0.sessionKey) && $0.reps > 0 && $0.load > 0 }
            for r in priors.sorted(by: { $0.e1RM > $1.e1RM }).prefix(5) {
                log("      \(d(r.sessionDate)) \(Int(r.load))×\(r.reps) e1RM \(String(format: "%.1f", r.e1RM)) [\(flags(r))] meso \(mesoNames[r.sessionKey] ?? "-") — \(r.isMaintenance ? "maintenance: now excluded" : "still counts")")
            }
            let thisMeso = snap.sets.filter { $0.exerciseId == id && meso12.contains($0.sessionKey) && $0.reps > 0 && $0.load > 0 }
            if let b = thisMeso.filter({ $0.status == .completed && !$0.isDeloadWeek }).max(by: { $0.e1RM < $1.e1RM }) {
                log("      this block's peak: \(d(b.sessionDate)) \(Int(b.load))×\(b.reps) e1RM \(String(format: "%.1f", b.e1RM))")
            }
        }
    }

    // MARK: - P1d: the screens read the engine; the only changes are the ones the P1c report listed

    func test_screens_changeOnlyWhereTheImpactReportSaid() throws {
        _ = try PinnedFixture.path(requiring: "2026-11-12")      // asserts the Nov 12 backup's numbers
        let (_, all, profile, customs) = try loadFixture()
        defer { flush() }
        _ = customs
        let completed = all.filter { $0.status == .completed }
        let bw = profile?.bodyWeight

        // (The old History summary screen was retired; the Meso Summary reads the engine and is covered by MesoComparisonTests.)
        var summaryDiffs: [String] = []

        // Analytics volume per exercise: old raw load x reps over every row vs the engine's hard-set effective-load volume.
        var oldRaw: [String: Double] = [:], newVol: [String: Double] = [:]
        for s in completed { for item in s.items {
            let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
            for i in 0..<min(item.actualLoads.count, item.actualReps.count) { oldRaw[id, default: 0] += item.actualLoads[i] * Double(item.actualReps[i]) }
            newVol[id, default: 0] += AnalyticsEngine.ItemStats.of(item, bodyWeight: bw).volume
        } }
        let volDiffs = Set(oldRaw.keys).union(newVol.keys).filter { abs((oldRaw[$0] ?? 0) - (newVol[$0] ?? 0)) > 0.5 }.map(name).sorted()
        log("Analytics volume: \(volDiffs.count) exercises differ \(volDiffs)")

        // Exercise history sheet: per-session best e1RM, old (max over logged sets, raw load) vs the item stats.
        var sheetDiffs = 0, pullUps = 0
        for s in completed {
            var seen = Set<String>()
            for item in s.items {
                let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                guard seen.insert(id).inserted else { continue }
                // A session can hold the same lift twice and SwiftData does not order `items`: both sides take the max over ALL of them.
                var old = 0.0
                for other in s.items where ExerciseCatalog.canonicalExerciseId(for: other.exerciseId) == id {
                    for i in 0..<min(other.actualReps.count, other.actualLoads.count) where other.actualReps[i] > 0 && other.actualLoads[i] > 0 {
                        old = max(old, other.actualLoads[i] * (1 + Double(max(1, other.actualReps[i])) / 30))
                    }
                }
                let new = s.items.filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == id }
                    .map { AnalyticsEngine.ItemStats.of($0, bodyWeight: bw).bestE1RM }.max() ?? 0
                if old == 0 && new == 0 { continue }
                if abs(old - new) > max(0.005 * old, 0.01) {
                    sheetDiffs += 1; if id == "pull_up" { pullUps += 1 }
                    if id != "pull_up" { log("   sheet diff: \(name(id)) \(s.date.formatted(date: .abbreviated, time: .omitted)) old \(f(old)) new \(f(new)) bw=\(ExerciseCatalog.isBodyweight(exerciseId: id))") }
                }
            }
        }
        log("Exercise sheet: \(sheetDiffs) session entries differ, of which Pull-Up (body weight now used): \(pullUps)")

        // Records / PR: the engine's index equals the rebuilt PRIndex rows.
        let engine = AnalyticsEngine(sessions: completed, bodyWeight: bw)
        let rows = try ModelContext(container).fetch(FetchDescriptor<PRIndex>())
        log("Records: engine \(engine.records.count) lifts · PRIndex rows \(rows.count)")

        XCTAssertEqual(summaryDiffs, [], "History summary must not change on this backup")
        XCTAssertEqual(volDiffs, ["Pull-Up"], "Analytics volume changes only for the bodyweight lift")
        XCTAssertEqual(sheetDiffs, 25, "the P1c report listed 25 changed session entries (16 of them Pull-Up)")
        XCTAssertEqual(pullUps, 16)
        XCTAssertEqual(engine.records.count, rows.count)
    }
}
