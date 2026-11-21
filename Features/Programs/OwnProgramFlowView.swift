// Features/Programs/OwnProgramFlowView.swift
import SwiftUI
import SwiftData

/// "Use my own program": schedule -> day names -> the exercises of each day -> one prescription each -> block length and deload ->
/// the preview with the weekly volume -> create. Reached from onboarding and from Change program; it hands back an
/// `OnboardingResult` with `ownProgram` set, and the caller takes it through the same confirmation, backup and seeding as any
/// program (Change program asks before replacing the upcoming sessions and backs up first).
struct OwnProgramFlowView: View {

    let base: OnboardingResult
    let initialWeekdays: Set<Int>
    let onCreate: (OnboardingResult) -> Void
    let onCancel: () -> Void

    enum Step: Int, CaseIterable {
        case schedule, dayNames, exercises, prescriptions, length, preview
        var title: String {
            switch self {
            case .schedule: return "Your week"
            case .dayNames: return "Name your days"
            case .exercises: return "Exercises"
            case .prescriptions: return "Sets and reps"
            case .length: return "Length"
            case .preview: return "Your program"
            }
        }
    }

    @State private var step: Step = .schedule
    @State private var dayCount: Int
    @State private var weekdays: Set<Int>
    @State private var days: [WavelessDay]
    @State private var programName = "My program"
    @State private var totalWeeks = ProgramTemplate.wavelessDefaultWeeks
    @State private var deload = false
    @State private var startDate: Date
    @State private var addingToDay: Int?
    @State private var editingSlot: SlotAddress?
    @State private var compoundDefault = OwnProgramBuilder.compoundDefault
    @State private var isolationDefault = OwnProgramBuilder.isolationDefault

    struct SlotAddress: Identifiable { let day: Int; let slot: Int; var id: String { "\(day)-\(slot)" } }

    init(base: OnboardingResult, initialWeekdays: Set<Int> = [], onCreate: @escaping (OnboardingResult) -> Void, onCancel: @escaping () -> Void) {
        self.base = base
        self.initialWeekdays = initialWeekdays
        self.onCreate = onCreate
        self.onCancel = onCancel
        let valid = initialWeekdays.filter { (1...7).contains($0) }
        let count = (2...6).contains(valid.count) ? valid.count : min(max(base.daysPerWeek, 2), 6)
        _dayCount = State(initialValue: count)
        _weekdays = State(initialValue: (2...6).contains(valid.count) ? valid : OnboardingDraft.defaultTrainingDays(for: count))
        _days = State(initialValue: OwnProgramBuilder.blankDays(count: count, names: OwnProgramBuilder.suggestedNames(count: count)))
        _startDate = State(initialValue: max(Calendar.current.startOfDay(for: base.startDate), Calendar.current.startOfDay(for: Date())))
    }

    private var spec: OwnProgramSpec {
        OwnProgramSpec(name: programName.trimmingCharacters(in: .whitespaces).isEmpty ? "My program" : programName,
                       days: days, totalWeeks: totalWeeks, deloadFinalWeek: deload)
    }

