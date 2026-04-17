import Foundation
import SwiftData

enum SessionHistoryBlockBackfill {
    private static let completionKey = "sessionHistoryBlockBackfill.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ SessionHistory block backfill not needed.")
            return
        }

        let historyDescriptor = FetchDescriptor<SessionHistory>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        let sessionDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        guard let histories = try? context.fetch(historyDescriptor) else {
            print("⚠️ SessionHistory block backfill failed: could not fetch history rows.")
            return
        }

        guard let sessions = try? context.fetch(sessionDescriptor) else {
            print("⚠️ SessionHistory block backfill failed: could not fetch sessions.")
            return
        }

        var changedCount = 0
        let calendar = Calendar.current

        for history in histories {
            if history.mesoBlockId != nil {
                continue
            }

            let start = calendar.startOfDay(for: history.date)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }

            let sameDaySessions = sessions.filter { session in
                session.date >= start && session.date < end
            }

            guard !sameDaySessions.isEmpty else { continue }

            guard let best = bestMatch(for: history, candidates: sameDaySessions) else { continue }
            guard let meso = best.meso else { continue }

            history.mesoBlockId = meso.id
            history.mesoBlockNameSnapshot = meso.name
            changedCount += 1
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ SessionHistory block backfill completed. Updated \(changedCount) rows.")
            } else {
                print("ℹ️ SessionHistory block backfill found nothing to update.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ SessionHistory block backfill save failed: \(error)")
        }
    }

    private static func bestMatch(for history: SessionHistory, candidates: [Session]) -> Session? {
        func score(_ session: Session) -> Int {
            var value = 0

            if session.status == .completed { value += 100 }
            if session.weekIndex == history.weekIndex { value += 40 }
            if session.items.count == history.totalExercises { value += 25 }

            let completedExerciseCount = session.items.filter { item in
                item.actualReps.contains(where: { $0 > 0 }) || item.actualLoads.contains(where: { $0 > 0 })
            }.count

            let exerciseDiff = abs(completedExerciseCount - history.totalExercises)
            value += max(0, 20 - exerciseDiff * 5)

            if session.hkWorkoutUUID != nil { value += 5 }

            return value
        }

        return candidates.sorted {
            let lhs = score($0)
            let rhs = score($1)

            if lhs != rhs { return lhs > rhs }
            return $0.date > $1.date
        }.first
    }
}
