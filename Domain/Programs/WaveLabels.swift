// Domain/Programs/WaveLabels.swift
import Foundation

/// The one path that names a wave letter on screen (Program tab, History, exercise history, the session screen).
///
/// A block's non-deload letters are named by what they ask of the lifter, not by a template's wording: the letters are
/// ordered by the mean `repMax` of the anchor items (the primary lifts), and the lowest becomes "Heavy", the highest
/// "Light", and with three letters the one between "Moderate". Two letters are Heavy / Light.
///
/// If the letters don't differ by rep zone (the means span 1 rep or less), or there is only one letter, or more than
/// three, the existing `WaveType.label(forRaw:mesoName:)` name is used for every letter. Deload and maintenance weeks
/// keep that function's "Deload" / "Maintenance". A block without wave letters has no labels.
///
/// The answer depends only on the prescriptions, so a renamed block gets the same labels.
enum WaveLabels {

    /// One prescription: which letter it belongs to, its top rep, and whether it is an anchor lift.
    struct Sample: Equatable {
        let letter: String
        let repMax: Int
        let isAnchor: Bool
    }

    /// Letters whose means differ by no more than this (in reps) count as the same rep zone.
    static let sameZoneSpan = 1.0

    // MARK: - Pure core

    /// letter ("a", "b", "c") -> name ("Heavy"), for the non-deload letters present in `samples`.
    static func labels(samples: [Sample], mesoName: String?, isMaintenance: Bool = false) -> [String: String] {
        let usable = samples.filter { $0.repMax > 0 && !isDeloadOrBlank($0.letter) }
        let letters = Set(usable.map { $0.letter.lowercased() }).sorted()
        guard !letters.isEmpty else { return [:] }

        func fallback() -> [String: String] {
            var out: [String: String] = [:]
            for l in letters { out[l] = WaveType.label(forRaw: l, mesoName: mesoName, isMaintenance: isMaintenance) ?? l.uppercased() }
            return out
        }

        // Anchors when every letter has some; otherwise every prescription.
        let anchors = usable.filter(\.isAnchor)
        let pool = Set(anchors.map { $0.letter.lowercased() }) == Set(letters) ? anchors : usable
        let means: [(letter: String, mean: Double)] = letters.map { l in
            let reps = pool.filter { $0.letter.lowercased() == l }.map { Double($0.repMax) }
            return (l, reps.reduce(0, +) / Double(reps.count))
        }
        guard (2...3).contains(means.count),
              let lo = means.map(\.mean).min(), let hi = means.map(\.mean).max(),
              hi - lo > sameZoneSpan else { return fallback() }

        let names = means.count == 2 ? ["Heavy", "Light"] : ["Heavy", "Moderate", "Light"]
        let ordered = means.sorted { $0.mean != $1.mean ? $0.mean < $1.mean : $0.letter < $1.letter }
        var out: [String: String] = [:]
        for (i, entry) in ordered.enumerated() { out[entry.letter] = names[i] }
        return out
    }

    private static func isDeloadOrBlank(_ raw: String) -> Bool {
        let w = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return w.isEmpty || w == "deload"
    }

    // MARK: - From a block's sessions, or a template

    static func samples(sessions: [Session]) -> [Sample] {
        sessions.flatMap { s in
            s.items.compactMap { i -> Sample? in
                guard let letter = i.waveRaw, let max = i.repMax else { return nil }
                return Sample(letter: letter, repMax: max, isAnchor: i.priorityRaw == ExercisePriority.anchor.rawValue)
            }
        }
    }

    static func labels(sessions: [Session], mesoName: String?, isMaintenance: Bool = false) -> [String: String] {
        labels(samples: samples(sessions: sessions), mesoName: mesoName, isMaintenance: isMaintenance)
    }

    static func labels(meso: MesoBlock?) -> [String: String] {
        guard let meso else { return [:] }
        return labels(sessions: meso.sessions, mesoName: meso.name, isMaintenance: meso.isMaintenance)
    }

    static func labels(template: ProgramTemplate) -> [String: String] {
        let all = template.dayTemplates.flatMap(\.exerciseTemplates).flatMap { slot in
            slot.prescriptions.map { Sample(letter: $0.wave.rawValue, repMax: $0.repMax, isAnchor: slot.priority == .anchor) }
        }
        return labels(samples: all, mesoName: template.name)
    }

    // MARK: - Names for a raw letter

    /// "Moderate" for a lettered week, "Deload" / "Maintenance" for a deload one, nil when there is no wave.
    static func name(forRaw raw: String?, labels: [String: String], mesoName: String?, isMaintenance: Bool = false) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let w = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if w == "deload" { return WaveType.label(forRaw: w, mesoName: mesoName, isMaintenance: isMaintenance) }
        return labels[w] ?? WaveType.label(forRaw: w, mesoName: mesoName, isMaintenance: isMaintenance)
    }

    /// "Moderate (B)", or "Deload" / "Maintenance" (no letter), or nil without a wave.
    static func display(forRaw raw: String?, labels: [String: String], mesoName: String?, isMaintenance: Bool = false) -> String? {
        guard let name = name(forRaw: raw, labels: labels, mesoName: mesoName, isMaintenance: isMaintenance), let raw else { return nil }
        let w = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return w == "deload" ? name : "\(name) (\(w.uppercased()))"
    }

    static func display(forRaw raw: String?, meso: MesoBlock?) -> String? {
        display(forRaw: raw, labels: labels(meso: meso), mesoName: meso?.name, isMaintenance: meso?.isMaintenance == true)
    }
}
