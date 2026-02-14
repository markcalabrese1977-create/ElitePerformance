import SwiftUI

struct ExtrasTabView: View {

    @State private var entries: [ExtrasEntry] = ExtrasLogStore.load()
    @State private var showAddSheet = false
    @State private var addKind: ExtrasEntry.Kind = .zone2

    private var zone2Target: Int {
        ExtrasPlanEngine.zone2WeeklyTarget()
    }

    private var zone2CompletedThisWeek: Int {
        ExtrasLogStore.count(kind: .zone2, inSameWeekAs: Date())
    }

    private var coreCompletedThisWeek: Int {
        ExtrasLogStore.count(kind: .core, inSameWeekAs: Date())
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summaryCard
                }

                Section("Quick Log") {
                    Button {
                        addKind = .zone2
                        showAddSheet = true
                    } label: {
                        Label("Log Zone 2", systemImage: ExtrasEntry.Kind.zone2.systemImage)
                    }

                    Button {
                        addKind = .core
                        showAddSheet = true
                    } label: {
                        Label("Log Core / Carries", systemImage: ExtrasEntry.Kind.core.systemImage)
                    }
                }

                Section("Plan") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Zone 2 target: \(zone2Target) sessions / week")
                            .font(.subheadline)

                        Text("Recommended slots: \(ExtrasPlanEngine.recommendedZone2Slots().joined(separator: " • "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(ExtrasPlanEngine.zone2PrescriptionText())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Core stability")
                            .font(.subheadline)

                        Text(ExtrasPlanEngine.corePrescriptionText())
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        coreTemplates
                    }
                    .padding(.vertical, 4)
                }

                if !entries.isEmpty {
                    Section("Log") {
                        ForEach(entries) { entry in
                            ExtrasEntryRow(entry: entry)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        ExtrasLogStore.delete(id: entry.id)
                                        reload()
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Extras")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addKind = .zone2
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear { reload() }
            .sheet(isPresented: $showAddSheet, onDismiss: reload) {
                AddExtrasEntrySheet(kind: addKind) {
                    showAddSheet = false
                    reload()
                }
            }
        }
    }

    private func reload() {
        entries = ExtrasLogStore.load()
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Week")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zone 2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(zone2CompletedThisWeek) / \(zone2Target)")
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Core")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(coreCompletedThisWeek)")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }

            Text("Rule: Thu + after D2 (+ after D4 starting W9)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 4, y: 2)
        )
    }

    private var coreTemplates: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick templates:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("• Farmer carry: 3 x 40–60s")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("• Suitcase carry: 3 x 30–45s/side")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("• Pallof press: 2–3 x 10–15/side")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("• Dead bug: 2 x 6–10/side (slow, braced)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}

private struct ExtrasEntryRow: View {
    let entry: ExtrasEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.kind.title)
                        .font(.headline)
                    Spacer()
                    Text(entry.date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let mins = entry.durationMinutes {
                    Text("\(mins) min")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !entry.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AddExtrasEntrySheet: View {
    let kind: ExtrasEntry.Kind
    let onDone: () -> Void

    @State private var date: Date = Date()
    @State private var durationMinutes: Int = 30
    @State private var notes: String = ""

    init(kind: ExtrasEntry.Kind, onDone: @escaping () -> Void) {
        self.kind = kind
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    HStack {
                        Image(systemName: kind.systemImage)
                        Text(kind.title)
                    }
                }

                Section("When") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date])
                }

                Section("Details") {
                    if kind == .zone2 {
                        Stepper(value: $durationMinutes, in: 10...90, step: 5) {
                            Text("Duration: \(durationMinutes) min")
                        }

                        Text("\"True Zone 2\": conversational pace. Leave feeling better.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Stepper(value: $durationMinutes, in: 5...30, step: 1) {
                            Text("Block: \(durationMinutes) min")
                        }

                        Text("Carries + bracing. Keep it crisp; no spinal fatigue.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextEditor(text: $notes)
                        .frame(minHeight: 90)
                }
            }
            .navigationTitle("Add \(kind.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let entry = ExtrasEntry(
                            kind: kind,
                            date: date,
                            durationMinutes: durationMinutes,
                            notes: notes
                        )
                        ExtrasLogStore.add(entry)
                        onDone()
                    }
                }
            }
        }
    }
}
