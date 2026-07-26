import Foundation
import SwiftData

enum DUPProgramReplaceService {
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
        var startDay = calendar.startOfDay(for: startDate)
        let todayStart = calendar.startOfDay(for: Date())
        if startDay < todayStart {
            print("⚠️ replacePlannedProgram: startDate \(startDay) is in the past — clamping to today.")
            startDay = todayStart
        }

        // 1) Archive any currently active meso blocks
        let mesoDescriptor = FetchDescriptor<MesoBlock>()
        let existingBlocks = try context.fetch(mesoDescriptor)

        for block in existingBlocks where block.status == .active {
            block.status = .archived
        }

        // 2) Delete non-completed sessions on or after the chosen start date
        let sessionDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        let allSessions = try context.fetch(sessionDescriptor)

        // Guard 2: never hard-delete maintenance sessions — they ride their archived
        // maintenance block and must remain visible in the carry-over filter.
        let sessionsToDelete = allSessions.filter { session in
            let sessionDay = calendar.startOfDay(for: session.date)
            return sessionDay >= startDay
                && session.status != .completed
                && session.meso?.isMaintenance != true
        }

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
