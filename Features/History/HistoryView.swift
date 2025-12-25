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

                    // Block recap card at the top of History
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

                    // Existing per-day history list
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

                // Keeping your existing layout (even though it repeats the same date).
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
    let isSkipped: Bool

    var lineText: String {
        if isSkipped {
            // Example: "Set 3  — skipped (planned 90.0 × 15 @ 2 RIR)"
            let loadString = load == 0 ? "0" : String(format: "%.1f", load)
            var planned = "planned \(loadString) × \(reps)"
            if let rir { planned += " @ \(rir) RIR" }
            return "Set \(index)  — skipped (\(planned))"
        } else {
            let loadString = load == 0 ? "0" : String(format: "%.1f", load)
            var base = "Set \(index)  \(loadString) × \(reps)"
            if let rir { base += " @ \(rir) RIR" }
            return base
        }
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

    @State private var showApplyAlert = false
    @State private var applyAlertMessage = ""

    private var sourceSession: Session? {
        fetchSourceSession()
    }

    /// Rebuild set-by-set data by finding the underlying Session
    /// that produced this SessionHistory (same date + weekIndex).
    private var exerciseDetails: [HistoryExerciseDetail] {
        guard let session = sourceSession else {
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
                let actualReps = set.actualReps ?? 0
                let actualLoad = set.actualLoad ?? 0.0

                let plannedReps = set.plannedReps ?? 0
                let plannedLoad = set.plannedLoad ?? 0.0

                // Executed if actuals exist and are non-zero
                let didExecute = actualReps > 0 && actualLoad > 0

                if didExecute {
                    let rir = set.actualRIR ?? set.plannedRIR

                    totalReps += actualReps
                    totalVolume += Double(actualReps) * actualLoad

                    setDetails.append(
                        HistorySetDetail(
                            index: set.index,
                            load: actualLoad,
                            reps: actualReps,
                            rir: rir,
                            isSkipped: false
                        )
                    )
                } else {
                    // Only show a skipped row if there was a real planned prescription
                    guard plannedReps > 0, plannedLoad > 0 else { continue }

                    setDetails.append(
                        HistorySetDetail(
                            index: set.index,
                            load: plannedLoad,
                            reps: plannedReps,
                            rir: set.plannedRIR,
                            isSkipped: true
                        )
                    )
                }
            }

            return HistoryExerciseDetail(
                name: uiEx.name,
                primaryMuscle: primary,
                totalSets: setDetails.filter { !$0.isSkipped }.count,
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

                workoutMetricsCard

                Button {
                    applyForwardToFutureSessions()
                } label: {
                    Label("Apply to future sessions", systemImage: "arrowshape.turn.up.right.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                exerciseBreakdown
            }
            .padding()
        }
        .navigationTitle("Session Recap")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Apply to future", isPresented: $showApplyAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(applyAlertMessage)
        }
    }

    // MARK: - Cards

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

    /// ✅ HealthKit / Apple Fitness metrics for this session (if linked).
    @ViewBuilder
    private var workoutMetricsCard: some View {
        if let s = sourceSession {
            if s.hkWorkoutUUID == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Workout metrics")
                        .font(.headline)

                    Text("Not linked yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Finish your Apple Watch workout, then reopen this recap (or tap Done and open again).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.systemBackground))
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Workout metrics")
                        .font(.headline)

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

                    if let start = s.hkWorkoutStart, let end = s.hkWorkoutEnd {
                        Text("\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // ✅ Pretty HR (no local `let` declarations)
                    if !s.hkHeartRateSeriesBPM.isEmpty {
                        HeartRateSparkline(values: s.hkHeartRateSeriesBPM)
                    }

                    if (s.hkZone1Seconds + s.hkZone2Seconds + s.hkZone3Seconds + s.hkZone4Seconds + s.hkZone5Seconds) > 0 {
                        HeartRateZonesBar(
                            z1: s.hkZone1Seconds,
                            z2: s.hkZone2Seconds,
                            z3: s.hkZone3Seconds,
                            z4: s.hkZone4Seconds,
                            z5: s.hkZone5Seconds
                        )
                    }

                    if !s.hkPostWorkoutHeartRateBPM.isEmpty {
                        PostWorkoutHRMiniChart(values: s.hkPostWorkoutHeartRateBPM)
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
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
    }

    private func formatNumber(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        return "\(Int(value.rounded()))"
    }

    /// Formats seconds as MM:SS (e.g., 54:15)
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
                                        .foregroundStyle(set.isSkipped ? .tertiary : .secondary)
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

    // MARK: - Helpers

    private func fetchSourceSession() -> Session? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: history.date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let targetWeek = history.weekIndex

        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { s in
                s.date >= start &&
                s.date < end &&
                s.weekInMeso == targetWeek
            }
        )
        descriptor.fetchLimit = 1

        return try? context.fetch(descriptor).first
    }

    private func applyForwardToFutureSessions() {
        let calendar = Calendar.current

        guard let sourceSession = fetchSourceSession() else {
            applyAlertMessage = "Could not find the original session for this recap."
            showApplyAlert = true
            return
        }

        do {
            let vm = SessionScreenViewModel(session: sourceSession)
            let weekday = calendar.component(.weekday, from: sourceSession.date)

            let descriptor = FetchDescriptor<Session>()
            let allSessions = try context.fetch(descriptor)

            let targetSessions = allSessions.filter { other in
                other.id != sourceSession.id &&
                other.date > sourceSession.date &&
                other.status != .completed &&
                calendar.component(.weekday, from: other.date) == weekday
            }

            guard !targetSessions.isEmpty else {
                applyAlertMessage = "No future sessions on this day pattern to update."
                showApplyAlert = true
                return
            }

            for target in targetSessions {
                for uiEx in vm.exercises {
                    guard let targetItem = target.items.first(where: { $0.exerciseId == uiEx.exerciseId }) else {
                        continue
                    }

                    let workingSetCount = max(1, min(uiEx.targetSets, uiEx.sets.count))

                    var plannedLoads: [Double] = []
                    var plannedReps: [Int] = []
                    var plannedRIRs: [Int] = []

                    for idx in 0..<workingSetCount {
                        let set = uiEx.sets[idx]
                        let reps = (set.actualReps ?? set.plannedReps) ?? 0
                        let load = (set.actualLoad ?? set.plannedLoad) ?? 0.0
                        let rir  = (set.actualRIR ?? set.plannedRIR) ?? 0

                        guard reps > 0, load > 0 else { continue }

                        plannedReps.append(reps)
                        plannedLoads.append(load)
                        plannedRIRs.append(rir)
                    }

                    guard !plannedReps.isEmpty, !plannedLoads.isEmpty else { continue }

                    let fallbackReps = plannedReps.first ?? 10
                    let fallbackRIR  = plannedRIRs.first ?? 2

                    let setCount = max(4, max(targetItem.targetSets, plannedLoads.count))

                    if plannedReps.count < setCount {
                        plannedReps.append(contentsOf: repeatElement(fallbackReps, count: setCount - plannedReps.count))
                    }
                    if plannedLoads.count < setCount {
                        plannedLoads.append(contentsOf: repeatElement(plannedLoads.last ?? 0.0, count: setCount - plannedLoads.count))
                    }
                    if plannedRIRs.count < setCount {
                        plannedRIRs.append(contentsOf: repeatElement(fallbackRIR, count: setCount - plannedRIRs.count))
                    }

                    targetItem.plannedRepsBySet  = Array(plannedReps.prefix(setCount))
                    targetItem.plannedLoadsBySet = Array(plannedLoads.prefix(setCount))

                    targetItem.targetReps = fallbackReps
                    targetItem.targetRIR  = fallbackRIR

                    if let lastWorkingLoad = plannedLoads.prefix(workingSetCount).last {
                        targetItem.suggestedLoad = lastWorkingLoad
                    }
                }
            }

            try context.save()
            applyAlertMessage = "Applied today’s plan to \(targetSessions.count) future session(s) on this day."
            showApplyAlert = true
        } catch {
            print("⚠️ Failed to apply forward from history: \(error)")
            applyAlertMessage = "Something went wrong while updating future sessions."
            showApplyAlert = true
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






