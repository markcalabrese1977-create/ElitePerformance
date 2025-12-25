import SwiftUI

// MARK: - Warm-up Card (UI only, no model changes)

struct WarmupCardView: View {

    enum LoadRounding {
        case barbell    // round to 5
        case dumbbell   // round to 2.5
        case machine    // round to 2.5 (pin/cable), allow decimals display
    }

    let sessionKey: String
    let firstExerciseName: String
    let firstExercisePlannedLoad: Double?   // nil => show % guidance
    let rounding: LoadRounding

    @AppStorage private var crankyJoint: Bool
    @AppStorage private var doneRaw: String

    init(
        sessionKey: String,
        firstExerciseName: String,
        firstExercisePlannedLoad: Double?,
        rounding: LoadRounding
    ) {
        self.sessionKey = sessionKey
        self.firstExerciseName = firstExerciseName
        self.firstExercisePlannedLoad = firstExercisePlannedLoad
        self.rounding = rounding

        self._crankyJoint = AppStorage(wrappedValue: false, "warmup_crankyJoint_\(sessionKey)")
        self._doneRaw     = AppStorage(wrappedValue: "",    "warmup_done_\(sessionKey)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack {
                Text("Warm-up (Non-negotiable)")
                    .font(.headline)

                Spacer()

                Toggle("Cranky", isOn: $crankyJoint)
                    .labelsHidden()
            }

            section(title: "1) Base (5–6 min)") {
                row("2 min easy cardio (bike / incline walk)")
                row("Scap push-ups ×10")
                row("Band pull-aparts ×15")
                row("Bodyweight RDL / hip hinge ×10")
                row("Squat-to-stand ×6 (or squat pry 20s)")
                row("Dead bug ×6/side (or plank 20–30s)")

                Text("Rule: if this makes you tired, you’re doing it too hard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            section(title: "2) Primer (60–90 sec)") {
                ForEach(primerSteps(for: firstExerciseName), id: \.self) { step in
                    row(step)
                }
            }

            section(title: "3) Ramp sets (first lift only)") {
                ForEach(rampSteps(), id: \.self) { step in
                    row(step)
                }

                Text("Rest: 30–60s early, then 90–150s before your first work set.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - Sections / rows

    @ViewBuilder
    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ text: String) -> some View {
        Button {
            toggleDone(text)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isDone(text) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                Text(text)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Done state (persisted via AppStorage, no models)

    private func doneSet() -> Set<String> {
        let parts = doneRaw
            .split(separator: "¦") // uncommon delimiter
            .map(String.init)
        return Set(parts)
    }

    private func isDone(_ key: String) -> Bool {
        doneSet().contains(key)
    }

    private func toggleDone(_ key: String) {
        var s = doneSet()
        if s.contains(key) { s.remove(key) } else { s.insert(key) }
        doneRaw = s.sorted().joined(separator: "¦")
    }

    // MARK: - Primer logic

    private func primerSteps(for exerciseName: String) -> [String] {
        let n = exerciseName.lowercased()

        if n.contains("bench") || n.contains("press") {
            return ["Cable/Band external rotations ×12/side (or light face pulls ×12)"]
        }

        if n.contains("pulldown") || n.contains("pull down") {
            return ["Straight-arm pulldown (light) ×12 — shoulders down, lats on"]
        }

        if n.contains("hack squat") || (n.contains("hack") && n.contains("squat")) {
            return ["Ankle rocks ×10/side", "Glute bridge ×10 — knees track, hips online"]
        }

        if n.contains("rdl") || n.contains("romanian") {
            return ["Hamstring floss ×8/side", "Hip hinge drill ×8 — brace + neutral spine"]
        }

        return ["Do 1 light “patterning” set of the first lift ×10 (very easy)"]
    }

    // MARK: - Ramp logic

    private func rampSteps() -> [String] {
        guard let top = firstExercisePlannedLoad, top > 0 else {
            var steps = [
                "Ramp 1: ~50% ×8–10",
                "Ramp 2: ~70% ×4–6",
                "Ramp 3: ~85% ×1–3",
                "→ then working sets"
            ]
            if crankyJoint {
                steps.insert("Extra light ramp: ~35–40% ×8 (cranky-joint rule)", at: 0)
            }
            return steps
        }

        let r1 = format(rounded(top * 0.50))
        let r2 = format(rounded(top * 0.70))
        let r3 = format(rounded(top * 0.85))
        let wk = format(rounded(top))

        var steps: [String] = []
        if crankyJoint {
            steps.append("Extra light ramp: \(format(rounded(top * 0.40))) ×8 (cranky-joint rule)")
        }

        steps.append("Ramp 1: \(r1) ×8–10")
        steps.append("Ramp 2: \(r2) ×4–6")
        steps.append("Ramp 3: \(r3) ×1–3")
        steps.append("→ then working sets @ \(wk)")

        return steps
    }

    private func rounded(_ value: Double) -> Double {
        switch rounding {
        case .barbell:
            let step = 5.0
            return (value / step).rounded() * step
        case .dumbbell, .machine:
            let step = 2.5
            return (value / step).rounded() * step
        }
    }

    private func format(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))"
        } else {
            return String(format: "%.1f", value)
        }
    }
}
