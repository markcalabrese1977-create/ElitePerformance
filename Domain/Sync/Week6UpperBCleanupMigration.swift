// Domain/Sync/Week6UpperBCleanupMigration.swift
import Foundation
import SwiftData

/// One-shot repair for the Week 6 roster/date corruption (weekday-matching propagation
/// bug, fixed separately in ProgramDayDetailView/SessionView) and the Upper B "no Seated
/// Cable Row" roster decision, per the reviewed Stage 2 write-list.
///
/// Scope, exactly as reviewed:
/// - Week 6 (4 sessions): restore dates to the Fri/Sat/Mon/Tue cadence; replace Upper A's
///   and Upper B's wrong (cross-contaminated) item rosters with the correct Upper A / Upper B
///   rosters; Lower A / Lower B get a date write only, items untouched.
/// - Weeks 7-10 Upper B (4 sessions): remove only the Seated Cable Row item, no renumber.
///
/// Safety: every session/item is re-verified live, immediately before writing. A session
/// with any logged data (isCompleted, or any nonzero actualLoads/actualReps) is never
/// touched. The Week 6 block is all-or-nothing (the four dates are collision-interdependent);
/// each Seated Cable Row removal is independent and aborts on its own if that item has drifted.
enum Week6UpperBCleanupMigration {
    private static let completionKey = "week6UpperBCleanupMigration.v1.completed"

    // MARK: - Target identities (from the reviewed Stage 2 write-list)

    private static let upperAId = UUID(uuidString: "0868FF1E-634B-457E-B32B-56A1E6F18280")!
    private static let lowerAId = UUID(uuidString: "C4C4D9B8-BB44-4542-A70F-E442453985CC")!
    private static let upperBId = UUID(uuidString: "01563BDB-A9BE-4186-8951-902177A4AD0A")!
    private static let lowerBId = UUID(uuidString: "32DD0948-4CBE-4F6C-B824-831E5D447D9A")!

    private struct SCRTarget {
        let label: String
        let sessionId: UUID
        let itemId: UUID
    }

    private static let scrTargets: [SCRTarget] = [
        SCRTarget(label: "Week 7 Upper B (9/14)", sessionId: UUID(uuidString: "9CC137E0-A518-48DC-B9B5-306D18938192")!, itemId: UUID(uuidString: "AE69D8EF-9E0A-42DA-9353-3A0A2B035AF9")!),
        SCRTarget(label: "Week 8 Upper B (9/21)", sessionId: UUID(uuidString: "2D2B4152-840F-4E57-B2F4-59D6991D56C9")!, itemId: UUID(uuidString: "75D988CD-4FC7-4631-A305-32C38E6D18CE")!),
        SCRTarget(label: "Week 9 Upper B (9/28)", sessionId: UUID(uuidString: "C16C98B8-7B40-4F39-95B6-EAF7C8033E53")!, itemId: UUID(uuidString: "DD363C54-FE41-46C7-B926-70B1A44B922A")!),
        SCRTarget(label: "Week 10 Upper B (10/5)", sessionId: UUID(uuidString: "FDD9C73F-A79A-4598-B015-B997EC68DB4C")!, itemId: UUID(uuidString: "FA157260-2725-430B-B3CA-3562E846D07B")!)
    ]

    // MARK: - Planned item specs

    private struct PlannedItem {
        let order: Int
        let exerciseId: String
        let name: String
        let sets: Int
        let reps: Int
        let rir: Int
        let waveRaw: String?
        let priorityRaw: String?
        let intensifierRaw: String?
        let setMin: Int?
        let setMax: Int?
        let repMin: Int?
        let repMax: Int?
        let rirMin: Int?
        let rirMax: Int?
        let suggestedLoad: Double
    }

