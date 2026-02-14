import SwiftUI
import SwiftData

struct AnalyticsView: View {
    @Query(sort: \Session.date, order: .reverse) private var sessions: [Session]

    @State private var selectedExerciseId: String? = nil
    @State private var selectedExerciseName: String = ""

    var body: some View {
        NavigationStack {
            List {
                summarySection
                activitySection
                topExercisesSection
            }
            .navigationTitle("Analytics")
            .sheet(item: sheetItemBinding) { item in
                ExerciseHistorySheet(
                    exerciseName: item.exerciseName,
                    onClose: {
                        selectedExerciseId = nil
                        selectedExerciseName = ""
                    }
                )
            }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section("Summary") {
            let completed = sessions.filter { $0.status == .completed }
            let totalSessions = sessions.count
            let completedCount = completed.count
            let totalLoggedItems = computeLoggedSetCount(from: sessions)

            row("Total sessions", "\(totalSessions)")
            row("Completed sessions", "\(completedCount)")
            row("Logged items", "\(totalLoggedItems)")
        }
    }

    private var activitySection: some View {
        Section("Activity") {
            let last7 = completedSessions(inLastDays: 7)
            let last30 = completedSessions(inLastDays: 30)

            row("Completed (7 days)", "\(last7)")
            row("Completed (30 days)", "\(last30)")
        }
    }

    private var topExercisesSection: some View {
        Section("Top exercises (last 30 days)") {
            let rows = topExercises(lastDays: 30, limit: 12)

            if rows.isEmpty {
                Text("No exercise data found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { r in
                    Button {
                        selectedExerciseId = r.exerciseId
                        selectedExerciseName = r.exerciseName
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.exerciseName)
                                    .font(.body)
                                Text("\(r.loggedItems) logged items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(r.estimatedVolumeK)k")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func completedSessions(inLastDays days: Int) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return sessions.filter { $0.status == .completed && $0.date >= cutoff }.count
    }

    /// Counts "logged items" using your same heuristic: any set with load>0 OR reps>0
    private func computeLoggedSetCount(from sessions: [Session]) -> Int {
        var count = 0
        for s in sessions {
            for item in s.items {
                let hasLoad = item.actualLoads.contains(where: { $0 > 0 })
                let hasReps = item.actualReps.contains(where: { $0 > 0 })
                if hasLoad || hasReps { count += 1 }
            }
        }
        return count
    }

    private func topExercises(lastDays days: Int, limit: Int) -> [TopExerciseRow] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let recent = sessions.filter { $0.date >= cutoff && $0.status == .completed }

        // Map: exerciseId -> accumulator
        var map: [String: Accum] = [:]

        for s in recent {
            for item in s.items {
                let exId = item.exerciseId
                let name = ExerciseCatalog.displayName(for: item.exerciseId)

                // estimate "volume" = sum(load * reps) across set arrays
                var volume: Double = 0
                let loads = item.actualLoads
                let reps = item.actualReps
                let n = min(loads.count, reps.count)
                if n > 0 {
                    for i in 0..<n {
                        volume += Double(loads[i]) * Double(reps[i])
                    }
                }

                // logged item heuristic (same as above)
                let logged = (loads.contains(where: { $0 > 0 }) || reps.contains(where: { $0 > 0 })) ? 1 : 0

                if map[exId] == nil {
                    map[exId] = Accum(exerciseId: exId, exerciseName: name, loggedItems: 0, volume: 0)
                }
                map[exId]?.loggedItems += logged
                map[exId]?.volume += volume
            }
        }

        var rows = map.values.map { a in
            TopExerciseRow(
                exerciseId: a.exerciseId,
                exerciseName: a.exerciseName,
                loggedItems: a.loggedItems,
                estimatedVolumeK: Int((a.volume / 1000.0).rounded())
            )
        }

        rows.sort {
            if $0.loggedItems != $1.loggedItems { return $0.loggedItems > $1.loggedItems }
            return $0.estimatedVolumeK > $1.estimatedVolumeK
        }

        if rows.count > limit { rows = Array(rows.prefix(limit)) }
        return rows
    }

    
    
    private struct Accum {
        let exerciseId: String
        let exerciseName: String
        var loggedItems: Int
        var volume: Double
    }

    struct TopExerciseRow: Identifiable {
        var id: String { exerciseId }
        let exerciseId: String
        let exerciseName: String
        let loggedItems: Int
        let estimatedVolumeK: Int
    }

    // MARK: - Sheet plumbing

    private var sheetItemBinding: Binding<ExerciseSheetItem?> {
        Binding<ExerciseSheetItem?>(
            get: {
                guard let id = selectedExerciseId else { return nil }
                return ExerciseSheetItem(exerciseId: id, exerciseName: selectedExerciseName)
            },
            set: { newValue in
                if newValue == nil {
                    selectedExerciseId = nil
                    selectedExerciseName = ""
                }
            }
        )
    }

    struct ExerciseSheetItem: Identifiable {
        var id: String { exerciseId }
        let exerciseId: String
        let exerciseName: String
    }
}
