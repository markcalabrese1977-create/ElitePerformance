import SwiftUI
import SwiftData

struct SessionView: View {
    @Environment(\.modelContext) private var context
    @State var session: Session
    @State private var currentIndex: Int = 0
    @State private var restRemaining: Int = 0
    @State private var timer: Timer?

    var body: some View {
        let items = session.items.sorted { $0.order < $1.order }
        VStack(alignment: .leading, spacing: 12) {
            if items.indices.contains(currentIndex) {
                let item = items[currentIndex]
                ExercisePane(item: item)

                HStack {
                    Button("Skip") { advance(items: items) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Swap") { swap(items: items) }
                        .buttonStyle(.bordered)
                }

                if restRemaining > 0 {
                    Text("Rest: \(restRemaining)s").monospaced().padding(.top, 8)
                }
            } else {
                Text("Session complete ✅").font(.title2)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Live Session")
        .onDisappear { timer?.invalidate() }
    }

    func advance(items: [SessionItem]) {
        Haptics.tick()
        currentIndex = min(currentIndex + 1, items.count)
    }

    func swap(items: [SessionItem]) {
        // Minimal demo: do nothing (placeholder for pattern-matched alternatives)
        Haptics.warn()
    }
}

struct ExercisePane: View {
    @Environment(\.modelContext) private var context
    @State var item: SessionItem
    @State private var setNumber: Int = 1
    @State private var lastDecision: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let ex = item.exercise {
                Text(ex.name).font(.headline)
                Text("\(item.targetSets) × \(item.targetReps) @ RIR \(item.targetRIR)")
                    .foregroundStyle(.secondary)
                if let cue = ex.cues.first { Text("Coach: \(cue)") }
            }

            Stepper("Reps: \(item.targetReps)", value: $item.targetReps, in: 5...20)
            Stepper("Load: \(Int(item.suggestedLoad))", value: $item.suggestedLoad, in: 20...1000, step: 5)

            PrimaryButton(title: setNumber <= item.targetSets ? "Log Set \(setNumber)" : "Continue") {
                logSet()
            }
            if !lastDecision.isEmpty {
                Text(lastDecision).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    func logSet() {
        let log = SetLog(setNumber: setNumber,
                         targetReps: item.targetReps,
                         targetRIR: item.targetRIR,
                         targetLoad: item.suggestedLoad,
                         actualReps: item.targetReps, // for demo, assume target hit
                         actualRIR: item.targetRIR,
                         actualLoad: item.suggestedLoad)

        item.logs.append(log)
        try? context.save()

        let reps = item.logs.map { $0.actualReps }
        let decision = Progression.decideAdjustment(actualReps: reps, targetUpper: item.targetReps, repDrop: 0)
        switch decision {
        case .increase(let pct):
            item.suggestedLoad = (item.suggestedLoad * (1.0 + pct)).rounded()
            lastDecision = "Next set: +\(Int(pct*100))% (Hold form)"
        case .decrease(let pct):
            item.suggestedLoad = (item.suggestedLoad * (1.0 - pct)).rounded()
            lastDecision = "Reducing by \(Int(pct*100))% (Rebuild clean)"
        case .hold:
            lastDecision = "Hold load. Focus on tempo."
        }
        setNumber += 1
    }
}
