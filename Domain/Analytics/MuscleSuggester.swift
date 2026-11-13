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
    }
    let shares: [FineMuscle: Double]
    /// The built-in the shares were copied from.
    let basedOn: String
    let confidence: Confidence
    /// Fraction of the custom's movement words found in `basedOn`'s name (0...1).
    let score: Double

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

    /// The closest built-in (same coarse group) by movement words, or nil when nothing is close enough.
    static func suggest(name: String, coarse: MuscleGroup) -> MuscleSuggestion? {
        let mine = movementWords(name)
        guard !mine.isEmpty else { return nil }
        struct Cand { let id: String; let name: String; let shares: [FineMuscle: Double]; let score: Double; let jaccard: Double }
        var cands: [Cand] = []
        for e in ExerciseCatalog.builtIn where e.primaryMuscle == coarse {
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
        let best = cands[0]
        let tied = cands.filter { $0.score == best.score && $0.jaccard == best.jaccard }
        let primaries = Set(tied.compactMap { c in c.shares.first { $0.value == 1 }?.key })
        let confidence: MuscleSuggestion.Confidence =
            primaries.count > 1 ? .ambiguous : (best.score == 1 && best.jaccard == 1 ? .exact : .close)
        return MuscleSuggestion(shares: best.shares, basedOn: best.name, confidence: confidence, score: best.score)
    }
}
