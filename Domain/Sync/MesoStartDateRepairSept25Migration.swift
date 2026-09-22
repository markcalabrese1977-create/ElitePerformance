// Domain/Sync/MesoStartDateRepairSept25Migration.swift
import Foundation
import SwiftData

/// One-shot repair: re-dates the active (regular) meso so it starts 2026-09-25,
/// preserving every session, item, and customization.
///
/// Why this is only a date write: `weekIndex`, `programIndex`, `dayLabel`, and
/// every `SessionItem` field are STORED, and `mesoPhase` / `isDeloadWeek` /
/// `weekDayLabel` derive from those stored values rather than from `date`. The
/// scheduler assigns (week, day, wave) purely by ordinal position in its forward
/// walk, so position i of this block already carries exactly what position i of a
/// fresh 2026-09-25 seed would carry. Only the calendar date differs — so writing
/// `session.date` alone reproduces the fresh-seed end state, with the existing
/// records (and their edits) kept.
///
/// Safety: all-or-nothing. Every precondition is checked before anything is
/// written, and any failure aborts the whole repair rather than leaving the block
/// half re-dated. A session with any logged data, or any status other than
/// `.planned`, aborts the entire run.
///
/// Layering: this file stays in the Domain layer and touches only SwiftData and
/// `AppStateBridge`. It deliberately does NOT reference `MesoLifecycle` or
/// `MesoLabel` (App layer) — it returns `true` on a successful write and the App
/// layer performs the `confirmStartNewMeso` step.
enum MesoStartDateRepairSept25Migration {

    // MARK: - Mode

    /// While true, the migration runs every Phase 1 check and prints the full
    /// before/after table, but writes nothing and never sets the completion flag.
    /// Flip to false to arm the real write.
    static let dryRun = false

    /// The day the active meso is being re-dated to start on.
    /// Exposed so the App layer can anchor meso labeling to the same day.
    static let targetStartDate: Date = makeDate(2026, 9, 25)

    private static let completionKey = "mesoStartDateRepairSept25.v1.completed"

    /// Every template a regular meso can have been seeded from. `MesoBlock.name`
    /// is set to `template.name` by `replacePlannedProgram`, and the six names are
    /// unique, so the name round-trips back to the template.
    private static let knownTemplates: [ProgramTemplate] = [
        DUP10WeekTemplate.template,
        PPL6DayTemplate.template,
        Hybrid5DayTemplate.template,
        UpperLower4DayTemplate.template,
        PPL3WeekTemplate.template,
        FullBody2DayTemplate.template
    ]

    // MARK: - Entry point

    /// - Returns: `true` only when the repair actually wrote and committed this
    ///   run. Dry runs, no-ops, and aborts all return `false`.
    @discardableResult
    static func runIfNeeded(in context: ModelContext) -> Bool {
        var report: [String] = []

        func abort(_ reason: String) -> Bool {
            var lines = ["⚠️ Sept-25 meso re-date ABORTED — \(reason)"]
            lines.append(contentsOf: report)
            print(lines.joined(separator: "\n"))
            return false
        }

        // MARK: Phase 1 — resolve and verify (no writes)

        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Sept-25 meso re-date not needed (already applied).")
            return false
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Past-date guard: re-dating a block to a day that has already passed
        // would backdate it, and the seeder itself clamps past starts forward.
        guard today <= targetStartDate else {
            return abort("today (\(format(today))) is already past the target start \(format(targetStartDate)). This repair is no longer meaningful; delete it or retarget it.")
        }

        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            return abort("could not fetch meso blocks.")
        }

        let activeBlocks = blocks.filter { $0.status == .active }
        guard activeBlocks.count == 1, let meso = activeBlocks.first else {
            return abort("expected exactly one active meso block, found \(activeBlocks.count).")
        }

        guard meso.isMaintenance == false else {
            return abort("the active block '\(meso.name)' is a maintenance block. This repair targets a regular meso only.")
        }

        if calendar.startOfDay(for: meso.startDate) == targetStartDate {
            if dryRun {
                print("🧪 DRY RUN — no writes\nℹ️ Sept-25 meso re-date: active block already starts \(format(targetStartDate)). Nothing to do.")
            } else {
                UserDefaults.standard.set(true, forKey: completionKey)
                print("ℹ️ Sept-25 meso re-date: active block already starts \(format(targetStartDate)). Marked complete, nothing written.")
            }
            return false
        }

