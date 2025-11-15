import SwiftUI
import SwiftData

/// Detailed recap of a single session: planned vs logged, volume, and per-exercise status.
struct SessionRecapView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: Session

    var body: some View {
        List {
            Section {
                header
            }

            Section(header: Text("Summary")) {
                summaryRows
            }

            Section(header: Text("Exercises")) {
                ForEach(sortedItems) { item in
                    ExerciseRecapRow(item: item)
                }
            }
        }
        .navigationTitle("Session Recap")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Computed data

    private var sortedItems: [SessionItem] {
        session.items.sorted { $0.order < $1.order }
    }

    /// Planned sets based on the program, **not** what you logged.
    private var plannedSetsTotal: Int {
        sortedItems.reduce(0) { total, item in
            total + item.plannedSetCount
        }
    }

    private var loggedSetsTotal: Int {
        sortedItems.reduce(0) { partial, item in
            partial + item.loggedSetsCount
        }
    }

    private var completedExercises: Int {
        sortedItems.filter { $0.loggedSetsCount > 0 }.count
    }

    private var totalVolume: Double {
        sortedItems.reduce(0) { $0 + $1.totalVolume }
    }

    private var completionPercent: Double {
        guard plannedSetsTotal > 0 else { return 0 }
        return (Double(loggedSetsTotal) / Double(plannedSetsTotal)) * 100.0
    }

    // MARK: - UI pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.date, style: .date)
                .font(.headline)

            Text(session.status.displayTitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var summaryRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Exercises completed")
                Spacer()
                Text("\(completedExercises)/\(sortedItems.count)")
                    .fontWeight(.semibold)
            }

            HStack {
                Text("Sets logged")
                Spacer()
                Text("\(loggedSetsTotal)/\(plannedSetsTotal)")
                    .fontWeight(.semibold)
            }

            HStack {
                Text("Completion")
                Spacer()
                Text(String(format: "%.0f%%", completionPercent))
                    .fontWeight(.semibold)
            }

            HStack {
                Text("Total volume")
                Spacer()
                Text(formattedVolume(totalVolume))
                    .fontWeight(.semibold)
            }
        }
    }

    private func formattedVolume(_ volume: Double) -> String {
        if volume >= 10_000 {
            return String(format: "%.1fk", volume / 1000.0)
        } else {
            return String(format: "%.0f", volume)
        }
    }
}

// MARK: - Per-exercise recap row

struct ExerciseRecapRow: View {
    let item: SessionItem

    private var exercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    /// Planned set count from the program. This does **not** change when you log fewer sets.
    private var plannedSets: Int {
        item.plannedSetCount
    }

    /// Planned top rep target (max planned reps or targetReps as fallback).
    private var plannedTopReps: Int {
        item.plannedTopReps
    }

    private var volume: Double {
        item.totalVolume
    }

    private var status: (text: String, color: Color) {
        let logged = item.loggedSetsCount

        // 1) Nothing logged at all
        if logged == 0 {
            return ("Not logged", .secondary)
        }

        // 2) If you logged fewer sets than planned → always under
        if logged < plannedSets {
            return ("Low sets", .orange)
        }

        // 3) You logged at least as many sets as planned, now check reps
        let bestReps = item.actualReps.max() ?? 0

        if bestReps >= plannedTopReps {
            return ("On target", .green)
        } else {
            return ("Low reps", .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(exercise?.name ?? "Unknown exercise")
                    .font(.headline)

                Spacer()

                if item.isPR {
                    Text("PR")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2))
                        .foregroundColor(.purple)
                        .cornerRadius(6)
                }

                Text(status.text)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(status.color.opacity(0.2))
                    .foregroundColor(status.color)
                    .cornerRadius(6)
            }

