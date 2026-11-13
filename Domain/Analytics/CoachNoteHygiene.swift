// Domain/Logic/CoachNoteHygiene.swift
import Foundation

/// An info note that cites a load ("One more clean session at 65.0 earns the increase", "Load stepping up to 70.0") is
/// only true while the session still plans that load. The plan can change after the note was written (a carry-forward
/// on a later session, an edit, a new seed), so a note that cites a load the item no longer plans is stale: it is cleared
/// where loads are written (carry-forward) and never shown when it disagrees with the plan.
enum CoachNoteHygiene {

    /// The load a generated info note cites ("at 65.0", "to 70.0"), in the lifter's unit; nil for a note that cites none
    /// (pain / soreness flags, "Load set from your best performance this meso") or a note that is not generated info.
    static func citedLoad(in note: String) -> Double? {
        guard note.hasPrefix("ℹ️") || note.hasPrefix("✅") else { return nil }
        guard let r = note.range(of: #"\b(?:at|to) (\d+(?:\.\d+)?)"#, options: .regularExpression) else { return nil }
        let match = String(note[r])
        guard let num = match.split(separator: " ").last, let v = Double(num) else { return nil }
        return v
    }

    /// The loads the item plans (stored lb): its per-set loads and its suggested load.
    static func plannedLoads(of item: SessionItem) -> [Double] {
        (item.plannedLoadsBySet + [item.suggestedLoad]).filter { $0 > 0 }
    }

    /// True when the item's note cites a load that none of its planned loads matches (to the one decimal the note shows).
    static func isStale(_ item: SessionItem, unit: LoadUnit) -> Bool {
        guard let note = item.coachNote, let cited = citedLoad(in: note) else { return false }
        let planned = plannedLoads(of: item).map { unit.fromStoredLb($0) }
        guard !planned.isEmpty else { return true }          // nothing planned any more: a note about a load is moot
        return !planned.contains { abs($0 - cited) < 0.06 }
    }

    /// The note to show: nil when it is stale.
    static func visibleNote(of item: SessionItem, unit: LoadUnit) -> String? {
        guard let note = item.coachNote, !note.isEmpty else { return nil }
        return isStale(item, unit: unit) ? nil : note
    }

    /// Clears the item's note when it is stale. Returns true when it changed.
    @discardableResult
    static func clearIfStale(_ item: SessionItem, unit: LoadUnit) -> Bool {
        guard isStale(item, unit: unit) else { return false }
        item.coachNote = nil
        return true
    }

    /// Clears stale notes on every not-yet-completed session's items. Returns how many were cleared.
    @discardableResult
    static func sweep(_ sessions: [Session], unit: LoadUnit) -> Int {
        var n = 0
        for s in sessions where s.status != .completed {
            for i in s.items where clearIfStale(i, unit: unit) { n += 1 }
        }
        return n
    }
}
