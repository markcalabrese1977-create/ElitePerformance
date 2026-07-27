// Domain/Sync/MechanicalLoadRecoveryMigration.swift
import Foundation
import SwiftData

enum MechanicalLoadRecoveryMigration {
    private static let completionKey = "mechanicalLoadRecovery.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Mechanical load recovery not needed.")
            return
        }

        guard let histories = try? context.fetch(
            FetchDescriptor<SessionHistory>(sortBy: [SortDescriptor(\.date, order: .forward)])
        ) else {
            print("⚠️ Mechanical load recovery: could not fetch history.")
            return
        }
        guard let sessions = try? context.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\.date, order: .forward)])
        ) else {
            print("⚠️ Mechanical load recovery: could not fetch sessions.")
            return
        }

        let calendar = Calendar.current
        var recovered = 0

        for history in histories where history.mechanicalLoad == nil {
            let match: Session?
            if let sid = history.sessionId {
                match = sessions.first { $0.id == sid }
            } else {
                let start = calendar.startOfDay(for: history.date)
                let end = calendar.date(byAdding: .day, value: 1, to: start)
                match = sessions.first {
                    $0.date >= start && ($0.date < (end ?? start)) &&
                    $0.weekIndex == history.weekIndex
                }
            }
            guard let session = match else { continue }

            let score = MechanicalLoadHealthKitService.calculateMechanicalLoad(from: session)
            if score > 0 {
                history.mechanicalLoad = score
                recovered += 1
            }
        }

        do {
            if recovered > 0 { try context.save() }
            print("✅ Mechanical load recovery: repopulated \(recovered) rows.")
        } catch {
            print("⚠️ Mechanical load recovery save failed: \(error)")
            return
        }

        // Rebuild the App Group projection from the (now-recovered) source of truth.
        MechanicalLoadProjector.projectAll(in: context)
        UserDefaults.standard.set(true, forKey: completionKey)
    }
}
