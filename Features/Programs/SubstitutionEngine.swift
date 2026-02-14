import Foundation

enum SubstitutionEngine {

    static func candidates(
        slot: Program1SlotId,
        profile: ExerciseCap.Profile
    ) -> [CatalogExercise] {

        guard let spec = Program1FatLossStrengthLibrary.specs[slot] else { return [] }

        // 1) Filter by equipment + pattern match (or fallback patterns)
        let filtered: [CatalogExercise] = ExerciseCatalog.all.filter { ex in
            guard let cap = ExerciseCapabilities.capability(for: ex.id) else { return false }
            guard cap.supports(profile) else { return false }

            let matchesRequired = !cap.patterns.isDisjoint(with: spec.required)
            let matchesFallback = !spec.fallbackAllowed.isEmpty && !cap.patterns.isDisjoint(with: spec.fallbackAllowed)

            return matchesRequired || matchesFallback
        }

        // 2) Rank: explicit ID order first, then priority overlap
        let byId: [CatalogExercise] = spec.rankedExerciseIds.compactMap { wantedId in
            filtered.first(where: { $0.id == wantedId })
        }

        let remaining = filtered.filter { ex in
            !spec.rankedExerciseIds.contains(ex.id)
        }

        let byPriority = remaining.sorted { a, b in
            let aCap = ExerciseCapabilities.capability(for: a.id)
            let bCap = ExerciseCapabilities.capability(for: b.id)
            let aScore = aCap?.priority.intersection(spec.preferredPriority).count ?? 0
            let bScore = bCap?.priority.intersection(spec.preferredPriority).count ?? 0
            return aScore > bScore
        }

        // 3) De-dupe
        var seen = Set<String>()
        return (byId + byPriority).filter { seen.insert($0.id).inserted }
    }
}
