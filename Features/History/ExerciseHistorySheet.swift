import SwiftUI
import SwiftData

struct ExerciseHistorySheet: View {
    let exerciseId: String
    let exerciseName: String
    let onClose: () -> Void

    @Environment(\.modelContext) private var context

    private struct ExerciseHistoryEntry: Identifiable {
        let id = UUID()
        let date: Date
        let weekIndex: Int

        let waveLabel: String?
        let prescriptionLabel: String?

        let sets: Int
        let reps: Int
        let volume: Double
        let detail: String
        let bestE1RM: Double?
        let session: Session
    }

    private static let df: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        return df
    }()

    @State private var entries: [ExerciseHistoryEntry] = []

    private var bestOverallE1RM: Double? {
        entries.compactMap { $0.bestE1RM }.max()
    }

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
            Color.clear.frame(width: 80)
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

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

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func loadHistory() {
        do {
            var descriptor = FetchDescriptor<Session>()
            descriptor.sortBy = [SortDescriptor(\Session.date, order: .reverse)]

            let sessions = try context.fetch(descriptor)
            var built: [ExerciseHistoryEntry] = []

            for session in sessions {
                guard session.items.contains(where: { $0.exerciseId == exerciseId }) else { continue }

                let vm = SessionScreenViewModel(session: session)

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

                let target = max(0, uiEx.targetSets)
                var executedTokens: [String] = []
                var repsTotal = 0
                var volumeTotal: Double = 0
                var executedSetCount = 0
                var bestE1RM: Double? = nil

                for set in uiEx.sets where set.index <= target {
                    let reps = set.actualReps ?? 0
                    guard reps > 0 else { continue }

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

                guard executedSetCount > 0 else { continue }

                built.append(
                    ExerciseHistoryEntry(
                        date: session.date,
                        weekIndex: session.weekIndex,
                        waveLabel: waveLabel,
                        prescriptionLabel: prescription,
                        sets: executedSetCount,
                        reps: repsTotal,
                        volume: volumeTotal,
                        detail: executedTokens.joined(separator: ", "),
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

    @ViewBuilder
    private func historyRow(_ entry: ExerciseHistoryEntry) -> some View {
        let isBest: Bool = {
            guard let best = bestOverallE1RM,
                  let e1 = entry.bestE1RM else { return false }
            return abs(e1 - best) < 0.5
        }()

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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        .buttonStyle(.plain)
    }

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
