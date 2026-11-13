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
/// - Computation (Domain/Analytics, the same definitions as every other screen):
///   For each Session that includes this exercise, the entry shows the BEST WORKING SET by estimated 1RM
///   (Epley via `E1RMCalculator`; warm-ups, rest-pause, drop and skipped rows are not working sets; a bodyweight lift is
///   measured at the lifter's body weight). That e1RM is the entry's "best e1RM" for the day.
struct ExerciseHistoryView: View {
    @Environment(\.loadUnit) private var unit
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
            let bodyWeight = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first?.bodyWeight
            let target = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
            var built: [ExerciseHistoryEntry] = []

            for session in sessions where session.status == .completed {
                // The session's best working set for this exercise, by e1RM.
                let best = session.items
                    .filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == target }
                    .map { AnalyticsEngine.ItemStats.of($0, bodyWeight: bodyWeight) }
                    .max { $0.bestE1RM < $1.bestE1RM }
                guard let best, best.bestE1RM > 0 else { continue }

                built.append(ExerciseHistoryEntry(
                    date: session.date,
                    weekIndex: session.weekIndex,
                    bestLoad: best.bestLoad,
                    bestReps: best.bestReps,
                    estimated1RM: best.bestE1RM
                ))
            }

            entries = built.sorted { $0.date > $1.date }
            bestE1RM = entries.compactMap { $0.estimated1RM }.max()
        } catch {
            print("⚠️ Failed to load exercise history: \(error)")
        }
    }

    // MARK: - Formatting

    private func formatLoad(_ value: Double) -> String {
        LoadFormatter(unit: unit).zeroOrOneDecimal(value)
    }
}
