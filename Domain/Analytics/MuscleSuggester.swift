// Domain/Analytics/MuscleSuggester.swift
import Foundation

/// A proposed fine-muscle mapping for a custom exercise, taken from the closest built-in by name. A suggestion is only
/// ever SHOWN (editor, reports); it never enters volume totals unless the lifter accepts it (saves it on the exercise).
struct MuscleSuggestion: Equatable {
    enum Confidence: String {
        /// Same movement words as a built-in (equipment / position / side words ignored).
        case exact
        /// Most of the custom's movement words are in one built-in's name.
        case close
        /// Several built-ins match equally well and do not agree on the primary muscle; the best is shown.
        case ambiguous
        /// A bracketed / parenthetical tag in the name names a muscle ("Lat Bias", "Rear Delt", "Long Head") and set the primary.
        case tagged
        /// Matched a row of `MuscleSuggester.keywordTable` (a movement the catalog does not have).
        case keyword
    }
    let shares: [FineMuscle: Double]
    /// The built-in the shares were copied from.
    let basedOn: String
    let confidence: Confidence
    /// Fraction of the custom's movement words found in `basedOn`'s name (0...1).
    let score: Double
    /// For a `.tagged` suggestion: how well the name itself matched a built-in before the tag set the primary muscle.
    var baseConfidence: Confidence? = nil

    var primary: FineMuscle? { shares.first { $0.value == 1 }?.key }
}

enum MuscleSuggester {

    /// Words that describe equipment, position, side or program tags, not the movement.
    private static let ignored: Set<String> = [
        "single", "arm", "alternating", "db", "dumbbell", "dumbbells", "barbell", "bb", "smith", "machine", "cable", "seated",
        "standing", "incline", "decline", "flat", "lever", "low", "high", "to", "gym", "rehab", "band", "kneeling", "ez", "bar",
        "the", "with", "and", "a", "one", "two", "unilateral", "bilateral", "assisted", "weighted", "heavy", "light",
    ]

    /// The movement words of a name: lower-case, bracketed / parenthesised notes dropped, hyphens split, ignored words out.
    static func movementWords(_ name: String) -> Set<String> {
        var s = name.lowercased()
        for (open, close) in [("[", "]"), ("(", ")")] {
            while let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) {
                s.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        let words = s.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { !ignored.contains($0) })
    }

    /// Minimum fraction of the custom's movement words that must appear in a built-in's name.
    static let minimumScore = 0.5

    // MARK: - Data tables

    /// Muscle words a tag may use -> the fine muscle ("Lat Bias", "Rear Delt", "Long Head"). Longest phrase wins.
    static let tagAliases: [(phrase: String, muscle: FineMuscle)] = {
        let rows: [(String, FineMuscle)] = [
            ("lat bias", FineMuscle.lats), ("lats", FineMuscle.lats), ("lat", FineMuscle.lats),
            ("rear delts", FineMuscle.rearDelts), ("rear delt", FineMuscle.rearDelts), ("rear", FineMuscle.rearDelts),
            ("side delts", FineMuscle.sideDelts), ("side delt", FineMuscle.sideDelts),
            ("front delts", FineMuscle.frontDelts), ("front delt", FineMuscle.frontDelts),
            ("upper back", FineMuscle.upperBack), ("traps", FineMuscle.upperBack), ("trap", FineMuscle.upperBack),
            ("lower back", FineMuscle.lowerBack),
            ("long head", FineMuscle.triceps), ("lateral head", FineMuscle.triceps), ("short head", FineMuscle.biceps),
            ("upper chest", FineMuscle.chest), ("lower chest", FineMuscle.chest), ("chest", FineMuscle.chest),
            ("triceps", FineMuscle.triceps), ("tricep", FineMuscle.triceps), ("biceps", FineMuscle.biceps), ("bicep", FineMuscle.biceps),
            ("quads", FineMuscle.quads), ("quad", FineMuscle.quads), ("hamstrings", FineMuscle.hamstrings), ("hamstring", FineMuscle.hamstrings),
            ("glutes", FineMuscle.glutes), ("glute", FineMuscle.glutes), ("calves", FineMuscle.calves), ("calf", FineMuscle.calves),
            ("forearms", FineMuscle.forearms), ("forearm", FineMuscle.forearms),
            ("adductors", FineMuscle.adductors), ("adductor", FineMuscle.adductors), ("abs", FineMuscle.abs),
        ]
        return rows.sorted { $0.0.count > $1.0.count }.map { (phrase: $0.0, muscle: $0.1) }
    }()

