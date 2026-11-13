import XCTest
import SwiftData
@testable import ElitePerformance

/// Report only: replays the FatigueMonitor chronologically over ALL completed history of the newest backup
/// (EP_BACKUP_FIXTURE) and prints every date the default policy reaches watch / deloadSuggested with the signals and
/// evidence behind it, then every raw signal occurrence. Set EP_FATIGUE_REPORT to also write it to a file.
/// Skipped without a fixture. Asserts only that the replay ran and never wrote.
final class FatigueBacktestTests: XCTestCase {

    private var lines: [String] = []
    private func log(_ s: String = "") { lines.append(s); print("FATIGUE| \(s)") }
    private func flush() {
        guard let path = ProcessInfo.processInfo.environment["EP_FATIGUE_REPORT"], !path.isEmpty else { return }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func dayText(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd EEE"; return f.string(from: d)
    }
    private func md(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM/dd"; return f.string(from: d)
    }

    func test_backtest_defaultPolicyOverAllCompletedHistory() throws {
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

        // What the app's launch does: a planned session gets plannedDate = date (in memory here, nothing is saved).
        for s in all where s.status == .planned && s.plannedDate == nil { s.plannedDate = s.date }
        let changedBefore = ctx.hasChanges

        let unit = profile?.loadUnit ?? .lb
        let incrementLb = unit.toStoredLb(profile?.minLoadIncrement ?? UnitAwareRounding.defaultIncrement(unit: unit))
        let snapshot = SetRecordBuilder.build(sessions: all, customExercises: customs, bodyWeight: profile?.bodyWeight)
        let completed = snapshot.sessions.filter { $0.status == .completed }.sorted { $0.date < $1.date }
        let dates = Array(Set(completed.map(\.date))).sorted()
        let regular = completed.filter(\.isRegularTraining).count

        log("fixture: \(URL(fileURLWithPath: path).lastPathComponent)")
        log("completed sessions \(completed.count) (regular \(regular), deload/inserted/maintenance \(completed.count - regular)) · "
            + "span \(dates.first.map(dayText) ?? "-") → \(dates.last.map(dayText) ?? "-") · load step \(incrementLb) lb")
        log("sessions with a plannedDate: \(snapshot.sessions.filter { $0.plannedDate != nil }.count) of \(snapshot.sessions.count) "
            + "(only planned sessions are backfilled, so the missed-session signal has little to read on old history)")
        let p = FatiguePolicy.default
        log("policy: \(p.deloadTypeCount)+ distinct signal types in a rolling \(p.windowDays) days = deloadSuggested, \(p.watchTypeCount) = watch; "
            + "rep drop ≥ \(p.repDropMeanReps) rep/set at the same load (±\(p.loadToleranceIncrements) step); e1RM ≥ \(Int(p.e1rmDeclineFraction * 100))% down on ≥ \(p.e1rmDeclineLiftCount) lifts "
            + "vs the mean of the last \(p.baselineExposures) same-letter exposures; \(p.missedSessionCount) missed in window (grace \(p.missedGraceDays) d); "
            + "feedback ≥ \(Int(p.feedbackShare * 100))% of ≥ \(p.feedbackMinSets) sets; readiness fatigued/compromised or fatigue/joint load override")

        func replay(_ policy: FatiguePolicy) -> [(date: Date, a: FatigueAssessment)] {
            dates.map { d in
                let end = d.addingTimeInterval(1)   // the whole session is known at its own date
                return (d, FatigueMonitor.evaluate(snapshot: snapshot, policy: policy, loadIncrementLb: incrementLb, asOf: end, unit: unit))
            }
        }

        // ---- the table -------------------------------------------------------------------------------------------------
        let run = replay(p)
        let hits = run.filter { $0.a.suggestion != .none }
        log("")
        log("== dates the default policy reaches watch / deloadSuggested (evaluated at each completed session, causally)")
        log("   \(run.count) session dates replayed · watch \(run.filter { $0.a.suggestion == .watch }.count) · deloadSuggested \(run.filter { $0.a.suggestion == .deloadSuggested }.count)")
        for h in hits {
            let refs = h.a.signals.map { s in "\(s.type.rawValue)@\(md(s.date))\(s.exerciseName.map { " \($0)" } ?? "")" }
            log("   \(dayText(h.date))  \(h.a.suggestion.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) types \(h.a.distinctTypes.map(\.rawValue).sorted())")
            log("        \(refs.joined(separator: "; "))")
        }
        // First date of each run of consecutive non-none dates, and the level it first reached.
        var transitions: [String] = []
        var prev: FatigueSuggestion = .none
        for r in run where r.a.suggestion != prev {
            transitions.append("\(dayText(r.date)): \(prev.rawValue) → \(r.a.suggestion.rawValue)")
            prev = r.a.suggestion
        }
        log("")
        log("== level changes")
        transitions.forEach { log("   \($0)") }

        // ---- raw occurrences -------------------------------------------------------------------------------------------
        let last = (dates.last ?? Date()).addingTimeInterval(1)
        let raw = FatigueMonitor.signals(in: snapshot, policy: p, loadIncrementLb: incrementLb, asOf: last, unit: unit)
        log("")
        log("== every raw signal occurrence (all of history, no window): " + FatigueSignalType.allCases
            .map { t in "\(t.rawValue) \(raw.filter { $0.type == t }.count)" }.joined(separator: " · "))
        for s in raw { log("   \(dayText(s.date))  \(s.type.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(s.evidence)") }

        // ---- sensitivity -----------------------------------------------------------------------------------------------
        log("")
        log("== sensitivity (number of session dates at watch / deloadSuggested)")
        func variant(_ label: String, _ edit: (inout FatiguePolicy) -> Void) {
            var v = FatiguePolicy.default; edit(&v)
            let r = replay(v)
            let sigs = FatigueMonitor.signals(in: snapshot, policy: v, loadIncrementLb: incrementLb, asOf: last, unit: unit)
            log("   \(label.padding(toLength: 46, withPad: " ", startingAt: 0)) watch \(r.filter { $0.a.suggestion == .watch }.count) · deload \(r.filter { $0.a.suggestion == .deloadSuggested }.count) · raw signals \(sigs.count)")
        }
        variant("default") { _ in }
        variant("e1RM: 2 lifts, 3%") { $0.e1rmDeclineLiftCount = 2; $0.e1rmDeclineFraction = 0.03 }
        variant("e1RM: 3 lifts, 3%") { $0.e1rmDeclineFraction = 0.03 }
        variant("e1RM: 2 lifts, 5%") { $0.e1rmDeclineLiftCount = 2 }
        variant("rep drop ≥ 1.5 rep/set") { $0.repDropMeanReps = 1.5 }
        variant("rep drop ≥ 0.5 rep/set") { $0.repDropMeanReps = 0.5 }
        variant("feedback share ≥ 10%") { $0.feedbackShare = 0.10 }
        variant("rep drop off") { $0.enabledTypes.remove(.repDrop) }
        variant("no deload reset") { $0.resetAfterDeload = false }
        variant("deload needs 3 types") { $0.deloadTypeCount = 3 }

        XCTAssertFalse(run.isEmpty, "the fixture has completed sessions")
        XCTAssertEqual(ctx.hasChanges, changedBefore, "the replay wrote nothing")
    }
}
