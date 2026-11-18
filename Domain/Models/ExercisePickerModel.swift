// Domain/Models/ExercisePickerModel.swift
import Foundation

/// Search over exercises for every exercise picker: one definition of "matches", one of "sorted".
enum ExerciseSearch {

    /// Lower case, diacritics folded, every run of non-letters/digits a single space: "Push-Up", "push up" and "PUSH  UP" agree.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        var out = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) { out.unicodeScalars.append(scalar); lastWasSpace = false }
            else if !lastWasSpace { out.append(" "); lastWasSpace = true }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// What lifters call an exercise besides its catalog name, by catalog id.
    static let aliasesById: [String: [String]] = [
        "bench_press": ["flat bench", "barbell bench press", "bb bench"],
        "incline_dumbbell_press": ["incline db press", "incline press"],
        "dumbbell_press": ["db bench", "dumbbell bench press", "db press"],
        "pec_deck": ["pec fly machine", "machine fly", "butterfly"],
        "cable_crossover": ["cable fly", "crossover"],
        "push_up": ["pushup", "press up"],
        "cable_tricep_rope_pushdown": ["rope pushdown", "triceps pushdown"],
        "cable_tricep_pushdown_straight_bar": ["tricep pushdown", "triceps pushdown", "bar pushdown"],
        "ez_bar_skull_crusher": ["skullcrusher", "skull crushers", "lying triceps extension", "nose breaker"],
        "overhead_rope_tricep_extension": ["overhead triceps extension", "cable overhead extension"],
        "dip": ["chest dip", "tricep dip", "parallel bar dip"],
        "hanging_knee_raise": ["knee raise", "hanging leg raise"],
        "hanging_straight_leg_raise": ["leg raise"],
        "ab_wheel_rollout": ["ab roller", "rollout"],
        "cable_woodchop": ["wood chop", "woodchopper"],
        "toes_to_bar": ["t2b", "ttb"],
        "hack_squat": ["machine squat"],
        "bulgarian_split_squat": ["rear foot elevated split squat", "rfess", "split squat"],
        "walking_lunge": ["lunge", "lunges"],
        "back_extension_45": ["hyperextension", "back raise", "45 degree back extension"],
        "romanian_deadlift": ["rdl", "stiff leg deadlift", "straight leg deadlift"],
        "dumbbell_romanian_deadlift": ["db rdl"],
        "lying_leg_curl": ["hamstring curl", "prone leg curl"],
        "seated_leg_curl": ["hamstring curl"],
        "machine_hip_thrust": ["hip thrust machine"],
        "barbell_hip_thrust": ["hip thrust"],
        "glute_bridge": ["bridge"],
        "conventional_deadlift": ["deadlift", "dl"],
        "sumo_deadlift": ["sumo dl"],
        "barbell_back_squat": ["squat", "back squat", "bb squat"],
        "front_squat": ["barbell front squat"],
        "smith_machine_calves": ["calf raise", "standing calf raise"],
        "seated_calf_raise": ["calf raise"],
        "wide_grip_pulldown": ["lat pulldown", "wide pulldown", "lats pulldown"],
        "pulldown_normal_grip": ["lat pulldown", "close grip pulldown"],
        "dumbbell_row_single_arm": ["one arm row", "single arm db row", "db row"],
        "seated_cable_row": ["cable row", "low row", "seated row"],
        "barbell_row": ["bent over row", "bb row", "pendlay row"],
        "t_bar_row": ["tbar row", "landmine row"],
        "pull_up": ["pullup", "pull ups"],
        "chin_up": ["chinup", "chin ups"],
        "incline_rear_delt_fly": ["rear delt fly", "reverse fly"],
        "dumbbell_lateral_raise": ["side raise", "lateral raise", "db lateral raise", "side lateral"],
        "single_arm_cable_lateral_raise": ["cable lateral raise", "cable side raise"],
        "dumbbell_shoulder_press": ["db shoulder press", "seated dumbbell press"],
        "barbell_overhead_press": ["ohp", "military press", "standing press", "shoulder press"],
        "machine_shoulder_press": ["shoulder press machine"],
        "arnold_press": ["arnolds"],
        "cable_face_pull": ["face pulls", "rear delt cable"],
        "ez_bar_curl": ["ez curl", "ez bar biceps curl"],
        "barbell_curl": ["bb curl", "straight bar curl"],
        "hammer_curl": ["db hammer curl"],
        "incline_dumbbell_curl": ["incline curl"],
        "preacher_curl": ["scott curl"],
        "dumbbell_pullover": ["db pullover"],
    ]

    /// Abbreviations a lifter types, expanded into the words the catalog uses.
    static let tokenSynonyms: [String: [String]] = [
        "db": ["dumbbell"], "dbs": ["dumbbell"], "bb": ["barbell"], "kb": ["kettlebell"],
        "ez": ["ez bar"], "ohp": ["overhead press"], "rdl": ["romanian deadlift"], "dl": ["deadlift"],
        "tri": ["tricep"], "tris": ["tricep"], "ham": ["hamstring"], "hams": ["hamstring"],
        "skullcrusher": ["skull crusher"], "skullcrushers": ["skull crusher"],
    ]

    static func aliases(for exercise: CatalogExercise) -> [String] {
        aliasesById[ExerciseCatalog.canonicalExerciseId(for: exercise.id)] ?? []
    }

    /// The text a query is matched against: the name, then its aliases.
    static func haystack(for exercise: CatalogExercise) -> (name: String, aliases: String) {
        (normalize(exercise.name), aliases(for: exercise).map(normalize).joined(separator: " | "))
    }