            if let primary = exercise?.primaryMuscle.rawValue {
                Text(primary.capitalized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Debug / clarity: show what the logic is actually using
            VStack(alignment: .leading, spacing: 2) {
                Text("Planned: \(plannedSets) sets · top reps \(plannedTopReps)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Logged: \(item.loggedSetsCount) sets · best reps \(item.bestReps)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Planned summary")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(plannedSets)x\(plannedTopReps)  ·  RIR \(item.targetRIR)")
                    .font(.caption)
            }

            HStack {
                Text("Volume")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formattedVolume(volume))
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            // MARK: Recommendation / "what should I do next?"

            Text(item.recommendationNote)
                .font(.caption)
                .foregroundColor(.blue)
                .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }

    private func formattedVolume(_ volume: Double) -> String {
        if volume >= 10_000 {
            return String(format: "%.1fk", volume / 1000.0)
        } else {
            return String(format: "%.0f", volume)
        }
    }
}

// MARK: - SessionItem helpers for recap & recommendations

extension SessionItem {

    /// Planned set count from the program. If the program didn't specify per-set reps,
    /// fall back to targetSets.
    var plannedSetCount: Int {
        if plannedRepsBySet.count > 0 {
            return plannedRepsBySet.count
        } else {
            return max(targetSets, 1)
        }
    }

    /// Planned top reps from the program or targetReps.
    var plannedTopReps: Int {
        if let maxFromPlan = plannedRepsBySet.max() {
            return maxFromPlan
        } else {
            return targetReps
        }
    }

    /// Number of sets with any meaningful work logged.
    var loggedSetsCount: Int {
        let count = min(actualReps.count, actualLoads.count)
        guard count > 0 else { return 0 }

        var logged = 0
        for i in 0..<count {
            let reps = actualReps[i]
            let load = actualLoads[i]
            if reps > 0 && load > 0 {
                logged += 1
            }
        }
        return logged
    }

    /// Total volume = sum(load * reps) across logged sets.
    var totalVolume: Double {
        let count = min(actualReps.count, actualLoads.count)
        guard count > 0 else { return 0 }

        var sum: Double = 0
        for i in 0..<count {
            let reps = actualReps[i]
            let load = actualLoads[i]
            if reps > 0 && load > 0 {
                sum += Double(reps) * load
            }
        }
        return sum
    }

    /// Best reps across logged sets.
    var bestReps: Int {
        actualReps.max() ?? 0
    }

    /// Simple text recommendation for the *next* session, based on planned vs logged.
    ///
    /// This is the first real "coach brain" – it doesn't change data yet,
    /// but it tells you how to shape your next session.
    var recommendationNote: String {
        // 1) No work → repeat prescription
        if loggedSetsCount == 0 {
            return "No meaningful work logged. Repeat this prescription next time before progressing."
        }

        // 2) Fewer sets than planned → fix sets before anything else
        if loggedSetsCount < plannedSetCount {
            return "You didn’t complete all \(plannedSetCount) planned sets. Keep the same load and aim to hit every set before increasing weight."
        }

        // 3) Same or more sets than planned – now check reps and fatigue pattern
        let top = plannedTopReps
        let best = bestReps

        // Detect obvious fatigue crash: first set at/near target, last set well below.
        var fatigueCrash = false
        if actualReps.count >= 2 {
            let first = actualReps[0]
            let lastIndex = min(loggedSetsCount, actualReps.count) - 1
            let last = actualReps[lastIndex]

            if first >= top && last <= top - 3 {
                fatigueCrash = true
            }
        }

        if fatigueCrash {
            return "Reps dropped hard on later sets from fatigue. Hold the load and work toward more even reps across all sets before progressing."
        }

        // Strong overperformance: clearly above rep target
        if best >= top + 2 {
            return "You exceeded the rep target at this load. Increase weight slightly next session (about 2.5–5%) and keep the same number of sets."
        }

        // On target, but not massively over – repeat once more, then consider volume
        if best >= top {
            return "You hit the planned sets and reps. Repeat this load once more; if it feels easier, consider adding an extra set."
        }

        // Under reps but not a full crash – fix rep quality first
        return "Reps were below the target range. Keep the same load and focus on hitting the full rep target before progressing."
    }
}
