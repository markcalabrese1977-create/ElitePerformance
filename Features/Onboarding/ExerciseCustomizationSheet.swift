import SwiftUI

/// One letter's editable prescription in the customization sheet.
struct WaveDraft: Equatable {
    var repMin: Int
    var repMax: Int
    var rir: Int
    var sets: Int
}

/// The pure part of the customization sheet: copying a letter to every letter, and turning the drafts into an override.
enum WaveCustomization {

    static let editableWaves: [WaveType] = [.a, .b, .c]

    /// "Apply to all week types": the edited letter's sets, rep range and RIR on every other non-deload letter. The source is
    /// unchanged; deload is never in the drafts.
    static func applyToAll(from source: WaveType, drafts: [WaveType: WaveDraft]) -> [WaveType: WaveDraft] {
        guard let draft = drafts[source] else { return drafts }
        var out = drafts
        for wave in editableWaves where wave != source { out[wave] = draft }
        return out
    }

    /// The override the drafts describe. Reps and RIR are per letter. Sets: a letter whose sets the lifter did not change keeps its
    /// per-week ramp (the existing override's weeks, else the template's); a letter whose sets were changed gets that number in
    /// every one of its weeks. Deload weeks are never touched.
    static func override(drafts: [WaveType: WaveDraft], loaded: [WaveType: WaveDraft], template: ProgramTemplate,
                         exerciseTemplate: ProgramExerciseTemplate, existing: ExerciseWaveOverride?) -> ExerciseWaveOverride {
        var wavePrescriptions: [WaveType: WavePrescriptionOverride] = [:]
        for wave in editableWaves {
            guard let draft = drafts[wave] else { continue }
            wavePrescriptions[wave] = WavePrescriptionOverride(repMin: draft.repMin, repMax: draft.repMax, targetRIR: draft.rir)
        }
        var setsByWeek = Array(repeating: 0, count: max(template.totalWeeks, 1))
        for weekNumber in 1...max(template.totalWeeks, 1) {
            let idx = weekNumber - 1
            guard let rule = template.rule(forWeek: weekNumber) else { continue }
            let kept: Int = {
                if let overridden = existing?.setsByWeek, idx < overridden.count { return overridden[idx] }
                return exerciseTemplate.sets(forWeek: weekNumber, wave: rule.wave)
            }()
            if rule.wave != .deload, let draft = drafts[rule.wave], draft.sets != loaded[rule.wave]?.sets {
                setsByWeek[idx] = draft.sets
            } else if rule.wave != .deload {
                setsByWeek[idx] = kept
            } else {
                setsByWeek[idx] = exerciseTemplate.sets(forWeek: weekNumber, wave: rule.wave)
            }
        }
        return ExerciseWaveOverride(wavePrescriptions: wavePrescriptions, setsByWeek: setsByWeek)
    }
}

/// Per-exercise, per-wave (A/B/C) override editor shown from the onboarding
/// Week 1 preview. Deload is never editable here — it always reflects the
/// template default (see ExerciseWaveOverride / DUPProgramSeeder.applying).
struct ExerciseCustomizationSheet: View {
    let exerciseId: String
    let exerciseTemplate: ProgramExerciseTemplate
    let template: ProgramTemplate
    let existingOverride: ExerciseWaveOverride?
    let onApply: (ExerciseWaveOverride) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [WaveType: WaveDraft] = [:]
    // Snapshot of `drafts` as loadDrafts() produced it. The swipe-dismiss
    // auto-commit compares against this so merely opening an exercise and
    // swiping away doesn't write an override (which would flag it "customized").
    @State private var loadedDrafts: [WaveType: WaveDraft] = [:]
    // Tracks whether an explicit button (Apply/Cancel/Reset) already handled the close.
    // onDisappear commits only when this is still false — i.e. an interactive swipe-dismiss.
    @State private var didCommitOrCancel = false
    @State private var confirmReset = false

