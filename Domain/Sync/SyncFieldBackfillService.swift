import Foundation
import SwiftData

enum SyncFieldBackfillService {
    static func runIfNeeded(in context: ModelContext) {
        var didChange = false
        let now = Date()

        // MesoBlock
        do {
            let blocks = try context.fetch(FetchDescriptor<MesoBlock>())
            for block in blocks {
                if block.id == nil {
                    block.id = UUID()
                    didChange = true
                }
                if block.createdAt == nil {
                    block.createdAt = block.startDate
                    didChange = true
                }
                if block.updatedAt == nil {
                    block.updatedAt = now
                    didChange = true
                }
            }
        } catch {
            print("⚠️ Backfill failed for MesoBlock: \(error)")
        }

        // Session
        do {
            let sessions = try context.fetch(FetchDescriptor<Session>())
            for session in sessions {
                if session.id == nil {
                    session.id = UUID()
                    didChange = true
                }
                if session.createdAt == nil {
                    session.createdAt = session.completedAt ?? session.date
                    didChange = true
                }
                if session.updatedAt == nil {
                    session.updatedAt = now
                    didChange = true
                }
            }
        } catch {
            print("⚠️ Backfill failed for Session: \(error)")
        }

        // SessionItem
        do {
            let items = try context.fetch(FetchDescriptor<SessionItem>())
            for item in items {
                if item.id == nil {
                    item.id = UUID()
                    didChange = true
                }
                if item.createdAt == nil {
                    item.createdAt = now
                    didChange = true
                }
                if item.updatedAt == nil {
                    item.updatedAt = now
                    didChange = true
                }
            }
        } catch {
            print("⚠️ Backfill failed for SessionItem: \(error)")
        }

        // SetLog
        do {
            let logs = try context.fetch(FetchDescriptor<SetLog>())
            for log in logs {
                if log.id == nil {
                    log.id = UUID()
                    didChange = true
                }
                if log.createdAt == nil {
                    log.createdAt = now
                    didChange = true
                }
                if log.updatedAt == nil {
                    log.updatedAt = now
                    didChange = true
                }
            }
        } catch {
            print("⚠️ Backfill failed for SetLog: \(error)")
        }

        guard didChange else {
            print("ℹ️ Sync field backfill not needed.")
            return
        }

        do {
            try context.save()
            print("✅ Sync field backfill completed.")
        } catch {
            print("⚠️ Failed to save sync field backfill: \(error)")
        }
    }
}
