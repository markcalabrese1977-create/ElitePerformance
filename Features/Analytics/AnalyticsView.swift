import SwiftUI
import SwiftData

struct AnalyticsView: View {
    @Environment(\.loadUnit) private var unit
    @Query(sort: \Session.date, order: .reverse) private var sessions: [Session]
    @Query private var profiles: [UserProfile]
    @Query private var customExercises: [CustomExercise]

    @State private var selectedExerciseId: String? = nil
    @State private var volume: MuscleVolumeSummary? = nil
    @State private var showUnmapped = false
    @State private var showCustomMuscles = false
    @State private var volumeRefresh = UUID()

    private var mesoCutoff: Date {
        Calendar.current.startOfDay(for: MesoLifecycle.activeStartDate)
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                MuscleVolumeSection(summary: volume, showUnmapped: $showUnmapped, showCustomMuscles: $showCustomMuscles)
                activitySection
                topExercisesSection
                allExercisesSection
            }
            .clearsFloatingTabBar()
            .navigationTitle("Analytics")
            .task(id: "\(sessions.count)-\(customExercises.count)-\(volumeRefresh)-\(profiles.first?.muscleSetRangesStored?.count ?? 0)") { refreshVolume() }
            .sheet(isPresented: $showCustomMuscles, onDismiss: { volumeRefresh = UUID() }) {
                CustomExerciseMusclesSheet()
            }
            .sheet(isPresented: $showUnmapped, onDismiss: { volumeRefresh = UUID() }) {
                UnmappedExercisesSheet(items: volume?.unmapped ?? [])
            }
            .sheet(item: sheetItemBinding) { item in
                ExerciseHistorySheet(
                                    exerciseId: item.exerciseId,
                                    exerciseName: item.exerciseName,
                                    currentWave: nil,
                                    onClose: { selectedExerciseId = nil }
                                )
                                .presentationDetents([.large])
                                .presentationDragIndicator(.hidden)
            }
        }
    }

    private func refreshVolume() {
        let profile = profiles.first
        let engine = AnalyticsEngine(sessions: sessions, customExercises: customExercises, bodyWeight: profile?.bodyWeight)
        volume = engine.muscleVolume(customs: customExercises, profile: profile)
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section("Summary (this meso)") {
            let mesoSessions = sessions.filter { $0.date >= mesoCutoff }
            let completed = mesoSessions.filter { $0.status == .completed }

            row("Active since", mesoCutoff.formatted(date: .abbreviated, time: .omitted))
            row("Total sessions", "\(mesoSessions.count)")
            row("Completed sessions", "\(completed.count)")
            row("Logged exercise entries", "\(computeLoggedExerciseEntryCount(from: mesoSessions))")
        }
    }

    private var activitySection: some View {
        Section("Activity (this meso)") {
            row("Completed (7 days)", "\(completedSessions(inLastDays: 7))")
            row("Completed (30 days)", "\(completedSessions(inLastDays: 30))")
        }
    }

    private var topExercisesSection: some View {
        Section("Top exercises (last 30 days, this meso)") {
            let rows = topExercises(lastDays: 30, limit: 12)
            if rows.isEmpty {
                Text("No exercise data found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { r in
                    exerciseButton(r)
                }
            }
        }
    }

    private var allExercisesSection: some View {
        Section("All exercises") {
            let all = allExercises(limit: 200)
            if all.isEmpty {
                Text("No exercise data found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(all) { r in
                    exerciseButton(r)
                }
            }
        }
    }

    private func exerciseButton(_ r: TopExerciseRow) -> some View {
        Button {
            selectedExerciseId = ExerciseCatalog.canonicalExerciseId(for: r.exerciseId)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.exerciseName)
                        .font(.body)
                    Text("\(r.loggedEntries) logged entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(LoadFormatter(unit: unit).volumeKText(r.estimatedVolumeK))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func completedSessions(inLastDays days: Int) -> Int {
        let cal = Calendar.current
        let daysCutoff = cal.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let cutoff = max(cal.startOfDay(for: daysCutoff), mesoCutoff)
        return sessions.filter { $0.status == .completed && $0.date >= cutoff }.count
    }

    private func computeLoggedExerciseEntryCount(from sessions: [Session]) -> Int {
        var count = 0
        for s in sessions {
            for item in s.items {
                let hasLoad = item.actualLoads.contains(where: { $0 > 0 })
                let hasReps = item.actualReps.contains(where: { $0 > 0 })
                if hasLoad || hasReps { count += 1 }
            }
        }
        return count
    }

    private func topExercises(lastDays days: Int, limit: Int) -> [TopExerciseRow] {
        let cal = Calendar.current
        let daysCutoff = cal.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let cutoff = max(cal.startOfDay(for: daysCutoff), mesoCutoff)
        let recent = sessions.filter { $0.status == .completed && $0.date >= cutoff }
        return buildRows(from: recent, limit: limit)
    }

    private func allExercises(limit: Int) -> [TopExerciseRow] {
        let completed = sessions.filter { $0.status == .completed }
        return buildRows(from: completed, limit: limit)
    }

    private func buildRows(from sessions: [Session], limit: Int) -> [TopExerciseRow] {
        var map: [String: Accum] = [:]

        for s in sessions {
            for item in s.items {
                let exId = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                let name = map[exId]?.exerciseName ?? ExerciseCatalog.displayName(for: exId)

                // Hard-set volume at the effective load (Domain/Analytics): warm-ups and skipped rows out, bodyweight sets in.
                let volume = AnalyticsEngine.ItemStats.of(item, bodyWeight: profiles.first?.bodyWeight).volume

                let loads = item.actualLoads
                let reps = item.actualReps

                let logged = (loads.contains(where: { $0 > 0 }) || reps.contains(where: { $0 > 0 })) ? 1 : 0

                if map[exId] == nil {
                    map[exId] = Accum(exerciseId: exId, exerciseName: name, loggedEntries: 0, volume: 0)
                }
                map[exId]?.loggedEntries += logged
                map[exId]?.volume += volume
            }
        }

        var rows = map.values.map { a in
            TopExerciseRow(
                exerciseId: a.exerciseId,
                exerciseName: a.exerciseName,
                loggedEntries: a.loggedEntries,
                estimatedVolumeK: LoadFormatter(unit: unit).volumeK(a.volume)
            )
        }
        .sorted {
            if $0.loggedEntries != $1.loggedEntries { return $0.loggedEntries > $1.loggedEntries }
            return $0.estimatedVolumeK > $1.estimatedVolumeK
        }

        return rows.count > limit ? Array(rows.prefix(limit)) : rows
    }

    // MARK: - Models

    private struct Accum {
        let exerciseId: String
        let exerciseName: String
        var loggedEntries: Int
        var volume: Double
    }

    struct TopExerciseRow: Identifiable {
        var id: String { exerciseId }
        let exerciseId: String
        let exerciseName: String
        let loggedEntries: Int
        let estimatedVolumeK: Int
    }

    // MARK: - Sheet plumbing

    private var sheetItemBinding: Binding<ExerciseSheetItem?> {
        Binding<ExerciseSheetItem?>(
            get: {
                guard let id = selectedExerciseId else { return nil }
                let name = ExerciseCatalog.displayName(for: id)
                return ExerciseSheetItem(exerciseId: id, exerciseName: name)
            },
            set: { newValue in
                if newValue == nil { selectedExerciseId = nil }
            }
        )
    }

    struct ExerciseSheetItem: Identifiable {
        var id: String { exerciseId }
        let exerciseId: String
        let exerciseName: String
    }
}


