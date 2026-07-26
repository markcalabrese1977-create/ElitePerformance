import SwiftUI

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
    // Tracks whether an explicit button (Apply/Cancel/Reset) already handled the close.
    // onDisappear commits only when this is still false — i.e. an interactive swipe-dismiss.
    @State private var didCommitOrCancel = false

    private struct WaveDraft {
        var repMin: Int
        var repMax: Int
        var rir: Int
        var sets: Int
    }

    private let editableWaves: [WaveType] = [.a, .b, .c]

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
                            didCommitOrCancel = true
                            onReset()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { loadDrafts() }
            .onDisappear {
                guard !didCommitOrCancel, !drafts.isEmpty else { return }
                onApply(buildOverride())
            }
        }
    }

    private func loadDrafts() {
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
    }

    private func buildOverride() -> ExerciseWaveOverride {
        var wavePrescriptions: [WaveType: WavePrescriptionOverride] = [:]
        for wave in editableWaves {
            guard let draft = drafts[wave] else { continue }
            wavePrescriptions[wave] = WavePrescriptionOverride(
                repMin: draft.repMin,
                repMax: draft.repMax,
                targetRIR: draft.rir
            )
        }

        var setsByWeek = Array(repeating: 0, count: max(template.totalWeeks, 1))
        for weekNumber in 1...template.totalWeeks {
            let idx = weekNumber - 1
            guard let rule = template.rule(forWeek: weekNumber) else { continue }
            if rule.wave != .deload, let draft = drafts[rule.wave] {
                setsByWeek[idx] = draft.sets
            } else {
                setsByWeek[idx] = exerciseTemplate.sets(forWeek: weekNumber, wave: rule.wave)
            }
        }

        return ExerciseWaveOverride(wavePrescriptions: wavePrescriptions, setsByWeek: setsByWeek)
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
