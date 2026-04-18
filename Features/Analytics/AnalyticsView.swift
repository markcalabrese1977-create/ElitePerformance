import SwiftUI
import SwiftData

struct AnalyticsView: View {
    @Query(sort: \Session.date, order: .reverse) private var sessions: [Session]

    @State private var selectedExerciseId: String? = nil

    private var mesoCutoff: Date {
        Calendar.current.startOfDay(for: MesoLifecycle.activeStartDate)
    }

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
                    exerciseId: item.exerciseId,
                    exerciseName: item.exerciseName,
                    onClose: { selectedExerciseId = nil }
                )
            }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section("Summary (this meso)") {
            let mesoSessions = sessions.filter { $0.date >= mesoCutoff }
            let completed = mesoSessions.filter { $0.status == .completed }

            row("Active since", mesoCutoff.formatted(date: .abbreviated, time: .omitted))
            row("Total sessions", "\(mesoSessions.count)")
            row("Completed sessions", "\(completed.count)")
            row("Logged exercise entries", "\(computeLoggedExerciseEntryCount(from: mesoSessions))")
        }
    }

    private var activitySection: some View {
        Section("Activity (this meso)") {
            row("Completed (7 days)", "\(completedSessions(inLastDays: 7))")
            row("Completed (30 days)", "\(completedSessions(inLastDays: 30))")
        }
    }

    private var topExercisesSection: some View {
        Section("Top exercises (last 30 days, this meso)") {
            let rows = topExercises(lastDays: 30, limit: 12)

            if rows.isEmpty {
                Text("No exercise data found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { r in
                    Button {
                        selectedExerciseId = ExerciseCatalog.canonicalExerciseId(for: r.exerciseId)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.exerciseName)
                                    .font(.body)
                                Text("\(r.loggedEntries) logged entries")
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
        let cal = Calendar.current
        let daysCutoff = cal.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let cutoff = max(cal.startOfDay(for: daysCutoff), mesoCutoff)

        return sessions.filter { $0.status == .completed && $0.date >= cutoff }.count
    }

    /// Counts "logged exercise entries" using the same heuristic: any set-array with load>0 OR reps>0.
    private func computeLoggedExerciseEntryCount(from sessions: [Session]) -> Int {
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
        let cal = Calendar.current
        let daysCutoff = cal.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let cutoff = max(cal.startOfDay(for: daysCutoff), mesoCutoff)

        let recent = sessions.filter { $0.status == .completed && $0.date >= cutoff }

        // Map: exerciseId -> accumulator
        var map: [String: Accum] = [:]

        for s in recent {
            for item in s.items {
                let exId = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)

                let name: String
                if let existing = map[exId]?.exerciseName {
                    name = existing
                } else {
                    name = ExerciseCatalog.displayName(for: exId)
                }

                var volume: Double = 0
                let loads = item.actualLoads
                let reps = item.actualReps
                let n = min(loads.count, reps.count)
                if n > 0 {
                    for i in 0..<n {
                        volume += Double(loads[i]) * Double(reps[i])
                    }
                }

                let logged = (loads.contains(where: { $0 > 0 }) || reps.contains(where: { $0 > 0 })) ? 1 : 0

                if map[exId] == nil {
                    map[exId] = Accum(exerciseId: exId, exerciseName: name, loggedEntries: 0, volume: 0)
                }
                map[exId]?.loggedEntries += logged
                map[exId]?.volume += volume
            }
        }

        var rows = map.values.map { a in
            TopExerciseRow(
                exerciseId: a.exerciseId,
                exerciseName: a.exerciseName,
                loggedEntries: a.loggedEntries,
                estimatedVolumeK: Int((a.volume / 1000.0).rounded())
            )
        }

        rows.sort {
            if $0.loggedEntries != $1.loggedEntries { return $0.loggedEntries > $1.loggedEntries }
            return $0.estimatedVolumeK > $1.estimatedVolumeK
        }

        if rows.count > limit { rows = Array(rows.prefix(limit)) }
        return rows
    }

    private struct Accum {
        let exerciseId: String
        let exerciseName: String
        var loggedEntries: Int
        var volume: Double
    }

    struct TopExerciseRow: Identifiable {
        var id: String { exerciseId }
        let exerciseId: String
        let exerciseName: String
        let loggedEntries: Int
        let estimatedVolumeK: Int
    }

    // MARK: - Sheet plumbing

    private var sheetItemBinding: Binding<ExerciseSheetItem?> {
        Binding<ExerciseSheetItem?>(
            get: {
                guard let id = selectedExerciseId else { return nil }
                let name = ExerciseCatalog.displayName(for: id)
                return ExerciseSheetItem(exerciseId: id, exerciseName: name)
            },
            set: { newValue in
                if newValue == nil { selectedExerciseId = nil }
            }
        )
    }

    struct ExerciseSheetItem: Identifiable {
        var id: String { exerciseId }
        let exerciseId: String
        let exerciseName: String
    }
}
