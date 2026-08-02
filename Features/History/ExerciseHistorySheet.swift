import SwiftUI
import SwiftData
import Charts

struct ExerciseHistorySheet: View {
    let exerciseId: String
    let exerciseName: String
    let currentWave: String?
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
    @State private var selectedWave: String? = nil // nil = All

    // MARK: - Derived

    private var availableWaves: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for e in entries {
            if let w = e.waveLabel, !seen.contains(w) {
                seen.insert(w)
                ordered.append(w)
            }
        }
        return ordered
    }

    private var filteredEntries: [ExerciseHistoryEntry] {
        guard let wave = selectedWave else { return entries }
        return entries.filter { $0.waveLabel == wave }
    }

    private var bestOverallE1RM: Double? {
        entries.compactMap { $0.bestE1RM }.max()
    }

    private var hasThinHistory: Bool { entries.count <= 1 }

    

    // MARK: - e1RM trend delta (same wave, consecutive entries)

    private func e1rmDelta(for entry: ExerciseHistoryEntry) -> Double? {
        guard let currentE1RM = entry.bestE1RM else { return nil }
        let sameWave = entries.filter { $0.waveLabel == entry.waveLabel }
        guard let idx = sameWave.firstIndex(where: { $0.id == entry.id }),
              idx + 1 < sameWave.count else { return nil }
        guard let prevE1RM = sameWave[idx + 1].bestE1RM else { return nil }
        return currentE1RM - prevE1RM
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if entries.isEmpty {
                        Text("No logged sets yet for \(exerciseName).")
                            .foregroundStyle(.secondary)
                            .padding(.top, 30)
                    } else {
                        e1rmChart
                        if availableWaves.count > 1 {
                            waveFilter
                        }
                        ForEach(filteredEntries) { entry in
                            historyRow(entry)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .navigationTitle(exerciseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close", action: onClose)
                }
            }
        }
        .task { loadHistory() }
    }

    

    // MARK: - e1RM Sparkline Chart

    private var e1rmChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Estimated 1RM trend")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            let chartEntries = entries
                .filter { $0.bestE1RM != nil }
                .reversed()

            if chartEntries.isEmpty {
                Text("No e1RM data yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(chartEntries.enumerated()), id: \.element.id) { idx, entry in
                        LineMark(
                            x: .value("Session", idx),
                            y: .value("e1RM", entry.bestE1RM ?? 0)
                        )
                        .foregroundStyle(waveColor(entry.waveLabel))
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value("Session", idx),
                            y: .value("e1RM", entry.bestE1RM ?? 0)
                        )
                        .foregroundStyle(waveColor(entry.waveLabel))
                        .symbolSize(30)
                    }
                }
                .frame(height: 100)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v))")
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }

                // Wave legend — only show waves that appear in chart
                let chartWaves = Array(Set(chartEntries.compactMap { $0.waveLabel })).sorted()
                if chartWaves.count > 1 {
                    HStack(spacing: 12) {
                        ForEach(chartWaves, id: \.self) { wave in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(waveColor(wave))
                                    .frame(width: 6, height: 6)
                                Text(wave)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Wave Filter

    private var waveFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill(label: "All", wave: nil)
                ForEach(availableWaves, id: \.self) { wave in
                    filterPill(label: wave, wave: wave)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func filterPill(label: String, wave: String?) -> some View {
        let isSelected = selectedWave == wave
        return Button {
            selectedWave = wave
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? waveColor(wave).opacity(0.2) : Color(.secondarySystemBackground))
                .foregroundStyle(isSelected ? waveColor(wave) : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? waveColor(wave).opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - History Row

    @ViewBuilder
    private func historyRow(_ entry: ExerciseHistoryEntry) -> some View {
        let isBest: Bool = {
            guard let best = bestOverallE1RM, let e1 = entry.bestE1RM else { return false }
            return abs(e1 - best) < 0.5
        }()

        let delta = e1rmDelta(for: entry)

        let isCurrentWave: Bool = {
            guard let current = currentWave else { return true }
            return entry.waveLabel == current
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

                HStack(spacing: 8) {
                    if let wave = entry.waveLabel {
                        Text(wave)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(waveColor(wave))
                    }

                    if let delta {
                        deltaBadge(delta)
                    }
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
            .opacity(isCurrentWave ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func deltaBadge(_ delta: Double) -> some View {
        let isPositive = delta > 0.5
        let isNegative = delta < -0.5
        let label: String = {
            if isPositive { return "↑ +\(Int(delta.rounded())) e1RM" }
            if isNegative { return "↓ \(Int(delta.rounded())) e1RM" }
            return "→ same"
        }()
        let color: Color = isPositive ? .green : (isNegative ? .orange : .secondary)

        Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Wave color

    private func waveColor(_ wave: String?) -> Color {
        switch wave?.lowercased() {
        case "strength":     return .red
        case "hypertrophy":  return .blue
        case "intensification": return .purple
        case "deload":       return .green
        default:             return .secondary
        }
    }

    // MARK: - Load history

    private func waveDisplayName(from raw: String?, mesoName: String? = nil) -> String? {
        WaveType.label(forRaw: raw, mesoName: mesoName)
    }

    private func prescriptionLabel(repMin: Int?, repMax: Int?, rirMin: Int?, rirMax: Int?) -> String? {
        var parts: [String] = []
        if let repMin, let repMax {
            parts.append(repMin == repMax ? "\(repMin) reps" : "\(repMin)–\(repMax) reps")
        }
        if let rirMin, let rirMax {
            parts.append(rirMin == rirMax ? "\(rirMin) RIR" : "\(rirMin)–\(rirMax) RIR")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func loadHistory() {
        do {
            var descriptor = FetchDescriptor<Session>()
            descriptor.sortBy = [SortDescriptor(\Session.date, order: .reverse)]
            let sessions = try context.fetch(descriptor)
            let bodyWeight = try? context.fetch(FetchDescriptor<UserProfile>()).first?.bodyWeight
            var built: [ExerciseHistoryEntry] = []
            let targetExerciseId = ExerciseCatalog.resolvedExerciseId(
                rawId: exerciseId,
                snapshotName: exerciseName,
                fallbackName: exerciseName
            )

            for session in sessions {
                guard session.items.contains(where: {
                    ExerciseCatalog.resolvedExerciseId(
                        rawId: $0.exerciseId,
                        snapshotName: $0.exerciseNameSnapshot,
                        fallbackName: nil
                    ) == targetExerciseId
                }) else { continue }

                let vm = SessionScreenViewModel(session: session)
                let uiEx =
                    vm.exercises.first(where: {
                        ExerciseCatalog.resolvedExerciseId(
                            rawId: $0.exerciseId,
                            snapshotName: $0.name,
                            fallbackName: $0.name
                        ) == targetExerciseId
                    }) ??
                    vm.exercises.first(where: { $0.name == exerciseName })

                guard let uiEx else { continue }

                let waveLabel = waveDisplayName(from: uiEx.waveRaw, mesoName: session.meso?.name)
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
                    let effLoad = E1RMCalculator.effectiveLoad(
                        actualLoad: load,
                        exerciseId: targetExerciseId,
                        bodyWeight: bodyWeight
                    )
                    let rir = set.actualRIR ?? set.plannedRIR
                    executedSetCount += 1
                    repsTotal += reps
                    volumeTotal += effLoad * Double(reps)
                    if load > 0 {
                        let e1 = estimate1RM(load: load, reps: reps)
                        bestE1RM = max(bestE1RM ?? 0, e1)
                    }
                    executedTokens.append(
                        formatSetToken(
                            load: load, reps: reps, rir: rir,
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

            // Pre-select current wave filter if provided
            if let current = currentWave, availableWaves.contains(current) {
                selectedWave = current
            }

        } catch {
            print("⚠️ Failed to load ExerciseHistorySheet sessions: \(error)")
        }
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
            if load == 0, ExerciseCatalog.isBodyweight(exerciseId: exerciseId) { return "BW" }
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
