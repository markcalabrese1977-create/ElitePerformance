import Foundation
import HealthKit
import SwiftData

enum HealthKitWorkoutSummarySyncService {

    private static let store = HKHealthStore()

    // MARK: - HR Zone Model (v2)

    /// NOTE: MVP hardcode for Mark. Move into UserProfile/Settings later.
    private static let markBirthDateComponents = DateComponents(year: 1977, month: 6, day: 7)

    /// Apple-like zoning works best with HR Reserve (HRR / Karvonen).
    /// We still need an HRmax estimate; "Fox" (220-age) tends to mirror Apple thresholds more closely for many users.
    private enum HRMaxFormula {
        case fox       // 220 - age
        case tanaka    // 208 - 0.7*age

        func estimate(ageYears: Int) -> Double {
            switch self {
            case .fox:
                return max(100, 220.0 - Double(ageYears))
            case .tanaka:
                return max(100, 208.0 - 0.7 * Double(ageYears))
            }
        }
    }

    private static let hrMaxFormula: HRMaxFormula = .fox

    // MARK: - Auth

    static func requestAuthorizationIfNeeded() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        var toRead: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!
        ]

        // ✅ Needed for HRR zones (30-day average resting HR)
        if let rhr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) {
            toRead.insert(rhr)
        }

        try await store.requestAuthorization(toShare: [], read: toRead)
    }

    // MARK: - Public API

    /// Pull metrics for the most likely workout for this session date.
    /// Bulletproof behavior:
    /// - If session.completedAt is missing (common when logging later), we fall back to a full-day search.
    /// - If multiple workouts exist, we score candidates and pick the best.
    /// - We use a non-strict predicate so workouts that overlap the window are still returned.
    @MainActor
    static func syncForCompletedSession(_ session: Session, in context: ModelContext) async {
        do {
            try await requestAuthorizationIfNeeded()

            // TEMP: Force recompute so existing sessions pick up the new HRR zone model.
            // TODO: store a zone-model version on Session once we add user-configurable settings.
            let forceRecomputeZones = true

            let hasPrettyHRAlready =
                !session.hkHeartRateSeriesBPM.isEmpty &&
                (session.hkZone1Seconds + session.hkZone2Seconds + session.hkZone3Seconds +
                 session.hkZone4Seconds + session.hkZone5Seconds) > 0

            if session.hkWorkoutUUID != nil && hasPrettyHRAlready && !forceRecomputeZones {
                print("ℹ️ HK workout already linked + HR analysis present; skipping.")
                return
            }

            let cal = Calendar.current

            // If completedAt exists, use it as a precise anchor. Otherwise use the session day.
            // ✅ Anchor logic
            // If completedAt exists, use it.
            // If not, anchor to MIDDAY of the session date (prevents “midnight anchor” rejecting real workouts).
            let sessionDayStart = cal.startOfDay(for: session.date)
            let sessionDayEnd = cal.date(byAdding: .day, value: 1, to: sessionDayStart) ?? sessionDayStart.addingTimeInterval(86400)

            let anchor: Date
            if let completed = session.completedAt {
                anchor = completed
            } else {
                anchor = cal.date(byAdding: .hour, value: 12, to: sessionDayStart)
                    ?? sessionDayStart.addingTimeInterval(12 * 3600)
            }

            // Day window should be based on the session day, not the anchor day.
            let dayStart = sessionDayStart
            let dayEnd = sessionDayEnd

            // Build search strategy:
            // 1) If completedAt exists -> narrow ±6h
            // 2) Always -> day window (the key fix for "yesterday workout logged today")
            // 3) Fallback -> broad ±24h
            var windows: [(label: String, start: Date, end: Date)] = []

            if session.completedAt != nil {
                let start = cal.date(byAdding: .hour, value: -6, to: anchor) ?? anchor.addingTimeInterval(-6 * 3600)
                let end = cal.date(byAdding: .hour, value: 6, to: anchor) ?? anchor.addingTimeInterval(6 * 3600)
                windows.append(("narrow", start, end))
            }

            windows.append(("day", dayStart, dayEnd))

            let broadStart = cal.date(byAdding: .hour, value: -24, to: anchor) ?? anchor.addingTimeInterval(-24 * 3600)
            let broadEnd = cal.date(byAdding: .hour, value: 24, to: anchor) ?? anchor.addingTimeInterval(24 * 3600)
            windows.append(("broad", broadStart, broadEnd))

            var chosen: HKWorkout? = nil
            var chosenFrom: String = ""
            var lastCounts: [String: Int] = [:]

            for w in windows {
                let list = try await fetchWorkoutCandidates(from: w.start, to: w.end)
                print("🔎 HK candidates [\(w.label)] = \(list.count)")
                for wk in list {
                    let type = wk.workoutActivityType.rawValue
                    let minutes = wk.duration / 60.0
                    let source = wk.sourceRevision.source.name
                    print("   • type=\(type) start=\(wk.startDate) end=\(wk.endDate) min=\(String(format: "%.1f", minutes)) source=\(source)")
                }
                lastCounts[w.label] = list.count

                if let best = pickBestWorkout(
                    from: list,
                    anchor: anchor,
                    dayStart: dayStart,
                    dayEnd: dayEnd
                ) {
                    chosen = best
                    chosenFrom = w.label
                    break
                }
            }

            guard let workout = chosen else {
                print("ℹ️ No matching workout found. Counts: \(lastCounts)")
                return
            }

            print("✅ HK match: \(workout.workoutActivityType) [\(chosenFrom)] start=\(workout.startDate) end=\(workout.endDate)")

            // Core workout fields
            session.hkWorkoutUUID = workout.uuid.uuidString
            session.hkWorkoutStart = workout.startDate
            session.hkWorkoutEnd = workout.endDate
            session.hkDuration = workout.duration

            let active = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0
            session.hkActiveCalories = active

            // v1: “Total Calories” approximation (active + basal in interval)
            let basal = try await sumBasalCalories(from: workout.startDate, to: workout.endDate)
            session.hkTotalCalories = active + basal

            // HR metrics
            let (avgHR, maxHR) = try await heartRateStats(from: workout.startDate, to: workout.endDate)
            session.hkAvgHeartRate = avgHR
            session.hkMaxHeartRate = maxHR

            // Zones + sparkline series + post-workout HR
            await syncHeartRateUIFields(
                into: session,
                workoutStart: workout.startDate,
                workoutEnd: workout.endDate,
                maxHR: maxHR
            )

            try context.save()
            print("✅ HK workout summary synced to Session")
        } catch {
            print("⚠️ HK sync failed: \(error)")
        }
    }

    // MARK: - Candidate Selection

    private static func fetchWorkoutCandidates(from start: Date, to end: Date) async throws -> [HKWorkout] {
        // Non-strict options so overlapping workouts still show up.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 50,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { return continuation.resume(throwing: error) }
                let workouts = (samples as? [HKWorkout]) ?? []
                continuation.resume(returning: workouts)
            }

            store.execute(query)
        }
    }

    private static func pickBestWorkout(
        from workouts: [HKWorkout],
        anchor: Date,
        dayStart: Date,
        dayEnd: Date
    ) -> HKWorkout? {

        guard !workouts.isEmpty else { return nil }

        // Prefer strength workouts, but don’t fail hard if user logged as “Other”.
        // We score and pick the best overall candidate.
        func typeScore(_ type: HKWorkoutActivityType) -> Double {
            switch type {
            case .traditionalStrengthTraining: return 120
            case .functionalStrengthTraining: return 100
            default: return 20
            }
        }

        func inSameDay(_ d: Date) -> Bool {
            d >= dayStart && d < dayEnd
        }

        func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
            min(hi, max(lo, x))
        }

        // Compute best by score
        var best: (workout: HKWorkout, score: Double)? = nil

        for w in workouts {
            let start = w.startDate
            let end = w.endDate

            // Distance to anchor (seconds)
            let dist = abs(start.timeIntervalSince(anchor))

            // Basic features
            let tScore = typeScore(w.workoutActivityType)
            let dayScore: Double = inSameDay(start) ? 40.0 : 0.0

            // Longer workouts are more likely the real lift vs a 2-min accidental
            let durationMinutes = w.duration / 60.0
            let durationScore = clamp(durationMinutes, 0, 30) // cap at +30

            // Penalize distance (0 penalty within ~30 min, then grows)
            let distHours = dist / 3600.0
            let distPenalty = clamp(distHours * 12, 0, 120) // max -120

            // Overlap bonus if it overlaps the session day window
            let overlapsDay = (start < dayEnd) && (end > dayStart)
            let overlapScore: Double = overlapsDay ? 25.0 : 0.0

            // Total
            let score = tScore + dayScore + durationScore + overlapScore - distPenalty

            if let cur = best {
                if score > cur.score {
                    best = (w, score)
                }
            } else {
                best = (w, score)
            }
        }

        // If we found a very low score across the board, still return nil (prevents linking random workouts)
        guard let chosen = best, chosen.score >= 35 else {
            return nil
        }

        return chosen.workout
    }

    // MARK: - Heart Rate Stats / Calories

    private static func heartRateStats(from start: Date, to end: Date) async throws -> (avg: Double, max: Double) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return (0, 0) }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: hrType,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMax],
                anchorDate: start,
                intervalComponents: DateComponents(second: 30)
            )

            query.initialResultsHandler = { _, results, error in
                if let error { return continuation.resume(throwing: error) }

                var sum: Double = 0
                var count: Double = 0
                var maxVal: Double = 0

                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    if let avgQ = stats.averageQuantity() {
                        let v = avgQ.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                        sum += v
                        count += 1
                    }
                    if let maxQ = stats.maximumQuantity() {
                        let v = maxQ.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                        if v > maxVal { maxVal = v }
                    }
                }

                let avg = (count > 0) ? (sum / count) : 0
                continuation.resume(returning: (avg, maxVal))
            }

            store.execute(query)
        }
    }

    private static func sumBasalCalories(from start: Date, to end: Date) async throws -> Double {
        guard let type = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let error { return continuation.resume(throwing: error) }
                let kcal = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                continuation.resume(returning: kcal)
            }
            store.execute(query)
        }
    }

    // MARK: - HR series + zones + post-workout HR

    /// Writes UI-friendly HR fields onto Session.
    /// Safe behavior: if we can’t get samples, we just leave series empty + zones at 0.
    @MainActor
    private static func syncHeartRateUIFields(into session: Session, workoutStart: Date, workoutEnd: Date, maxHR: Double) async {
        do {
            let samples = try await fetchHeartRateSamples(from: workoutStart, to: workoutEnd)
            guard samples.count >= 2 else {
                session.hkHeartRateSeriesBPM = []
                session.hkHeartRateSeriesStepSeconds = 0
                session.hkPostWorkoutHeartRateBPM = []
                session.hkPostWorkoutHeartRateStepSeconds = 0

                session.hkZone1Seconds = 0
                session.hkZone2Seconds = 0
                session.hkZone3Seconds = 0
                session.hkZone4Seconds = 0
                session.hkZone5Seconds = 0
                return
            }

            let (series, step) = downsampleHRSeries(samples: samples, start: workoutStart, end: workoutEnd, maxPoints: 140)
            session.hkHeartRateSeriesBPM = series
            session.hkHeartRateSeriesStepSeconds = step

            // ✅ v2 Zones: HRR (Karvonen) using 30-day resting HR average.
            // If we fail to fetch RHR, we fall back to legacy %max model.
            if let rhr30 = try await restingHeartRateAverageBPM(endingAt: workoutStart, lookbackDays: 30),
               rhr30 > 0 {

                let ageYears = markAgeYears(at: workoutStart) ?? 48
                let hrMax = hrMaxFormula.estimate(ageYears: ageYears)
                let zones = computeZoneDurationsHRR(samples: samples, hrMax: hrMax, restingHR: rhr30)

                session.hkZone1Seconds = zones.z1
                session.hkZone2Seconds = zones.z2
                session.hkZone3Seconds = zones.z3
                session.hkZone4Seconds = zones.z4
                session.hkZone5Seconds = zones.z5
            } else {
                let effectiveMax = maxHR > 0 ? maxHR : (session.hkMaxHeartRate > 0 ? session.hkMaxHeartRate : 180)
                let zones = computeZoneDurationsPercentMax(samples: samples, maxHR: effectiveMax)

                session.hkZone1Seconds = zones.z1
                session.hkZone2Seconds = zones.z2
                session.hkZone3Seconds = zones.z3
                session.hkZone4Seconds = zones.z4
                session.hkZone5Seconds = zones.z5
            }

            // Post-workout HR (first 2 minutes after end)
            let postStart = workoutEnd
            let postEnd = workoutEnd.addingTimeInterval(120)

            let postSamples = try await fetchHeartRateSamples(from: postStart, to: postEnd)
            if postSamples.count >= 2 {
                let (postSeries, postStep) = downsampleHRSeries(samples: postSamples, start: postStart, end: postEnd, maxPoints: 24)
                session.hkPostWorkoutHeartRateBPM = postSeries
                session.hkPostWorkoutHeartRateStepSeconds = postStep
            } else {
                session.hkPostWorkoutHeartRateBPM = []
                session.hkPostWorkoutHeartRateStepSeconds = 0
            }

        } catch {
            print("⚠️ HK HR series/zones failed: \(error)")
        }
    }

    private static func fetchHeartRateSamples(from start: Date, to end: Date) async throws -> [HKQuantitySample] {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { return continuation.resume(throwing: error) }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }

            store.execute(query)
        }
    }

    /// 30-day average Resting Heart Rate (bpm) from Apple Health.
    private static func restingHeartRateAverageBPM(endingAt end: Date, lookbackDays: Int) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else { return nil }
        let start = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: end)
            ?? end.addingTimeInterval(-Double(lookbackDays) * 86400)

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage]
            ) { _, result, error in
                if let error { return continuation.resume(throwing: error) }
                let avg = result?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                continuation.resume(returning: avg)
            }

            store.execute(query)
        }
    }

    private static func markAgeYears(at date: Date) -> Int? {
        guard let birth = Calendar.current.date(from: markBirthDateComponents) else { return nil }
        return Calendar.current.dateComponents([.year], from: birth, to: date).year
    }

    /// Downsample heart rate to <= maxPoints evenly spaced points.
    /// Returns (bpmSeries, stepSeconds).
    private static func downsampleHRSeries(
        samples: [HKQuantitySample],
        start: Date,
        end: Date,
        maxPoints: Int
    ) -> ([Double], Double) {
        guard !samples.isEmpty else { return ([], 0) }

        let total = max(1, end.timeIntervalSince(start))
        let rawStep = total / Double(maxPoints)
        let step = max(5.0, (rawStep / 5.0).rounded() * 5.0) // round to 5s

        var series: [Double] = []
        series.reserveCapacity(min(maxPoints, 200))

        var targetTime = start
        var i = 0

        while targetTime <= end {
            while i < samples.count && samples[i].startDate < targetTime {
                i += 1
            }

            let sampleIndex: Int
            if i == 0 {
                sampleIndex = 0
            } else if i >= samples.count {
                sampleIndex = samples.count - 1
            } else {
                let prev = samples[i - 1].startDate
                let next = samples[i].startDate
                sampleIndex = (targetTime.timeIntervalSince(prev) <= next.timeIntervalSince(targetTime)) ? (i - 1) : i
            }

            let bpm = samples[sampleIndex].quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            series.append(bpm)

            targetTime = targetTime.addingTimeInterval(step)
            if series.count >= maxPoints { break }
        }

        return (series, step)
    }

    // MARK: - Zone calculation

    /// v2: Zones based on HRR (Karvonen).
    /// Z1 <60%, Z2 60–70%, Z3 70–80%, Z4 80–90%, Z5 >=90% of HRR, offset by Resting HR.
    private static func computeZoneDurationsHRR(
        samples: [HKQuantitySample],
        hrMax: Double,
        restingHR: Double
    ) -> (z1: Double, z2: Double, z3: Double, z4: Double, z5: Double) {

        guard samples.count >= 2 else { return (0,0,0,0,0) }

        let rhr = max(30, restingHR)
        let maxHr = max(rhr + 40, hrMax)
        let hrr = max(1, maxHr - rhr)

        func boundary(_ pct: Double) -> Double { rhr + pct * hrr }

        let z1Upper = boundary(0.60)
        let z2Upper = boundary(0.70)
        let z3Upper = boundary(0.80)
        let z4Upper = boundary(0.90)

        var z1: Double = 0
        var z2: Double = 0
        var z3: Double = 0
        var z4: Double = 0
        var z5: Double = 0

        for idx in 0..<(samples.count - 1) {
            let a = samples[idx]
            let b = samples[idx + 1]

            let dt = max(0, b.startDate.timeIntervalSince(a.startDate))
            if dt == 0 { continue }

            let hr = a.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))

            switch hr {
            case ..<z1Upper: z1 += dt
            case ..<z2Upper: z2 += dt
            case ..<z3Upper: z3 += dt
            case ..<z4Upper: z4 += dt
            default: z5 += dt
            }
        }

        return (z1, z2, z3, z4, z5)
    }

    /// Legacy v1 Zones based on % of max HR:
    /// Z1 <60%, Z2 60–70%, Z3 70–80%, Z4 80–90%, Z5 >=90%
    private static func computeZoneDurationsPercentMax(
        samples: [HKQuantitySample],
        maxHR: Double
    ) -> (z1: Double, z2: Double, z3: Double, z4: Double, z5: Double) {

        guard samples.count >= 2 else { return (0,0,0,0,0) }

        let z1Upper = 0.60 * maxHR
        let z2Upper = 0.70 * maxHR
        let z3Upper = 0.80 * maxHR
        let z4Upper = 0.90 * maxHR

        var z1: Double = 0
        var z2: Double = 0
        var z3: Double = 0
        var z4: Double = 0
        var z5: Double = 0

        for idx in 0..<(samples.count - 1) {
            let a = samples[idx]
            let b = samples[idx + 1]

            let dt = max(0, b.startDate.timeIntervalSince(a.startDate))
            if dt == 0 { continue }

            let hr = a.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))

            switch hr {
            case ..<z1Upper: z1 += dt
            case ..<z2Upper: z2 += dt
            case ..<z3Upper: z3 += dt
            case ..<z4Upper: z4 += dt
            default: z5 += dt
            }
        }

        return (z1, z2, z3, z4, z5)
    }
}
