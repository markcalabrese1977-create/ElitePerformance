import Foundation
import SwiftData

enum DUPProgramReplaceService {

    /// What a replacement would delete, and whether it may run at all. Computed without writing anything.
    struct Plan {
        let startDay: Date
        /// Planned sessions on or after the start day, with nothing logged: the ones that are deleted.
        let sessionsToDelete: [Session]
        /// Sessions that block the replacement: one in progress, or a planned one that already has logged sets.
        let blockers: [Session]

        var isAllowed: Bool { blockers.isEmpty }
        var dateRange: (first: Date, last: Date)? {
            let dates = sessionsToDelete.map(\.date)
            guard let a = dates.min(), let b = dates.max() else { return nil }
            return (a, b)
        }

        /// What the lifter is told before anything is deleted.
        var message: String {
            let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
            if !blockers.isEmpty {
                let n = blockers.count
                return "\(n) session\(n == 1 ? "" : "s") on or after \(startDay.formatted(f)) \(n == 1 ? "is" : "are") in progress or already \(n == 1 ? "has" : "have") logged sets. Finish \(n == 1 ? "it" : "them") first; nothing was changed. Logged work is never deleted."
            }
            guard let range = dateRange else { return "No planned sessions will be deleted. The new program starts \(startDay.formatted(f)); your completed history is kept." }
            let n = sessionsToDelete.count
            return "\(n) planned session\(n == 1 ? "" : "s") (\(range.first.formatted(f)) – \(range.last.formatted(f))) will be deleted and replaced by the new program. Your completed history is kept, and a backup is taken first."
        }
    }

    enum ReplaceError: LocalizedError {
        case refused(String)
        var errorDescription: String? { if case .refused(let m) = self { return m } else { return nil } }
    }

    /// The sessions a replacement from `startDate` deletes, and any that forbid it. Same selection the replacement uses.
    static func plan(startDate: Date, context: ModelContext, calendar: Calendar = .current) -> Plan {
        let startDay = effectiveStartDay(for: startDate, calendar: calendar)
        let all = (try? context.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\.date, order: .forward)]))) ?? []
        // Guard 2: never hard-delete maintenance sessions: they ride their archived maintenance block.
        let affected = all.filter {
            calendar.startOfDay(for: $0.date) >= startDay && $0.status != .completed && $0.meso?.isMaintenance != true
        }
        let blockers = affected.filter { $0.status == .inProgress || SessionEditSafety.hasLoggedData($0) }
        let deletable = affected.filter { $0.status == .planned && !SessionEditSafety.hasLoggedData($0) }
        return Plan(startDay: startDay, sessionsToDelete: deletable, blockers: blockers)
    }
    /// The day this service will actually seed from, for a requested start date:
    /// normalized to the start of its day, then clamped forward to today because
    /// a past start would over-delete planned history.
    ///
    /// Exposed so callers can ask what the seeder will do without re-deriving it.
    /// The meso labeling anchor in particular must land on exactly this day, or
    /// W/D labels count from a different date than the block actually starts.
    static func effectiveStartDay(for startDate: Date, calendar: Calendar = .current) -> Date {
        max(calendar.startOfDay(for: startDate), calendar.startOfDay(for: Date()))
    }

    /// Replaces all non-completed sessions on or after the chosen start date
    /// with a freshly seeded DUP block.
    ///
    /// Keeps completed history intact.
    /// Archives any currently active meso blocks, then seeds the new block as active.
    static func replacePlannedProgram(
        startDate: Date,
        trainingWeekdays: [Int],
        context: ModelContext,
        template: ProgramTemplate = DUP10WeekTemplate.template,
        calendar: Calendar = .current,
        overrides: PreviewOverrides? = nil
    ) throws {
        // Guard 1: clamp a past startDate to today to prevent over-deletion.
        let startDay = effectiveStartDay(for: startDate, calendar: calendar)
        if startDay != calendar.startOfDay(for: startDate) {
            print("⚠️ replacePlannedProgram: startDate \(calendar.startOfDay(for: startDate)) is in the past — clamping to today.")
        }

        // Guard 3: logged work is never deleted. An in-progress session, or a planned one with logged sets, stops the replacement.
        let plan = plan(startDate: startDate, context: context, calendar: calendar)
        guard plan.isAllowed else { throw ReplaceError.refused(plan.message) }

        // 1) Archive any currently active meso blocks
        let mesoDescriptor = FetchDescriptor<MesoBlock>()
        let existingBlocks = try context.fetch(mesoDescriptor)

        for block in existingBlocks where block.status == .active {
            block.status = .archived
        }

        // 2) Delete non-completed sessions on or after the chosen start date
        let sessionsToDelete = plan.sessionsToDelete

        for session in sessionsToDelete {
            context.delete(session)
        }

        try context.save()

        // 3) Seed the replacement block as the new active meso
        try DUPProgramSeeder.seed(
            startDate: startDay,
            trainingWeekdays: trainingWeekdays,
            context: context,
            template: template,
            calendar: calendar,
            mesoName: template.name,
            mesoStatus: .active,
            mesoNotes: "Seeded via replacePlannedProgram on \(startDay.formatted(date: .abbreviated, time: .omitted))",
            overrides: overrides
        )

        // 4) Anchor loads from prior history — mirrors MaintenanceProgramSeeder.seed's
        // own placement (anchor as the final step, immediately after the new meso's
        // sessions are saved). DUPProgramSeeder.seed doesn't return the MesoBlock it
        // creates, so re-fetch it as the most recently created active block — step 3
        // above always passes mesoStatus: .active for this call, and step 1 already
        // archived every other active block, so exactly one match is expected.
        let newMesoDescriptor = FetchDescriptor<MesoBlock>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        if let newMeso = try context.fetch(newMesoDescriptor).first(where: { $0.status == .active }) {
            ProgramGenerator.anchorLoadsForNewMeso(mesoBlock: newMeso, context: context)
        } else {
            print("⚠️ replacePlannedProgram: no active meso found after seeding; loads not anchored")
        }
    }
}