    private var editableWaves: [WaveType] { WaveCustomization.editableWaves }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(editableWaves, id: \.self) { wave in
                    Section(wave.displayName) {
                        Stepper(
                            "Sets: \(drafts[wave]?.sets ?? 1)",
                            value: binding(for: wave, keyPath: \.sets),
                            in: 1...6
                        )
                        Stepper(
                            "Rep min: \(drafts[wave]?.repMin ?? 1)",
                            value: binding(for: wave, keyPath: \.repMin),
                            in: 1...30
                        )
                        Stepper(
                            "Rep max: \(drafts[wave]?.repMax ?? 1)",
                            value: binding(for: wave, keyPath: \.repMax),
                            in: 1...30
                        )
                        Stepper(
                            "Target RIR: \(drafts[wave]?.rir ?? 0)",
                            value: binding(for: wave, keyPath: \.rir),
                            in: 0...5
                        )
                        Button("Apply to all week types") {
                            drafts = WaveCustomization.applyToAll(from: wave, drafts: drafts)
                        }
                        .accessibilityIdentifier("applyToAllWeekTypes-\(wave.rawValue)")
                    }
                }

                if let deload = exerciseTemplate.prescription(for: .deload) {
                    Section("Deload (fixed)") {
                        Text("\(deload.defaultSetCount) sets · \(deload.repMin)-\(deload.repMax) reps @ \(deload.targetRIRMax) RIR")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(ExerciseCatalog.displayName(for: exerciseId))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        didCommitOrCancel = true
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        didCommitOrCancel = true
                        onApply(buildOverride())
                        dismiss()
                    }
                }
                if existingOverride != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Reset to default", role: .destructive) {
                            confirmReset = true
                        }
                    }
                }
            }
            .confirmationDialog("Reset to default?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset to default", role: .destructive) {
                    didCommitOrCancel = true
                    onReset()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your custom prescription for this exercise is removed and the program default is used again.")
            }
            .onAppear { loadDrafts() }
            .onDisappear {
                guard !didCommitOrCancel, !drafts.isEmpty, drafts != loadedDrafts else { return }
                onApply(buildOverride())
            }
        }
    }

    private func loadDrafts() {
        // SwiftUI can reuse this view's @State across successive presentations
        // from the same .sheet position. Without this reset, the guard stays
        // armed after the first Apply/Cancel and every later swipe-dismiss
        // silently discards the user's edits.
        didCommitOrCancel = false

        for wave in editableWaves {
            let weekNumber = template.weekRules.first(where: { $0.wave == wave })?.weekNumber ?? 1
            let prescription = exerciseTemplate.prescription(for: wave)
            let waveOverride = existingOverride?.wavePrescriptions?[wave]

            let repMin = waveOverride?.repMin ?? prescription?.repMin ?? 1
            let repMax = waveOverride?.repMax ?? prescription?.repMax ?? 1
            let rir = waveOverride?.targetRIR ?? prescription?.targetRIRMax ?? 0

            let sets: Int
            if let overriddenSets = existingOverride?.setsByWeek, weekNumber - 1 < overriddenSets.count {
                sets = overriddenSets[weekNumber - 1]
            } else {
                sets = exerciseTemplate.sets(forWeek: weekNumber, wave: wave)
            }

            drafts[wave] = WaveDraft(repMin: repMin, repMax: repMax, rir: rir, sets: sets)
        }

        loadedDrafts = drafts
    }

    private func buildOverride() -> ExerciseWaveOverride {
        WaveCustomization.override(drafts: drafts, loaded: loadedDrafts, template: template,
                                   exerciseTemplate: exerciseTemplate, existing: existingOverride)
    }

    private func binding(for wave: WaveType, keyPath: WritableKeyPath<WaveDraft, Int>) -> Binding<Int> {
        Binding(
            get: { drafts[wave]?[keyPath: keyPath] ?? 0 },
            set: { newValue in
                var draft = drafts[wave] ?? WaveDraft(repMin: 1, repMax: 1, rir: 0, sets: 1)
                draft[keyPath: keyPath] = newValue
                drafts[wave] = draft
            }
        )
    }
}
