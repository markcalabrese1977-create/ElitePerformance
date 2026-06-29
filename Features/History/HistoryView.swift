import SwiftUI
import SwiftData

// MARK: - History List

struct HistoryView: View {
    @Query(sort: \SessionHistory.date, order: .reverse)
    private var sessions: [SessionHistory]

    /// Group by day for headers like "December 9, 2025"
    private var groupedSessions: [(date: Date, sessions: [SessionHistory])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: sessions) { s in
            calendar.startOfDay(for: s.date)
        }

        return groups
            .map { (date: $0.key, sessions: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    NavigationLink {
                        HistorySummaryView()
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Block recap")
                                .font(.headline)

                            Text("See best lifts, total volume, and how often you’ve trained each exercise this block.")
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
                    .buttonStyle(.plain)

                    if sessions.isEmpty {
                        Text("No history yet.")
                            .font(.headline)
                            .padding(.top, 12)

                        Text("Complete a session from the Today tab and it will appear here.")
                            .foregroundStyle(.secondary)
                    } else {
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
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("History")
        }
    }
}

// MARK: - History Row

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

// MARK: - Per-set detail structs (UI-only)

private struct HistorySetDetail: Identifiable {
    let id = UUID()
    let index: Int
    let load: Double
    let reps: Int
    let rir: Int?
    let isSkipped: Bool
    let feedback: SetFeedback
    let pumpRating: PumpRating
    let exerciseId: String

    let rpUsed: Bool
    let rpPattern: String

    private func loadText(_ load: Double) -> String {
        if load == 0, ExerciseCatalog.isBodyweight(exerciseId: exerciseId) { return "BW" }
        return String(format: "%.0f", load)
    }

    var lineText: String {
        if isSkipped {
            let reason: String = {
                switch feedback {
                case .pain: return "pain"
                case .soreness: return "soreness"
                case .disruption: return "disruption"
                case .fatigue: return "fatigue"
                case .none: return "skipped"
                }
            }()
            var s = "Set \(index) — \(reason) (planned \(loadText(load)) × \(reps)"
            if let rir { s += " @ \(rir) RIR" }
            s += ")"
            return s
        } else {
            var s = "Set \(index)  \(loadText(load)) × \(reps)"
            if let rir { s += " @ \(rir) RIR" }
            if rpUsed {
                let trimmed = rpPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                s += trimmed.isEmpty ? " (RP)" : " (RP: \(trimmed))"
            }
            if pumpRating != .none {
                s += " · \(pumpRating.label) pump"
            }
            return s
        }
    }
    var displayColor: Color {
            switch feedback {
            case .pain: return Color.red.opacity(0.8)
            case .soreness: return Color.yellow.opacity(0.8)
            case .disruption: return Color.orange.opacity(0.8)
            case .fatigue: return Color.purple.opacity(0.8)
            case .none: return isSkipped ? Color(UIColor.tertiaryLabel) : Color(UIColor.secondaryLabel)
            }
        }
}

private struct HistoryExerciseDetail: Identifiable {
    let id = UUID()
    let name: String
    let primaryMuscle: String?

    let waveLabel: String?
    let prescriptionLabel: String?
    let executionNote: String?

    let totalSets: Int
    let totalReps: Int
    let totalVolume: Double
    let sets: [HistorySetDetail]
}

// MARK: - Day Detail

private struct HistoryDayDetailView: View {
    @Environment(\.modelContext) private var context
    let history: SessionHistory



    private var sourceSession: Session? {
        fetchSourceSession()
    }

    private func waveDisplayName(from raw: String?) -> String? {
        WaveType.label(forRaw: raw, mesoName: sourceSession?.meso?.name)
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
    
    private var exerciseDetails: [HistoryExerciseDetail] {
        // If we can reconstruct from the original Session, do it (gives per-set loads).
        if let session = sourceSession {
            let vm = SessionScreenViewModel(session: session)

            return vm.exercises.map { uiEx in
                let catalog = ExerciseCatalog.all.first(where: { $0.id == uiEx.exerciseId })
                let primary = catalog?.primaryMuscle.rawValue.capitalized

                let waveLabel = waveDisplayName(from: uiEx.waveRaw)
                    ?? waveDisplayName(from: vm.exercises.compactMap { $0.waveRaw }.first)
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

                var totalReps = 0
                var totalVol: Double = 0
                var setDetails: [HistorySetDetail] = []

                let working = min(uiEx.targetSets, uiEx.sets.count)

                for idx in 0..<working {
                    let set = uiEx.sets[idx]

                    let actualReps = set.actualReps ?? 0
                    let actualLoad = set.actualLoad ?? 0

                    let plannedReps = set.plannedReps ?? 0
                    let plannedLoad = set.plannedLoad ?? 0

                    if actualReps > 0 {
                        let rir = set.actualRIR ?? set.plannedRIR

                        // ✅ If actual load isn't present, fall back to planned load for display + volume.
                        let displayLoad: Double = {
                            if actualLoad > 0 { return actualLoad }
                            if plannedLoad > 0 { return plannedLoad }
                            return 0
                        }()

                        totalReps += actualReps
                        totalVol += Double(actualReps) * displayLoad

                        setDetails.append(
                                                    HistorySetDetail(
                                                        index: set.index,
                                                        load: displayLoad,
                                                        reps: actualReps,
                                                        rir: rir,
                                                        isSkipped: false,
                                                        feedback: .none,
                                                        pumpRating: set.pumpRating,
                                                        exerciseId: uiEx.exerciseId,
                                                        rpUsed: set.usedRestPause,
                                                        rpPattern: set.restPausePattern
                                                    )
                                                )
                    } else if plannedReps > 0 {
                        setDetails.append(
                                                    HistorySetDetail(
                                                        index: set.index,
                                                        load: plannedLoad,
                                                        reps: plannedReps,
                                                        rir: set.plannedRIR,
                                                        isSkipped: true,
                                                        feedback: set.status.feedbackValue,
                                                        pumpRating: .none,
                                                        exerciseId: uiEx.exerciseId,
                                                        rpUsed: false,
                                                        rpPattern: ""
                                                    )
                                                )
                    }
                }

                return HistoryExerciseDetail(
                    name: uiEx.name,
                    primaryMuscle: primary,
                    waveLabel: waveLabel,
                    prescriptionLabel: prescription,
                    executionNote: note,
                    totalSets: setDetails.filter { !$0.isSkipped }.count,
                    totalReps: totalReps,
                    totalVolume: totalVol,
                    sets: setDetails
                )
            }
        }

        // Fallback: use the persisted summary only (no per-set loads exist in SessionHistoryExercise).
        return history.exercises.map { ex in
            HistoryExerciseDetail(
                name: ex.name,
                primaryMuscle: ex.primaryMuscle,
                waveLabel: nil,
                prescriptionLabel: nil,
                executionNote: nil,
                totalSets: ex.sets,
                totalReps: ex.reps,
                totalVolume: ex.volume,
                sets: []
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
                workoutMetricsCard

                if let s = sourceSession {
                    NavigationLink {
                        SessionView(session: s)
                    } label: {
                        Label("Edit this session", systemImage: "pencil")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }

                exerciseBreakdown
            }
            .padding()
        }
        .navigationTitle("Session Recap")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Cards

    private var headerCard: some View {
        let historyLabel = history.dayLabelSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionLabel = sourceSession?.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDayLabel = (historyLabel?.isEmpty == false) ? historyLabel : ((sessionLabel?.isEmpty == false) ? sessionLabel : nil)

        return VStack(alignment: .leading, spacing: 8) {
            if let resolvedDayLabel {
                Text(resolvedDayLabel)
                    .font(.headline)
            }

            Text(history.date, format: .dateTime.month().day().year())
                .font(resolvedDayLabel == nil ? .headline : .subheadline)
                .foregroundStyle(resolvedDayLabel == nil ? .primary : .secondary)

            Text("Week \(history.weekIndex)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let blockName = history.mesoBlockNameSnapshot,
               !blockName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(blockName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text("Exercises").font(.caption).foregroundStyle(.secondary)
                    Text("\(history.totalExercises)").font(.headline)
                }

                Spacer()

                VStack(alignment: .leading) {
                    Text("Sets completed").font(.caption).foregroundStyle(.secondary)
                    Text("\(history.totalSets)").font(.headline)
                }

                Spacer()

                VStack(alignment: .leading) {
                    Text("Total volume").font(.caption).foregroundStyle(.secondary)
                    Text("\(Int(history.totalVolume))").font(.headline)
                }
            }

            if let mechLoad = history.mechanicalLoad, mechLoad > 0 {
                HStack {
                    Text("Mechanical load").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f", mechLoad)).font(.caption)
                }
            }

            if totalReps > 0 {
                HStack {
                    Text("Total reps").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(totalReps)").font(.caption)
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

    @ViewBuilder
    private var workoutMetricsCard: some View {
        if let s = sourceSession {
            if s.hkWorkoutUUID == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Workout metrics").font(.headline)
                    Text("Not linked yet.").font(.caption).foregroundStyle(.secondary)
                    Text("Finish your Apple Watch workout, then tap below to pull in Apple Health metrics.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { @MainActor in
                            await HealthKitWorkoutSummarySyncService.syncForCompletedSession(s, in: context)
                        }
                    } label: {
                        Label("Link Apple Health metrics", systemImage: "heart.text.square")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.systemBackground))
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Workout metrics").font(.headline)

                    // HR sparklines (only when series exists)
                    if !s.hkHeartRateSeriesBPM.isEmpty, s.hkHeartRateSeriesStepSeconds > 0 {
                        HeartRateSparklineView(
                            title: "Heart rate (workout)",
                            series: s.hkHeartRateSeriesBPM,
                            stepSeconds: s.hkHeartRateSeriesStepSeconds,
                            height: 84
                        )
                    }

                    if !s.hkPostWorkoutHeartRateBPM.isEmpty, s.hkPostWorkoutHeartRateStepSeconds > 0 {
                        HeartRateSparklineView(
                            title: "Recovery (post-workout)",
                            series: s.hkPostWorkoutHeartRateBPM,
                            stepSeconds: s.hkPostWorkoutHeartRateStepSeconds,
                            height: 72
                        )
                    }

                    HStack {
                        metricBlock(title: "Duration", value: formatDuration(s.hkDuration))
                        Spacer()
                        metricBlock(title: "Total cals", value: formatNumber(s.hkTotalCalories))
                    }

                    HStack {
                        metricBlock(title: "Active cals", value: formatNumber(s.hkActiveCalories))
                        Spacer()
                        metricBlock(title: "Avg HR", value: formatNumber(s.hkAvgHeartRate))
                        Spacer()
                        metricBlock(title: "Max HR", value: formatNumber(s.hkMaxHeartRate))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.systemBackground))
                )
            }
        } else {
            EmptyView()
        }
    }

    private func metricBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
    }

    private func formatNumber(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        return "\(Int(value.rounded()))"
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return "\(m):" + String(format: "%02d", s)
    }

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

                        if let wave = ex.waveLabel {
                            Text(wave)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.blue)
                        }

                        if let prescription = ex.prescriptionLabel {
                            Text(prescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let note = ex.executionNote {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .italic()
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 12) {
                            if let primary = ex.primaryMuscle { Text(primary) }
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
                                                                    .foregroundStyle(set.displayColor)
                                                                    .strikethrough(set.isSkipped)
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

    // MARK: - Session matching

    private func fetchSourceSession() -> Session? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: history.date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!

        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { s in
                s.date >= start && s.date < end
            }
        )
        descriptor.fetchLimit = 50

        let matches = (try? context.fetch(descriptor)) ?? []
        guard !matches.isEmpty else { return nil }
        let historyBlockId = history.mesoBlockId

        func hasAnyActuals(_ s: Session) -> Bool {
            for item in s.items {
                if item.actualReps.contains(where: { $0 > 0 }) { return true }
                if item.actualLoads.contains(where: { $0 > 0 }) { return true }
            }
            return false
        }

        func score(_ s: Session) -> Int {
            var x = 0
            if s.status == .completed { x += 100 }
            if hasAnyActuals(s) { x += 50 }
            if s.hkWorkoutUUID != nil { x += 10 }
            x += min(10, s.items.count)

            if let historyBlockId, s.meso?.id == historyBlockId {
                x += 500
            }

            return x
        }

        return matches.sorted {
            let a = score($0), b = score($1)
            if a != b { return a > b }
            return $0.date > $1.date
        }.first
    }

    // MARK: - Apply forward

    
}

// MARK: - Preview

struct HistoryView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryView()
            .modelContainer(for: SessionHistory.self, inMemory: true)
    }
}
