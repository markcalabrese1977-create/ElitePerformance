// Features/History/MesoSummaryView.swift
import SwiftUI
import SwiftData
import Charts

// MARK: - Next Block Choice

enum NextBlockChoice {
    case newHypertrophyMeso
    case maintenanceBlock
    case custom
}

// MARK: - Main View

struct MesoSummaryView: View {
    let meso: MesoBlock
    let onNextBlock: (NextBlockChoice) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var analysis: MesoAnalysis? = nil
        @State private var analysisComplete: Bool = false
    @State private var expandedExerciseId: String? = nil
    @State private var showMaintenancePathChoice: Bool = false
    @State private var showProgramPicker: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if let analysis = analysis {
                                    ScrollView {
                                        VStack(spacing: 20) {
                                            verdictHeader(analysis)
                                            statsRow(analysis)
                                            volumeRampChart(analysis)
                                            exerciseSection(analysis)
                                            nextBlockSection(analysis)
                                        }
                                        .padding()
                                    }
                                } else if analysisComplete {
                                    VStack(spacing: 16) {
                                        Image(systemName: "chart.bar.xaxis")
                                            .font(.system(size: 48))
                                            .foregroundStyle(.secondary)
                                        Text("No completed sessions yet")
                                            .font(.headline)
                                        Text("Complete at least one session to see your meso analysis.")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 32)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    ProgressView("Analyzing meso...")
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
            }
            .navigationTitle(meso.status == .archived ? "Meso Complete" : "Meso Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                            buildAnalysis()
                        }
            .sheet(isPresented: $showProgramPicker) {
                MaintenanceProgramPickerView {
                    onNextBlock(.maintenanceBlock)
                    dismiss()
                }
            }
        }
    }

    // MARK: - Build analysis

    private func buildAnalysis() {
            let descriptor = FetchDescriptor<Session>(
                sortBy: [SortDescriptor(\Session.date, order: .forward)]
            )
            let allSessions = (try? context.fetch(descriptor)) ?? []
            let mesoSessionIDs = Set(meso.sessions.map { $0.persistentModelID })
            let priorSessions = allSessions.filter { !mesoSessionIDs.contains($0.persistentModelID) }

        analysis = MesoPerformanceAnalyzer.analyze(meso: meso, allPriorSessions: priorSessions)
                    analysisComplete = true
        }
    
    private func seedMaintenanceBlock() {
            // Derive training weekdays from the MODE weekday per dayLabel, not a
            // union of every weekday ever seen across the meso. Unioning absorbs
            // one-off anomalies (e.g. a skip/reorder that landed a session on a
            // normal rest day), permanently corrupting the maintenance schedule.
            var weekdayCountsByLabel: [String: [Int: Int]] = [:]
            for session in meso.sessions {
                let label = session.dayLabel ?? "Day \(session.programIndex)"
                let weekday = Calendar.current.component(.weekday, from: session.date)
                weekdayCountsByLabel[label, default: [:]][weekday, default: 0] += 1
            }

            let trainingWeekdays = weekdayCountsByLabel.values
                .compactMap { counts in counts.max(by: { $0.value < $1.value })?.key }
                .reduce(into: Set<Int>()) { $0.insert($1) }
                .sorted()

            let startDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()

            do {
                try MaintenanceProgramSeeder.seed(
                    from: meso,
                    trainingWeekdays: trainingWeekdays,
                    totalWeeks: 4,
                    startDate: startDate,
                    context: context
                )
                MesoLifecycle.confirmStartNewMeso(on: startDate)
                AppStateBridge.setActiveMesoStartDate(startDate, in: context)
                onNextBlock(.maintenanceBlock)
                dismiss()
            } catch {
                print("ERROR MaintenanceProgramSeeder: \(error)")
            }
        }

    // MARK: - Verdict header

    private func verdictHeader(_ analysis: MesoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(analysis.mesoName)
                        .font(.headline)
                    Text("\(analysis.totalWeeks) weeks · \(analysis.completedSessions) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                verdictBadge(analysis.overallVerdict)
            }

            Text(analysis.verdictNarrative)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 2, y: 1)
        )
    }

    // MARK: - Stats row

    private func statsRow(_ analysis: MesoAnalysis) -> some View {
        HStack(spacing: 0) {
            statCell(label: "Volume", value: formatVolume(analysis.totalVolume))
            Divider().frame(height: 40)
            statCell(label: "Sets", value: "\(analysis.totalSets)")
            Divider().frame(height: 40)
            statCell(label: "Reps", value: "\(analysis.totalReps)")
            Divider().frame(height: 40)
            statCell(label: "PRs", value: "\(analysis.exerciseSummaries.filter { $0.isPR }.count)")
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 2, y: 1)
        )
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Volume ramp chart

    private func volumeRampChart(_ analysis: MesoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weekly volume")
                .font(.subheadline.bold())

            Chart {
                ForEach(analysis.weeklyVolume, id: \.weekIndex) { week in
                    BarMark(
                        x: .value("Week", "W\(week.weekIndex)"),
                        y: .value("Volume", week.totalVolume)
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .cornerRadius(4)
                }
            }
            .frame(height: 120)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatVolume(v))
                                .font(.caption2)
                        }
                    }
                    AxisGridLine()
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 2, y: 1)
        )
    }

    // MARK: - Exercise section

    private func exerciseSection(_ analysis: MesoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By exercise")
                .font(.subheadline.bold())

            VStack(spacing: 8) {
                ForEach(analysis.exerciseSummaries, id: \.exerciseId) { summary in
                    exerciseRow(summary)
                }
            }
        }
    }

    private func exerciseRow(_ summary: ExercisePerformanceSummary) -> some View {
        let isExpanded = expandedExerciseId == summary.exerciseId

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedExerciseId = isExpanded ? nil : summary.exerciseId
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(summary.exerciseName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            if summary.isPR {
                                Text("PR")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.orange)
                                    .clipShape(Capsule())
                            }
                        }

                        if let muscle = summary.primaryMuscle {
                            Text(muscle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                                            verdictBadge(summary.verdict)

                                            if let open = summary.openingLoad, let close = summary.closingLoad, open > 0 {
                                                Text("\(formatLoad(open)) → \(formatLoad(close))")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }

                                            if summary.totalSets > 0 {
                                                Text("\(summary.totalSets) sets · \(formatVolume(summary.totalVolume))")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .buttonStyle(.plain)

            if isExpanded && !summary.e1rmBySession.isEmpty {
                Divider()
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    if let peak = summary.peakE1RM {
                                            HStack {
                                                Text("Peak e1RM")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Text(String(format: "%.0f", peak))
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                            }
                                        }

                                        if summary.totalSets > 0 {
                                            HStack {
                                                Text("Volume")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Text("\(summary.totalSets) sets · \(summary.totalReps) reps · \(formatVolume(summary.totalVolume))")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                            }
                                        }

                    if summary.e1rmBySession.count >= 2 {
                        Chart {
                            ForEach(Array(summary.e1rmBySession.enumerated()), id: \.offset) { idx, point in
                                LineMark(
                                    x: .value("Session", idx),
                                    y: .value("e1RM", point.e1rm)
                                )
                                .foregroundStyle(Color.blue)
                                .interpolationMethod(.catmullRom)

                                PointMark(
                                    x: .value("Session", idx),
                                    y: .value("e1RM", point.e1rm)
                                )
                                .foregroundStyle(Color.blue)
                                .symbolSize(25)
                            }
                        }
                        .frame(height: 80)
                        .chartXAxis(.hidden)
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                                AxisValueLabel {
                                    if let v = value.as(Double.self) {
                                        Text("\(Int(v))")
                                            .font(.caption2)
                                    }
                                }
                                AxisGridLine()
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
                .shadow(radius: 1, y: 1)
        )
    }

    // MARK: - Next block section

    private func nextBlockSection(_ analysis: MesoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's next?")
                .font(.subheadline.bold())

            Text(nextBlockRecommendationText(analysis))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                nextBlockButton(
                    title: "Start new hypertrophy meso",
                    subtitle: "Pick up where you left off. Loads anchor from this meso's peak.",
                    icon: "arrow.up.forward.circle",
                    color: .blue
                ) {
                    onNextBlock(.newHypertrophyMeso)
                    dismiss()
                }

                nextBlockButton(
                                    title: "Start maintenance block",
                                    subtitle: "Hold your gains. Reduced volume, same loads, lower RIR targets.",
                                    icon: "equal.circle",
                                    color: .green
                                ) {
                                    showMaintenancePathChoice = true
                                }
                                .confirmationDialog(
                                    "Start maintenance block",
                                    isPresented: $showMaintenancePathChoice,
                                    titleVisibility: .visible
                                ) {
                                    Button("Continue current split") {
                                        seedMaintenanceBlock()
                                    }
                                    Button("Choose a new program") {
                                        showProgramPicker = true
                                    }
                                    Button("Cancel", role: .cancel) { }
                                } message: {
                                    Text("Continue your current split at reduced volume, or switch to a different program structure for this maintenance phase.")
                                }

                nextBlockButton(
                    title: "I'll decide later",
                    subtitle: "Close this summary and configure the next block manually.",
                    icon: "clock",
                    color: .secondary
                ) {
                    dismiss()
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 2, y: 1)
        )
    }

    private func nextBlockButton(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
    }

    private func nextBlockRecommendationText(_ analysis: MesoAnalysis) -> String {
        switch analysis.overallVerdict {
        case .progressing:
            return "You're responding well. A new hypertrophy meso is the right call — you have room to climb higher."
        case .plateaued:
            return "Performance held steady. Either path works — a new meso will push you forward, or maintenance will consolidate what you've built."
        case .declining:
            return "Fatigue accumulated this block. A maintenance phase before the next accumulation meso will let you recover and come back stronger."
        case .insufficient:
            return "Choose your next block when you're ready."
        }
    }

    // MARK: - Helpers

    private func verdictBadge(_ verdict: ExerciseVerdict) -> some View {
        let (label, color): (String, Color) = {
            switch verdict {
            case .progressing:  return ("↑ Progressing", .green)
            case .plateaued:    return ("→ Holding", .blue)
            case .declining:    return ("↓ Declining", .orange)
            case .insufficient: return ("—", .secondary)
            }
        }()

        return Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func formatLoad(_ load: Double) -> String {
        load == load.rounded() ? "\(Int(load))" : String(format: "%.1f", load)
    }

    private func formatVolume(_ volume: Double) -> String {
        if volume >= 1_000_000 {
            return String(format: "%.1fM", volume / 1_000_000)
        } else if volume >= 1_000 {
            return String(format: "%.0fK", volume / 1_000)
        }
        return "\(Int(volume))"
    }
}
