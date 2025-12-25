import SwiftUI
import SwiftData

/// One row of history for a given exercise on a given day.
struct ExerciseHistoryEntry: Identifiable {
    let id = UUID()
    let date: Date
    let weekIndex: Int
    let bestLoad: Double
    let bestReps: Int
    let estimated1RM: Double?
}

/// Shows history for a single exercise across all logged sessions.
///
/// - Computation:
///   For each Session that includes this exercise:
///   • Find the set with the HIGHEST REPS (your “highest-rep” set)
///   • Use its load + reps to compute an estimated 1RM (Epley: 1RM = w * (1 + reps/30))
///   • Display that as the entry’s “best e1RM” for that day
struct ExerciseHistoryView: View {
    @Environment(\.modelContext) private var context

    let exerciseId: String
    let exerciseName: String

    @State private var entries: [ExerciseHistoryEntry] = []
    @State private var bestE1RM: Double?

    var body: some View {
        NavigationStack {
            List {
                // Top summary card
                if let bestE1RM {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Best est. 1RM")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(formatLoad(bestE1RM))
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Per-session timeline
                Section("History") {
                    if entries.isEmpty {
                        Text("No logged sets yet for \(exerciseName).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.date, format: .dateTime.month().day().year())
                                        .font(.subheadline)

                                    Spacer()

                                    Text("Week \(entry.weekIndex)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 12) {
                                    Text("\(formatLoad(entry.bestLoad)) × \(entry.bestReps)")
                                    if let e1rm = entry.estimated1RM {
                                        Text("e1RM \(formatLoad(e1rm))")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(exerciseName)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                loadHistory()
            }
        }
    }

    // MARK: - Loading

    private func loadHistory() {
        do {
            var descriptor = FetchDescriptor<Session>()
            descriptor.sortBy = [SortDescriptor(\Session.date, order: .reverse)]

            let sessions = try context.fetch(descriptor)
            var built: [ExerciseHistoryEntry] = []

            for session in sessions {
                // Find the SessionItem for this exercise
                let items = session.items.sorted { $0.order < $1.order }
                guard let item = items.first(where: { $0.exerciseId == exerciseId }) else {
                    continue
                }

                guard let best = bestSet(in: item) else { continue }

                let entry = ExerciseHistoryEntry(
                    date: session.date,
                    weekIndex: session.weekInMeso,
                    bestLoad: best.load,
                    bestReps: best.reps,
                    estimated1RM: best.e1rm
                )
                built.append(entry)
            }

            entries = built.sorted { $0.date > $1.date }
            bestE1RM = entries.compactMap { $0.estimated1RM }.max()
        } catch {
            print("⚠️ Failed to load exercise history: \(error)")
        }
    }

    // MARK: - Highest-rep e1RM logic

    /// Find the set with the **highest reps** and compute its e1RM.
    private func bestSet(in item: SessionItem) -> (load: Double, reps: Int, e1rm: Double?)? {
        let repsArray = item.actualReps
        let loadsArray = item.actualLoads
        let plannedLoads = item.plannedLoadsBySet

        if repsArray.isEmpty && loadsArray.isEmpty && plannedLoads.isEmpty {
            return nil
        }

        var bestIndex: Int?
        var bestReps = 0

        let count = max(repsArray.count, loadsArray.count, plannedLoads.count)

        for idx in 0..<count {
            let reps = idx < repsArray.count ? repsArray[idx] : 0
            let loadActual = idx < loadsArray.count ? loadsArray[idx] : 0
            let loadPlanned = idx < plannedLoads.count ? plannedLoads[idx] : 0
            let load = loadActual > 0 ? loadActual : loadPlanned

            guard reps > 0, load > 0 else { continue }

            // Highest REP wins (this is your “highest-rep e1RM” rule)
            if reps > bestReps {
                bestReps = reps
                bestIndex = idx
            }
        }

        guard let index = bestIndex else { return nil }

        let reps = index < repsArray.count ? repsArray[index] : bestReps
        let loadActual = index < loadsArray.count ? loadsArray[index] : 0
        let loadPlanned = index < plannedLoads.count ? plannedLoads[index] : 0
        let load = loadActual > 0 ? loadActual : loadPlanned

        guard reps > 0, load > 0 else { return nil }

        let e1rm = estimate1RM(load: load, reps: reps)
        return (load, reps, e1rm)
    }

    /// Epley: 1RM = weight × (1 + reps/30)
    private func estimate1RM(load: Double, reps: Int) -> Double {
        let r = max(1, reps)
        return load * (1.0 + Double(r) / 30.0)
    }

    // MARK: - Formatting

    private func formatLoad(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%.1f", value)
    }
}
