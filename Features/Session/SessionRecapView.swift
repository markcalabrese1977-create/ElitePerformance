import SwiftUI
import SwiftData

/// Detailed recap of a single session: planned vs logged, volume, per-exercise status,
/// end-of-session readiness + notes, and per-set breakdowns.
struct SessionRecapView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: Session

    var body: some View {
        List {
            Section {
                header
            }

            // Readiness rating + notes
            Section(header: Text("Readiness & Notes")) {
                readinessSection
                notesSection
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

    /// Binding to session.sessionNotes, treating nil as empty string.
    private var notesBinding: Binding<String> {
        Binding(
            get: { session.sessionNotes ?? "" },
            set: { newValue in
                session.sessionNotes = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private var clampedStars: Int {
        max(0, min(session.readinessStars, 5))
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

    // Readiness stars + labels
    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How ready did you feel today?")
                    .font(.subheadline)
                Spacer()
                if clampedStars > 0 {
                    Text("\(clampedStars) ★")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } else {
                    Text("Not set")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        session.readinessStars = star
                    } label: {
                        Image(systemName: star <= clampedStars ? "star.fill" : "star")
                            .imageScale(.large)
                            .foregroundColor(star <= clampedStars ? .yellow : .gray)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Text("1 = Drained")
                    .font(.caption2)
                Spacer()
                Text("5 = Locked in")
                    .font(.caption2)
            }
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    // Notes editor
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes for next time")
                .font(.subheadline)

            TextEditor(text: notesBinding)
                .frame(minHeight: 100)
                .padding(6)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
        }
        .padding(.vertical, 4)
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
    /// Falls back to suggestedLoad or plannedLoadsBySet if needed.
    private func baselineLoad(for item: SessionItem) -> Double? {
        let nonZeroActuals = item.actualLoads.filter { abs($0) > 0.1 }
        if let first = nonZeroActuals.first {
            return first
        }

        if item.suggestedLoad > 0 {
            return item.suggestedLoad
        }

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
            // Header + status
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

            // Planned vs logged overview
            VStack(alignment: .leading, spacing: 2) {
                Text("Planned: \(plannedSets) sets · top reps \(plannedTopReps)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Logged: \(item.loggedSetsCount) sets · best reps \(item.bestReps)")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                // Top set with RP pattern if used
                if let top = item.bestSetDescription {
                    Text("Top set: \(top)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
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

            // 🔹 Per-set breakdown
            if !item.loggedSetIndices.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sets")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(item.loggedSetIndices, id: \.self) { idx in
                        // Manual safe indexing so we don't rely on subscript(safe:)
                        let load: Double = idx < item.actualLoads.count ? item.actualLoads[idx] : 0
                        let reps: Int    = idx < item.actualReps.count  ? item.actualReps[idx]  : 0
                        let rir: Int?    = idx < item.actualRIRs.count  ? item.actualRIRs[idx]  : nil

                        HStack(spacing: 6) {
                            Text("Set \(idx + 1)")
                                .font(.caption2)
                                .frame(width: 46, alignment: .leading)

                            Text(String(format: "%.1f x %d", load, reps))
                                .font(.caption2)

                            if let rir {
                                Text("RIR \(rir)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if let rp = item.restPauseDescription(forSetAt: idx) {
                                Text(rp)
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }

                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
            }

            // Recommendation / "what should I do next?"
            if let rec = coachingRecommendation {
                Text(rec.message)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.top, 4)

                if let next = rec.nextSuggestedLoad {
                    Text("Next time target: \(next, specifier: "%.1f") lb")
                        .font(.caption2)
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
            let load = actualLoads[i]
            if reps > 0 && load > 0 {
                logged += 1
            }
        }
        return logged
    }

    /// Indices of sets that have non-zero work logged.
    var loggedSetIndices: [Int] {
        let count = min(actualReps.count, actualLoads.count)
        guard count > 0 else { return [] }

        return (0..<count).filter { i in
            actualReps[i] > 0 && actualLoads[i] > 0
        }
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

    /// Index of the best (highest reps) set with non-zero load/reps.
    var bestSetIndex: Int? {
        let count = min(actualReps.count, actualLoads.count)
        guard count > 0 else { return nil }

        var bestIdx: Int?
        var bestRepsValue = -1

        for i in 0..<count {
            let reps = actualReps[i]
            let load = actualLoads[i]
            if reps > 0 && load > 0 && reps > bestRepsValue {
                bestRepsValue = reps
                bestIdx = i
            }
        }
        return bestIdx
    }

    /// Human-readable description of the top set, including RP pattern if used.
    /// e.g. "120.0 x 17 (RP: 10+4+3)"
    var bestSetDescription: String? {
        guard let idx = bestSetIndex else { return nil }
        guard idx < actualLoads.count, idx < actualReps.count else { return nil }

        let load = actualLoads[idx]
        let reps = actualReps[idx]
        guard reps > 0, load > 0 else { return nil }

        let base = String(format: "%.1f x %d", load, reps)

        let usedRP = idx < usedRestPauseFlags.count ? usedRestPauseFlags[idx] : false
        let pattern = idx < restPausePatternsBySet.count ? restPausePatternsBySet[idx] : ""

        if usedRP && !pattern.isEmpty {
            return base + " (RP: \(pattern))"
        } else {
            return base
        }
    }

    /// Description of rest-pause for a specific set index, e.g. "RP: 10+4+3".
    func restPauseDescription(forSetAt index: Int) -> String? {
        guard index < usedRestPauseFlags.count, usedRestPauseFlags[index] else {
            return nil
        }
        let pattern = index < restPausePatternsBySet.count ? restPausePatternsBySet[index] : ""
        if pattern.isEmpty {
            return "RP"
        } else {
            return "RP: \(pattern)"
        }
    }
}