    private var canAdvance: Bool {
        switch step {
        case .schedule: return weekdays.count == dayCount
        case .dayNames: return days.allSatisfy { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        case .exercises: return days.allSatisfy { !$0.slots.isEmpty }
        case .prescriptions, .length: return true
        case .preview: return spec.isValid
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count)).padding(.horizontal)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(step.title).font(.title2.bold())
                        switch step {
                        case .schedule: schedulePage
                        case .dayNames: dayNamesPage
                        case .exercises: exercisesPage
                        case .prescriptions: prescriptionsPage
                        case .length: lengthPage
                        case .preview: previewPage
                        }
                    }
                    .padding()
                }
                bottomBar
            }
            .navigationTitle("Your own program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
            .sheet(isPresented: Binding(get: { addingToDay != nil }, set: { if !$0 { addingToDay = nil } })) {
                ExercisePickerList(mode: .add, onSelect: { exercise in
                    if let d = addingToDay, days.indices.contains(d) { days[d].slots.append(OwnProgramBuilder.newSlot(for: exercise)) }
                    addingToDay = nil
                }, onCancel: { addingToDay = nil })
            }
            .sheet(item: $editingSlot) { address in
                SlotEditor(slot: Binding(
                    get: { days.indices.contains(address.day) && days[address.day].slots.indices.contains(address.slot) ? days[address.day].slots[address.slot] : .defaults(exerciseId: "", isCompound: false) },
                    set: { if days.indices.contains(address.day), days[address.day].slots.indices.contains(address.slot) { days[address.day].slots[address.slot] = $0 } }
                ), onDone: { editingSlot = nil })
            }
        }
    }

    // MARK: Pages

    private let weekdaySymbols = Calendar.current.shortWeekdaySymbols

    private var schedulePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Stepper("Training days: \(dayCount)", value: $dayCount, in: 2...6)
                .onChange(of: dayCount) { _, new in
                    weekdays = OnboardingDraft.defaultTrainingDays(for: new)
                    days = OwnProgramBuilder.resized(days, to: new)
                    if days.allSatisfy({ $0.slots.isEmpty }) { days = OwnProgramBuilder.blankDays(count: new, names: OwnProgramBuilder.suggestedNames(count: new)) }
                }
            Text("Which days? Pick \(dayCount).").font(.subheadline.bold())
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { weekday in
                    Button { toggle(weekday) } label: {
                        Text(String(weekdaySymbols[weekday - 1].prefix(3))).font(.subheadline)
                            .padding(.horizontal, 8).padding(.vertical, 8)
                            .background(Capsule().fill(weekdays.contains(weekday) ? Color.blue.opacity(0.2) : Color(.systemGray6)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if weekdays.count != dayCount { Text("Select \(dayCount) days (\(weekdays.count) selected).").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func toggle(_ weekday: Int) {
        if weekdays.contains(weekday) { weekdays.remove(weekday) } else if weekdays.count < dayCount { weekdays.insert(weekday) }
    }

    private static let nameChips = ["Upper", "Lower", "Push", "Pull", "Legs", "Full body"]

    private var dayNamesPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Days that share a name are numbered for you (Upper A, Upper B).").font(.caption).foregroundStyle(.secondary)
            ForEach(days.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Day \(i + 1) · \(dayText(i))").font(.caption).foregroundStyle(.secondary)
                    TextField("Day name", text: Binding(get: { days[i].title }, set: { days[i].title = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("dayName-\(i)")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.nameChips, id: \.self) { chip in
                                Button(chip) { days[i].title = chip }
                                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(Color(.systemGray6)))
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func dayText(_ index: Int) -> String {
        let sorted = weekdays.sorted()
        guard sorted.indices.contains(index) else { return "" }
        return weekdaySymbols[sorted[index] - 1]
    }

    private var exercisesPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(days.indices, id: \.self) { d in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(days[d].title).font(.headline)
                        Spacer()
                        if days.indices.contains(where: { $0 != d && !days[$0].slots.isEmpty }) {
                            Menu {
                                ForEach(days.indices.filter { $0 != d && !days[$0].slots.isEmpty }, id: \.self) { s in
                                    Button("Copy \(days[s].title)") { days = OwnProgramBuilder.copyDay(days, from: s, to: d) }
                                }
                            } label: { Label("Copy day", systemImage: "doc.on.doc").font(.caption) }
                            .accessibilityIdentifier("copyDay-\(d)")
                        }
                    }
                    ForEach(Array(days[d].slots.enumerated()), id: \.offset) { s, slot in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ExerciseCatalog.displayName(for: slot.exerciseId)).font(.body)
                                Text(slot.isCompound ? "Compound" : "Isolation").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { days[d].slots.remove(at: s) } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    Button { addingToDay = d } label: { Label("Add exercise", systemImage: "plus.circle.fill") }
                        .accessibilityIdentifier("addExercise-\(d)")
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            }
        }
    }

    private var prescriptionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Every exercise gets one prescription for the whole block. Set the two defaults once, then change single exercises if you need to.")
                .font(.caption).foregroundStyle(.secondary)
            groupCard("All compounds", slot: $compoundDefault, compounds: true)
            groupCard("All isolations", slot: $isolationDefault, compounds: false)
            ForEach(days.indices, id: \.self) { d in
                VStack(alignment: .leading, spacing: 6) {
                    Text(days[d].title).font(.headline)
                    ForEach(Array(days[d].slots.enumerated()), id: \.offset) { s, slot in
                        Button { editingSlot = SlotAddress(day: d, slot: s) } label: {
                            HStack {
                                Text(ExerciseCatalog.displayName(for: slot.exerciseId)).foregroundStyle(.primary)
                                Spacer()
                                Text(Self.summary(slot, mode: setupMode)).font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// "3 × 8–10 @ RIR 2–3" (Detailed), "3 × 8–10 @ Easy–Solid" (Simple), "3 × 8–10" (Off).
    static func summary(_ s: WavelessSlot, mode: EffortMode = EffortTracking.mode) -> String {
        func r(_ a: Int, _ b: Int) -> String { a == b ? "\(a)" : "\(a)–\(b)" }
        let base = "\(s.sets) × \(r(s.repMin, s.repMax))"
        switch mode {
        case .detailed: return "\(base) @ RIR \(r(s.rirMin, s.rirMax))"
        case .simple: return "\(base) @ \(EffortTracking.plannedRangeText(s.rirMin, s.rirMax, mode: .simple) ?? "")"
        case .off: return base
        }
    }

    @AppStorage(EffortTracking.mirrorKey) private var effortRaw: String = ""
    private var setupMode: EffortMode { EffortTracking.setupMode(raw: effortRaw) }

    /// The deload week's one-line description, in the effort mode's own words.
    static func deloadFooter(mode: EffortMode) -> String {
        switch mode {
        case .detailed: return "The last week has half the sets and two more reps in reserve."
        case .simple: return "The last week has half the sets and feels easier."
        case .off: return "The last week has half the sets."
        }
    }

    private func groupCard(_ title: String, slot: Binding<WavelessSlot>, compounds: Bool) -> some View {
        let apply = { days = OwnProgramBuilder.applyPrescription(slot.wrappedValue, toCompounds: compounds, in: days) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Stepper("Sets: \(slot.wrappedValue.sets)", value: slot.sets, in: 1...8).onChange(of: slot.wrappedValue.sets) { _, _ in apply() }
            Stepper("Rep min: \(slot.wrappedValue.repMin)", value: slot.repMin, in: 1...30).onChange(of: slot.wrappedValue.repMin) { _, _ in apply() }
            Stepper("Rep max: \(slot.wrappedValue.repMax)", value: slot.repMax, in: 1...30).onChange(of: slot.wrappedValue.repMax) { _, _ in apply() }
            if setupMode == .detailed {
                Stepper("RIR min: \(slot.wrappedValue.rirMin)", value: slot.rirMin, in: 0...5).onChange(of: slot.wrappedValue.rirMin) { _, _ in apply() }
                Stepper("RIR max: \(slot.wrappedValue.rirMax)", value: slot.rirMax, in: 0...5).onChange(of: slot.wrappedValue.rirMax) { _, _ in apply() }
            } else if setupMode == .simple {
                Picker("Hardest set", selection: Binding(get: { min(slot.wrappedValue.rirMin, 3) }, set: { slot.wrappedValue.rirMin = $0 })) {
                    ForEach(EffortTracking.simpleChoices, id: \.rir) { Text($0.label).tag($0.rir) }
                }.onChange(of: slot.wrappedValue.rirMin) { _, _ in apply() }
                Picker("Easiest set", selection: Binding(get: { min(slot.wrappedValue.rirMax, 3) }, set: { slot.wrappedValue.rirMax = $0 })) {
                    ForEach(EffortTracking.simpleChoices, id: \.rir) { Text($0.label).tag($0.rir) }
                }.onChange(of: slot.wrappedValue.rirMax) { _, _ in apply() }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var lengthPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Program name", text: $programName).textFieldStyle(.roundedBorder)
            Stepper("Block length: \(totalWeeks) weeks", value: $totalWeeks, in: ProgramTemplate.wavelessWeeks)
            Toggle("Deload in the last week", isOn: $deload)
            Text(deload ? Self.deloadFooter(mode: setupMode) : "Every week is a working week.")
                .font(.caption).foregroundStyle(.secondary)
            DatePicker("Start date", selection: $startDate, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
        }
    }

    private var previewPage: some View {
        let finalSpec = spec
        return VStack(alignment: .leading, spacing: 16) {
            Text("\(finalSpec.name) · \(finalSpec.totalWeeks) weeks · \(days.count) days a week\(deload ? " · deload in week \(finalSpec.totalWeeks)" : "")")
                .font(.subheadline).foregroundStyle(.secondary)
            PlannedVolumeCard(input: .template(finalSpec.template, .empty))
            ForEach(days.indices, id: \.self) { d in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(days[d].title) · \(dayText(d))").font(.headline)
                    ForEach(Array(days[d].slots.enumerated()), id: \.offset) { _, slot in
                        HStack {
                            Text(ExerciseCatalog.displayName(for: slot.exerciseId)).font(.subheadline)
                            Spacer()
                            Text(Self.summary(slot, mode: setupMode)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Button("Back") { if let prev = Step(rawValue: step.rawValue - 1) { step = prev } else { onCancel() } }
                .foregroundStyle(.secondary)
            Spacer()
            if step == .preview {
                Button("Create program") { create() }
                    .buttonStyle(.borderedProminent).disabled(!canAdvance)
                    .accessibilityIdentifier("createOwnProgram")
            } else {
                Button("Next") { advance() }
                    .buttonStyle(.borderedProminent).disabled(!canAdvance)
                    .accessibilityIdentifier("ownProgramNext")
            }
        }
        .padding()
        .background(.bar)
    }

    private func advance() {
        if step == .dayNames {
            let names = OwnProgramBuilder.numberedNames(days.map(\.title))
            for i in days.indices { days[i].title = names[i] }
        }
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    private func create() {
        var result = base
        result.daysPerWeek = days.count
        result.trainingDaysOfWeek = weekdays.sorted()
        result.startDate = startDate
        result.ownProgram = spec
        onCreate(result)
    }
}

/// One exercise's single prescription.
private struct SlotEditor: View {
    @AppStorage(EffortTracking.mirrorKey) private var effortRaw: String = ""
    private var setupMode: EffortMode { EffortTracking.setupMode(raw: effortRaw) }

    @Binding var slot: WavelessSlot
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(ExerciseCatalog.displayName(for: slot.exerciseId)) {
                    Stepper("Sets: \(slot.sets)", value: $slot.sets, in: 1...8)
                    Stepper("Rep min: \(slot.repMin)", value: $slot.repMin, in: 1...30)
                    Stepper("Rep max: \(max(slot.repMin, slot.repMax))", value: $slot.repMax, in: 1...30)
                    if setupMode == .detailed {
                        Stepper("RIR min: \(slot.rirMin)", value: $slot.rirMin, in: 0...5)
                        Stepper("RIR max: \(max(slot.rirMin, slot.rirMax))", value: $slot.rirMax, in: 0...5)
                    } else if setupMode == .simple {
                        Picker("Hardest set", selection: Binding(get: { min(slot.rirMin, 3) }, set: { slot.rirMin = $0 })) {
                            ForEach(EffortTracking.simpleChoices, id: \.rir) { Text($0.label).tag($0.rir) }
                        }
                        Picker("Easiest set", selection: Binding(get: { min(max(slot.rirMin, slot.rirMax), 3) }, set: { slot.rirMax = $0 })) {
                            ForEach(EffortTracking.simpleChoices, id: \.rir) { Text($0.label).tag($0.rir) }
                        }
                    }
                }
            }
            .navigationTitle("Prescription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) } }
        }
        .presentationDetents([.medium])
    }
}
