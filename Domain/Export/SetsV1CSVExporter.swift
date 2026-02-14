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

        let completed = sessions
            .filter { $0.status == .completed }
            .sorted { $0.date < $1.date }

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
            "coach_note"
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
                let suggestedLoad = formatDouble(item.suggestedLoad)
                let isPR = item.isPR ? "true" : "false"
                let coachNote = item.coachNote ?? ""

                let setCount = max(1, item.targetSets)

                for idx0 in 0..<setCount {
                    let setIndex = String(idx0 + 1)

                    let plannedReps = item.plannedRepsBySet.safeInt(at: idx0).map(String.init) ?? ""
                    let plannedLoad = item.plannedLoadsBySet.safeDouble(at: idx0).map(formatDouble) ?? ""

                    let actualReps = item.actualReps.safeInt(at: idx0).map(String.init) ?? ""
                    let actualLoad = item.actualLoads.safeDouble(at: idx0).map(formatDouble) ?? ""
                    let actualRIR  = item.actualRIRs.safeInt(at: idx0).map(String.init) ?? ""

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
                        coachNote
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