    /// Common movements the catalog does not have: every keyword must be a word of the name. One table, no code paths.
    /// (keywords, shares). Checked before name matching, so "Hip Adduction" is not read as a hip thrust.
    static let keywordTable: [(keywords: [String], shares: [FineMuscle: Double])] = [
        (["y", "raise"], [.rearDelts: 1.0, .upperBack: 0.5, .sideDelts: 0.25]),
        (["reverse", "fly"], [.rearDelts: 1.0, .upperBack: 0.5]),
        (["reverse", "flye"], [.rearDelts: 1.0, .upperBack: 0.5]),
        (["adduction"], [.adductors: 1.0]),
        (["abduction"], [.glutes: 1.0]),
        (["shrug"], [.upperBack: 1.0, .forearms: 0.25]),
        (["wrist", "curl"], [.forearms: 1.0]),
    ]

    // MARK: - Pieces

    /// The text inside [..] and (..) of a name, lower-cased.
    static func tags(_ name: String) -> [String] {
        var out: [String] = []
        var s = name.lowercased()
        for (open, close) in [("[", "]"), ("(", ")")] {
            while let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) {
                out.append(String(s[a.upperBound..<b.lowerBound]))
                s.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        return out
    }

    /// The muscle a tag names, if any.
    static func tagMuscle(_ name: String) -> FineMuscle? {
        for tag in tags(name) {
            let words = " " + tag.split { !$0.isLetter }.joined(separator: " ") + " "
            for (phrase, muscle) in tagAliases where words.contains(" \(phrase) ") { return muscle }
        }
        return nil
    }

    /// `muscle` becomes the primary (1.0); the old primary drops to 0.5; every other share stays.
    static func applyingTag(_ muscle: FineMuscle, to shares: [FineMuscle: Double]) -> [FineMuscle: Double] {
        var out = shares
        if let old = shares.first(where: { $0.value == 1 })?.key, old != muscle { out[old] = 0.5 }
        out[muscle] = 1.0
        return out
    }

    /// A straight-arm movement has no elbow flexion: no biceps or forearm share (unless that is the whole movement).
    static func removingElbowFlexors(from shares: [FineMuscle: Double]) -> [FineMuscle: Double] {
        let primary = shares.first(where: { $0.value == 1 })?.key
        if primary == .biceps || primary == .forearms { return shares }
        return shares.filter { $0.key != .biceps && $0.key != .forearms }
    }

    static func isStraightArm(_ name: String) -> Bool {
        let n = name.lowercased().replacingOccurrences(of: "-", with: " ")
        return n.contains("straight arm")
    }

    private static func rawWords(_ name: String) -> Set<String> {
        Set(name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    // MARK: - Suggest

    /// The closest built-in (same coarse group) by movement words, with the tag / straight-arm / keyword rules, or nil.
    static func suggest(name: String, coarse: MuscleGroup) -> MuscleSuggestion? {
        let tagged = tagMuscle(name)
        let base = baseSuggestion(name: name, coarse: coarse)
        guard let tagged else { return base }
        if let base {
            return MuscleSuggestion(shares: applyingTag(tagged, to: base.shares), basedOn: base.basedOn, confidence: .tagged, score: base.score, baseConfidence: base.confidence)
        }
        return MuscleSuggestion(shares: [tagged: 1.0], basedOn: "its tag", confidence: .tagged, score: 1)
    }

    /// Whether the closest built-in is a compound lift, when the match is exact or close (a tag does not change the movement).
    /// Ambiguous, keyword-only and unmatched names are false: nothing is assumed compound on a weak match.
    static func suggestedCompound(name: String, coarse: MuscleGroup) -> Bool {
        guard let s = suggest(name: name, coarse: coarse) else { return false }
        let confidence = s.confidence == .tagged ? s.baseConfidence : s.confidence
        guard confidence == .exact || confidence == .close else { return false }
        return ExerciseCatalog.builtIn.first { $0.name == s.basedOn }?.isCompound ?? false
    }

    private static func baseSuggestion(name: String, coarse: MuscleGroup) -> MuscleSuggestion? {
        let mine = movementWords(name)
        let all = rawWords(name)
        // 1. keyword table (movements the catalog does not have)
        for row in keywordTable where row.keywords.allSatisfy({ all.contains($0) }) {
            return MuscleSuggestion(shares: row.shares, basedOn: "keyword \"\(row.keywords.joined(separator: " "))\"", confidence: .keyword, score: 1)
        }
        let straight = isStraightArm(name)
        let group = ExerciseCatalog.builtIn.filter { $0.primaryMuscle == coarse && ExerciseMuscleShares.table[$0.id] != nil }
        // 2. straight-arm: prefer the straight-arm / pullover built-ins of the group
        if straight {
            let pull = group.filter { $0.name.lowercased().contains("pullover") || $0.name.lowercased().contains("straight") }
                .sorted { l, r in
                    let lo = all.intersection(rawWords(l.name)).count, ro = all.intersection(rawWords(r.name)).count
                    if lo != ro { return lo > ro }
                    return (l.name.count, l.id) < (r.name.count, r.id)
                }
            if let e = pull.first, let shares = ExerciseMuscleShares.table[e.id] {
                return MuscleSuggestion(shares: shares, basedOn: e.name, confidence: .close, score: 1)
            }
        }
        // 3. closest name
        guard !mine.isEmpty else { return nil }
        struct Cand { let id: String; let name: String; let shares: [FineMuscle: Double]; let score: Double; let jaccard: Double }
        var cands: [Cand] = []
        for e in group {
            guard let shares = ExerciseMuscleShares.table[e.id] else { continue }
            let theirs = movementWords(e.name)
            let common = Double(mine.intersection(theirs).count)
            let score = common / Double(mine.count)
            let jaccard = common / Double(mine.union(theirs).count)
            if score >= minimumScore { cands.append(Cand(id: e.id, name: e.name, shares: shares, score: score, jaccard: jaccard)) }
        }
        guard !cands.isEmpty else { return nil }
        // best score, then best overlap, then the plainest built-in name (fewest equipment words), then id
        cands.sort { ($1.score, $1.jaccard, $0.name.count, $0.id) < ($0.score, $0.jaccard, $1.name.count, $1.id) }
        let top = cands[0]
        let tied = cands.filter { $0.score == top.score && $0.jaccard == top.jaccard }
        func primary(_ c: Cand) -> FineMuscle? { c.shares.first { $0.value == 1 }?.key }
        let primaries = Set(tied.compactMap(primary))
        // a tie stays "ambiguous", but lands on the primary that most of the tied candidates share
        var counts: [FineMuscle: Int] = [:]
        for c in tied { if let p = primary(c) { counts[p, default: 0] += 1 } }
        let majority = counts.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }?.key
        let best = tied.first { primary($0) == majority } ?? top
        var shares = best.shares
        if straight { shares = removingElbowFlexors(from: shares) }
        let confidence: MuscleSuggestion.Confidence =
            primaries.count > 1 ? .ambiguous : (best.score == 1 && best.jaccard == 1 ? .exact : .close)
        return MuscleSuggestion(shares: shares, basedOn: best.name, confidence: confidence, score: best.score)
    }
}
