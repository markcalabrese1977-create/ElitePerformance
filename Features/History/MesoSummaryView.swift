// Features/History/MesoSummaryView.swift
import SwiftUI
import SwiftData
import Charts

// MARK: - Next Block Choice

enum NextBlockChoice {
    /// Carries the start date chosen on the meso-summary picker so the
    /// downstream onboarding flow seeds from it instead of defaulting to today.
    case newHypertrophyMeso(startDate: Date)
    case maintenanceBlock
    case custom
}

// MARK: - Main View

struct MesoSummaryView: View {
    @Environment(\.loadUnit) private var unit
    let meso: MesoBlock
    /// false when the summary is opened from a screen that cannot run the new-program flow (the History tab).
    var hostHandlesNewProgram: Bool = true
    let onNextBlock: (NextBlockChoice) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var analysis: MesoAnalysis? = nil
        @State private var analysisComplete: Bool = false
    @State private var expandedExerciseId: String? = nil
    @State private var showMaintenancePathChoice: Bool = false
    @State private var showProgramPicker: Bool = false
    @State private var showStartNextMeso: Bool = false
    @State private var mesoStartDate: Date = MesoLifecycle.defaultMesoStartDate
    @State private var remaining: MesoRemaining? = nil

    /// "Week 8 of 12 · 37/43 sessions" (completed / due to date).
    private var headerLine: String {
        let h = MesoHeader.compute(
            name: meso.name, totalWeeks: meso.totalWeeks,
            sessions: meso.sessions.map { ($0.date, $0.plannedDate, $0.status, $0.weekIndex) })
        return "\(h.weekText) · \(h.sessionsText)"
    }

    // Extend maintenance block (mid-block action)
    @State private var showExtendSheet: Bool = false
    @State private var additionalWeeks: Int = 2
    @State private var extendConfirmation: String? = nil
    @State private var showExtendError: Bool = false
    @State private var extendErrorMessage: String = ""

    // Repair a mis-seeded extension (manually revealed via "Something look wrong?")
    @State private var showRepairOption: Bool = false
    @State private var showRepairSheet: Bool = false
    @State private var repairOriginalWeeks: Int = 4
    @State private var repairAdditionalWeeks: Int = 2
    @State private var repairConfirmation: String? = nil
    @State private var showRepairError: Bool = false
    @State private var repairErrorMessage: String = ""

    private var canExtendMaintenance: Bool {
        meso.isMaintenance && meso.status == .active
    }

