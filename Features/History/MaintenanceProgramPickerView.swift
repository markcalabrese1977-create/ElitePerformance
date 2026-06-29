// Features/History/MaintenanceProgramPickerView.swift
import SwiftUI
import SwiftData

/// Path B picker: lets the user choose a different program structure for
/// their maintenance block instead of continuing their current split.
/// Lists available structural templates by name + days/week, plus a
/// duration picker (4/6/8/12 weeks). On confirm, seeds via
/// MaintenanceProgramSeeder.seedFromNewProgram(...).
struct MaintenanceProgramPickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let startDate: Date
    let onSeeded: () -> Void

    @State private var selectedTemplate: ProgramTemplate?
    @State private var selectedWeeks: Int = 4
    @State private var isSeeding = false
    @State private var errorMessage: String?

    private let availableTemplates: [ProgramTemplate] = [
        FullBody2DayTemplate.template,
        PPL3WeekTemplate.template,
        UpperLower4DayTemplate.template,
        Hybrid5DayTemplate.template,
        DUP10WeekTemplate.template,
        PPL6DayTemplate.template
    ]

    private let durationOptions = [4, 6, 8, 12]

    var body: some View {
        NavigationStack {
            Form {
                Section("Choose a program") {
                    ForEach(availableTemplates) { template in
                        Button {
                            selectedTemplate = template
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(template.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text("\(template.trainingDaysPerWeek) days/week")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedTemplate?.id == template.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedTemplate != nil {
                    Section("Duration") {
                        Picker("Weeks", selection: $selectedWeeks) {
                            ForEach(durationOptions, id: \.self) { weeks in
                                Text("\(weeks) weeks").tag(weeks)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        seed()
                    }
                    .disabled(selectedTemplate == nil || isSeeding)
                }
            }
        }
    }

    private func seed() {
        guard let template = selectedTemplate else { return }
        isSeeding = true
        errorMessage = nil

        do {
            try MaintenanceProgramSeeder.seedFromNewProgram(
                template: template,
                totalWeeks: selectedWeeks,
                startDate: startDate,
                context: context
            )
            MesoLifecycle.confirmStartNewMeso(on: startDate)
            AppStateBridge.setActiveMesoStartDate(startDate, in: context)
            isSeeding = false
            onSeeded()
            dismiss()
        } catch {
            isSeeding = false
            errorMessage = "Couldn't start the new program: \(error.localizedDescription)"
        }
    }
}
