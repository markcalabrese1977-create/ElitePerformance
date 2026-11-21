import Foundation
import SwiftData

/// How the lifter records effort (reps in reserve) on a set. A profile setting, stored as an optional raw string.
///
/// - `simple`: four word buttons, Easy · Solid · Hard · All out, stored as RIR 3, 2, 1, 0.
/// - `detailed`: the 0-4 chips (compound lifts) with a one-line explanation.
/// - `off`: no effort input at all. `RIREntry.decisionRIR` returns nil for every set, recorded or not, so progression is
///   pure rep progression. (Recorded values stay in the data; only decisions ignore them.)
enum EffortMode: String, CaseIterable, Equatable {
    case simple, detailed, off

    var title: String {
        switch self {
        case .simple: return "Simple"
        case .detailed: return "Detailed"
        case .off: return "Off"
        }
    }

    var oneLine: String {
        switch self {
        case .simple: return "Tap a word after each set: Easy, Solid, Hard or All out."
        case .detailed: return "Record reps in reserve (0–4) on each compound set."
        case .off: return "Don't record effort. Progression follows your reps and loads only."
        }
    }
}

enum EffortTracking {

    /// UserDefaults mirror of the RESOLVED mode, so context-free code (`RIREntry.decisionRIR`) and `@AppStorage` views read it.
    /// Absent = Detailed, i.e. the behaviour before the setting existed (and what every test that never syncs sees).
    static let mirrorKey = "effortTracking.mode.v1"

    static var mode: EffortMode {
        get { EffortMode(rawValue: UserDefaults.standard.string(forKey: mirrorKey) ?? "") ?? .detailed }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: mirrorKey) }
    }

    static func clearMirror() { UserDefaults.standard.removeObject(forKey: mirrorKey) }

    /// The Simple words, easiest first, with the RIR each one stores.
    /// `hint` is the small line under each word: the scale in plain terms (reps still left in the tank).
    static let simpleChoices: [(label: String, rir: Int, hint: String)] = [
        ("Easy", 3, "3+ left"), ("Solid", 2, "2 left"), ("Hard", 1, "1 left"), ("All out", 0, "0"),
    ]

    static func simpleLabel(for rir: Int) -> String? { simpleChoices.first { $0.rir == rir }?.label }

    /// " @ 2 RIR" (Detailed) or " · Solid" (Simple) for a LOGGED RIR; empty when nothing was logged or effort is Off.
    static func loggedSuffix(_ rir: Int?, mode: EffortMode = EffortTracking.mode) -> String {
        guard let rir, mode != .off else { return "" }
        if mode == .simple, let word = simpleLabel(for: rir) { return " · \(word)" }
        return " @ \(rir) RIR"
    }

    // MARK: Resolution

    /// Logged working sets on COMPOUND lifts that carry a recorded RIR. Isolation lifts are left out on purpose: they stored the
    /// plan's number as "actual", so their values say nothing about what the lifter chose to tap.
    static func recordedCompoundRIRs(in context: ModelContext) -> [Int] {
        var out: [Int] = []
        for s in (try? context.fetch(FetchDescriptor<Session>())) ?? [] {
            for item in s.items where RIREntry.isCompound(item.exerciseId) {
                for idx in item.actualReps.indices where item.actualReps[idx] > 0 {
                    if let r = RIREntry.recorded(item, at: idx) { out.append(r) }
                }
            }
        }
        return out
    }

    /// The stored choice, else: Detailed when any compound RIR was recorded, otherwise Simple.
    static func resolved(profile: UserProfile?, in context: ModelContext) -> EffortMode {
        if let raw = profile?.effortModeRaw, let m = EffortMode(rawValue: raw) { return m }
        return recordedCompoundRIRs(in: context).isEmpty ? .simple : .detailed
    }

    /// True when the lifter never chose a mode and every RIR they recorded is 0 (the "tapped 0 on everything" pattern).
    static func needsModePrompt(profile: UserProfile?, in context: ModelContext) -> Bool {
        guard let profile, EffortMode(rawValue: profile.effortModeRaw ?? "") == nil else { return false }
        let all = recordedCompoundRIRs(in: context)
        return !all.isEmpty && all.allSatisfy { $0 == 0 }
    }

    /// Refreshes the mirror from the profile. Call at launch, after a restore and after the lifter changes the setting.
    static func sync(in context: ModelContext) {
        let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
        mode = resolved(profile: profile, in: context)
    }

    /// Stores the lifter's choice and refreshes the mirror.
    static func choose(_ m: EffortMode, in context: ModelContext) {
        let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
        profile?.effortModeRaw = m.rawValue
        try? context.save()
        mode = m
    }
}
