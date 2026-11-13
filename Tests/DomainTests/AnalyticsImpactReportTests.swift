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

        // ---- 1. HistorySummaryView (best e1RM / sets / volume per exercise, all-time) -------------------------------
        let old1 = HistorySummaryBuilder.build(from: completed, bodyWeight: bodyWeight)
        let bests = PersonalRecords.bests(from: snap.sets)
        table("1. HistorySummaryView: best e1RM per exercise (today: any set incl. warm-ups, rest-pause, drop, deload, maintenance)",
              old1.map { s in (ExerciseCatalog.canonicalExerciseId(for: s.id), s.bestE1RM, bests[ExerciseCatalog.canonicalExerciseId(for: s.id)]?.e1RM ?? 0) })
        var hard: [String: Int] = [:]
        for r in snap.sets where r.countsAsHardSet { hard[r.exerciseId, default: 0] += 1 }
        table("1b. HistorySummaryView: total sets per exercise (today: reps>0 & load>0 rows) vs hard sets",
              old1.map { s in (ExerciseCatalog.canonicalExerciseId(for: s.id), Double(s.totalSets), Double(hard[ExerciseCatalog.canonicalExerciseId(for: s.id)] ?? 0)) })

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

        // ---- 5. PRService / PRIndex versus the single PR definition --------------------------------------------------
        let prIndex = try ctx.fetch(FetchDescriptor<PRIndex>())
        var prRows: [(id: String, old: Double, new: Double)] = []
        var differentSet = 0
        var prLines: [String] = []
        for p in prIndex {
            let id = ExerciseCatalog.canonicalExerciseId(for: p.exerciseId)
            guard let b = bests[id] else { continue }
            let oldE1 = E1RMCalculator.e1RM(load: p.bestLoad, reps: p.bestReps)
            prRows.append((id, oldE1, b.e1RM))
            if abs(p.bestLoad - b.load) > 0.01 || p.bestReps != b.reps {
                differentSet += 1
                prLines.append("   \(name(id)): PRIndex \(f(p.bestLoad))×\(p.bestReps) (e1RM \(f(oldE1))) → \(f(b.load))×\(b.reps) (e1RM \(f(b.e1RM)))")
            }
        }
        table("5. PRIndex best set expressed as e1RM versus the single PR definition", prRows)
        log("   PRIndex rows \(prIndex.count) · exercises whose record SET differs \(differentSet)")
        prLines.prefix(40).forEach { log($0) }
        let flagged = completed.flatMap(\.items).filter(\.isPR).count
        let events = PersonalRecords.events(from: snap.sets)
        log("   items flagged isPR in history: \(flagged) · session PR events under the single definition: \(events.count) (baselines \(events.filter(\.isBaseline).count))")

        // ---- 6. AnalyticsView volume per exercise --------------------------------------------------------------------
        var oldVol: [String: Double] = [:], newVol: [String: Double] = [:]
        for s in completed { for it in s.items {
            let id = ExerciseCatalog.canonicalExerciseId(for: it.exerciseId)
            for i in 0..<min(it.actualLoads.count, it.actualReps.count) { oldVol[id, default: 0] += it.actualLoads[i] * Double(it.actualReps[i]) }
        } }
        for r in snap.sets where r.countsAsHardSet { newVol[r.exerciseId, default: 0] += r.load * Double(r.reps) }
        table("6. AnalyticsView volume per exercise (today: load×reps over every row of completed sessions) vs hard-set volume",
              oldVol.map { ($0.key, $0.value, newVol[$0.key] ?? 0) })
        let totOld = oldVol.values.reduce(0, +), totNew = newVol.values.reduce(0, +)
        log("   total volume \(Int(totOld)) → \(Int(totNew)) (\(f(pct(totOld, totNew)))%)")

        log("")
        log("== not affected (snapshots written at completion, or session-level): SessionRecapView, HistoryView set lists and totals (SessionHistory), Analytics session counts.")
    }
}
