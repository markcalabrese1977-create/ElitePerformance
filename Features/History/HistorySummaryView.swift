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

    private enum ExerciseSort: String, CaseIterable, Identifiable {
        case sessions = "Most sessions"
        case volume = "Most volume"
        case e1rm = "Best e1RM"
        case recent = "Recent"

        var id: String { rawValue }
    }

    private enum Scope: String, CaseIterable, Identifiable {
        case allTime = "All-time"
        case thisMeso = "This meso"

        var id: String { rawValue }
        var title: String { rawValue }
    }

    @State private var scope: Scope = .allTime
    @State private var exerciseSort: ExerciseSort = .sessions

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

    private var rawExerciseSummaries: [ExerciseSummary] {
        HistorySummaryBuilder.build(from: filteredCompletedSessions)
    }

    private var exerciseSummaries: [ExerciseSummary] {
        switch exerciseSort {
        case .sessions:
            return rawExerciseSummaries.sorted {
                if $0.totalSessions != $1.totalSessions { return $0.totalSessions > $1.totalSessions }
                return $0.name < $1.name
            }
        case .volume:
            return rawExerciseSummaries.sorted {
                if $0.totalVolume != $1.totalVolume { return $0.totalVolume > $1.totalVolume }
                return $0.name < $1.name
            }
        case .e1rm:
            return rawExerciseSummaries.sorted {
                if $0.bestE1RM != $1.bestE1RM { return $0.bestE1RM > $1.bestE1RM }
                return $0.name < $1.name
            }
        case .recent:
            return rawExerciseSummaries.sorted {
                ($0.lastTrained ?? .distantPast) > ($1.lastTrained ?? .distantPast)
            }
        }
    }

    private var topCompounds: [ExerciseSummary] {
        Array(
            rawExerciseSummaries
                .filter { $0.isCompound }
                .sorted { $0.bestE1RM > $1.bestE1RM }
                .prefix(5)
        )
    }

    private var topAccessories: [ExerciseSummary] {
        Array(
            rawExerciseSummaries
                .filter { !$0.isCompound }
                .sorted { $0.bestE1RM > $1.bestE1RM }
                .prefix(5)
        )
    }

    private var overallTotals: (sets: Int, reps: Int, volume: Double) {
        var sets = 0
        var reps = 0
        var volume: Double = 0

        for summary in rawExerciseSummaries {
            sets += summary.totalSets
            reps += summary.totalReps
            volume += summary.totalVolume
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
        let lastDate = filteredCompletedSessions.last?.date

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

            Picker("Sort", selection: $exerciseSort) {
                ForEach(ExerciseSort.allCases) { sort in
                    Text(sort.rawValue).tag(sort)
                }
            }
            .pickerStyle(.segmented)

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
                            switch exerciseSort {
                            case .sessions:
                                Text("\(summary.totalSessions)")
                                    .font(.body.bold())
                                Text("sessions")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                            case .volume:
                                Text(String(format: "%.0f", summary.totalVolume))
                                    .font(.body.bold())
                                Text("volume")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                            case .e1rm:
                                Text(String(format: "%.0f", summary.bestE1RM))
                                    .font(.body.bold())
                                Text("e1RM")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                            case .recent:
                                if let last = summary.lastTrained {
                                    Text(Self.shortDateFormatter.string(from: last))
                                        .font(.body.bold())
                                    Text("last trained")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("—")
                                        .font(.body.bold())
                                    Text("last trained")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
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
    let id: String
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
        let catalogById: [String: CatalogExercise] = Dictionary(
            uniqueKeysWithValues: ExerciseCatalog.all.map { ($0.id, $0) }
        )

        var buckets: [String: TempBucket] = [:]

        for session in sessions {
            let sessionKey = String(describing: session.id)
            let sessionDate = session.date

            let vm = SessionScreenViewModel(session: session)
            let uiByExerciseId: [String: UISessionExercise] = Dictionary(
                uniqueKeysWithValues: vm.exercises.map { ($0.exerciseId, $0) }
            )

            for item in session.items {
                let exerciseId = item.exerciseId
                let catalog = catalogById[exerciseId]
                let uiExercise = uiByExerciseId[exerciseId]

                let resolvedName = displayName(
                    exerciseId: exerciseId,
                    catalogName: catalog?.name,
                    uiName: uiExercise?.name
                )

                let resolvedMuscle = primaryMuscle(
                    catalog: catalog,
                    uiExercise: uiExercise
                )

                let resolvedIsCompound = catalog?.isCompound ?? inferredIsCompound(from: resolvedName)

                let setCount = min(item.actualLoads.count, item.actualReps.count)
                guard setCount > 0 else { continue }

                var bucket = buckets[exerciseId] ?? TempBucket(
                    exerciseId: exerciseId,
                    name: resolvedName,
                    primaryMuscle: resolvedMuscle,
                    isCompound: resolvedIsCompound,
                    totalSets: 0,
                    totalReps: 0,
                    totalVolume: 0,
                    bestE1RM: 0,
                    lastTrained: nil,
                    sessionKeys: []
                )

                if bucket.name == bucket.exerciseId || bucket.name.isEmpty {
                    bucket.name = resolvedName
                }

                if bucket.primaryMuscle == "—", resolvedMuscle != "—" {
                    bucket.primaryMuscle = resolvedMuscle
                }

                var didRecordAnySet = false

                for idx in 0..<setCount {
                    let reps = item.actualReps[idx]
                    let load = item.actualLoads[idx]

                    guard reps > 0, load > 0 else { continue }

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

        let summaries = buckets.values.map { bucket in
            ExerciseSummary(
                id: bucket.exerciseId,
                name: bucket.name,
                primaryMuscle: bucket.primaryMuscle,
                isCompound: bucket.isCompound,
                totalSessions: bucket.sessionKeys.count,
                totalSets: bucket.totalSets,
                totalReps: bucket.totalReps,
                totalVolume: bucket.totalVolume,
                bestE1RM: bucket.bestE1RM,
                lastTrained: bucket.lastTrained
            )
        }

        return summaries.sorted {
            if $0.totalSessions != $1.totalSessions { return $0.totalSessions > $1.totalSessions }
            return $0.name < $1.name
        }
    }

    static func estimateE1RM(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        return weight * (1.0 + Double(reps) / 30.0)
    }

    private static func displayName(
        exerciseId: String,
        catalogName: String?,
        uiName: String?
    ) -> String {
        if let catalogName, !catalogName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return catalogName
        }

        if let uiName, !uiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, uiName != "Exercise" {
            return uiName
        }

        let readable = humanizeExerciseId(exerciseId)
        if !readable.isEmpty {
            return readable
        }

        return "Legacy / Custom Exercise"
    }

    private static func primaryMuscle(
        catalog: CatalogExercise?,
        uiExercise: UISessionExercise?
    ) -> String {
        if let catalog {
            return catalog.primaryMuscle.rawValue.capitalized
        }

        let detail = uiExercise?.detail ?? ""
        let parts = detail.components(separatedBy: " · ")

        if parts.count >= 2 {
            let candidate = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty,
               !candidate.lowercased().contains("sets"),
               !candidate.lowercased().contains("reps"),
               !candidate.lowercased().contains("rir") {
                return candidate
            }
        }

        return "—"
    }

    private static func inferredIsCompound(from name: String) -> Bool {
        let n = name.lowercased()
        let compoundHints = [
            "press", "row", "pulldown", "squat", "leg press", "hip thrust",
            "rdl", "deadlift", "bench", "carry", "dip"
        ]
        return compoundHints.contains(where: { n.contains($0) })
    }

    private static func humanizeExerciseId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // UUID-like ids are not user-friendly
        if trimmed.contains("-"), trimmed.count >= 24 {
            return ""
        }

        let humanized = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")

        return humanized
    }

    private struct TempBucket {
        let exerciseId: String
        var name: String
        var primaryMuscle: String
        let isCompound: Bool

        var totalSets: Int
        var totalReps: Int
        var totalVolume: Double
        var bestE1RM: Double
        var lastTrained: Date?

        var sessionKeys: Set<String>
    }
}
