import Foundation
import SwiftData

/// CSV v1 export: one row per set, completed sessions only.
enum SetsV1CSVExporter {

    struct ExportResult {
        let url: URL
        let rowCount: Int
    }

    static func exportCompletedSessionsCSV(
        modelContext: ModelContext,
        fileName: String = "eliteperformance_sets_v1.csv"
    ) throws -> ExportResult {

        let sessions = try modelContext.fetch(
            FetchDescriptor<Session>(sortBy: [SortDescriptor(\.date, order: .forward)])
        )

        // Load columns are in the lifter's unit (stored lb, converted here); `load_unit` says which.
        let unit = (try? modelContext.fetch(FetchDescriptor<UserProfile>()).first)?.loadUnit ?? .lb
        let completed = sessions
            .filter { $0.status == .completed }
            .sorted { $0.date < $1.date }

        // is_pr comes from the PR EVENTS (PersonalRecords via PRRebuildService.recordItems), never from SessionItem.isPR.
        let customs = (try? modelContext.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let bodyWeight = (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first?.bodyWeight
        let records = SetRecordBuilder.build(sessions: sessions, customExercises: customs, bodyWeight: bodyWeight)
        let recordItems = PRRebuildService.recordItems(sessions: sessions, records: records)

        let header = [
            "session_id",
            "session_date",
            "week_index",
            "exercise_order",
            "exercise_id",
            "exercise_name",
            "set_index",
            "target_sets",
            "target_reps",
            "target_rir",
            "suggested_load",
            "planned_reps",
            "planned_load",
            "actual_reps",
            "actual_load",
            "actual_rir",
            "used_rest_pause",
            "rest_pause_pattern",
            "is_pr",
            "coach_note",
            "set_role",
            "load_unit"
        ]

        var rows: [String] = []
        rows.reserveCapacity(2048)
        rows.append(header.joined(separator: ","))

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]

        var rowCount = 0

        for s in completed {
            let sessionDate = iso.string(from: s.date)
            let weekIndex = String(s.weekIndex)

            // Stable-ish session id:
            // Prefer HealthKit uuid if present, else derive from date+week.
            let sessionId = csvSessionId(session: s, isoDate: sessionDate)

            let items = s.items.sorted { $0.order < $1.order }

            for item in items {
                let exerciseId = item.exerciseId
                let exerciseName = ExerciseCatalog.displayName(for: exerciseId)

                let exerciseOrder = String(item.order)
                let targetSets = String(item.targetSets)
                let targetReps = String(item.targetReps)
                let targetRIR  = String(item.targetRIR)
                let suggestedLoad = formatDouble(unit.fromStoredLb(item.suggestedLoad))
                let isPR = recordItems.contains(item.persistentModelID) ? "true" : "false"
                let coachNote = item.coachNote ?? ""

                // Every planned row, plus any later row that has a logged set.
                let loggedRowCount = max(item.actualReps.count, item.actualLoads.count)
                let rowIndices = LoggedRowSelection.indices(
                    targetSets: item.targetSets,
                    rowCount: max(max(1, item.targetSets), loggedRowCount),
                    isLogged: { (item.actualReps.safeInt(at: $0) ?? 0) > 0 || (item.actualLoads.safeDouble(at: $0) ?? 0) > 0 }
                )

                for idx0 in rowIndices {
                    let setIndex = String(idx0 + 1)

                    let plannedReps = item.plannedRepsBySet.safeInt(at: idx0).map(String.init) ?? ""
                    let plannedLoad = item.plannedLoadsBySet.safeDouble(at: idx0).map { formatDouble(unit.fromStoredLb($0)) } ?? ""

                    let actualReps = item.actualReps.safeInt(at: idx0).map(String.init) ?? ""
                    let actualLoad = item.actualLoads.safeDouble(at: idx0).map { formatDouble(unit.fromStoredLb($0)) } ?? ""
                    let actualRIR  = RIREntry.recorded(item, at: idx0).map(String.init) ?? ""   // unset is an empty cell

                    let usedRP = item.usedRestPauseFlags.safeBool(at: idx0).map { $0 ? "true" : "false" } ?? ""
                    let rpPattern = item.restPausePatternsBySet.safeString(at: idx0) ?? ""

                    let fields = [
                        sessionId,
                        sessionDate,
                        weekIndex,
                        exerciseOrder,
                        exerciseId,
                        exerciseName,
                        setIndex,
                        targetSets,
                        targetReps,
                        targetRIR,
                        suggestedLoad,
                        plannedReps,
                        plannedLoad,
                        actualReps,
                        actualLoad,
                        actualRIR,
                        usedRP,
                        rpPattern,
                        isPR,
                        coachNote,
                        item.isTopRow(idx0) ? "top" : "",
                        unit.label
                    ]

                    rows.append(fields.map(csvEscape).joined(separator: ","))
                    rowCount += 1
                }
            }
        }

        let csv = rows.joined(separator: "\n")

        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(fileName)

        guard let data = csv.data(using: .utf8) else {
            throw ExportError.failedToEncodeUTF8
        }
        try data.write(to: url, options: .atomic)

        return ExportResult(url: url, rowCount: rowCount)
    }

    // MARK: - Session ID strategy

    private static func csvSessionId(session: Session, isoDate: String) -> String {
        if let hk = session.hkWorkoutUUID, !hk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hk
        }
        // Deterministic fallback: date + week + completedAt presence
        if let completedAt = session.completedAt {
            let t = ISO8601DateFormatter()
            t.formatOptions = [.withInternetDateTime]
            return "\(isoDate)_w\(session.weekIndex)_\(t.string(from: completedAt))"
        }
        return "\(isoDate)_w\(session.weekIndex)"
    }

    // MARK: - Errors

    enum ExportError: Error {
        case failedToEncodeUTF8
    }

    // MARK: - Formatting + CSV escaping

    private static func formatDouble(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v == floor(v) { return String(format: "%.0f", v) }
        return String(format: "%.2f", v)
    }

    private static func csvEscape(_ s: String) -> String {
        let needsWrap = s.contains(",") || s.contains("\"") || s.contains("\n")
        var out = s.replacingOccurrences(of: "\"", with: "\"\"")
        if needsWrap { out = "\"\(out)\"" }
        return out
    }
}

// MARK: - Safe indexing helpers

private extension Array where Element == Int {
    func safeInt(at idx: Int) -> Int? {
        guard idx >= 0 && idx < count else { return nil }
        return self[idx]
    }
}

private extension Array where Element == Double {
    func safeDouble(at idx: Int) -> Double? {
        guard idx >= 0 && idx < count else { return nil }
        return self[idx]
    }
}

private extension Array where Element == Bool {
    func safeBool(at idx: Int) -> Bool? {
        guard idx >= 0 && idx < count else { return nil }
        return self[idx]
    }
}

private extension Array where Element == String {
    func safeString(at idx: Int) -> String? {
        guard idx >= 0 && idx < count else { return nil }
        return self[idx]
    }
}