    private static func tokens(_ query: String) -> [String] { normalize(query).split(separator: " ").map(String.init) }

    /// Every word of the query must be found (as part of a word) in the name or an alias; an abbreviation also matches the
    /// word it stands for, and a plural the singular. An empty query matches everything.
    static func matches(_ exercise: CatalogExercise, query: String) -> Bool { rank(exercise, query: query) != nil }

    /// nil = no match. Lower is better: 0 name starts with the query, 1 a name word starts with it, 2 the name contains it,
    /// 3 only an alias or abbreviation matches.
    static func rank(_ exercise: CatalogExercise, query: String) -> Int? {
        let words = tokens(query)
        guard !words.isEmpty else { return 0 }
        let h = haystack(for: exercise)
        let all = h.name + " | " + h.aliases
        var worst = 0
        for word in words {
            var candidates = [word] + (tokenSynonyms[word] ?? [])
            if word.count > 3, word.hasSuffix("s") { candidates.append(String(word.dropLast())) }
            var best: Int?
            for c in candidates {
                let r: Int?
                if h.name.hasPrefix(c) { r = 0 }
                else if h.name.split(separator: " ").contains(where: { $0.hasPrefix(c) }) { r = 1 }
                else if h.name.contains(c) { r = 2 }
                else if all.contains(c) { r = 3 }
                else { r = nil }
                if let r { best = min(best ?? r, r) }
            }
            guard let best else { return nil }
            worst = max(worst, best)
        }
        return worst
    }

    /// The A-Z sort key: the folded name, then the id.
    static func sortKey(_ exercise: CatalogExercise) -> String { normalize(exercise.name) + "\u{0}" + exercise.id }
}

/// The exercises last picked, newest first (every picker records into it).
struct ExercisePickerRecents {
    static let key = "exercisePicker.recentIds.v1"
    static let limit = 6
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var ids: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func record(_ id: String) {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
        var list = ids.filter { ExerciseCatalog.canonicalExerciseId(for: $0) != canonical }
        list.insert(id, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.key)
    }
}

/// What an exercise picker shows: recent picks (empty search), suggested alternatives (a swap, empty search), then A-Z; or
/// one ranked list of results while searching. Pure, so every picker and the tests share it.
struct ExercisePickerModel {

    enum Kind: Equatable { case recent, suggested, letter(String), results }

    struct Section: Identifiable, Equatable {
        let kind: Kind
        let title: String
        let exercises: [CatalogExercise]
        var id: String {
            switch kind {
            case .recent: return "recent"
            case .suggested: return "suggested"
            case .letter(let l): return "letter-\(l)"
            case .results: return "results"
            }
        }
    }

    static func sections(exercises: [CatalogExercise], query: String, recentIds: [String] = [],
                         swapping current: CatalogExercise? = nil) -> [Section] {
        // One row per exercise, the swapped-out one never offered.
        var seen = Set<String>()
        let pool = exercises.filter { ex in
            guard ex.id != current?.id, seen.insert(ex.id).inserted else { return false }
            return true
        }
        let sorted = pool.sorted { ExerciseSearch.sortKey($0) < ExerciseSearch.sortKey($1) }

        let trimmed = ExerciseSearch.normalize(query)
        if !trimmed.isEmpty {
            let ranked = sorted.compactMap { ex in ExerciseSearch.rank(ex, query: query).map { (ex, $0) } }
                .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : ExerciseSearch.sortKey($0.0) < ExerciseSearch.sortKey($1.0) }
            return ranked.isEmpty ? [] : [Section(kind: .results, title: "Results", exercises: ranked.map(\.0))]
        }

        var out: [Section] = []
        let byCanonical = Dictionary(sorted.map { (ExerciseCatalog.canonicalExerciseId(for: $0.id), $0) }, uniquingKeysWith: { a, _ in a })
        var recent: [CatalogExercise] = []
        for id in recentIds {
            if let ex = byCanonical[ExerciseCatalog.canonicalExerciseId(for: id)], !recent.contains(ex) { recent.append(ex) }
        }
        if !recent.isEmpty { out.append(Section(kind: .recent, title: "Recent", exercises: Array(recent.prefix(ExercisePickerRecents.limit)))) }
        if let current {
            let same = sorted.filter { $0.primaryMuscle == current.primaryMuscle }
            if !same.isEmpty { out.append(Section(kind: .suggested, title: "Suggested alternatives", exercises: same)) }
        }
        var letters: [String: [CatalogExercise]] = [:]
        for ex in sorted { letters[letter(for: ex), default: []].append(ex) }
        for l in letters.keys.sorted(by: letterOrder) {
            out.append(Section(kind: .letter(l), title: l, exercises: letters[l] ?? []))
        }
        return out
    }

    /// The A-Z section an exercise belongs to; "#" when its name does not start with a letter.
    static func letter(for exercise: CatalogExercise) -> String {
        guard let first = ExerciseSearch.normalize(exercise.name).unicodeScalars.first, CharacterSet.letters.contains(first) else { return "#" }
        return String(first).uppercased()
    }

    private static func letterOrder(_ a: String, _ b: String) -> Bool {
        if a == "#" { return false }
        if b == "#" { return true }
        return a < b
    }

    /// The side index: the letters that have rows, in order.
    static func indexLetters(_ sections: [Section]) -> [String] {
        sections.compactMap { if case .letter(let l) = $0.kind { return l } else { return nil } }
    }
}
