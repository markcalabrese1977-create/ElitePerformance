import XCTest
import SwiftData
@testable import ElitePerformance

/// Report only (plus the injection checks): replays the FatigueMonitor chronologically over ALL completed history of the
/// newest backup (EP_BACKUP_FIXTURE): level changes, every deloadSuggested / watch episode with the lifts and signals
/// behind it, raw signals, and a sensitivity table. Set EP_FATIGUE_REPORT to also write it to a file. Skipped without a
/// fixture. Signals are computed once per policy over the whole history (each is causal: it reads only earlier data) and
/// the level is assessed at each completed-session date from the signals dated up to then.
final class FatigueBacktestTests: XCTestCase {

    private var lines: [String] = []
    private func log(_ s: String = "") { lines.append(s); print("FATIGUE| \(s)") }
    private var reportKey = "EP_FATIGUE_REPORT"
    private func flush() {
        guard let path = ProcessInfo.processInfo.environment[reportKey], !path.isEmpty else { return }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    private func fmt(_ pattern: String, _ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern; return f.string(from: d)
    }
    private func dayText(_ d: Date) -> String { fmt("yyyy-MM-dd EEE", d) }
    private func md(_ d: Date) -> String { fmt("MM/dd", d) }

    func test_backtest_planRelativePolicyOverAllCompletedHistory() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        defer { flush() }
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let all = try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date }
        let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
        let customs = try ctx.fetch(FetchDescriptor<CustomExercise>())
        // What the app's launch does: a planned session gets plannedDate = date (in memory; nothing is saved). The
        // backfill never marks a date exact, so missed sessions stay off for this history.
        for s in all where s.status == .planned && s.plannedDate == nil { s.plannedDate = s.date }
        let changedBefore = ctx.hasChanges
        let unit = profile?.loadUnit ?? .lb
        let incrementLb = unit.toStoredLb(profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: unit))
        let maxLoad: (String) -> Double? = { UserProfile.effectiveMaxLoad(for: $0, profile: profile, customExercises: customs) }
        let snapshot = SetRecordBuilder.build(sessions: all, customExercises: customs, bodyWeight: profile?.bodyWeight)
        let completed = snapshot.sessions.filter { $0.status == .completed }.sorted { $0.date < $1.date }
        let dates = Array(Set(completed.map(\.date))).sorted()
        let end = (dates.last ?? Date()).addingTimeInterval(1)
        let p = FatiguePolicy.default
        let calendar = Calendar(identifier: .gregorian)

        log("fixture: \(URL(fileURLWithPath: path).lastPathComponent)")
        log("completed sessions \(completed.count) · span \(dates.first.map(dayText) ?? "-") → \(dates.last.map(dayText) ?? "-") · load step \(incrementLb) lb")
        log("sessions with an EXACT plannedDate: \(snapshot.sessions.filter(\.plannedDateIsExact).count) of \(snapshot.sessions.count) — missed sessions are off for this history")
        log("policy: sets within \(Int(p.loadMatchIncrements)) step of plan; deviation = logged − planned reps/set; norm = median over \(p.baselineDays) days (≥ \(p.baselineMinExposures) exposures); "
            + "shortfall < norm − \(p.shortfallReps); breadth ≥ \(p.breadthMinLifts) lifts and \(Int(p.breadthShare * 100))% of the lifts trained in a calendar week; "
            + "deloadSuggested = breadth in \(p.breadthWeeksForDeload) consecutive weeks OR breadth + (self report or missed); watch = any one of breadth/missed/feedback/self report")

        func replay(_ policy: FatiguePolicy) -> (signals: [FatigueSignal], run: [(date: Date, a: FatigueAssessment)]) {
            let sigs = FatigueMonitor.signals(in: snapshot, policy: policy, loadIncrementLb: incrementLb, asOf: end, unit: unit, maxLoad: maxLoad)
            let run = dates.map { d in
                (d, FatigueMonitor.assess(signals: sigs.filter { $0.date <= d.addingTimeInterval(1) }, snapshot: snapshot, policy: policy, asOf: d.addingTimeInterval(1)))
            }
            return (sigs, run)
        }
        var armed = p; armed.performanceDrivesDeload = true
        let armedRun = replay(armed).run
        let (signals, run) = replay(p)
        let deloadDates = run.filter { $0.a.suggestion == .deloadSuggested }
        let late = deloadDates.filter { d in
            let c = calendar.dateComponents([.year, .month, .day], from: d.date)
            return c.year == 2026 && ((c.month == 10 && (c.day ?? 0) >= 30) || (c.month == 11 && (c.day ?? 0) <= 11))
        }
        log("")
        log("== RESULT")
        log("   SHIPPED (performance watch-only): deloadSuggested on \(deloadDates.count) of \(run.count) session dates · dates Oct 30 – Nov 11 2026: \(late.count) · watch on \(run.filter { $0.a.suggestion == .watch }.count) dates")
        let armedDeload = armedRun.filter { $0.a.suggestion == .deloadSuggested }
        log("   ARMED (performance may drive deload): deloadSuggested on \(armedDeload.count) of \(armedRun.count) dates (\(String(format: "%.1f", Double(armedDeload.count) / Double(max(1, armedRun.count)) * 100))%) · Oct 30 – Nov 11: \(armedDeload.filter { d in let c = calendar.dateComponents([.month, .day], from: d.date); return (c.month == 10 && (c.day ?? 0) >= 30) || (c.month == 11 && (c.day ?? 0) <= 11) }.count)")

        func episodes(_ level: FatigueSuggestion) -> [[(date: Date, a: FatigueAssessment)]] {
            var out: [[(date: Date, a: FatigueAssessment)]] = []; var cur: [(date: Date, a: FatigueAssessment)] = []
            for r in run { if r.a.suggestion == level { cur.append(r) } else if !cur.isEmpty { out.append(cur); cur = [] } }
            if !cur.isEmpty { out.append(cur) }
            return out
        }
        log("")
        log("== deloadSuggested episodes (\(episodes(.deloadSuggested).count))")
        for (n, ep) in episodes(.deloadSuggested).enumerated() {
            let unique = ep.flatMap(\.a.signals).reduce(into: [String: FatigueSignal]()) { $0["\($1.date.timeIntervalSince1970)|\($1.type.rawValue)|\($1.exerciseId ?? "")"] = $1 }
                .values.sorted { ($0.date, $0.type.rawValue) < ($1.date, $1.type.rawValue) }
            log("   #\(n + 1)  \(dayText(ep.first!.date)) → \(dayText(ep.last!.date))  (\(ep.count) session dates)")
            for s in unique where s.type != .shortfall && s.type != .repDrop { log("        \(md(s.date)) \(s.type.rawValue): \(s.evidence)") }
        }
        log("")
        log("== watch episodes (\(episodes(.watch).count))")
        for ep in episodes(.watch) {
            let types = Set(ep.flatMap { $0.a.signals.map(\.type) }.filter { p.levelTypes.contains($0) }).map(\.rawValue).sorted()
            log("   \(dayText(ep.first!.date)) → \(dayText(ep.last!.date))  (\(ep.count) dates) types \(types)")
        }
        log("")
        log("== every raw signal: " + FatigueSignalType.allCases.map { t in "\(t.rawValue) \(signals.filter { $0.type == t }.count)" }.joined(separator: " · "))
        for s in signals where s.type == .breadth || s.type == .missedSessions || s.type == .feedbackShare || s.type == .selfReport {
            log("   \(dayText(s.date))  \(s.type.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(s.evidence)")
        }

        log("")
        log("== sensitivity (session dates at watch / deloadSuggested)")
        func variant(_ label: String, _ edit: (inout FatiguePolicy) -> Void) {
            var v = FatiguePolicy.default; edit(&v)
            let r = replay(v)
            let d = r.run.filter { $0.a.suggestion == .deloadSuggested }.count
            log("   \(label.padding(toLength: 46, withPad: " ", startingAt: 0)) watch \(r.run.filter { $0.a.suggestion == .watch }.count) · deload \(d) (\(String(format: "%.1f", r.run.isEmpty ? 0 : Double(d) / Double(r.run.count) * 100))%) · shortfalls \(r.signals.filter { $0.type == .shortfall }.count) · breadth \(r.signals.filter { $0.type == .breadth }.count)")
        }
        variant("default") { _ in }
        variant("shortfall 0.5 rep under norm") { $0.shortfallReps = 0.5 }
        variant("shortfall 1.5 reps under norm") { $0.shortfallReps = 1.5 }
        variant("breadth min 2 lifts") { $0.breadthMinLifts = 2 }
        variant("breadth min 4 lifts") { $0.breadthMinLifts = 4 }
        variant("breadth share 25%") { $0.breadthShare = 0.25 }
        variant("breadth share 40%") { $0.breadthShare = 0.40 }
        variant("norm over 28 days") { $0.baselineDays = 28 }
        variant("norm over 84 days") { $0.baselineDays = 84 }
        variant("load match 0 steps (exact plan load)") { $0.loadMatchIncrements = 0 }
        variant("load match 2 steps") { $0.loadMatchIncrements = 2 }
        variant("reached-top guard off") { $0.exemptReachedTop = false }
        variant("deload after 1 breadth week") { $0.breadthWeeksForDeload = 1 }
        variant("deload after 3 breadth weeks") { $0.breadthWeeksForDeload = 3 }
        variant("self report counts 21 days") { $0.selfReportDays = 21 }
        variant("self report not a level") { $0.levelTypes.remove(.selfReport) }
        variant("no deload reset") { $0.resetAfterDeload = false }
        variant("performance MAY drive deload (armed)") { $0.performanceDrivesDeload = true }

        XCTAssertFalse(run.isEmpty)
        XCTAssertEqual(ctx.hasChanges, changedBefore, "the replay wrote nothing")
    }

    // MARK: - Injection on the real backup (in memory only)

    private func modified(_ r: SetRecord, reps: Int? = nil, load: Double? = nil, plannedLoad: Double?? = nil) -> SetRecord {
        SetRecord(
            sessionKey: r.sessionKey, sessionDate: r.sessionDate, status: r.status, weekIndex: r.weekIndex, dayLabel: r.dayLabel, mesoKey: r.mesoKey,
            exerciseId: r.exerciseId, exerciseName: r.exerciseName, muscle: r.muscle, isBodyweight: r.isBodyweight,
            waveLetter: r.waveLetter, isDeloadWaveItem: r.isDeloadWaveItem, isInsertedDeload: r.isInsertedDeload, isDeloadWeek: r.isDeloadWeek,
            isMaintenance: r.isMaintenance, rowIndex: r.rowIndex, isTop: r.isTop, plannedReps: r.plannedReps,
            plannedLoad: plannedLoad ?? r.plannedLoad, repMin: r.repMin, repMax: r.repMax, targetRIRMin: r.targetRIRMin,
            targetRIRMax: r.targetRIRMax, targetRIR: r.targetRIR, reps: reps ?? r.reps, load: load ?? r.load, rir: r.rir, isSkipped: r.isSkipped,
            isRestPause: r.isRestPause, isDrop: r.isDrop, feedback: r.feedback, pump: r.pump, loadOverride: r.loadOverride,
            planEdited: r.planEdited, readiness: r.readiness, readinessStars: r.readinessStars, hkDuration: r.hkDuration,
            isWorkingSet: r.isWorkingSet, isHardSetRow: r.isHardSetRow)
    }

    /// Replays the monitor over `snap` at every completed-session date in [from, to] and returns the assessments.
    private func replay(_ snap: AnalyticsSnapshot, from: Date, to: Date, incrementLb: Double, unit: LoadUnit, policy: FatiguePolicy = .default,
                        maxLoad: @escaping (String) -> Double?) -> [(date: Date, a: FatigueAssessment)] {
        let dates = Array(Set(snap.sessions.filter { $0.status == .completed && $0.date >= from && $0.date <= to }.map(\.date))).sorted()
        let sigs = FatigueMonitor.signals(in: snap, policy: policy, loadIncrementLb: incrementLb, asOf: to.addingTimeInterval(1), unit: unit, maxLoad: maxLoad)
        return dates.map { d in (d, FatigueMonitor.assess(signals: sigs.filter { $0.date <= d.addingTimeInterval(1) }, snapshot: snap, policy: policy, asOf: d.addingTimeInterval(1))) }
    }

    func test_injection_onTheRealBackup() throws {
        guard let path = ProcessInfo.processInfo.environment["EP_BACKUP_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_EP_BACKUP_FIXTURE to a backup JSON to run")
        }
        reportKey = "EP_FATIGUE_INJECTION_REPORT"
        defer { flush() }
        let container = try BackupTestSupport.makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: URL(fileURLWithPath: path), modelContainer: container)
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let all = try ctx.fetch(FetchDescriptor<Session>()).sorted { $0.date < $1.date }
        let profile = try ctx.fetch(FetchDescriptor<UserProfile>()).first
        let customs = try ctx.fetch(FetchDescriptor<CustomExercise>())
        let unit = profile?.loadUnit ?? .lb
        let incrementLb = unit.toStoredLb(profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: unit))
        let maxLoad: (String) -> Double? = { UserProfile.effectiveMaxLoad(for: $0, profile: profile, customExercises: customs) }
        let base = SetRecordBuilder.build(sessions: all, customExercises: customs, bodyWeight: profile?.bodyWeight)
        let cal = Calendar(identifier: .gregorian)
        func date(_ m: Int, _ d: Int) -> Date { DateComponents(calendar: cal, year: 2026, month: m, day: d).date! }
        func dayText(_ d: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd EEE"; return f.string(from: d) }
        let end = date(11, 12)

        log("fixture: \(URL(fileURLWithPath: path).lastPathComponent) · injection works on in-memory records only; nothing is written")

        // (c) the unmodified backup
        var armed = FatiguePolicy.default; armed.performanceDrivesDeload = true
        let longAgo = date(12, 1).addingTimeInterval(-86_400 * 365)
        let clean = replay(base, from: longAgo, to: end, incrementLb: incrementLb, unit: unit, maxLoad: maxLoad)
        let cleanDeload = clean.filter { $0.a.suggestion == .deloadSuggested }
        let cleanArmed = replay(base, from: longAgo, to: end, incrementLb: incrementLb, unit: unit, policy: armed, maxLoad: maxLoad)
        log("")
        log("== (c) the unmodified backup: SHIPPED deloadSuggested on \(cleanDeload.count) of \(clean.count) session dates (must be 0) · watch on \(clean.filter { $0.a.suggestion == .watch }.count)"
            + " · ARMED (performance may drive deload): deloadSuggested on \(cleanArmed.filter { $0.a.suggestion == .deloadSuggested }.count)")

        // (a) For each onset and strength: 40% of the tracked lifts of the following three weeks lose `minus` reps on every
        // set for 14 days at unchanged loads, and the engine's reductions are replayed as lower PLANNED loads (-5% per
        // later exposure; no edit, no reason, no deload).
        func injectedSnapshot(onset: Date, minus: Int, engineReduce: Bool = true) -> (AnalyticsSnapshot, Set<String>, Int) {
            let injectionEnd = onset.addingTimeInterval(14 * 86_400)
            let windowEnd = onset.addingTimeInterval(21 * 86_400)
            let tracked = Array(Set(base.sets.filter { $0.isPerformanceSet && !$0.isBodyweight && $0.load >= 2 * incrementLb && $0.sessionDate >= onset && $0.sessionDate < windowEnd }.map(\.exerciseId))).sorted()
            let injected = Set(tracked.enumerated().filter { $0.offset % 5 == 0 || $0.offset % 5 == 2 }.map(\.element))
            var first: [String: Date] = [:]
            for r in base.sets where injected.contains(r.exerciseId) && r.sessionDate >= onset && r.sessionDate < injectionEnd && r.status == .completed {
                first[r.exerciseId] = min(first[r.exerciseId] ?? .distantFuture, r.sessionDate)
            }
            let sets = base.sets.map { r -> SetRecord in
                guard injected.contains(r.exerciseId), r.status == .completed, r.sessionDate >= onset else { return r }
                var reps = r.reps, planned = r.plannedLoad, load = r.load
                if r.sessionDate < injectionEnd, r.reps > 0 { reps = max(1, r.reps - minus) }
                if engineReduce, let f = first[r.exerciseId], r.sessionDate > f, let p = r.plannedLoad { planned = p * 0.95; load = r.load * 0.95 }   // engine reduce: the lifter follows the lower plan
                return modified(r, reps: reps, load: load, plannedLoad: .some(planned))
            }
            return (AnalyticsSnapshot(sessions: base.sessions, sets: sets), injected, tracked.count)
        }
        var lags: [(onset: Date, minus: Int, lag: Int?)] = []
        log("")
        log("== (a) robustness: onset x strength → days from onset to the first deloadSuggested (nil = not reached by \(dayText(end)))")
        for onset in [date(10, 16), date(10, 23), date(10, 30)] {
            for minus in [1, 2] {
                let (snap, injected, trackedCount) = injectedSnapshot(onset: onset, minus: minus)
                let run = replay(snap, from: onset.addingTimeInterval(-1), to: end, incrementLb: incrementLb, unit: unit, policy: armed, maxLoad: maxLoad)
                let shipped = replay(snap, from: onset.addingTimeInterval(-1), to: end, incrementLb: incrementLb, unit: unit, maxLoad: maxLoad)
                let trigger = run.first { $0.a.suggestion == .deloadSuggested }
                let lag = trigger.map { Calendar.current.dateComponents([.day], from: onset, to: $0.date).day ?? -1 }
                lags.append((onset, minus, lag))
                let peak = run.map { $0.a.suggestion }.max { rank($0) < rank($1) } ?? .none
                log("   onset \(dayText(onset)) · −\(minus) rep/set · \(injected.count) of \(trackedCount) lifts · ARMED lag \(lag.map(String.init) ?? "nil") · armed peak \(peak.rawValue) · SHIPPED peak \(shipped.map { $0.a.suggestion }.max { rank($0) < rank($1) }?.rawValue ?? "none")")
                do {   // why: judged / regressing lifts in the 21 days to onset + 14 (latest judgement per lift), and breadth signals
                    let asOf = onset.addingTimeInterval(14 * 86_400)
                    let js = FatigueMonitor.judgements(in: snap, policy: .default, loadIncrementLb: incrementLb, asOf: asOf, unit: unit, maxLoad: maxLoad)
                        .filter { $0.date > asOf.addingTimeInterval(-21 * 86_400) }
                    var latest: [String: FatigueMonitor.Judgement] = [:]
                    for j in js { latest[j.exerciseId] = j }
                    let injectedJudged = latest.values.filter { injected.contains($0.exerciseId) }
                    log("      at onset+14d: \(latest.count) lifts judged in 21d, \(latest.values.filter(\.regressing).count) latest-regressing (\(injectedJudged.count) injected lifts judged, \(injectedJudged.filter(\.regressing).count) regressing); "
                        + "breadth signals so far \(FatigueMonitor.signals(in: snap, loadIncrementLb: incrementLb, asOf: asOf, unit: unit, maxLoad: maxLoad).filter { $0.type == .breadth }.count)")
                }
                do {   // the same injection WITHOUT the replayed engine reduces: is the planned-load cut what hides it?
                    let (noCut, _, _) = injectedSnapshot(onset: onset, minus: minus, engineReduce: false)
                    let r2 = replay(noCut, from: onset.addingTimeInterval(-1), to: end, incrementLb: incrementLb, unit: unit, policy: armed, maxLoad: maxLoad)
                    let t2 = r2.first { $0.a.suggestion == .deloadSuggested }
                    log("      without engine reduces: lag \(t2.map { String(Calendar.current.dateComponents([.day], from: onset, to: $0.date).day ?? -1) } ?? "nil") · peak \(r2.map { $0.a.suggestion }.max { rank($0) < rank($1) }?.rawValue ?? "none")")
                }
                if let t = trigger {
                    log("      first deloadSuggested \(dayText(t.date)):")
                    for sig in t.a.signals where sig.type != .shortfall && sig.type != .repDrop { log("         \(sig.type.rawValue) \(dayText(sig.date)): \(sig.evidence)") }
                    let regs = t.a.signals.filter { $0.type == .shortfall }
                    log("         shortfall lifts in the window (\(regs.count)): " + regs.map { $0.exerciseName ?? "?" }.sorted().joined(separator: ", "))
                    if let ex = regs.first { log("         e.g. \(ex.evidence)") }
                }
            }
        }
        let within = lags.filter { ($0.lag ?? 99) <= 14 }.count
        log("   → ARMED lag ≤ 14 days in \(within) of \(lags.count) runs (required for arming: ≥ 4 with a clean backup at 0). SHIPPED never suggests a deload from performance.")

        // (b) one session with many lifts down: reps -3 on every row of the busiest regular session of Sep 1 – Oct 12.
        let candidates = Dictionary(grouping: base.sets.filter { $0.isPerformanceSet && $0.sessionDate >= date(9, 1) && $0.sessionDate < date(10, 13) }, by: \.sessionKey)
        // A session whose next three weeks hold no real self report: otherwise breadth + that report would (rightly) suggest a deload.
        let selfDates = base.sets.filter { $0.loadOverride.map { [.generalFatigue, .jointTenderness].contains($0) } ?? false || [.fatigued, .compromised].contains($0.readiness) }.map(\.sessionDate)
        let busiest = candidates.filter { c in
            let d = c.value[0].sessionDate
            return !selfDates.contains { $0 >= d && $0 < d.addingTimeInterval(21 * 86_400) }
        }.max { Set($0.value.map(\.exerciseId)).count < Set($1.value.map(\.exerciseId)).count }
        if let (key, rows) = busiest {
            let when = rows[0].sessionDate
            let setsB = base.sets.map { $0.sessionKey == key && $0.reps > 0 ? modified($0, reps: max(1, $0.reps - 3)) : $0 }
            let b = replay(AnalyticsSnapshot(sessions: base.sessions, sets: setsB), from: when.addingTimeInterval(-1), to: when.addingTimeInterval(86_400 * 35), incrementLb: incrementLb, unit: unit, maxLoad: maxLoad)
            let bArmed = replay(AnalyticsSnapshot(sessions: base.sessions, sets: setsB), from: when.addingTimeInterval(-1), to: when.addingTimeInterval(86_400 * 35), incrementLb: incrementLb, unit: unit, policy: armed, maxLoad: maxLoad)
            let peak = b.map(\.a.suggestion).max { rank($0) < rank($1) } ?? .none
            log("   (armed peak for the same session: \(bArmed.map { $0.a.suggestion }.max { rank($0) < rank($1) }?.rawValue ?? "none"))")
            log("")
            log("== (b) one session: \(dayText(when)) \(rows[0].dayLabel ?? "") with \(Set(rows.map(\.exerciseId)).count) lifts, reps −3 on every set → peak level over the next 35 days: \(peak.rawValue) (limit: watch)")
            for x in b where x.a.suggestion != .none { log("   \(dayText(x.date))  \(x.a.suggestion.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) types \(x.a.distinctTypes.map(\.rawValue).sorted())") }
            XCTAssertLessThanOrEqual(rank(peak), rank(.watch), "one bad session alone must never suggest a deload")
        } else { XCTFail("no session found for injection (b)") }

        XCTAssertEqual(cleanDeload.count, 0, "(c) the unmodified backup must never suggest a deload")
        // (a) is reported, not asserted: the shipped default is watch-only for performance (see the FatigueMonitor header).
        XCTAssertFalse(ctx.hasChanges)
    }

    private func rank(_ s: FatigueSuggestion) -> Int { s == .none ? 0 : (s == .watch ? 1 : 2) }
}