        let sessions = meso.sessions
        guard !sessions.isEmpty else {
            return abort("the active block '\(meso.name)' has no sessions.")
        }

        // Safety gate — the whole block must be untouched. Any logged data or any
        // non-planned status aborts everything; there is no partial path.
        let unsafe = sessions.filter { !isSafeToModify($0) }
        guard unsafe.isEmpty else {
            let detail = unsafe
                .sorted { $0.date < $1.date }
                .map { "\(format($0.date)) \($0.dayLabel ?? "?") (status=\($0.status.rawValue), hasLoggedData=\(hasLoggedData($0)))" }
                .joined(separator: "; ")
            return abort("\(unsafe.count) of \(sessions.count) session(s) on the active block are not safe to modify: \(detail)")
        }

        guard let template = knownTemplates.first(where: { $0.name == meso.name }) else {
            return abort("could not resolve a template from block name '\(meso.name)'. Known: \(knownTemplates.map(\.name).joined(separator: ", ")).")
        }

        guard let totalWeeks = meso.totalWeeks else {
            return abort("the active block has no totalWeeks.")
        }
        if totalWeeks != template.totalWeeks {
            report.append("NOTE: block totalWeeks (\(totalWeeks)) differs from template '\(template.name)' totalWeeks (\(template.totalWeeks)). Using the block's value.")
        }

        // trainingWeekdays is not stored anywhere — recover it from the block's
        // own session dates. The scheduler only ever places sessions on the chosen
        // weekdays, so the distinct set IS the original pattern.
        let weekdays = Set(sessions.map { calendar.component(.weekday, from: $0.date) }).sorted()
        guard weekdays.count == template.trainingDaysPerWeek else {
            return abort("recovered \(weekdays.count) distinct training weekday(s) \(weekdays) from the block's sessions, but template '\(template.name)' needs exactly \(template.trainingDaysPerWeek). A session was probably moved off-pattern.")
        }

        // Date order must equal program order, because the re-date maps by
        // position in the date-sorted sequence.
        guard sessions.allSatisfy({ $0.programIndex != nil }) else {
            return abort("one or more sessions have no programIndex, so program order cannot be verified.")
        }
        let byDate = sessions.sorted { $0.date < $1.date }
        let byIndex = sessions.sorted { ($0.programIndex ?? 0) < ($1.programIndex ?? 0) }
        guard zip(byDate, byIndex).allSatisfy({ $0 === $1 }) else {
            return abort("date order does not match programIndex order — a session has been moved out of sequence. Re-dating by position would assign wrong dates.")
        }

        let schedule: [ScheduledProgramDay]
        do {
            schedule = try DUPProgramScheduler.buildSchedule(
                startDate: targetStartDate,
                totalWeeks: totalWeeks,
                trainingWeekdays: weekdays,
                template: template,
                calendar: calendar
            )
        } catch {
            return abort("scheduler failed to build a \(format(targetStartDate)) schedule: \(error)")
        }

        guard schedule.count == byDate.count else {
            return abort("schedule produced \(schedule.count) session(s) but the block has \(byDate.count). Sessions have been added or deleted.")
        }

        // MARK: Report — carry-over preview

        report.append("Block: '\(meso.name)' · template '\(template.name)' · \(totalWeeks) weeks · \(template.trainingDaysPerWeek) days/week")
        report.append("Recovered training weekdays: \(weekdays.map(weekdayName).joined(separator: ", "))")
        report.append("MesoBlock.startDate: \(format(meso.startDate)) → \(format(targetStartDate))")
        report.append("")
        report.append(carryOverPreview(blocks: blocks, today: today, calendar: calendar))
        report.append("")

        // MARK: Report — before/after table

