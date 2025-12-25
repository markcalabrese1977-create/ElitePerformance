import SwiftUI
import SwiftData

// MARK: - Public view

/// High-level history dashboard:
/// - Aggregates across all *completed* sessions
/// - Groups data by exercise
/// - Shows best e1RM, total volume, and last trained date.
struct HistorySummaryView: View {
    @Environment(\.modelContext) private var modelContext

    // Pull all Sessions; we'll filter in Swift.
    @Query(sort: \Session.date, order: .forward)
    private var sessions: [Session]

    /// Only completed sessions are considered for summary stats.
    private var completedSessions: [Session] {
        sessions.filter { $0.status == .completed }
    }

    /// Aggregated data per exercise across all completed sessions.
    private var exerciseSummaries: [ExerciseSummary] {
        HistorySummaryBuilder.build(from: completedSessions)
    }

    /// Top lifts by best e1RM.
    private var topLifts: [ExerciseSummary] {
        Array(
            exerciseSummaries
                .sorted { $0.bestE1RM > $1.bestE1RM }
                .prefix(5)
        )
    }

    /// Overall totals derived from exercise summaries.
    private var overallTotals: (sets: Int, reps: Int, volume: Double) {
        var sets = 0
        var reps = 0
        var volume: Double = 0

        for summary in exerciseSummaries {
            sets += summary.totalSets
            reps += summary.totalReps
            volume += summary.totalVolume
        }

        return (sets, reps, volume)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if completedSessions.isEmpty {
                    Text("No completed sessions yet.")
                        .font(.body)
                        .padding()
                } else {
                    overallSection

                    if !topLifts.isEmpty {
                        topLiftsSection
                    }

                    allExercisesSection
                }
            }
            .padding()
        }
        .navigationTitle("Block Summary")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var overallSection: some View {
        let totalSessions = completedSessions.count
        let totals = overallTotals

        let firstDate = completedSessions.first?.date
        let lastDate  = completedSessions.last?.date

        return VStack(alignment: .leading, spacing: 8) {
            Text("Block overview")
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Completed sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(totalSessions)")
                        .font(.title3.bold())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Total sets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(totals.sets)")
                        .font(.title3.bold())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Volume (lb·reps)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f", totals.volume))
                        .font(.title3.bold())
                }
            }

            if let firstDate, let lastDate {
                Text("From \(HistorySummaryView.dateFormatter.string(from: firstDate)) to \(HistorySummaryView.dateFormatter.string(from: lastDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Includes only completed sessions with logged sets (load and reps > 0).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var topLiftsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top lifts (best e1RM)")
                .font(.headline)

            ForEach(topLifts) { summary in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.name)
                            .font(.subheadline.bold())

                        Text(summary.primaryMuscle)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("\(summary.totalSessions) sessions · \(summary.totalSets) sets · \(summary.totalReps) reps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.0f", summary.bestE1RM))
                            .font(.title3.bold())
                        Text("est. 1RM")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if let last = summary.lastTrained {
                            Text("Last: \(HistorySummaryView.shortDateFormatter.string(from: last))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground))
                )
            }
        }
    }

    private var allExercisesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All exercises")
                .font(.headline)

            if exerciseSummaries.isEmpty {
                Text("No logged exercise data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(exerciseSummaries) { summary in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.name)
                                .font(.subheadline)

                            Text("\(summary.totalSessions) sessions · \(summary.totalSets) sets · \(summary.totalReps) reps")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.0f", summary.bestE1RM))
                                .font(.body.bold())
                            Text("e1RM")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if let last = summary.lastTrained {
                                Text(HistorySummaryView.shortDateFormatter.string(from: last))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Date formatters

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    private static let shortDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        return df
    }()
}

// MARK: - Exercise summary model

struct ExerciseSummary: Identifiable {
    /// Stable string key derived from SessionItem.exerciseId.
    let id: String          // used for Identifiable
    let exerciseKey: String // same as id, kept explicit

    let name: String
    let primaryMuscle: String

    let totalSessions: Int
    let totalSets: Int
    let totalReps: Int
    let totalVolume: Double
    let bestE1RM: Double
    let lastTrained: Date?
}

// MARK: - Builder

enum HistorySummaryBuilder {

    /// Builds per-exercise summaries from completed sessions.
    static func build(from sessions: [Session]) -> [ExerciseSummary] {
        // Temporary aggregation per exerciseKey
        var buckets: [String: TempBucket] = [:]

        for session in sessions {
            let sessionKey = String(describing: session.id)
            let sessionDate = session.date

            for item in session.items {
                let exerciseKey = String(describing: item.exerciseId)

                // Resolve name + muscle from catalog
                let catalog = ExerciseCatalog.all.first { exercise in
                    String(describing: exercise.id) == exerciseKey
                }

                let name   = catalog?.name ?? "Exercise"
                let muscle = catalog?.primaryMuscle.rawValue.capitalized ?? "—"

                let setCount = min(item.actualLoads.count, item.actualReps.count)
                if setCount == 0 { continue }

                var bucket = buckets[exerciseKey] ?? TempBucket(
                    exerciseKey: exerciseKey,
                    name: name,
                    primaryMuscle: muscle,
                    totalSets: 0,
                    totalReps: 0,
                    totalVolume: 0,
                    bestE1RM: 0,
                    lastTrained: nil,
                    sessionKeys: []
                )

                var didRecordAnySet = false

                for idx in 0..<setCount {
                    let reps = item.actualReps[idx]
                    let load = item.actualLoads[idx]

                    // Only count real working sets
                    if reps <= 0 || load <= 0 { continue }

                    didRecordAnySet = true

                    let volume = Double(reps) * load
                    let e1rm = estimateE1RM(weight: load, reps: reps)

                    bucket.totalSets += 1
                    bucket.totalReps += reps
                    bucket.totalVolume += volume

                    if e1rm > bucket.bestE1RM {
                        bucket.bestE1RM = e1rm
                    }
                }

                if didRecordAnySet {
                    bucket.sessionKeys.insert(sessionKey)

                    if let last = bucket.lastTrained {
                        if sessionDate > last {
                            bucket.lastTrained = sessionDate
                        }
                    } else {
                        bucket.lastTrained = sessionDate
                    }

                    buckets[exerciseKey] = bucket
                }
            }
        }

        // Convert buckets into summaries
        let summaries: [ExerciseSummary] = buckets.values.map { bucket in
            ExerciseSummary(
                id: bucket.exerciseKey,
                exerciseKey: bucket.exerciseKey,
                name: bucket.name,
                primaryMuscle: bucket.primaryMuscle,
                totalSessions: bucket.sessionKeys.count,
                totalSets: bucket.totalSets,
                totalReps: bucket.totalReps,
                totalVolume: bucket.totalVolume,
                bestE1RM: bucket.bestE1RM,
                lastTrained: bucket.lastTrained
            )
        }

        // Sort alphabetically by name for the "All exercises" section.
        return summaries.sorted { $0.name < $1.name }
    }

    /// Simple Epley estimated 1RM.
    static func estimateE1RM(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        return weight * (1.0 + Double(reps) / 30.0)
    }

    // Internal aggregation bucket
    private struct TempBucket {
        let exerciseKey: String
        let name: String
        let primaryMuscle: String

        var totalSets: Int
        var totalReps: Int
        var totalVolume: Double
        var bestE1RM: Double
        var lastTrained: Date?

        var sessionKeys: Set<String>
    }
}