    private static let upperARoster: [PlannedItem] = [
        PlannedItem(order: 1, exerciseId: "bench_press", name: "Bench Press", sets: 4, reps: 4, rir: 1, waveRaw: "c", priorityRaw: "anchor", intensifierRaw: "none", setMin: 4, setMax: 4, repMin: 4, repMax: 5, rirMin: 1, rirMax: 1, suggestedLoad: 310.0),
        PlannedItem(order: 2, exerciseId: "decline_bench_press", name: "Decline Bench Press", sets: 3, reps: 6, rir: 1, waveRaw: "c", priorityRaw: "anchor", intensifierRaw: "none", setMin: 4, setMax: 4, repMin: 6, repMax: 8, rirMin: 1, rirMax: 1, suggestedLoad: 305.0),
        PlannedItem(order: 3, exerciseId: "t_bar_row", name: "T-Bar Row", sets: 4, reps: 5, rir: 1, waveRaw: "c", priorityRaw: "standard", intensifierRaw: "none", setMin: 3, setMax: 3, repMin: 5, repMax: 6, rirMin: 1, rirMax: 1, suggestedLoad: 267.5),
        PlannedItem(order: 4, exerciseId: "single_arm_cable_lateral_raise", name: "Single-Arm Cable Lateral Raise", sets: 3, reps: 6, rir: 1, waveRaw: "c", priorityRaw: "standard", intensifierRaw: "none", setMin: 3, setMax: 4, repMin: 6, repMax: 8, rirMin: 1, rirMax: 1, suggestedLoad: 32.5),
        PlannedItem(order: 5, exerciseId: "incline_rear_delt_fly", name: "Incline Rear Delt Fly", sets: 3, reps: 12, rir: 1, waveRaw: "c", priorityRaw: "standard", intensifierRaw: "none", setMin: 3, setMax: 3, repMin: 12, repMax: 15, rirMin: 1, rirMax: 1, suggestedLoad: 35.0),
        PlannedItem(order: 6, exerciseId: "hammer_curl", name: "Hammer Curl", sets: 3, reps: 8, rir: 1, waveRaw: "c", priorityRaw: "standard", intensifierRaw: "none", setMin: 3, setMax: 3, repMin: 8, repMax: 10, rirMin: 1, rirMax: 1, suggestedLoad: 92.5),
        PlannedItem(order: 16, exerciseId: "custom_3e27879b-cb43-4050-a3f4-fede3fc6e3fd", name: "DB Skull Crusher [Rehab]", sets: 3, reps: 10, rir: 3, waveRaw: "c", priorityRaw: "standard", intensifierRaw: "none", setMin: 3, setMax: 3, repMin: 10, repMax: 10, rirMin: 3, rirMax: 3, suggestedLoad: 5.0)
    ]

    private static let upperBRoster: [PlannedItem] = [
        PlannedItem(order: 2, exerciseId: "pull_up", name: "Pull-Up", sets: 3, reps: 10, rir: 2, waveRaw: nil, priorityRaw: nil, intensifierRaw: nil, setMin: nil, setMax: nil, repMin: nil, repMax: nil, rirMin: nil, rirMax: nil, suggestedLoad: 0),
        PlannedItem(order: 3, exerciseId: "chest_supported_incline_dumbbell_row", name: "Chest-Supported Incline DB Row", sets: 4, reps: 10, rir: 1, waveRaw: "c", priorityRaw: "anchor", intensifierRaw: "none", setMin: 3, setMax: 4, repMin: 8, repMax: 10, rirMin: 1, rirMax: 1, suggestedLoad: 92.5),
        PlannedItem(order: 4, exerciseId: "custom_a45d8c4e-fc18-45a2-a224-8c89eebad7c8", name: "Smith Incline Bench Press", sets: 3, reps: 10, rir: 1, waveRaw: "c", priorityRaw: "standard", intensifierRaw: "none", setMin: 3, setMax: 3, repMin: 8, repMax: 10, rirMin: 1, rirMax: 1, suggestedLoad: 185.0),
        PlannedItem(order: 5, exerciseId: "dumbbell_lateral_raise", name: "Dumbbell Lateral Raise", sets: 3, reps: 15, rir: 1, waveRaw: "c", priorityRaw: "standard", intensifierRaw: "none", setMin: 3, setMax: 3, repMin: 12, repMax: 15, rirMin: 1, rirMax: 1, suggestedLoad: 32.5),
        PlannedItem(order: 6, exerciseId: "single_arm_cable_curl", name: "Single-Arm Cable Curl", sets: 3, reps: 10, rir: 1, waveRaw: "c", priorityRaw: "standard", intensifierRaw: "none", setMin: 3, setMax: 3, repMin: 10, repMax: 12, rirMin: 1, rirMax: 1, suggestedLoad: 40.0),
        PlannedItem(order: 7, exerciseId: "custom_1342b9ca-dea5-435f-b705-1c3285633efa", name: "Band Pushdown [Rehab]", sets: 3, reps: 15, rir: 3, waveRaw: "c", priorityRaw: "standard", intensifierRaw: "none", setMin: 3, setMax: 3, repMin: 12, repMax: 15, rirMin: 3, rirMax: 3, suggestedLoad: 7.5)
    ]

