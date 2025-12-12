import SwiftUI
import SwiftData

// MARK: - History List

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SessionHistory.date, order: .reverse)
    private var sessions: [SessionHistory]

    /// Group by calendar day so the header shows "December 9, 2025"
    private var groupedSessions: [(date: Date, sessions: [SessionHistory])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: sessions) { session in
            calendar.startOfDay(for: session.date)
        }

        return groups
            .map { (date: $0.key,
                    sessions: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // 🔹 Block summary card at the top
                    NavigationLink {
                        HistorySummaryView()
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Block summary")
                                        .font(.headline)

                                    Text("Best lifts, volume, and exercise stats")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)

                    // 🔹 Existing per-day history blocks
                    ForEach(groupedSessions, id: \.date) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.date, format: .dateTime.month(.wide).day().year())
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            ForEach(group.sessions) { history in
                                NavigationLink {
                                    HistoryDayDetailView(history: history)
                                } label: {
                                    HistoryRow(history: history)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("History")
        }
    }
}

// MARK: - History Row (summary card per day)

private struct HistoryRow: View {
    let history: SessionHistory

    private var shortDate: String {
        history.date.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortDate)
                        .font(.headline)

                    Text("Week \(history.weekIndex)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(shortDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Label("\(history.totalExercises) lifts", systemImage: "dumbbell")
                Label("\(history.totalSets) sets", systemImage: "square.grid.2x2")
                Label("\(Int(history.totalVolume)) lb", systemImage: "scalemass")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Per-set detail models

private struct HistorySetDetail: Identifiable {
    let id = UUID()
    let index: Int
    let load: Double
    let reps: Int
    let rir: Int?

    var lineText: String {
        let loadString = load == 0 ? "0" : String(format: "%.1f", load)
        var base = "Set \(index)  \(loadString) × \(reps)"
        if let rir {
            base += " @ \(rir) RIR"
        }
        return base
    }
}

private struct HistoryExerciseDetail: Identifiable {
    let id = UUID()
    let name: String
    let primaryMuscle: String?
    let totalSets: Int
    let totalReps: Int
    let totalVolume: Double
    let sets: [HistorySetDetail]
}

// MARK: - Day Detail (per-exercise + per-set breakdown)

private struct HistoryDayDetailView: View {
    @Environment(\.modelContext) private var context
    let history: SessionHistory

    /// Rebuild set-by-set data by finding the underlying Session
    /// that produced this SessionHistory (same date + weekIndex).
    private var exerciseDetails: [HistoryExerciseDetail] {
        let targetDate = history.date
        let targetWeek = history.weekIndex

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { session in
                session.date == targetDate && session.weekIndex == targetWeek
            }
        )

        guard
            let session = (try? context.fetch(descriptor))?.first
        else {
            // Fall back to aggregate history only
            return history.exercises.map { ex in
                HistoryExerciseDetail(
                    name: ex.name,
                    primaryMuscle: ex.primaryMuscle,
                    totalSets: ex.sets,
                    totalReps: ex.reps,
                    totalVolume: ex.volume,
                    sets: []
                )
            }
        }

        // Reuse the same reconstruction logic as the live Session screen.
        let vm = SessionScreenViewModel(session: session)

        return vm.exercises.map { uiEx in
            let catalog = ExerciseCatalog.all.first(where: { $0.id == uiEx.exerciseId })
            let primary = catalog?.primaryMuscle.rawValue.capitalized

            var totalReps = 0
            var totalVolume: Double = 0
            var setDetails: [HistorySetDetail] = []

            for set in uiEx.sets where set.index <= uiEx.targetSets {
                let reps = set.actualReps ?? set.plannedReps
                let load = set.actualLoad ?? set.plannedLoad
                let rir  = set.actualRIR ?? set.plannedRIR

                // Only count sets that were actually done
                guard reps > 0, load > 0 else { continue }

                totalReps += reps
                totalVolume += Double(reps) * load

                setDetails.append(
                    HistorySetDetail(
                        index: set.index,
                        load: load,
                        reps: reps,
                        rir: rir
                    )
                )
            }

            return HistoryExerciseDetail(
                name: uiEx.name,
                primaryMuscle: primary,
                totalSets: setDetails.count,
                totalReps: totalReps,
                totalVolume: totalVolume,
                sets: setDetails
            )
        }
    }

    private var totalReps: Int {
        exerciseDetails.reduce(0) { $0 + $1.totalReps }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                exerciseBreakdown
            }
            .padding()
        }
        .navigationTitle("Session Recap")
        .navigationBarTitleDisplayMode(.inline)
    }

    // Top summary card (day-level)
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(history.date, format: .dateTime.month().day().year())
                .font(.headline)

            Text("Week \(history.weekIndex)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text("Exercises")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(history.totalExercises)")
                        .font(.headline)
                }

                Spacer()

                VStack(alignment: .leading) {
                    Text("Sets completed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(history.totalSets)")
                        .font(.headline)
                }

                Spacer()

                VStack(alignment: .leading) {
                    Text("Total volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(history.totalVolume))")
                        .font(.headline)
                }
            }

            if totalReps > 0 {
                HStack {
                    Text("Total reps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(totalReps)")
                        .font(.caption)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
        )
    }

    // Per-exercise + per-set breakdown
    private var exerciseBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By exercise")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                ForEach(Array(exerciseDetails.enumerated()), id: \.element.id) { index, ex in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ex.name)
                            .font(.body)

                        HStack(spacing: 12) {
                            if let primary = ex.primaryMuscle {
                                Text(primary)
                            }
                            Text("Sets: \(ex.totalSets)")
                            Text("Reps: \(ex.totalReps)")
                            Text("Vol: \(Int(ex.totalVolume))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if !ex.sets.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(ex.sets) { set in
                                    Text(set.lineText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 8)

                    if index != exerciseDetails.indices.last {
                        Divider()
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
            )
        }
    }
}

// MARK: - Preview

struct HistoryView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryView()
            .modelContainer(for: SessionHistory.self, inMemory: true)
    }
}
