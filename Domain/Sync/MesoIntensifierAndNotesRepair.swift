// Domain/Sync/MesoIntensifierAndNotesRepair.swift
import Foundation
import SwiftData

/// One-shot, field-only repair on the active meso:
///
/// 1. Clears every template intensifier — any item whose `intensifierRaw` is set
///    to something other than "none" gets `intensifierRaw = "none"` and
///    `intensifierNotes = nil`.
/// 2. Replaces `prescriptionNotes` across every item in every week with the
///    user's own coaching notes; any exercise not in the table is set to nil, so
///    stale template prose cannot survive.
///
/// No item construction, no load writes, no order changes — only
/// `intensifierRaw`, `intensifierNotes` and `prescriptionNotes` are touched.
///
/// Items are matched by dayLabel + canonical exerciseId. Four of the user's
/// exercises are custom records whose UUIDs are not knowable from source, so a
/// rule may also carry an exact `exerciseNameSnapshot` match — see `ExerciseKey`.
enum MesoIntensifierAndNotesRepair {

    // MARK: - Mode

    /// While true: runs every gate, prints the full plan, writes nothing and
    /// never sets the completion flag.
    static let dryRun = true

    private static let completionKey = "mesoIntensifierAndNotesRepair.v1.completed"

    private static var template: ProgramTemplate { DUP10WeekTemplate.template }

    // MARK: - Exercise matching

    /// How a rule identifies its item.
    ///
    /// `.id` is the canonical-exerciseId match asked for. `.name` exists because
    /// "Smith Machine Hip Thrust" and "Single Arm Pulldown (Kneeling)" are custom
    /// exercises whose `custom_<uuid>` ids live only in the user's store — they
    /// cannot be written down here, so those rules match on the durable
    /// `exerciseNameSnapshot` instead. A rule matches if ANY of its keys match.
    private enum ExerciseKey {
        case id(String)
        case name(String)