    // MARK: - Entry point

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Week 6 / Upper B cleanup not needed.")
            return
        }

        guard let allSessions = try? context.fetch(FetchDescriptor<Session>()) else {
            print("⚠️ Week 6 cleanup: could not fetch sessions — aborting, nothing written.")
            return
        }
        let byId = Dictionary(uniqueKeysWithValues: allSessions.compactMap { s -> (UUID, Session)? in
            guard let id = s.id else { return nil }
            return (id, s)
        })

        var report: [String] = []
        var wroteAnything = false

        // MARK: Week 6 block (all-or-nothing — dates are collision-interdependent)

        if let upperA = byId[upperAId], let lowerA = byId[lowerAId],
           let upperB = byId[upperBId], let lowerB = byId[lowerBId] {

            let week6 = [
                (label: "Upper A", session: upperA), (label: "Lower A", session: lowerA),
                (label: "Upper B", session: upperB), (label: "Lower B", session: lowerB)
            ]

            let unsafe = week6.filter { !isSafeToModify($0.session) }

            if !unsafe.isEmpty {
                report.append("ABORTED Week 6 block entirely — not safe: " + unsafe.map {
                    "\($0.label) (status=\($0.session.status.rawValue), hasLoggedData=\(hasLoggedData($0.session)))"
                }.joined(separator: ", "))
            } else {
                report.append("Week 6 pre-write roster snapshot:")
                report.append("  Upper A current items: " + upperA.items.sorted { $0.order < $1.order }.map { "\($0.order):\($0.exerciseId)" }.joined(separator: ", "))
                report.append("  Upper B current items: " + upperB.items.sorted { $0.order < $1.order }.map { "\($0.order):\($0.exerciseId)" }.joined(separator: ", "))

                // Date writes
                upperA.date = date(2026, 9, 4)
                lowerA.date = date(2026, 9, 5)
                upperB.date = date(2026, 9, 7)
                lowerB.date = date(2026, 9, 8)

                // Roster repair — Upper A
                replaceItems(on: upperA, with: upperARoster, in: context)
                // Roster repair — Upper B
                replaceItems(on: upperB, with: upperBRoster, in: context)

                // Lower A / Lower B: date only, items untouched — nothing further to do.

                report.append("WROTE Week 6: dates restored (9/4, 9/5, 9/7, 9/8); Upper A roster replaced (7 items); Upper B roster replaced (6 items, no SCR); Lower A/Lower B items untouched.")
                wroteAnything = true
            }
        } else {
            report.append("ABORTED Week 6 block — one or more of the four session ids were not found live.")
        }

        // MARK: Weeks 7-10 Upper B — Seated Cable Row removal (independent per session)

        for target in scrTargets {
            guard let session = byId[target.sessionId] else {
                report.append("ABORTED \(target.label) — session id not found live.")
                continue
            }
            guard isSafeToModify(session) else {
                report.append("ABORTED \(target.label) — not safe (status=\(session.status.rawValue), hasLoggedData=\(hasLoggedData(session))).")
                continue
            }
            guard let item = session.items.first(where: { $0.id == target.itemId }) else {
                report.append("ABORTED \(target.label) — item id \(target.itemId) not found on session (drift). Current items: " + session.items.sorted { $0.order < $1.order }.map { "\($0.order):\($0.exerciseId)" }.joined(separator: ", "))
                continue
            }
            guard item.exerciseId == "seated_cable_row" else {
                report.append("ABORTED \(target.label) — item \(target.itemId) exists but exerciseId is '\(item.exerciseId)', not 'seated_cable_row' (drift). Not deleted.")
                continue
            }
            context.delete(item)
            report.append("WROTE \(target.label): deleted Seated Cable Row (order \(item.order)). No renumber.")
            wroteAnything = true
        }

        // MARK: Single atomic save

        if wroteAnything {
            do {
                try context.save()
                print("✅ Week 6 / Upper B cleanup complete:\n" + report.joined(separator: "\n"))
            } catch {
                print("⚠️ Week 6 cleanup save failed: \(error). Report of intended writes (NOT persisted):\n" + report.joined(separator: "\n"))
                return // do not mark complete — allow retry next launch
            }
        } else {
            print("ℹ️ Week 6 cleanup: nothing was safe to write.\n" + report.joined(separator: "\n"))
        }

        UserDefaults.standard.set(true, forKey: completionKey)
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

    private static func replaceItems(on session: Session, with roster: [PlannedItem], in context: ModelContext) {
        for item in session.items {
            context.delete(item)
        }
        session.items = []

        for spec in roster {
            let plannedReps = Array(repeating: spec.reps, count: spec.sets)
            let plannedRIRs = Array(repeating: spec.rir, count: spec.sets)
            let plannedLoads = Array(repeating: spec.suggestedLoad, count: spec.sets)

            let newItem = SessionItem(
                order: spec.order,
                exerciseId: spec.exerciseId,
                exerciseNameSnapshot: spec.name,
                targetReps: spec.reps,
                targetSets: spec.sets,
                targetRIR: spec.rir,
                suggestedLoad: spec.suggestedLoad,
                waveRaw: spec.waveRaw,
                priorityRaw: spec.priorityRaw,
                setMin: spec.setMin,
                setMax: spec.setMax,
                repMin: spec.repMin,
                repMax: spec.repMax,
                targetRIRMin: spec.rirMin,
                targetRIRMax: spec.rirMax,
                intensifierRaw: spec.intensifierRaw,
                plannedRepsBySet: plannedReps,
                plannedLoadsBySet: plannedLoads,
                plannedRIRsBySet: plannedRIRs
            )
            session.items.append(newItem)
        }
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = DateComponents(year: year, month: month, day: day)
        return calendar.date(from: components) ?? Date()
    }
}