// MARK: - Weekly sets per muscle

/// "Weekly sets per muscle" (current block): the 4-week average vs the lifter's range, a per-week sparkline, adherence
/// markers per week and the exercises that have no muscle mapping yet.
struct MuscleVolumeSection: View {
    let summary: MuscleVolumeSummary?
    @Binding var showUnmapped: Bool
    @Binding var showCustomMuscles: Bool

    var body: some View {
        Section {
            if let s = summary, !s.isEmpty {
                adherenceHeader(s)
                ForEach(s.rows) { row in MuscleVolumeRow(row: row, weeks: s.weeks) }
                Button { showUnmapped = true } label: {
                    HStack {
                        Text("Unmapped exercises: \(s.unmapped.count)")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("unmappedExercisesRow")
                Button { showCustomMuscles = true } label: {
                    HStack {
                        Text("Custom exercise muscles")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("customExerciseMusclesRow")
            } else {
                Text("No completed training in the current block yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Weekly sets per muscle")
        } footer: {
            if let s = summary, !s.isEmpty {
                Text("Hard sets, current block\(s.blockName.map { " (\($0))" } ?? ""). Average of the last \(s.averagedWeeks) full week\(s.averagedWeeks == 1 ? "" : "s"); synergists count 0.25–0.5 of a set. Weeks with under 70% of planned sessions done (hollow points) and deload weeks are left out of the average. Ranges are adjustable in Settings.")
            }
        }
    }

    private func adherenceHeader(_ s: MuscleVolumeSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 4 weeks (sessions done / planned)")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(s.windowWeeks.enumerated()), id: \.offset) { _, w in
                    VStack(spacing: 2) {
                        Text(w.weekStart, format: .dateTime.month(.abbreviated).day()).font(.caption2)
                        Text("\(w.completedSessions)/\(w.plannedSessions)\(w.hasDeload ? " D" : "")")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(w.isIncomplete ? Color.orange : (w.hasDeload ? Color.blue : Color.green))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MuscleVolumeRow: View {
    let row: MuscleVolumeSummary.Row
    let weeks: [MuscleWeek]

    private var color: Color {
        switch row.status {
        case .below: return .orange
        case .within: return .green
        case .above: return .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.muscle.displayName).font(.subheadline)
                Text("range \(Int(row.range.min))–\(Int(row.range.max))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Sparkline(values: row.series, weeks: weeks, color: color)
                .frame(width: 72, height: 24)
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f", row.average)).font(.subheadline).fontWeight(.semibold)
                Text(row.status.rawValue).font(.caption2).foregroundStyle(color)
            }
            .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A tiny line per week; a week with under 70% of its sessions done (or a deload week) is a hollow point.
private struct Sparkline: View {
    let values: [Double]
    let weeks: [MuscleWeek]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let top = max(values.max() ?? 0, 1)
            let n = max(values.count - 1, 1)
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(n), y: geo.size.height * (1 - CGFloat(v / top)) * 0.9 + 2)
            }
            ZStack {
                Path { p in
                    for (i, pt) in pts.enumerated() { i == 0 ? p.move(to: pt) : p.addLine(to: pt) }
                }
                .stroke(color.opacity(0.7), lineWidth: 1.5)
                ForEach(Array(pts.enumerated()), id: \.offset) { i, pt in
                    let held = i < weeks.count && (weeks[i].isIncomplete || weeks[i].hasDeload)
                    Circle()
                        .strokeBorder(color, lineWidth: 1.2)
                        .background(Circle().fill(held ? Color(.systemBackground) : color))
                        .frame(width: 5, height: 5)
                        .position(pt)
                }
            }
        }
    }
}

/// The exercises with hard sets in the block that are in no muscle's total; tap one to map it.
struct UnmappedExercisesSheet: View {
    let items: [MuscleVolumeSummary.Unmapped]
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MappingTarget?

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("Every exercise in this block is mapped.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(items) { item in
                            Button {
                                if item.isEditable { editing = MappingTarget(id: item.id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                        Text("\(item.sets) hard sets in this block, in no muscle's total")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if item.isEditable { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                                }
                            }
                            .disabled(!item.isEditable)
                        }
                    } footer: {
                        Text("Pick the muscle each custom exercise trains. You can also swipe a custom exercise right in the exercise picker.")
                    }
                }
            }
            .navigationTitle("Unmapped exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { target in CustomMuscleMappingSheet(exerciseId: target.id) }
        }
    }
}