        report.append("Session re-date plan (\(byDate.count) sessions):")
        var unchangedCount = 0
        for (i, session) in byDate.enumerated() {
            let old = calendar.startOfDay(for: session.date)
            let new = calendar.startOfDay(for: schedule[i].date)
            let same = (old == new)
            if same { unchangedCount += 1 }

            let idx = String(format: "%02d", i + 1)
            let wk = String(format: "%2d", session.weekIndex)
            let pi = String(format: "%2d", session.programIndex ?? -1)
            let label = (session.dayLabel ?? "?").padding(toLength: 16, withPad: " ", startingAt: 0)

            report.append("  #\(idx)  wk=\(wk) pi=\(pi)  \(label) \(format(old)) → \(format(new))\(same ? "   (unchanged)" : "")")
        }
        report.append("Summary: \(byDate.count - unchangedCount) session(s) move, \(unchangedCount) unchanged.")

        // MARK: Dry run — stop here

        if dryRun {
            var lines = ["🧪 DRY RUN — no writes", "Sept-25 meso re-date: all preconditions passed. Nothing was written and the completion flag was NOT set."]
            lines.append(contentsOf: report)
            print(lines.joined(separator: "\n"))
            return false
        }

        // MARK: Phase 2 — write, single atomic save

        for (i, session) in byDate.enumerated() {
            session.date = schedule[i].date
        }
        meso.startDate = targetStartDate

        do {
            try context.save()
        } catch {
            var lines = ["⚠️ Sept-25 meso re-date save FAILED: \(error). Intended writes below were NOT persisted; the completion flag was not set, so this retries next launch."]
            lines.append(contentsOf: report)
            print(lines.joined(separator: "\n"))
            return false
        }

        // MARK: Phase 3 — lifecycle state (AppState side only)

        // AppState is the authority: ContentView's launch-time
        // restoreUserDefaultsFromAppStateIfAvailable copies AppState over
        // UserDefaults, so writing only UserDefaults here would be erased on the
        // next launch. Both setters write AppState and then sync to UserDefaults.
        // The App layer completes this with MesoLifecycle.confirmStartNewMeso.
        AppStateBridge.setActiveMesoStartDate(targetStartDate, in: context)
        AppStateBridge.setMesoAnchor(date: targetStartDate, dayNumber: 1, in: context)

        UserDefaults.standard.set(true, forKey: completionKey)

        var lines = ["✅ Sept-25 meso re-date complete."]
        lines.append(contentsOf: report)
        print(lines.joined(separator: "\n"))
        return true
    }

    // MARK: - Carry-over preview

    /// Non-completed sessions on any ARCHIVED block dated in
    /// `[today, targetStartDate)`. Moving the active block's start forward widens
    /// MainTabView's carry-over window (archived + non-completed + date >= today +
    /// date < activeMesoStartDate) from empty to this span, so these will start
    /// appearing in Today/Upcoming after the repair.
    private static func carryOverPreview(blocks: [MesoBlock], today: Date, calendar: Calendar) -> String {
        let carryOver = blocks
            .filter { $0.status == .archived }
            .flatMap(\.sessions)
            .filter { session in
                let day = calendar.startOfDay(for: session.date)
                return session.status != .completed && day >= today && day < targetStartDate
            }
            .sorted { $0.date < $1.date }

        guard !carryOver.isEmpty else {
            return "Carry-over window [\(format(today)), \(format(targetStartDate))): no archived-block sessions would surface."
        }

        var lines = ["Carry-over window [\(format(today)), \(format(targetStartDate))): \(carryOver.count) archived-block session(s) will surface in Today/Upcoming after this repair:"]
        for session in carryOver {
            let block = session.meso?.name ?? "?"
            lines.append("  \(format(session.date))  \(session.dayLabel ?? "?")  (block '\(block)', status=\(session.status.rawValue))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func isSafeToModify(_ session: Session) -> Bool {
        guard session.status == .planned else { return false }
        return !hasLoggedData(session)
    }

    private static func hasLoggedData(_ session: Session) -> Bool {
        session.items.contains { item in
            item.isCompleted ||
            item.actualLoads.contains { $0 > 0 } ||
            item.actualReps.contains { $0 > 0 }
        }
    }

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = DateComponents(year: year, month: month, day: day)
        return calendar.date(from: components) ?? Date()
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd EEE"
        return formatter.string(from: date)
    }

    private static func weekdayName(_ calendarWeekday: Int) -> String {
        let names = ["?", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        guard calendarWeekday >= 1, calendarWeekday <= 7 else { return "?" }
        return names[calendarWeekday]
    }
}
