import Foundation
import SwiftData
import SwiftUI

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

    /// " @ 2 RIR" (Detailed), " @ Solid" (Simple: the word whose scale contains the planned RIR, 3+ is Easy) or "" (Off) for the
    /// PLANNED RIR on a plan line. The plan line labels it as the plan (SUGGESTED / PLAN / OPTIONAL EXTRA SET).
    static func plannedSuffix(_ rir: Int?, mode: EffortMode = EffortTracking.mode) -> String {
        guard let rir, mode != .off, let aim = aimText(rir, mode: mode) else { return "" }
        return " · \(aim)"
    }

    /// The label for a PLANNED / TARGET effort: "aim: 0 RIR" (Detailed), "aim: All out" (Simple), nil (Off). Planned effort never reads like a logged
    /// one ("@ 0 RIR", "· All out"): a target of 0 once read as the lifter's own taps.
    static func aimText(_ rir: Int, mode: EffortMode = EffortTracking.mode) -> String? {
        plannedText(rir, mode: mode).map { "aim: \($0)" }
    }

    /// A line that may carry an aim chunk ("… · aim: 2 RIR"): the aim part is italic, the rest is not, so planned effort never looks like a logged one.
    static func styledText(_ line: String) -> Text {
        guard let r = line.range(of: "aim:") else { return Text(line) }
        return Text(String(line[..<r.lowerBound])) + Text(String(line[r.lowerBound...])).italic()
    }

    /// The range form: "aim: 2–3 RIR" (Detailed), "aim: Easy–Solid" (Simple), nil (Off).
    static func aimRangeText(_ lo: Int, _ hi: Int, mode: EffortMode = EffortTracking.mode) -> String? {
        plannedRangeText(lo, hi, mode: mode).map { "aim: \($0)" }
    }

    // MARK: Planned / target RIR text (one rule for every screen)

    /// The Simple word for a PLANNED or TARGET RIR: 3 or more is Easy, then Solid, Hard, All out.
    static func plannedWord(_ rir: Int) -> String {
        simpleChoices.first { $0.rir == min(max(rir, 0), 3) }?.label ?? "Solid"
    }

    /// A planned / target RIR as display text: "2 RIR" (Detailed), "Solid" (Simple), nil (Off: no effort text anywhere).
    static func plannedText(_ rir: Int, mode: EffortMode = EffortTracking.mode) -> String? {
        switch mode {
        case .detailed: return "\(rir) RIR"
        case .simple: return plannedWord(rir)
        case .off: return nil
        }
    }

    /// A planned / target RIR range: "2–3 RIR" (Detailed), "Easy–Solid" (Simple; one word when both ends map to the same word), nil (Off).
    static func plannedRangeText(_ lo: Int, _ hi: Int, mode: EffortMode = EffortTracking.mode) -> String? {
        let (a, b) = (min(lo, hi), max(lo, hi))
        switch mode {
        case .detailed: return a == b ? "\(a) RIR" : "\(a)–\(b) RIR"
        case .simple:
            let easy = plannedWord(b), hard = plannedWord(a)
            return easy == hard ? easy : "\(easy)–\(hard)"
        case .off: return nil
        }
    }

    /// Rewrites the effort part of a stored prescription summary for display: "4 x 8-12 @ RIR 2-3" and "1 x 4-6 @ 2 top + ..." stay
    /// as they are in Detailed; Simple shows the words ("4 x 8-12 @ Easy–Solid"); Off drops the effort part. The domain strings
    /// themselves never change (they are compared and logged), only what the lifter reads.
    static func localize(_ text: String, mode: EffortMode = EffortTracking.mode) -> String {
        guard mode != .detailed else { return text }
        var out = text
        func replace(_ pattern: String, _ body: (NSTextCheckingResult, NSString) -> String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = out as NSString
            var result = ""; var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                result += body(m, ns)
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        // "@ RIR 2-3" / "@ RIR 3"
        replace(#" @ RIR (\d+)(?:-(\d+))?"#) { m, ns in
            guard mode == .simple else { return "" }
            let lo = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let hi = m.range(at: 2).location == NSNotFound ? lo : (Int(ns.substring(with: m.range(at: 2))) ?? lo)
            return " @ " + (plannedRangeText(lo, hi, mode: .simple) ?? "")
        }
        // "@ 2 top"
        replace(#" @ (\d+) top"#) { m, ns in
            guard mode == .simple else { return " top" }
            return " @ \(plannedWord(Int(ns.substring(with: m.range(at: 1))) ?? 0)) top"
        }
        return out
    }

    /// The mode setup screens (onboarding, "Use my own program") show text in. A lifter with no stored mode yet is a NEW lifter, and
    /// onboarding writes Simple for them, so the setup screens already speak Simple. (`raw` is the `@AppStorage` mirror value.)
    static func setupMode(raw: String) -> EffortMode { EffortMode(rawValue: raw) ?? .simple }
    /// The same, read now (for setup screens that build text outside a view body).
    static var setupModeNow: EffortMode { setupMode(raw: UserDefaults.standard.string(forKey: mirrorKey) ?? "") }

    /// Joins display parts with " · ", dropping nil / empty ones (so an Off-mode RIR leaves no dangling separator).
    static func joined(_ parts: [String?], separator: String = " · ") -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: separator)
    }

    /// "the target RIR" (Detailed) / "planned" (Simple) in coaching sentences. Off never reaches an RIR rule (`decisionRIR` is nil).
    static func targetPhrase(mode: EffortMode = EffortTracking.mode) -> String {
        mode == .simple ? "planned" : "the target RIR"
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

    /// The "How do you want to track effort?" prompt waits until nothing else owns the screen: no sheet or alert (the welcome
    /// sheet, a restore prompt, Rest today), no restore running, no HealthKit permission sheet, the app active, and it has not
    /// been shown this launch. It is answered with one of three buttons, so it cannot be left open.
    static func canPresentPrompt(needsPrompt: Bool, shownThisLaunch: Bool, sceneActive: Bool, nothingPresented: Bool,
                                 restoreInProgress: Bool, healthKitRequesting: Bool) -> Bool {
        needsPrompt && !shownThisLaunch && sceneActive && nothingPresented && !restoreInProgress && !healthKitRequesting
    }

    /// The one-shot: a profile that never stored a mode gets the resolved one WRITTEN (Detailed if any compound RIR is recorded,
    /// otherwise Simple), so it is never re-derived from data again. The one exception is the all-0 pattern: nothing is written, the
    /// lifter is asked (`needsModePrompt`) and their answer is stored. Returns true when it wrote.
    @discardableResult
    static func resolveOnce(in context: ModelContext) -> Bool {
        guard let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first,
              EffortMode(rawValue: profile.effortModeRaw ?? "") == nil,
              !needsModePrompt(profile: profile, in: context) else { return false }
        profile.effortModeRaw = resolved(profile: profile, in: context).rawValue
        return (try? context.save()) != nil
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
