import Foundation
import SwiftData

/// Which items carry a record. Nothing about records is stored any more (`PRIndex` and the `isPR` rewrite are gone): the events are
/// derived from the completed sessions by `PersonalRecords` whenever a screen or the CSV export needs them.
enum PRRebuildService {

    /// The items that carry a record: for every PR EVENT of `PersonalRecords` (a session that beat a lift's earlier record; a
    /// lift's first-ever session is a baseline, not a record), the one item of that lift in that session with the best
    /// working-set e1RM (a session can hold the same lift twice). This is THE source of "is this a PR": the CSV export reads
    /// it and the Meso Summary's record-setting sessions count its events.
    static func recordItems(sessions: [Session], records: AnalyticsSnapshot) -> Set<PersistentIdentifier> {
        var recordKeys = Set<String>()
        for e in PersonalRecords.events(from: records.sets) where !e.isBaseline { recordKeys.insert("\(e.sessionKey)|\(e.exerciseId)") }
        var out = Set<PersistentIdentifier>()
        for s in sessions where s.status == .completed {
            let key = s.id?.uuidString ?? "\(s.persistentModelID)"
            var carrier: [String: (item: SessionItem, e1RM: Double)] = [:]
            for item in s.items {
                let id = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                guard recordKeys.contains("\(key)|\(id)") else { continue }
                let mine = BestSetRule.best(of: item, bodyWeight: nil)?.e1RM ?? 0
                if let cur = carrier[id], cur.e1RM >= mine { continue }
                carrier[id] = (item, mine)
            }
            for c in carrier.values { out.insert(c.item.persistentModelID) }
        }
        return out
    }
}
