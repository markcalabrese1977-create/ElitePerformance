import SwiftUI
import SwiftData

/// High-level history dashboard:
/// - Aggregates across completed sessions
/// - Groups data by exercise
/// - Shows best e1RM, total volume, and last trained date.
struct HistorySummaryView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Session.date, order: .forward)
    private var sessions: [Session]

    // MARK: - Scope (optional UI control)

    private enum Scope: String, CaseIterable, Identifiable {
        case allTime = "All-time"
        case thisMeso = "This meso"

        var id: String { rawValue }
        var title: String { rawValue }
    }

    @State private var scope: Scope = .allTime

    // MARK: - Derived

    private var mesoCutoff: Date {
        Calendar.current.startOfDay(for: MesoLifecycle.activeStartDate)
    }

    private var filteredCompletedSessions: [Session] {
        let completed = sessions.filter { $0.status == .completed }
        switch scope {
        case .allTime:
            return completed
        case .thisMeso:
            return completed.filter { $0.date >= mesoCutoff }
        }
    }

    private var exerciseSummaries: [ExerciseSummary] {
        HistorySummaryBuilder.build(from: filteredCompletedSessions)
    }

    private var topCompounds: [ExerciseSummary] {
        Array(
            exerciseSummaries
                .filter { $0.isCompound }
                .sorted { $0.bestE1RM > $1.bestE1RM }
                .prefix(5)
        )
    }

    private var topAccessories: [ExerciseSummary] {
        Array(
            exerciseSummaries
                .filter { !$0.isCompound }
                .sorted { $0.bestE1RM > $1.bestE1RM }
                .prefix(5)
        )
    }

    private var overallTotals: (sets: Int, reps: Int, volume: Double) {
        var sets = 0
        var reps = 0
        var volume: Double = 0
        for s in exerciseSummaries {
            sets += s.totalSets
            reps += s.totalReps
            volume += s.totalVolume
        }
        return (sets, reps, volume)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                scopePicker

                if filteredCompletedSessions.isEmpty {
                    Text("No completed sessions yet.")
                        .font(.body)
                        .padding(.top, 8)
                } else {
                    overallSection

                    if !topCompounds.isEmpty || !topAccessories.isEmpty {
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

    // MARK: - UI

    private var scopePicker: some View {
        HStack {
            Text("Scope")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
    }

    private var overallSection: some View {
        let totalSessions = filteredCompletedSessions.count
        let totals = overallTotals

        let firstDate = filteredCompletedSessions.first?.date
        let lastDate  = filteredCompletedSessions.last?.date

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
                Text("From \(Self.dateFormatter.string(from: firstDate)) to \(Self.dateFormatter.string(from: lastDate))")
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
        VStack(alignment: .leading, spacing: 12) {

            if !topCompounds.isEmpty {
                Text("Top lifts — Compounds (best e1RM)")
                    .font(.headline)

                ForEach(topCompounds) { summary in
                    topLiftRow(summary)
                }
            }

            if !topAccessories.isEmpty {
                Text("Top lifts — Accessories (best e1RM)")
                    .font(.headline)
                    .padding(.top, topCompounds.isEmpty ? 0 : 8)

                ForEach(topAccessories) { summary in
                    topLiftRow(summary)
                }
            }
        }
    }

    private func topLiftRow(_ summary: ExerciseSummary) -> some View {
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
                    Text("Last: \(Self.shortDateFormatter.string(from: last))")
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
                                Text(Self.shortDateFormatter.string(from: last))
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
    let id: String           // exerciseId
    let name: String
    let primaryMuscle: String
    let isCompound: Bool

    let totalSessions: Int
    let totalSets: Int
    let totalReps: Int
    let totalVolume: Double
    let bestE1RM: Double
    let lastTrained: Date?
}

// MARK: - Builder

enum HistorySummaryBuilder {

    static func build(from sessions: [Session]) -> [ExerciseSummary] {
        // O(1) catalog lookup by id (NO KVC / reflection)
        let catalogById: [String: CatalogExercise] = Dictionary(
            uniqueKeysWithValues: ExerciseCatalog.all.map { ($0.id, $0) }
        )

        var buckets: [String: TempBucket] = [:]

        for session in sessions {
            let sessionKey = String(describing: session.id)
            let sessionDate = session.date

            for item in session.items {
                let exerciseId = item.exerciseId
                let catalog = catalogById[exerciseId]

                let name = catalog?.name ?? ExerciseCatalog.displayName(for: exerciseId)
                let muscle = catalog?.primaryMuscle.rawValue.capitalized ?? "—"
                let isCompound = catalog?.isCompound ?? false

                let setCount = min(item.actualLoads.count, item.actualReps.count)
                if setCount == 0 { continue }

                var bucket = buckets[exerciseId] ?? TempBucket(
                    exerciseId: exerciseId,
                    name: name,
                    primaryMuscle: muscle,
                    isCompound: isCompound,
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
                    bucket.bestE1RM = max(bucket.bestE1RM, e1rm)
                }

                if didRecordAnySet {
                    bucket.sessionKeys.insert(sessionKey)
                    bucket.lastTrained = max(bucket.lastTrained ?? sessionDate, sessionDate)
                    buckets[exerciseId] = bucket
                }
            }
        }

        let summaries = buckets.values.map { b in
            ExerciseSummary(
                id: b.exerciseId,
                name: b.name,
                primaryMuscle: b.primaryMuscle,
                isCompound: b.isCompound,
                totalSessions: b.sessionKeys.count,
                totalSets: b.totalSets,
                totalReps: b.totalReps,
                totalVolume: b.totalVolume,
                bestE1RM: b.bestE1RM,
                lastTrained: b.lastTrained
            )
        }

        return summaries.sorted { $0.name < $1.name }
    }

    static func estimateE1RM(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        return weight * (1.0 + Double(reps) / 30.0)
    }

    private struct TempBucket {
        let exerciseId: String
        let name: String
        let primaryMuscle: String
        let isCompound: Bool

        var totalSets: Int
        var totalReps: Int
        var totalVolume: Double
        var bestE1RM: Double
        var lastTrained: Date?

        var sessionKeys: Set<String>
    }
}