        func matches(_ item: SessionItem) -> Bool {
            switch self {
            case let .id(value):
                return ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                    == ExerciseCatalog.canonicalExerciseId(for: value)
            case let .name(value):
                let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let snapshot = (item.exerciseNameSnapshot ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if snapshot == wanted { return true }
                return ExerciseCatalog.displayName(for: item.exerciseId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == wanted
            }
        }

        var describe: String {
            switch self {
            case let .id(value):   return "id:\(value)"
            case let .name(value): return "name:\"\(value)\""
            }
        }
    }

    // MARK: - Note rules

    private struct NoteRule {
        let label: String
        let keys: [ExerciseKey]
        let defaultNote: String
        /// Per-wave overrides (bench B/C carry the top-set line).
        let waveOverrides: [WaveType: String]

        init(_ label: String, _ keys: [ExerciseKey], _ defaultNote: String, waveOverrides: [WaveType: String] = [:]) {
            self.label = label
            self.keys = keys
            self.defaultNote = defaultNote
            self.waveOverrides = waveOverrides
        }

        func matches(_ item: SessionItem) -> Bool { keys.contains { $0.matches(item) } }
        func note(for wave: WaveType) -> String { waveOverrides[wave] ?? defaultNote }
    }

    private static let benchBackOff = "Rest 3–4 min heavy, 2–3 back-offs."
    private static let benchTopSet = "Top set 1 × 4–6 @2 first — log it as the LAST row. Rest 3–4 min heavy, 2–3 back-offs."
    private static let rehabPushdown = "Rehab track. Shortened range. Add load only on clean next-morning elbow reads."
    private static let legExtensionNote = "Capped at 2 sets."
    private static let hammerCurlNote = "Neutral grip. Track left arm independently."

    /// day label (post-rename) -> rules. Every item not matched by a rule on its
    /// day has its prescriptionNotes set to nil.
    private static let rulesByDay: [String: [NoteRule]] = [
        "Push A": [
            NoteRule("Bench Press", [.id("bench_press")], benchBackOff,
                     waveOverrides: [.b: benchTopSet, .c: benchTopSet]),
            NoteRule("Smith Incline Bench Press",
                     [.id("custom_a45d8c4e-fc18-45a2-a224-8c89eebad7c8"), .name("Smith Incline Bench Press")],
                     "Scapular-plane, shortened ROM."),
            NoteRule("Cable Tricep Rope Pushdown", [.id("cable_tricep_rope_pushdown")], rehabPushdown)
        ],
        "Legs A": [
            NoteRule("Hack Squat", [.id("hack_squat")], "Wide stance, toe-out. Progress reps, not load."),
            NoteRule("Leg Extension", [.id("leg_extension")], legExtensionNote),
            NoteRule("Farmer Carry", [.id("farmer_carry")], "Hex bar, 40–50 ft per set.")
        ],
        "Pull A": [
            NoteRule("T-Bar Row", [.id("t_bar_row")], "Elevated start, belt. A week only on back 0–1/10."),
            NoteRule("Pull-Up", [.id("pull_up")], "Strict. No kip, no dead-hang, BW only."),
            NoteRule("Hammer Curl", [.id("hammer_curl")], hammerCurlNote)
        ],
        "Push B": [
            NoteRule("Cable Tricep Rope Pushdown", [.id("cable_tricep_rope_pushdown")], rehabPushdown),
            NoteRule("Decline Bench Press", [.id("decline_bench_press")], "3 sets during the cut.")
        ],
        "Legs B": [
            NoteRule("Leg Extension", [.id("leg_extension")], legExtensionNote),
            NoteRule("Smith Machine Hip Thrust",
                     [.name("Smith Machine Hip Thrust"), .id("machine_hip_thrust")],
                     "Gated: back 0–1/10, no spasm. Not cleared → skip, leg curl to 4 sets. Neutral-spine lockout."),
            NoteRule("Romanian Deadlift", [.id("romanian_deadlift")], "Hard cap 300 lb. Belt on.")
        ],
        "Pull B": [
            NoteRule("Single Arm Pulldown (Kneeling)", [.name("Single Arm Pulldown (Kneeling)")],
                     "Track left arm independently."),
            NoteRule("Barbell Row", [.id("barbell_row")], "Chest-supported. Spine-unloaded."),
            NoteRule("Hammer Curl", [.id("hammer_curl")], hammerCurlNote)
        ]
    ]

    private static let dayOrder = ["Push A", "Legs A", "Pull A", "Push B", "Legs B", "Pull B"]

    // MARK: - Entry point

    static func runIfNeeded(in context: ModelContext) {
        var report: [String] = []

        func abort(_ reason: String) {
            print(([header(), "ABORT — \(reason)"] + report).joined(separator: "\n"))
        }

        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Meso intensifier/notes repair not needed (already applied).")
            return
        }

        // MARK: Gates

        guard let blocks = try? context.fetch(FetchDescriptor<MesoBlock>()) else {
            abort("could not fetch meso blocks."); return
        }
        let active = blocks.filter { $0.status == .active && $0.isMaintenance == false }
        guard active.count == 1, let meso = active.first else {
            abort("expected exactly one active non-maintenance block, found \(active.count)."); return
        }

        let unsafe = meso.sessions.filter { !isSafeToModify($0) }
        guard unsafe.isEmpty else {
            let detail = unsafe.sorted { $0.date < $1.date }
                .map { "\(($0.dayLabel ?? "?")) w\($0.weekIndex) (status=\($0.status.rawValue), logged=\(hasLoggedData($0)))" }
                .joined(separator: "; ")
            abort("\(unsafe.count) of \(meso.sessions.count) sessions are not safe to modify: \(detail)"); return
        }

        // Resolve each day. Labels are the post-rename ones; the pre-rename
        // template titles are accepted as aliases so this still works if
        // MesoProgramAlignmentRepair has not run.
        var sessionsByDay: [String: [Int: Session]] = [:]
        for label in dayOrder {
            let aliases = Set([label] + MesoProgramAlignmentRepair.dayRenames
                .filter { $0.new == label }
                .map(\.old))

            let daySessions = meso.sessions.filter { aliases.contains($0.dayLabel ?? "") }
            guard !daySessions.isEmpty else {
                abort("no sessions carry any of \(aliases.sorted()). Present labels: \(Set(meso.sessions.compactMap(\.dayLabel)).sorted().joined(separator: ", "))")
                return
            }
            var byWeek: [Int: Session] = [:]
            for session in daySessions {
                guard byWeek[session.weekIndex] == nil else {
                    abort("day '\(label)' has more than one session for week \(session.weekIndex)."); return
                }
                byWeek[session.weekIndex] = session
            }
            guard Set(byWeek.keys) == Set(1...10) else {
                abort("day '\(label)' weeks are \(byWeek.keys.sorted()), expected 1...10."); return
            }
            sessionsByDay[label] = byWeek
        }

        // Every note rule must resolve in every week of its day, or the key is
        // wrong — most likely a custom exercise whose name differs from the table.
        for label in dayOrder {
            let byWeek = sessionsByDay[label]!
            for rule in rulesByDay[label] ?? [] {
                let missing = (1...10).filter { week in
                    !byWeek[week]!.items.contains { rule.matches($0) }
                }
                guard missing.isEmpty else {
                    let found = byWeek[1]!.items.sorted { $0.order < $1.order }
                        .map { "\($0.order):\(ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId))/\"\($0.exerciseNameSnapshot ?? "")\"" }
                        .joined(separator: ", ")
                    abort("day '\(label)': rule '\(rule.label)' (\(rule.keys.map(\.describe).joined(separator: " OR "))) matched nothing in week(s) \(missing.map(String.init).joined(separator: ", ")). Week 1 holds: [\(found)]")
                    return
                }
                let ambiguous = (1...10).filter { week in
                    byWeek[week]!.items.filter { rule.matches($0) }.count > 1
                }
                guard ambiguous.isEmpty else {
                    abort("day '\(label)': rule '\(rule.label)' matched more than one item in week(s) \(ambiguous.map(String.init).joined(separator: ", ")). Refusing to guess.")
                    return
                }
            }
        }

        report.append(header())
        report.append("Block '\(meso.name)' · \(meso.sessions.count) sessions")
        report.append("Intensifiers: every item with intensifierRaw != \"none\" is cleared. Notes: table below; every unlisted item gets nil.")
        report.append("")

        // MARK: Apply

        var totals = Totals()

        for label in dayOrder {
            let byWeek = sessionsByDay[label]!
            let rules = rulesByDay[label] ?? []
            report.append("── \(label)")

            for week in 1...10 {
                let session = byWeek[week]!
                let wave = waveFor(week)
                let verbose = (week == 1 || week == 3)
                if verbose { report.append("   ── week \(week) (wave \(wave.displayName))") }

                for item in session.items.sorted(by: { $0.order < $1.order }) {

                    // 1) Intensifier
                    let beforeIntensifier = item.intensifierRaw ?? "nil"
                    let beforeIntensifierNotes = item.intensifierNotes
                    let clearsIntensifier = (item.intensifierRaw != nil && item.intensifierRaw != IntensifierType.none.rawValue)
                    if clearsIntensifier {
                        totals.intensifiersCleared += 1
                        if !dryRun {
                            item.intensifierRaw = IntensifierType.none.rawValue
                            item.intensifierNotes = nil
                        }
                    } else if item.intensifierRaw == IntensifierType.none.rawValue, beforeIntensifierNotes != nil {
                        // Not in scope per spec (only non-"none" items are cleared),
                        // but surfaced so a stale note cannot hide.
                        totals.staleIntensifierNotesLeft += 1
                        report.append("      NOTE \(label) w\(week) \(shortName(item)): intensifierRaw is \"none\" but intensifierNotes is non-nil (\"\(beforeIntensifierNotes!)\") — left as-is per spec.")
                    }

                    // 2) Prescription notes
                    let beforeNote = item.prescriptionNotes
                    let afterNote = rules.first { $0.matches(item) }?.note(for: wave)
                    let noteChanges = (beforeNote != afterNote)
                    if noteChanges {
                        if afterNote == nil { totals.notesCleared += 1 } else { totals.notesSet += 1 }
                        if !dryRun { item.prescriptionNotes = afterNote }
                    }

                    if verbose && (clearsIntensifier || noteChanges) {
                        let intensifierPart = clearsIntensifier
                            ? "intensifier \(beforeIntensifier) → none" + (beforeIntensifierNotes != nil ? " (notes cleared)" : "")
                            : "intensifier \(beforeIntensifier) unchanged"
                        let notePart = noteChanges
                            ? "note \(render(beforeNote)) → \(render(afterNote))"
                            : "note unchanged"
                        report.append("      \(shortName(item)): \(intensifierPart); \(notePart)")
                    }
                }
            }
            report.append("")
        }

        report.append("TOTALS: \(totals.intensifiersCleared) intensifiers cleared · \(totals.notesSet) notes set · \(totals.notesCleared) notes cleared to nil · \(totals.staleIntensifierNotesLeft) stale intensifierNotes left on \"none\" items")

        // MARK: Finish

        if dryRun {
            report.append("")
            report.append("DRY RUN — nothing was written and the completion flag was NOT set.")
            print(report.joined(separator: "\n"))
            return
        }

        do {
            try context.save()
        } catch {
            report.append("")
            report.append("⚠️ SAVE FAILED: \(error). Nothing persisted; flag not set, so this retries next launch.")
            print(report.joined(separator: "\n"))
            return
        }

        UserDefaults.standard.set(true, forKey: completionKey)
        report.append("")
        report.append("✅ Applied and saved.")
        print(report.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private static func header() -> String {
        dryRun ? "🧪 DRY RUN — no writes" : "🔧 MESO INTENSIFIER + NOTES REPAIR"
    }

    private static func waveFor(_ week: Int) -> WaveType {
        template.rule(forWeek: week)?.wave ?? .a
    }

    private static func shortName(_ item: SessionItem) -> String {
        let name = item.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: item.exerciseId)
        return "[ord \(item.order)] \(name)"
    }

    private static func render(_ note: String?) -> String {
        guard let note else { return "nil" }
        return "\"\(note)\""
    }

    private static func isSafeToModify(_ session: Session) -> Bool {
        guard session.status == .planned else { return false }
        return !hasLoggedData(session)
    }

    private static func hasLoggedData(_ session: Session) -> Bool {
        session.items.contains { item in
            item.isCompleted ||
            item.actualLoads.contains { $0 > 0 } ||
            item.actualReps.contains { $0 > 0 }
        }
    }

    private struct Totals {
        var intensifiersCleared = 0
        var notesSet = 0
        var notesCleared = 0
        var staleIntensifierNotesLeft = 0
    }
}
