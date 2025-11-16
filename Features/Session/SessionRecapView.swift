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

            Section(header: Text("Next session adjustments")) {
                nextAdjustmentsSection
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

    /// Items for which the coaching engine has a concrete next-load suggestion.
    private var itemsWithRecommendations: [SessionItem] {
        sortedItems.filter {
            if let rec = CoachingEngine.recommend(for: $0),
               rec.nextSuggestedLoad != nil {
                return true
            }
            return false
        }
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

    private var nextAdjustmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if itemsWithRecommendations.isEmpty {
                Text("No load changes suggested. Repeat today’s prescription next time.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(itemsWithRecommendations) { item in
                    if let rec = CoachingEngine.recommend(for: item),
                       let next = rec.nextSuggestedLoad {

                        let exerciseName = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })?.name
                            ?? "Unknown exercise"

                        let baseline = baselineLoad(for: item)

                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exerciseName)
                                    .font(.subheadline)

                                // Shortened coach message for quick scan
                                Text(rec.message)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                if let base = baseline, base > 0 {
                                    Text(String(format: "%.1f → %.1f", base, next))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                } else {
                                    Text(String(format: "Next: %.1f lb", next))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }

                                Text("Next session target")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
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

    /// Baseline working load used this session, based on actuals.
    /// Falls back to suggestedLoad if actuals are all zero.
    private func baselineLoad(for item: SessionItem) -> Double? {
        let nonZeroActuals = item.actualLoads.filter { abs($0) > 0.1 }
        if let first = nonZeroActuals.first {
            return first
        }

        if item.suggestedLoad > 0 {
            return item.suggestedLoad
        }

        // As last resort, check planned loads
        let nonZeroPlanned = item.plannedLoadsBySet.filter { abs($0) > 0.1 }
        return nonZeroPlanned.first
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

    /// CoachingEngine-driven recommendation for this exercise, based on plan vs actual.
    private var coachingRecommendation: CoachingRecommendation? {
        CoachingEngine.recommend(for: item)
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

            if let rec = coachingRecommendation {
                Text(rec.message)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.top, 4)

                if let next = rec.nextSuggestedLoad {
                    Text("Next time target: \(next, specifier: "%.1f") lb")                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
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

// MARK: - SessionItem helpers for recap

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
            if reps > 0 {
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
}
