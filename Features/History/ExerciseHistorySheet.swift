import SwiftUI
import SwiftData

struct ExerciseHistorySheet: View {
    let exerciseId: String
    let exerciseName: String
    let onClose: () -> Void

    @Environment(\.modelContext) private var context

    // MARK: - Row model

    private struct ExerciseHistoryEntry: Identifiable {
        let id = UUID()
        let date: Date
        let weekIndex: Int

        let waveLabel: String?
        let prescriptionLabel: String?
        let executionNote: String?

        let sets: Int
        let reps: Int
        let volume: Double

        /// Executed sets only (includes RP tokens)
        let detail: String

        /// Best e1RM for the day (computed from executed sets where load > 0)
        let bestE1RM: Double?

        /// Used for drill-in
        let session: Session
    }

    // MARK: - Date format

    private static let df: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        return df
    }()

    // MARK: - State

    @State private var entries: [ExerciseHistoryEntry] = []

    private var bestOverallE1RM: Double? {
        entries.compactMap { $0.bestE1RM }.max()
    }

    // MARK: - View

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 16) {
                header

                ScrollView {
                    VStack(spacing: 12) {
                        if entries.isEmpty {
                            Text("No logged sets yet for \(exerciseName).")
                                .foregroundStyle(.secondary)
                                .padding(.top, 30)
                        } else {
                            ForEach(entries) { entry in
                                historyRow(entry)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
        }
        .task { loadHistory() }
    }

    private var header: some View {
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
    }

    // MARK: - Loading

    private func waveDisplayName(from raw: String?) -> String? {
        guard let raw else { return nil }

        switch raw.lowercased() {
        case "a":
            return "Strength"
        case "b":
            return "Hypertrophy"
        case "c":
            return "Intensification"
        case "deload":
            return "Deload"
        default:
            return raw.capitalized
        }
    }

    private func prescriptionLabel(
        repMin: Int?,
        repMax: Int?,
        rirMin: Int?,
        rirMax: Int?
    ) -> String? {
        var parts: [String] = []

        if let repMin, let repMax {
            if repMin == repMax {
                parts.append("\(repMin) reps")
            } else {
                parts.append("\(repMin)–\(repMax) reps")
            }
        }

        if let rirMin, let rirMax {
            if rirMin == rirMax {
                parts.append("\(rirMin) RIR")
            } else {
                parts.append("\(rirMin)–\(rirMax) RIR")
            }
        }

        if parts.isEmpty { return nil }
        return parts.joined(separator: " · ")
    }

    private func executionNote(
        intensifierNotes: String?,
        prescriptionNotes: String?
    ) -> String? {
        let intensifier = intensifierNotes?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let intensifier, !intensifier.isEmpty {
            return intensifier
        }

        let prescription = prescriptionNotes?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let prescription, !prescription.isEmpty {
            return prescription
        }

        return nil
    }
    
    private func loadHistory() {
        do {
            var descriptor = FetchDescriptor<Session>()
            descriptor.sortBy = [SortDescriptor(\Session.date, order: .reverse)]

            let sessions = try context.fetch(descriptor)
            var built: [ExerciseHistoryEntry] = []

            for session in sessions {
                // Must contain this exercise (by ID) in persisted items
                guard session.items.contains(where: { $0.exerciseId == exerciseId }) else { continue }

                // Reconstruct with the same pipeline as live session screen (gives RP fields)
                let vm = SessionScreenViewModel(session: session)

                // Find the reconstructed UI exercise by ID first, then fallback by name
                let uiEx =
                    vm.exercises.first(where: { $0.exerciseId == exerciseId }) ??
                    vm.exercises.first(where: { $0.name == exerciseName })

                guard let uiEx else { continue }
                
                let waveLabel = waveDisplayName(from: uiEx.waveRaw)
                let prescription = prescriptionLabel(
                    repMin: uiEx.repMin,
                    repMax: uiEx.repMax,
                    rirMin: uiEx.targetRIRMin,
                    rirMax: uiEx.targetRIRMax
                )
                let note = executionNote(
                    intensifierNotes: uiEx.intensifierNotes,
                    prescriptionNotes: uiEx.prescriptionNotes
                )

                // Build executed set tokens + totals from executed sets only
                let target = max(0, uiEx.targetSets)
                var executedTokens: [String] = []
                var repsTotal = 0
                var volumeTotal: Double = 0
                var executedSetCount = 0
                var bestE1RM: Double? = nil

                for set in uiEx.sets where set.index <= target {
                    let reps = set.actualReps ?? 0
                    guard reps > 0 else { continue } // executed only

                    let load = set.actualLoad ?? 0
                    let rir = set.actualRIR ?? set.plannedRIR

                    executedSetCount += 1
                    repsTotal += reps
                    volumeTotal += load * Double(reps)

                    if load > 0 {
                        let e1 = estimate1RM(load: load, reps: reps)
                        bestE1RM = max(bestE1RM ?? 0, e1)
                    }

                    executedTokens.append(
                        formatSetToken(
                            load: load,
                            reps: reps,
                            rir: rir,
                            usedRP: set.usedRestPause,
                            rpPattern: set.restPausePattern
                        )
                    )
                }

                // If there are no executed sets, skip showing the day (keeps history clean)
                guard executedSetCount > 0 else { continue }

                let detailText = executedTokens.joined(separator: ", ")

                built.append(
                    ExerciseHistoryEntry(
                        date: session.date,
                        weekIndex: session.weekIndex,
                        waveLabel: waveLabel,
                        prescriptionLabel: prescription,
                        executionNote: note,
                        sets: executedSetCount,
                        reps: repsTotal,
                        volume: volumeTotal,
                        detail: detailText,
                        bestE1RM: (bestE1RM == 0 ? nil : bestE1RM),
                        session: session
                    )
                )
            }

            entries = built
        } catch {
            print("⚠️ Failed to load ExerciseHistorySheet sessions: \(error)")
        }
    }

    // MARK: - Row UI

    @ViewBuilder
    private func historyRow(_ entry: ExerciseHistoryEntry) -> some View {
        let isBest: Bool = {
            guard let best = bestOverallE1RM,
                  let e1 = entry.bestE1RM else { return false }
            return abs(e1 - best) < 0.5
        }()

        // If you DON'T want drill-in, replace NavigationLink with a plain VStack.
        NavigationLink {
            ExerciseSessionDetailView(
                session: entry.session,
                exerciseId: exerciseId,
                exerciseName: exerciseName
            )
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Self.df.string(from: entry.date))
                        .font(.headline)
                    Spacer()
                    Text("Week \(entry.weekIndex)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let wave = entry.waveLabel {
                    Text(wave)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                }

                if let prescription = entry.prescriptionLabel {
                    Text(prescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let note = entry.executionNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .italic()
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    Text("Sets: \(entry.sets)")
                    Text("Reps: \(entry.reps)")
                    Text("Vol: \(formatVolume(entry.volume))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let e1 = entry.bestE1RM {
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
        .buttonStyle(.plain) // keeps your card style
    }

    // MARK: - Helpers

    private func estimate1RM(load: Double, reps: Int) -> Double {
        let r = max(1, reps)
        return load * (1.0 + Double(r) / 30.0)
    }

    private func formatVolume(_ v: Double) -> String {
        let iv = Int(v.rounded())
        return NumberFormatter.localizedString(from: NSNumber(value: iv), number: .decimal)
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
