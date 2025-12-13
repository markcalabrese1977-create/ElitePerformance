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

    // State for "Apply to future" feedback
    @State private var showApplyAlert = false
    @State private var applyAlertMessage = ""

    /// Rebuild set-by-set data by finding the underlying Session
    /// that produced this SessionHistory (same date + weekIndex).
    private var exerciseDetails: [HistoryExerciseDetail] {
        guard let session = fetchSourceSession() else {
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
                let reps = (set.actualReps ?? set.plannedReps) ?? 0
                let load = (set.actualLoad ?? set.plannedLoad) ?? 0.0
                let rir  = (set.actualRIR ?? set.plannedRIR)

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

                // Apply-to-future button
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

    // MARK: - Helpers

    /// Find the live Session that produced this history entry.
    private func fetchSourceSession() -> Session? {
        let targetDate = history.date
        let targetWeekIndex = history.weekIndex

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { session in
                session.date == targetDate && session.weekIndex == targetWeekIndex
            }
        )

        return try? context.fetch(descriptor).first
    }

    /// Take what actually happened in this session and push it forward to
    /// all *future* sessions on the same weekday that share the same exercises.
    private func applyForwardToFutureSessions() {
        let calendar = Calendar.current

        guard let sourceSession = fetchSourceSession() else {
            applyAlertMessage = "Could not find the original session for this recap."
            showApplyAlert = true
            return
        }

        do {
            // Build UI model from the completed session so we can see per-set actuals.
            let vm = SessionScreenViewModel(session: sourceSession)

            let weekday = calendar.component(.weekday, from: sourceSession.date)

            // Fetch all sessions; we'll filter in Swift.
            let descriptor = FetchDescriptor<Session>()
            let allSessions = try context.fetch(descriptor)

            // Future sessions on the same weekday, not yet completed.
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
                    // Match by exerciseId across sessions
                    guard let targetItem = target.items.first(where: { $0.exerciseId == uiEx.exerciseId }) else {
                        continue
                    }

                    // How many sets are we really using from this completed session?
                    let workingSetCount = max(1, min(uiEx.targetSets, uiEx.sets.count))

                    var plannedLoads: [Double] = []
                    var plannedReps: [Int] = []
                    var plannedRIRs: [Int] = []

                    for idx in 0..<workingSetCount {
                        let set = uiEx.sets[idx]
                        let reps = (set.actualReps ?? set.plannedReps) ?? 0
                        let load = (set.actualLoad ?? set.plannedLoad) ?? 0.0
                        let rir  = (set.actualRIR ?? set.plannedRIR) ?? 0

                        // Only copy meaningful work sets
                        guard reps > 0, load > 0 else { continue }

                        plannedReps.append(reps)
                        plannedLoads.append(load)
                        plannedRIRs.append(rir)
                    }

                    guard !plannedReps.isEmpty, !plannedLoads.isEmpty else {
                        // Nothing useful logged for this exercise, skip
                        continue
                    }

                    let fallbackReps = plannedReps.first ?? 10
                    let fallbackRIR  = plannedRIRs.first ?? 2

                    // Decide final set count for the plan (match existing plan shape but at least 4)
                    let setCount = max(4, max(targetItem.targetSets, plannedLoads.count))

                    // Pad out arrays so they match setCount
                    if plannedReps.count < setCount {
                        plannedReps.append(
                            contentsOf: repeatElement(fallbackReps, count: setCount - plannedReps.count)
                        )
                    }
                    if plannedLoads.count < setCount {
                        plannedLoads.append(
                            contentsOf: repeatElement(plannedLoads.last ?? 0.0, count: setCount - plannedLoads.count)
                        )
                    }
                    if plannedRIRs.count < setCount {
                        plannedRIRs.append(
                            contentsOf: repeatElement(fallbackRIR, count: setCount - plannedRIRs.count)
                        )
                    }

                    targetItem.plannedRepsBySet  = Array(plannedReps.prefix(setCount))
                    targetItem.plannedLoadsBySet = Array(plannedLoads.prefix(setCount))

                    // Update simple headline plan fields for this exercise.
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
