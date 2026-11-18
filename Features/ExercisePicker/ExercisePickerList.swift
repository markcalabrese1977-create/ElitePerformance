// Features/ExercisePicker/ExercisePickerList.swift
import SwiftUI
import SwiftData

/// THE exercise picker: every swap and every add (in a session, on the day page, in the onboarding / Change program preview)
/// is this view. Search (case and diacritics ignored, names and common aliases, custom exercises included), A-Z sections with a
/// side index, recent picks first when the search is empty, and for a swap the suggested alternatives above A-Z.
struct ExercisePickerList: View {

    enum Mode {
        case add
        /// Replace `currentExerciseId`. `footer` is a note under the list (Today's swap says to replace the rest from the Program tab).
        case swap(currentExerciseId: String, currentName: String, footer: String? = nil)
    }

    let mode: Mode
    let onSelect: (CatalogExercise) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var showingCreateCustom = false
    @State private var refreshToken = UUID()
    @State private var mappingTarget: MappingTarget?
    @State private var pendingCustomDelete: [CatalogExercise] = []

    private var title: String {
        if case .swap = mode { return "Swap Exercise" }
        return "Add Exercise"
    }

    private var current: CatalogExercise? {
        guard case .swap(let id, _, _) = mode else { return nil }
        let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
        return ExerciseCatalog.all.first { $0.id == canonical }
    }

    /// The built-ins plus every custom exercise (the store's and the universal list's), one row each.
    private var allExercises: [CatalogExercise] {
        var seen = Set<String>()
        return (ExerciseCatalog.all + ExerciseCatalog.customExercises(in: modelContext)).filter { seen.insert($0.id).inserted }
    }

    private var customIds: Set<String> {
        Set(ExerciseCatalog.customExercises(in: modelContext).map(\.id)).union(ExerciseCatalog.all.filter { ex in !ExerciseCatalog.builtIn.contains { $0.id == ex.id } }.map(\.id))
    }

    private var sections: [ExercisePickerModel.Section] {
        ExercisePickerModel.sections(exercises: allExercises, query: searchText, recentIds: ExercisePickerRecents().ids, swapping: current)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                let shown = sections
                List {
                    Section {
                        Button { showingCreateCustom = true } label: {
                            Label("Create Custom Exercise", systemImage: "plus.circle.fill")
                        }
                        if case .swap(_, let name, _) = mode {
                            Text("Choose a replacement for \(name)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    if shown.isEmpty {
                        Section { Text("No exercises match “\(searchText)”.").foregroundStyle(.secondary) }
                    }
                    ForEach(shown) { section in
                        Section {
                            ForEach(section.exercises) { ex in row(ex) }
                        } header: {
                            Text(section.title).id("hdr-\(section.id)")
                        }
                    }

                    if case .swap(_, _, let footer?) = mode {
                        Section { } footer: { Text(footer) }
                    }
                }
                .id(refreshToken)
                .overlay(alignment: .trailing) {
                    if searchText.isEmpty { SectionIndex(letters: ExercisePickerModel.indexLetters(shown)) { letter in
                        proxy.scrollTo("hdr-letter-\(letter)", anchor: .top)
                    } }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exerciseCatalogDidChange)) { _ in refreshToken = UUID() }
            .confirmationDialog(
                "Delete custom exercise?",
                isPresented: Binding(get: { !pendingCustomDelete.isEmpty }, set: { if !$0 { pendingCustomDelete = [] } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    ExerciseCatalog.deleteCustomExercises(ids: pendingCustomDelete.map(\.id), in: modelContext)
                    pendingCustomDelete = []
                    refreshToken = UUID()
                }
                Button("Cancel", role: .cancel) { pendingCustomDelete = [] }
            } message: {
                Text("Delete \(pendingCustomDelete.map(\.name).joined(separator: ", "))? It disappears from the exercise picker and its muscle mapping is lost. Sessions that already use it keep their logged history.")
            }
            .sheet(item: $mappingTarget) { target in CustomMuscleMappingSheet(exerciseId: target.id) }
            .sheet(isPresented: $showingCreateCustom) {
                CreateCustomExerciseSheet(
                    onDone: { newEx in
                        showingCreateCustom = false
                        pick(newEx)
                    },
                    onCancel: { showingCreateCustom = false }
                )
            }
        }
    }

    private func pick(_ ex: CatalogExercise) {
        ExercisePickerRecents().record(ex.id)
        onSelect(ex)
    }

    @ViewBuilder
    private func row(_ ex: CatalogExercise) -> some View {
        let isCustom = customIds.contains(ex.id)
        Button { pick(ex) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ex.name).font(.body).foregroundStyle(.primary)
                    if isCustom {
                        Text("Custom").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
                    }
                }
                Text(ex.primaryMuscle.rawValue.capitalized + (ex.isCompound ? " · Compound" : " · Isolation"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())          // the whole row taps
        }
        .buttonStyle(.plain)                     // names read as text, not as links
        .swipeActions(edge: .leading) {
            if isCustom {
                Button { mappingTarget = MappingTarget(id: ex.id) } label: {
                    Label("Muscles", systemImage: "figure.strengthtraining.traditional")
                }
                .tint(.indigo)
            }
        }
        .swipeActions(edge: .trailing) {
            if isCustom {
                Button(role: .destructive) { pendingCustomDelete = [ex] } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

/// The A-Z strip down the trailing edge: tap or drag to jump to a section.
private struct SectionIndex: View {
    let letters: [String]
    let jump: (String) -> Void
    @State private var lastLetter: String?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { l in
                    Text(l).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                        .frame(maxWidth: .infinity).frame(height: max(12, min(18, geo.size.height / CGFloat(max(letters.count, 1)))))
                }
            }
            .frame(width: 22)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !letters.isEmpty else { return }
                let rowHeight = max(12, min(18, geo.size.height / CGFloat(letters.count)))
                let index = min(max(Int((value.location.y - 4) / rowHeight), 0), letters.count - 1)
                let letter = letters[index]
                if letter != lastLetter { lastLetter = letter; jump(letter) }
            }.onEnded { _ in lastLetter = nil })
            .frame(maxHeight: .infinity, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 22)
        .accessibilityHidden(true)
    }
}
