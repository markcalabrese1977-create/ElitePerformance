import SwiftUI
import SwiftData
import Charts

struct ExerciseHistorySheet: View {
    @Environment(\.loadUnit) private var unit
    let exerciseId: String
    let exerciseName: String
    let currentWave: String?
    let onClose: () -> Void

    @Environment(\.modelContext) private var context

    private struct ExerciseHistoryEntry: Identifiable {
        let id = UUID()
        let date: Date
        let weekIndex: Int
        let waveLabel: String?
        let prescriptionLabel: String?
        let sets: Int
        let reps: Int
        let volume: Double
        let detail: String
        let bestE1RM: Double?
        /// When the session has no set of 12 reps or fewer there is no e1RM: its top working set by load (the Meso Summary's
        /// fallback, `BestSetRule`), shown as a LOAD, never as an e1RM.
        let topLoadSet: BestSet?
        let session: Session
    }

    private static let df: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        return df
    }()

    @State private var entries: [ExerciseHistoryEntry] = []
    @State private var selectedWave: String? = nil // nil = All
    /// Stall flags for this lift in the current block (one per letter / role), from StallDetector.
    @State private var stalls: [Stall] = []
    /// All-time totals for this lift (completed sessions, every block).
    @State private var lifetime: LifetimeStats?

    private struct LifetimeStats {
        let sessions: Int
        let sets: Int
        let reps: Int
        let bestSet: BestSet?
    }

    // MARK: - Derived

    private var availableWaves: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for e in entries {
            if let w = e.waveLabel, !seen.contains(w) {
                seen.insert(w)
                ordered.append(w)
            }
        }
        return ordered
    }

    private var filteredEntries: [ExerciseHistoryEntry] {
        guard let wave = selectedWave else { return entries }
        return entries.filter { $0.waveLabel == wave }
    }

    private var bestOverallE1RM: Double? {
        entries.compactMap { $0.bestE1RM }.max()
    }

    private var hasThinHistory: Bool { entries.count <= 1 }

    

    // MARK: - e1RM trend delta (same wave, consecutive entries)

    private func e1rmDelta(for entry: ExerciseHistoryEntry) -> Double? {
        guard let currentE1RM = entry.bestE1RM else { return nil }
        let sameWave = entries.filter { $0.waveLabel == entry.waveLabel }
        guard let idx = sameWave.firstIndex(where: { $0.id == entry.id }),
              idx + 1 < sameWave.count else { return nil }
        guard let prevE1RM = sameWave[idx + 1].bestE1RM else { return nil }
        return currentE1RM - prevE1RM
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if entries.isEmpty {
                        Text("No logged sets yet for \(exerciseName).")
                            .foregroundStyle(.secondary)
                            .padding(.top, 30)
                    } else {
                        lifetimeCard
                        stallChips
                        e1rmChart
                        if availableWaves.count > 1 {
                            waveFilter
                        }
                        ForEach(filteredEntries) { entry in
                            historyRow(entry)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .navigationTitle(exerciseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close", action: onClose)
                }
            }
        }
        .task { loadHistory() }
    }

    

    // MARK: - Lifetime stats

    @ViewBuilder private var lifetimeCard: some View {
        if let l = lifetime {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lifetime").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                HStack {
                    lifetimeCell("Sessions", LoadFormatter.grouped(l.sessions))
                    lifetimeCell("Sets", LoadFormatter.grouped(l.sets))
                    lifetimeCell("Reps", LoadFormatter.grouped(l.reps))
                    if let b = l.bestSet {
                        lifetimeCell("Best set", "\(LoadFormatter(unit: unit).compact(b.load)) × \(b.reps)")
                    }
                }
                Text("Hard sets in completed sessions (warm-ups and skipped sets excluded). Best set: highest e1RM among sets of 12 reps or fewer; the heaviest load when there is none.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
            .accessibilityIdentifier("lifetimeCard")
        }
    }

    private func lifetimeCell(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline).fontWeight(.semibold)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stall chips

    @ViewBuilder private var stallChips: some View {
        if !stalls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(stalls.enumerated()), id: \.offset) { _, stall in
                    HStack(spacing: 6) {
                        Image(systemName: stall.status == .stalled ? "pause.circle.fill" : "minus.circle.fill")
                        Text(stall.chipText)
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(stall.status == .stalled ? Color.orange : Color.secondary)
                    .background(Capsule().fill((stall.status == .stalled ? Color.orange : Color.secondary).opacity(0.15)))
                    .accessibilityIdentifier("stallChip")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - e1RM Sparkline Chart

    private var e1rmChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Chronological points: an e1RM where the session has a set of 12 reps or fewer, else the top set's LOAD.
            let points = Array(entries.filter { $0.bestE1RM != nil || $0.topLoadSet != nil }.reversed().enumerated())
            let hasLoadPoints = points.contains { $0.element.bestE1RM == nil }
            let hasE1RMPoints = points.contains { $0.element.bestE1RM != nil }

            Text(hasLoadPoints ? (hasE1RMPoints ? "Estimated 1RM and top-set load" : "Top-set load") : "Estimated 1RM trend")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if points.isEmpty {
                Text("No e1RM data yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points, id: \.element.id) { idx, entry in
                        if let e1 = entry.bestE1RM {
                            LineMark(
                                x: .value("Session", idx),
                                y: .value("e1RM", unit.fromStoredLb(e1)),
                                series: .value("Kind", "e1RM")
                            )
                            .foregroundStyle(waveColor(entry.waveLabel))
                            .interpolationMethod(.catmullRom)

                            PointMark(
                                x: .value("Session", idx),
                                y: .value("e1RM", unit.fromStoredLb(e1))
                            )
                            .foregroundStyle(waveColor(entry.waveLabel))
                            .symbol(.circle)
                            .symbolSize(30)
                        } else if let top = entry.topLoadSet {
                            // a LOAD, not an e1RM: a hollow diamond on a dashed line of its own
                            LineMark(
                                x: .value("Session", idx),
                                y: .value("Load", unit.fromStoredLb(top.load)),
                                series: .value("Kind", "load")
                            )
                            .foregroundStyle(waveColor(entry.waveLabel).opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

                            PointMark(
                                x: .value("Session", idx),
                                y: .value("Load", unit.fromStoredLb(top.load))
                            )
                            .foregroundStyle(waveColor(entry.waveLabel))
                            .symbol { Image(systemName: "diamond").font(.system(size: 9, weight: .bold)).foregroundStyle(waveColor(entry.waveLabel)) }
                        }
                    }
                }
                .frame(height: 100)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v))")
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }

                if hasLoadPoints {
                    HStack(spacing: 14) {
                        if hasE1RMPoints {
                            Label("e1RM", systemImage: "circle.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                        Label("top-set load (no set of 12 reps or fewer, so no e1RM)", systemImage: "diamond")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("loadMarkerLegend")
                }

                // Wave legend — only show waves that appear in chart
                let chartWaves = Array(Set(points.compactMap { $0.element.waveLabel })).sorted()
                if chartWaves.count > 1 {
                    HStack(spacing: 12) {
                        ForEach(chartWaves, id: \.self) { wave in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(waveColor(wave))
                                    .frame(width: 6, height: 6)
                                Text(wave)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Wave Filter

    private var waveFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill(label: "All", wave: nil)
                ForEach(availableWaves, id: \.self) { wave in
                    filterPill(label: wave, wave: wave)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func filterPill(label: String, wave: String?) -> some View {
        let isSelected = selectedWave == wave
        return Button {
            selectedWave = wave
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? waveColor(wave).opacity(0.2) : Color(.secondarySystemBackground))
                .foregroundStyle(isSelected ? waveColor(wave) : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? waveColor(wave).opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - History Row

    @ViewBuilder
    private func historyRow(_ entry: ExerciseHistoryEntry) -> some View {
        let isBest: Bool = {
            guard let best = bestOverallE1RM, let e1 = entry.bestE1RM else { return false }
            return abs(e1 - best) < 0.5
        }()

        let delta = e1rmDelta(for: entry)

        let isCurrentWave: Bool = {
            guard let current = currentWave else { return true }
            return entry.waveLabel == current
        }()

        NavigationLink {
            ExerciseSessionDetailView(
                session: entry.session,
                exerciseId: exerciseId,
                exerciseName: exerciseName
            )
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Self.df.string(from: entry.date))
                        .font(.headline)
                    Spacer()
                    Text("Week \(entry.weekIndex)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if let wave = entry.waveLabel {
                        Text(wave)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(waveColor(wave))
                    }

                    if let delta {
                        deltaBadge(delta)
                    }
                }

                if let prescription = entry.prescriptionLabel {
                    Text(prescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Text("Sets: \(entry.sets)")
                    Text("Reps: \(entry.reps)")
                    Text("Vol: \(formatVolume(entry.volume))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let e1 = entry.bestE1RM {
                    HStack(spacing: 6) {
                        Text("Top est 1RM: \(Int(unit.fromStoredLb(e1).rounded()))")
                            .font(.caption2)
                            .fontWeight(.semibold)
                        if isBest {
                            Text("Best so far")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.top, 2)
                } else if let top = entry.topLoadSet {
                    HStack(spacing: 6) {
                        Image(systemName: "diamond").font(.caption2)
                        Text("Top set: \(LoadFormatter(unit: unit).compact(top.load)) × \(top.reps)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                        Text("(load; no set of 12 reps or fewer)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.secondarySystemBackground))
            )
            .opacity(isCurrentWave ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func deltaBadge(_ delta: Double) -> some View {
        let isPositive = delta > 0.5
        let isNegative = delta < -0.5
        let label: String = {
            if isPositive { return "↑ +\(Int(unit.fromStoredLb(delta).rounded())) e1RM" }
            if isNegative { return "↓ \(Int(unit.fromStoredLb(delta).rounded())) e1RM" }
            return "→ same"
        }()
        let color: Color = isPositive ? .green : (isNegative ? .orange : .secondary)

        Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Wave color

    private func waveColor(_ wave: String?) -> Color {
        // Labels read "Heavy (A)": colour by the letter so a letter keeps its colour in every block.
        let text = wave?.lowercased() ?? ""
        if text.hasSuffix("(a)") { return .red }
        if text.hasSuffix("(b)") { return .blue }
        if text.hasSuffix("(c)") { return .purple }
        switch text {
        case "strength":     return .red
        case "hypertrophy":  return .blue
        case "intensification": return .purple
        case "deload", "maintenance": return .green
        default:             return .secondary
        }
    }

    // MARK: - Load history

    private func waveDisplayName(from raw: String?, meso: MesoBlock? = nil) -> String? {
        WaveLabels.display(forRaw: raw, meso: meso)
    }

    private func prescriptionLabel(repMin: Int?, repMax: Int?, rirMin: Int?, rirMax: Int?) -> String? {
        var parts: [String] = []
        if let repMin, let repMax {
            parts.append(repMin == repMax ? "\(repMin) reps" : "\(repMin)–\(repMax) reps")
        }
        if let rirMin, let rirMax {
            parts.append(rirMin == rirMax ? "\(rirMin) RIR" : "\(rirMin)–\(rirMax) RIR")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// All-time sessions, hard sets, reps and best set of this lift, on the shared analytics definitions.
    private func computeLifetime(sessions: [Session], bodyWeight: Double?, customs: [CustomExercise]) -> LifetimeStats? {
        let target = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        var nSessions = 0, nSets = 0, nReps = 0
        var rows: [(load: Double, reps: Int)] = []
        for s in sessions where s.status == .completed {
            let items = s.items.filter { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == target }
            guard !items.isEmpty else { continue }
            var counted = false
            for item in items {
                let st = AnalyticsEngine.ItemStats.of(item, bodyWeight: bodyWeight, customExercises: customs)
                if st.sets > 0 { counted = true }
                nSets += st.sets; nReps += st.reps
                if let b = BestSetRule.best(of: item, bodyWeight: bodyWeight, customExercises: customs) { rows.append((b.load, b.reps)) }
            }
            if counted { nSessions += 1 }
        }
        guard nSessions > 0 else { return nil }
        return LifetimeStats(sessions: nSessions, sets: nSets, reps: nReps, bestSet: BestSetRule.best(of: rows))
    }

    private func loadHistory() {
        do {
            var descriptor = FetchDescriptor<Session>()
            descriptor.sortBy = [SortDescriptor(\Session.date, order: .reverse)]
            let sessions = try context.fetch(descriptor)
            let bodyWeight = try? context.fetch(FetchDescriptor<UserProfile>()).first?.bodyWeight
            var built: [ExerciseHistoryEntry] = []
            let targetExerciseId = ExerciseCatalog.resolvedExerciseId(
                rawId: exerciseId,
                snapshotName: exerciseName,
                fallbackName: exerciseName
            )

            for session in sessions {
                guard session.items.contains(where: {
                    ExerciseCatalog.resolvedExerciseId(
                        rawId: $0.exerciseId,
                        snapshotName: $0.exerciseNameSnapshot,
                        fallbackName: nil
                    ) == targetExerciseId
                }) else { continue }

                let vm = SessionScreenViewModel(session: session)
                let uiEx =
                    vm.exercises.first(where: {
                        ExerciseCatalog.resolvedExerciseId(
                            rawId: $0.exerciseId,
                            snapshotName: $0.name,
                            fallbackName: $0.name
                        ) == targetExerciseId
                    }) ??
                    vm.exercises.first(where: { $0.name == exerciseName })

                guard let uiEx else { continue }

                let waveLabel = waveDisplayName(from: uiEx.waveRaw, meso: session.meso)
                let prescription = prescriptionLabel(
                    repMin: uiEx.repMin,
                    repMax: uiEx.repMax,
                    rirMin: uiEx.targetRIRMin,
                    rirMax: uiEx.targetRIRMax
                )

                let target = max(0, uiEx.targetSets)
                var executedTokens: [String] = []
                var repsTotal = 0
                var volumeTotal: Double = 0
                var executedSetCount = 0

                for set in uiEx.sets where set.index <= target || (set.actualReps ?? 0) > 0 {
                    let reps = set.actualReps ?? 0
                    guard reps > 0 else { continue }
                    let load = set.actualLoad ?? 0
                    let effLoad = E1RMCalculator.effectiveLoad(
                        actualLoad: load,
                        exerciseId: targetExerciseId,
                        bodyWeight: bodyWeight
                    )
                    let rir = set.actualRIR   // logged RIR only
                    executedSetCount += 1
                    repsTotal += reps
                    volumeTotal += effLoad * Double(reps)
                    executedTokens.append(
                        formatSetToken(
                            load: load, reps: reps, rir: rir,
                            usedRP: set.usedRestPause,
                            rpPattern: set.restPausePattern
                        )
                    )
                }

                guard executedSetCount > 0 else { continue }

                // Best working-set e1RM of the session for this lift: the single e1RM definition (Domain/Analytics).
                let bestE1RM: Double? = {
                    let best = session.items
                        .filter { ExerciseCatalog.resolvedExerciseId(rawId: $0.exerciseId, snapshotName: $0.exerciseNameSnapshot, fallbackName: nil) == targetExerciseId }
                        .map { AnalyticsEngine.ItemStats.of($0, bodyWeight: bodyWeight).bestE1RM }.max() ?? 0
                    return best > 0 ? best : nil
                }()
                let topLoadSet: BestSet? = {
                    guard bestE1RM == nil else { return nil }
                    let customsForSet = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
                    return session.items
                        .filter { ExerciseCatalog.resolvedExerciseId(rawId: $0.exerciseId, snapshotName: $0.exerciseNameSnapshot, fallbackName: nil) == targetExerciseId }
                        .compactMap { BestSetRule.best(of: $0, bodyWeight: bodyWeight, customExercises: customsForSet) }
                        .max { ($0.load, $0.reps) < ($1.load, $1.reps) }
                }()

                built.append(
                    ExerciseHistoryEntry(
                        date: session.date,
                        weekIndex: session.weekIndex,
                        waveLabel: waveLabel,
                        prescriptionLabel: prescription,
                        sets: executedSetCount,
                        reps: repsTotal,
                        volume: volumeTotal,
                        detail: executedTokens.joined(separator: ", "),
                        bestE1RM: bestE1RM,
                        topLoadSet: topLoadSet,
                        session: session
                    )
                )
            }

            entries = built

            let customs = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
            let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
            lifetime = computeLifetime(sessions: sessions, bodyWeight: profile?.bodyWeight, customs: customs)
            stalls = AnalyticsEngine(sessions: sessions, customExercises: customs, bodyWeight: profile?.bodyWeight)
                .stalls(forExerciseId: exerciseId, customs: customs, profile: profile)

            // Pre-select current wave filter if provided
            if let current = currentWave, availableWaves.contains(current) {
                selectedWave = current
            }

        } catch {
            print("⚠️ Failed to load ExerciseHistorySheet sessions: \(error)")
        }
    }

    // MARK: - Helpers

    private func formatVolume(_ v: Double) -> String {
        let iv = Int(unit.fromStoredLb(v).rounded())
        return NumberFormatter.localizedString(from: NSNumber(value: iv), number: .decimal)
    }

    private func formatSetToken(load: Double, reps: Int, rir: Int?, usedRP: Bool, rpPattern: String) -> String {
        let loadString: String = {
            if load == 0, ExerciseCatalog.isBodyweight(exerciseId: exerciseId) { return "BW" }
            return LoadFormatter(unit: unit).compact(load)
        }()
        var s = "\(loadString)×\(reps)"
        s += EffortTracking.loggedSuffix(rir)
        if usedRP {
            let trimmed = rpPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            s += trimmed.isEmpty ? " (RP)" : " (RP: \(trimmed))"
        }
        return s
    }
}