    var body: some View {
        NavigationStack {
            Group {
                if let analysis = analysis {
                                    ScrollView {
                                        VStack(spacing: 20) {
                                            verdictHeader(analysis)
                                            statsRow(analysis)
                                            volumeRampChart(analysis)
                                            MesoMuscleSection(meso: meso)
                                            exerciseSection(analysis)
                                            MesoComparisonSection(meso: meso)
                                            if canExtendMaintenance {
                                                extendBlockSection
                                            }
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
                            let r = MesoRemaining.compute(sessions: meso.sessions.map { ($0.date, $0.status) })
                            remaining = r
                            // an unfinished active meso: the next block starts the day after its last planned session
                            if meso.status == .active, !r.isFinalWeekOrOver { mesoStartDate = r.defaultStart }
                        }
            .sheet(isPresented: $showProgramPicker) {
                MaintenanceProgramPickerView(startDate: mesoStartDate) {
                    onNextBlock(.maintenanceBlock)
                    dismiss()
                }
            }
            .sheet(isPresented: $showStartNextMeso) {
                StartNextMesoFlow(meso: meso, onFinish: {
                    showStartNextMeso = false
                    dismiss()
                })
            }
            .sheet(isPresented: $showExtendSheet) {
                extendSheet
            }
            .sheet(isPresented: $showRepairSheet) {
                repairSheet
            }
            .alert("Couldn't extend block", isPresented: $showExtendError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(extendErrorMessage)
            }
            .alert("Couldn't fix extension", isPresented: $showRepairError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(repairErrorMessage)
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
            // Only what came BEFORE this meso is "prior": a later block's sessions must not make an old block's first
            // exposure look like a repeat.
            let firstDate = meso.sessions.map(\.date).min() ?? meso.startDate
            let priorSessions = allSessions.filter { !mesoSessionIDs.contains($0.persistentModelID) && $0.date < firstDate }

        let bodyWeight = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first?.bodyWeight
        analysis = AnalyticsEngine.mesoAnalysis(meso: meso, allPriorSessions: priorSessions, bodyWeight: bodyWeight)
                    analysisComplete = true
        }
    
    private func seedMaintenanceBlock() {
            // Derive training weekdays from the MODE weekday per dayLabel, not a
            // union of every weekday ever seen across the meso. Unioning absorbs
            // one-off anomalies (e.g. a skip/reorder that landed a session on a
            // normal rest day), permanently corrupting the maintenance schedule.
            var weekdayCountsByLabel: [String: [Int: Int]] = [:]
            for session in meso.sessions {
                let label = session.dayLabel ?? "Day \(session.programIndex.map(String.init) ?? "?")"
                let weekday = Calendar.current.component(.weekday, from: session.date)
                weekdayCountsByLabel[label, default: [:]][weekday, default: 0] += 1
            }

            let trainingWeekdays = weekdayCountsByLabel.values
                .compactMap { counts in counts.max(by: { $0.value < $1.value })?.key }
                .reduce(into: Set<Int>()) { $0.insert($1) }
                .sorted()

            let startDate = mesoStartDate

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

    // MARK: - Extend maintenance block

    /// Last currently-seeded session date on the active block (the day we
    /// extend from).
    private var currentEndDate: Date? {
        meso.sessions.max(by: { $0.date < $1.date })?.date
    }

    /// Approximate end date after extending by `additionalWeeks` weeks — for
    /// display only. Sessions run on a weekly cadence, so the last extension
    /// session lands ~`additionalWeeks` weeks after the current end.
    private func projectedEndDate(afterAdding weeks: Int) -> Date? {
        guard let current = currentEndDate else { return nil }
        return Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: current)
    }

    private static let extendDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var extendBlockSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extend this block")
                .font(.subheadline.bold())

            Text("Add more weeks of the same structure at the same loads and reduced volume. Existing sessions are untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let confirmation = extendConfirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            nextBlockButton(
                title: "Extend Maintenance Block",
                subtitle: extendButtonSubtitle,
                icon: "calendar.badge.plus",
                color: .teal
            ) {
                extendConfirmation = nil
                showExtendSheet = true
            }

            if let repairConfirmation = repairConfirmation {
                Label(repairConfirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showRepairOption {
                Button {
                    repairConfirmation = nil
                    showRepairSheet = true
                } label: {
                    Label("Fix Extension", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(.orange)
                }
            } else {
                Button("Something look wrong?") {
                    showRepairOption = true
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 2, y: 1)
        )
    }

    private var extendButtonSubtitle: String {
        if let end = currentEndDate {
            return "Currently ends \(Self.extendDateFormatter.string(from: end))."
        }
        return "Add 1–4 more weeks."
    }

    private var extendSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Additional weeks")
                        .font(.headline)

                    Picker("Additional weeks", selection: $additionalWeeks) {
                        ForEach(1...4, id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let end = currentEndDate {
                        Text("Current end date: \(Self.extendDateFormatter.string(from: end))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let newEnd = projectedEndDate(afterAdding: additionalWeeks) {
                        Text("New end date: ~\(Self.extendDateFormatter.string(from: newEnd))")
                            .font(.subheadline.bold())
                    }
                }

                Spacer()

                Button {
                    performExtend()
                } label: {
                    Text("Extend by \(additionalWeeks) week\(additionalWeeks == 1 ? "" : "s")")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Extend Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showExtendSheet = false }
                }
            }
        }
    }

    private func performExtend() {
        do {
            try MaintenanceProgramSeeder.extend(
                block: meso,
                additionalWeeks: additionalWeeks,
                context: context
            )
            showExtendSheet = false
            extendConfirmation = "Added \(additionalWeeks) week\(additionalWeeks == 1 ? "" : "s"). Block now runs through ~\(projectedEndDate(afterAdding: 0).map { Self.extendDateFormatter.string(from: $0) } ?? "the new end date")."
            buildAnalysis()
        } catch {
            extendErrorMessage = error.localizedDescription
            showExtendSheet = false
            showExtendError = true
        }
    }

    private var repairSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("If your extended sessions show wrong week numbers or missing days, this will remove and re-seed them correctly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Original block length")
                        .font(.headline)
                    Picker("Original block length", selection: $repairOriginalWeeks) {
                        ForEach(1...8, id: \.self) { n in
                            Text("\(n) week\(n == 1 ? "" : "s")").tag(n)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Extended by")
                        .font(.headline)
                    Picker("Extended by", selection: $repairAdditionalWeeks) {
                        ForEach(1...4, id: \.self) { n in
                            Text("\(n) week\(n == 1 ? "" : "s")").tag(n)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Spacer()

                Button {
                    performRepair()
                } label: {
                    Text("Fix Extension")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding()
            .navigationTitle("Fix Maintenance Extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRepairSheet = false }
                }
            }
        }
    }

    private func performRepair() {
        do {
            try MaintenanceProgramSeeder.repairExtension(
                block: meso,
                originalWeeks: repairOriginalWeeks,
                additionalWeeks: repairAdditionalWeeks,
                context: context
            )
            showRepairSheet = false
            showRepairOption = false
            repairConfirmation = "Re-seeded \(repairAdditionalWeeks) week\(repairAdditionalWeeks == 1 ? "" : "s") of extension sessions correctly."
            buildAnalysis()
        } catch {
            repairErrorMessage = error.localizedDescription
            showRepairSheet = false
            showRepairError = true
        }
    }

    // MARK: - Verdict header

    private func verdictHeader(_ analysis: MesoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(analysis.mesoName)
                        .font(.headline)
                    Text(headerLine)
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
            statCell(label: "Volume", value: LoadFormatter(unit: unit).volumeGrouped(analysis.totalVolume))
            Divider().frame(height: 40)
            statCell(label: "Sets", value: LoadFormatter.grouped(analysis.totalSets))
            Divider().frame(height: 40)
            statCell(label: "Reps", value: LoadFormatter.grouped(analysis.totalReps))
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
                        y: .value("Volume", unit.fromStoredLb(week.totalVolume))
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
                            Text(formatVolumeInUnit(v))
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

            Text(Self.trendCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("trendCaption")

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

                            if summary.isNew {
                                Text("New")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.teal)
                                    .clipShape(Capsule())
                            } else if summary.isPR {
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

                                            if let best = summary.bestSet {
                                                Text("best \(LoadFormatter(unit: unit).compact(best.load)) × \(best.reps)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            } else if summary.repsBased, let c = summary.closingReps {
                                                Text("\(String(format: "%.1f", c)) reps/set")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }

                                            if let change = summary.trendChange {
                                                Text("\(String(format: "%+.1f%%", change * 100)) \(trendBasisLabel(summary.trendBasis))")
                                                    .font(.caption2)
                                                    .foregroundStyle(change > 0.005 ? Color.green : (change < -0.005 ? Color.orange : Color.secondary))
                                            }

                                            if summary.totalSets > 0 {
                                                Text("\(LoadFormatter.grouped(summary.totalSets)) sets · \(LoadFormatter(unit: unit).volumeGrouped(summary.totalVolume))")
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
                                                Text(LoadFormatter(unit: unit).wholeGrouped(peak))
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
                                                Text("\(LoadFormatter.grouped(summary.totalSets)) sets · \(LoadFormatter.grouped(summary.totalReps)) reps · \(LoadFormatter(unit: unit).volumeGrouped(summary.totalVolume))")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                            }
                                        }

                    if summary.e1rmBySession.count >= 2 {
                        Chart {
                            ForEach(Array(summary.e1rmBySession.enumerated()), id: \.offset) { idx, point in
                                LineMark(
                                    x: .value("Session", idx),
                                    y: .value("e1RM", unit.fromStoredLb(point.e1rm))
                                )
                                .foregroundStyle(Color.blue)
                                .interpolationMethod(.catmullRom)

                                PointMark(
                                    x: .value("Session", idx),
                                    y: .value("e1RM", unit.fromStoredLb(point.e1rm))
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

            Text(nextBlockHeadline(analysis))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Start date picker — shared by Path A (continue split) and
            // Path B (new program). The date chosen here flows into both
            // seedMaintenanceBlock() and MaintenanceProgramPickerView.
            HStack {
                Text("Start date")
                    .font(.subheadline)
                Spacer()
                DatePicker(
                    "Start date",
                    selection: $mesoStartDate,
                    in: MesoLifecycle.mesoStartDateRange.lowerBound...max(MesoLifecycle.mesoStartDateRange.upperBound, mesoStartDate),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
            }

            VStack(spacing: 10) {
                nextBlockButton(
                    title: "Start next meso from this one",
                    subtitle: "Same exercises, sets, rep targets and cues on new dates. Starting loads are 95% of your best set in this meso.",
                    icon: "arrow.triangle.branch",
                    color: .blue
                ) {
                    showStartNextMeso = true
                }

                if hostHandlesNewProgram {
                nextBlockButton(
                    title: "New program from template",
                    subtitle: "Choose a program and set it up fresh. Loads start from your recent history.",
                    icon: "arrow.up.forward.circle",
                    color: .blue
                ) {
                    onNextBlock(.newHypertrophyMeso(startDate: mesoStartDate))
                    dismiss()
                }
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

    /// While planned sessions remain before the final week there is no verdict yet, only how long is left.
    private func nextBlockHeadline(_ analysis: MesoAnalysis) -> String {
        if meso.status == .active, let r = remaining, !r.isFinalWeekOrOver {
            let last = r.lastPlannedDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
            return "\(r.weeksRemaining) week\(r.weeksRemaining == 1 ? "" : "s") remaining (\(r.remainingSessions) sessions, last on \(last)). The next block starts the day after the last planned session; pick it when this one is nearly done."
        }
        return nextBlockRecommendationText(analysis)
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

    private func trendBasisLabel(_ basis: ExerciseTrendBasis) -> String {
        switch basis {
        case .e1RM: return "e1RM"
        case .loadAtReps(let r): return "load at \(r)+ reps"
        case .reps: return "reps/set"
        case .none: return ""
        }
    }

    /// What every number on a By-exercise row measures, as the code computes it (MesoPerformanceAnalyzer):
    /// - the chip and the % are the SAME comparison: this lift's e1RM in the block's first session vs its last session
    ///   (each session's best set of 12 reps or fewer, warm-ups out; deload weeks excluded). Progressing / Declining at
    ///   +/-3% or more, else Holding. With no set of 12 reps or fewer it is the best load at matched reps instead;
    ///   a bodyweight lift with no body weight set uses reps per set.
    /// - "best" is the block's best single set of that lift (highest e1RM among sets of 12 reps or fewer).
    /// - sets and volume count the block's working sets (WorkingSetFilter: no warm-ups), load x reps.
    static let trendCaption = "Trend and % = this lift's e1RM, first → last session of the block (±3% = Holding). Best = top set of the block, load × reps. Sets · volume = working sets of the block (no warm-ups)."

    /// The chip is one word. What it measures is stated once, in `trendCaption`, under the "By exercise" header.
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
        LoadFormatter(unit: unit).compact(load)
    }

    /// A stored (lb·reps) volume, shown in the lifter's unit.
    private func formatVolume(_ storedVolume: Double) -> String {
        formatVolumeInUnit(unit.fromStoredLb(storedVolume))
    }

    /// A volume that is already in the lifter's unit (chart axis values).
    private func formatVolumeInUnit(_ volume: Double) -> String {
        if volume >= 1_000_000 {
            return String(format: "%.1fM", volume / 1_000_000)
        } else if volume >= 1_000 {
            return String(format: "%.0fK", volume / 1_000)
        }
        return "\(Int(volume))"
    }
}


// MARK: - vs previous block

/// "vs previous block": how this block's lifts, volume and adherence compare with the block it followed, plus factual
/// notes for planning the next block. Nothing here edits a plan.
struct MesoComparisonSection: View {
    let meso: MesoBlock
    @Environment(\.modelContext) private var context
    @Environment(\.loadUnit) private var unit
    @State private var comparison: MesoComparison?
    @State private var loaded = false

    private var fmt: LoadFormatter { LoadFormatter(unit: unit) }

    var body: some View {
        // A ZStack, not a Group: an empty Group has no view for `.task` to attach to, so the load would never run.
        ZStack {
            if let c = comparison {
                VStack(alignment: .leading, spacing: 14) {
                    Text("vs previous block").font(.subheadline.bold())
                    Text("\(c.current.name) vs \(c.previous.name)").font(.caption).foregroundStyle(.secondary)
                    summaryRows(c)
                    liftsGroup(c)
                    changesGroup(c)
                    musclesGroup(c)
                    notesGroup(c)
                    Text("A new block's starting loads are 95% of the previous peak, so values early in the block below the old peak are not regressions. Comparisons use regular working sets only (no deload or maintenance weeks).")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
                .accessibilityIdentifier("mesoComparisonSection")
            } else if loaded {
                EmptyView()
            }
        }
        .task { load() }
    }

    private func load() {
        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let blocks = (try? context.fetch(FetchDescriptor<MesoBlock>())) ?? []
        let customs = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let engine = AnalyticsEngine(sessions: sessions, customExercises: customs, bodyWeight: profile?.bodyWeight)
        let key = meso.id?.uuidString ?? "\(meso.persistentModelID)"
        comparison = engine.mesoComparison(blocks: blocks, customs: customs, profile: profile, currentKey: key)
        loaded = true
    }

    private func pct(_ v: Double) -> String { String(format: "%+.1f%%", v * 100) }
    private func color(_ v: Double) -> Color { v > 0.005 ? .green : (v < -0.005 ? .orange : .secondary) }

    private func summaryRows(_ c: MesoComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Sessions done", "\(c.adherencePrevious.completed)/\(c.adherencePrevious.planned) → \(c.adherenceCurrent.completed)/\(c.adherenceCurrent.planned)")
            row("Record-setting sessions", "\(c.prsPrevious) → \(c.prsCurrent)")
            let up = c.lifts.filter { $0.peakChange > 0.005 }.count, down = c.lifts.filter { $0.peakChange < -0.005 }.count
            row("Lift peaks (\(c.lifts.count) lift×letter)", "\(up) up · \(down) down")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).font(.caption); Spacer(); Text(value).font(.caption.bold()) }
    }

    private func liftsGroup(_ c: MesoComparison) -> some View {
        DisclosureGroup("Lifts: peak and top-3 e1RM (\(c.lifts.count))") {
            VStack(spacing: 6) {
                ForEach(Array(c.lifts.enumerated()), id: \.offset) { _, l in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(l.name + (l.letter.isEmpty ? "" : " \(l.letter.uppercased())")).font(.caption)
                            Spacer()
                            Text("\(fmt.wholeGrouped(l.previousPeak)) → \(fmt.wholeGrouped(l.currentPeak))").font(.caption)
                            Text(pct(l.peakChange)).font(.caption.bold()).foregroundStyle(color(l.peakChange)).frame(width: 56, alignment: .trailing)
                        }
                        HStack {
                            Text("top-3 \(fmt.wholeGrouped(l.previousTop3)) → \(fmt.wholeGrouped(l.currentTop3)) (\(pct(l.top3Change)))")
                            Spacer()
                            Text("started at \(Int((l.previousPeak > 0 ? l.currentFirst / l.previousPeak : 0) * 100))% of old peak")
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    @ViewBuilder private func changesGroup(_ c: MesoComparison) -> some View {
        if !(c.replaced.isEmpty && c.newLifts.isEmpty && c.droppedLifts.isEmpty) {
            DisclosureGroup("Exercise changes") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(c.replaced.enumerated()), id: \.offset) { _, r in Text("Replaced: \(r.old.name) → \(r.new.name)").font(.caption) }
                    ForEach(c.newLifts, id: \.id) { Text("New: \($0.name)").font(.caption) }
                    ForEach(c.droppedLifts, id: \.id) { Text("Dropped: \($0.name)").font(.caption) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }

    private func musclesGroup(_ c: MesoComparison) -> some View {
        DisclosureGroup("Weekly sets per muscle (last \(c.previousWeeksAveraged) / \(c.currentWeeksAveraged) full weeks)") {
            VStack(spacing: 4) {
                ForEach(c.muscles, id: \.muscle) { m in
                    HStack {
                        Text(m.muscle.displayName).font(.caption)
                        Spacer()
                        Text(String(format: "%.1f → %.1f", m.previousAverage, m.currentAverage)).font(.caption)
                        Text("\(Int(m.range.min))–\(Int(m.range.max))").font(.caption2).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                    .foregroundStyle(m.currentAverage < m.range.min ? Color.orange : Color.primary)
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    private func notesGroup(_ c: MesoComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Next block notes").font(.caption.bold())
            noteLine("Below range", c.notes.musclesBelowRange.map { "\($0.muscle.displayName) \(String(format: "%.1f", $0.average)) (min \(Int($0.minimum)))" })
            noteLine("Stalled", c.notes.stalledLifts)
            noteLine("Reps up at the same load (candidates for an extra set)", c.notes.earnedSetCandidates.map {
                "\($0.name)\($0.letter.isEmpty ? "" : " \($0.letter.uppercased())") \(String(format: "%.1f", $0.firstReps))→\(String(format: "%.1f", $0.lastReps)) reps\($0.atCap ? " (at your max load)" : "")"
            })
            Text("Facts only. Nothing is changed automatically.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func noteLine(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(items.isEmpty ? "None" : items.joined(separator: " · ")).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}


// MARK: - Weekly hard sets by muscle (this block)

/// "Weekly hard sets by muscle": the average over the COMPLETE weeks of this block, as weighted sets against each muscle's
/// range, plus the sets of custom exercises that have no muscle mapping yet (with a way to map them).
struct MesoMuscleSection: View {
    let meso: MesoBlock
    @Environment(\.modelContext) private var context
    @State private var summary: MuscleVolumeSummary?
    @State private var showUnmapped = false
    @State private var refresh = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weekly hard sets by muscle").font(.subheadline.bold())
            if let s = summary {
                if s.isEmpty || s.averagedWeeks == 0 {
                    Text("No complete training week in this block yet, so there is no weekly average.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("mesoMuscleEmpty")
                } else {
                    Text("Average of \(s.averagedWeeks) complete week\(s.averagedWeeks == 1 ? "" : "s") (weeks under 70% of planned sessions and deload weeks are left out). A synergist counts 0.25–0.5 of a set.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(s.rows) { row in
                        HStack {
                            Text(row.muscle.displayName).font(.caption)
                            Spacer()
                            Text(String(format: "%.1f", row.average)).font(.caption.bold())
                            Text("\(Int(row.range.min))–\(Int(row.range.max))").font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                            Text(row.status.rawValue).font(.caption2).foregroundStyle(color(row.status)).frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                let n = s.unmapped.reduce(0) { $0 + $1.sets }
                Button { showUnmapped = true } label: {
                    HStack {
                        Text("Unmapped custom sets: \(LoadFormatter.grouped(n))")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
                .accessibilityIdentifier("mesoUnmappedRow")
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)).shadow(radius: 2, y: 1))
        .task(id: refresh) { load() }
        .sheet(isPresented: $showUnmapped, onDismiss: { refresh = UUID() }) {
            UnmappedExercisesSheet(items: summary?.unmapped ?? [])
        }
    }

    private func color(_ s: MuscleVolume.Status) -> Color {
        switch s { case .below: return .orange; case .within: return .green; case .above: return .red }
    }

    private func load() {
        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let customs = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let profile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        let engine = AnalyticsEngine(sessions: sessions, customExercises: customs, bodyWeight: profile?.bodyWeight)
        let key = meso.id?.uuidString ?? "\(meso.persistentModelID)"
        summary = MuscleVolume.summary(snapshot: engine.snapshot, customs: customs, profile: profile, asOf: Date(), mesoKey: key, wholeBlock: true)
    }
}
