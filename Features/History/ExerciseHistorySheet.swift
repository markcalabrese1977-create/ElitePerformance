import SwiftUI
import SwiftData

struct ExerciseHistorySheet: View {
    let exerciseName: String
    let onClose: () -> Void

    @Environment(\.modelContext) private var context

    // Fetch all SessionHistory rows; we’ll filter per-exercise in memory.
    private var history: [SessionHistory] {
        let descriptor = FetchDescriptor<SessionHistory>()
        do {
            return try context.fetch(descriptor)
        } catch {
            print("⚠️ Failed to fetch SessionHistory: \(error)")
            return []
        }
    }

    // One row in the history list
    private struct ExerciseHistoryEntry: Identifiable {
        let id = UUID()
        let date: Date
        let weekIndex: Int
        let sets: Int
        let reps: Int
        let volume: Double
        let detail: String          // e.g. "140×12, 140×12, 140×12, 140×12"
        let estimated1RM: Double?   // top e1RM for that day
    }

    // Date formatter to match 12/7/25 style
    private static let df: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        return df
    }()

    private var entries: [ExerciseHistoryEntry] {
        history.compactMap { sessionHistory in
            // Find this exercise in the recap for set/rep/volume totals
            guard let ex = sessionHistory.exercises.first(where: { $0.name == exerciseName }) else {
                return nil
            }

            var detailParts: [String] = []
            var bestE1RM: Double? = nil

            // Try to find the underlying Session so we can reconstruct set-by-set detail (including RP)
            do {
                // Fetch all sessions, then filter in memory to match this history row
                let descriptor = FetchDescriptor<Session>()
                let sessions = try context.fetch(descriptor)

                if let session = sessions.first(where: {
                    $0.date == sessionHistory.date && $0.weekIndex == sessionHistory.weekIndex
                }) {

                    // ✅ Use the same reconstruction pipeline as the live Session screen so we get RP fields.
                    let vm = SessionScreenViewModel(session: session)

                    // Try to match the exercise by name in the reconstructed UI list
                    if let uiEx = vm.exercises.first(where: { $0.name == exerciseName }) {

                        for set in uiEx.sets where set.index <= uiEx.targetSets {
                            // Executed set = has actual reps
                            let actualReps = set.actualReps ?? 0
                            let didExecute = actualReps > 0
                            guard didExecute else { continue }   // program history: show executed sets only

                            let reps = actualReps
                            let load = set.actualLoad ?? 0
                            let rir = set.actualRIR ?? set.plannedRIR

                            // --- e1RM tracking (Epley) --- (only meaningful when load > 0)
                            if load > 0 {
                                let e1rm = load * (1.0 + Double(reps) / 30.0)
                                if let currentBest = bestE1RM {
                                    if e1rm > currentBest { bestE1RM = e1rm }
                                } else {
                                    bestE1RM = e1rm
                                }
                            }

                            // --- Detail string for this set (✅ now includes RP) ---
                            let part = formatSetToken(
                                load: load,
                                reps: reps,
                                rir: rir,
                                usedRP: set.usedRestPause,
                                rpPattern: set.restPausePattern
                            )

                            detailParts.append(part)
                        }
                    }
                }
            } catch {
                print("⚠️ Failed to fetch Session for history row: \(error)")
            }

            let detailText = detailParts.isEmpty
                ? ""
                : detailParts.joined(separator: ", ")

            return ExerciseHistoryEntry(
                date: sessionHistory.date,
                weekIndex: sessionHistory.weekIndex,
                sets: ex.sets,
                reps: ex.reps,
                volume: ex.volume,
                detail: detailText,
                estimated1RM: bestE1RM
            )
        }
        // Newest first
        .sorted { $0.date > $1.date }
    }

    private var bestOverallE1RM: Double? {
        entries.compactMap { $0.estimated1RM }.max()
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                // Header with Close + title
                HStack {
                    Button(action: onClose) {
                        Text("Close")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Text(exerciseName)
                        .font(.title3)
                        .fontWeight(.semibold)

                    Spacer()
                    Color.clear.frame(width: 80) // balance Close button
                }
                .padding(.horizontal)
                .padding(.top, 12)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(entries) { entry in
                            historyRow(entry)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: ExerciseHistoryEntry) -> some View {
        let isBest: Bool = {
            guard let best = bestOverallE1RM,
                  let e1 = entry.estimated1RM else { return false }
            return abs(e1 - best) < 0.5   // fuzzy match
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.df.string(from: entry.date))
                    .font(.headline)
                Spacer()
                Text("Week \(entry.weekIndex)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text("Sets: \(entry.sets)")
                Text("Reps: \(entry.reps)")
                Text("Vol: \(Int(entry.volume))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let e1 = entry.estimated1RM {
                HStack(spacing: 6) {
                    Text("Top est 1RM: \(Int(e1.rounded()))")
                        .font(.caption2)
                        .fontWeight(.semibold)

                    if isBest {
                        Text("Best so far")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground))
        )
    }
    private func formatSetToken(load: Double, reps: Int, rir: Int?, usedRP: Bool, rpPattern: String) -> String {
        let loadString: String = {
            if load == 0 { return "BW" }
            if load == floor(load) { return String(format: "%.0f", load) }
            return String(format: "%.1f", load)
        }()

        var s = "\(loadString)×\(reps)"
        if let rir { s += " @ RIR \(rir)" }

        if usedRP {
            let trimmed = rpPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            s += trimmed.isEmpty ? " (RP)" : " (RP: \(trimmed))"
        }
        return s
    }
}
