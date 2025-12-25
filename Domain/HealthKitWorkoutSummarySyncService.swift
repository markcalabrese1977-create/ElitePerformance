import Foundation
import HealthKit
import SwiftData

enum HealthKitWorkoutSummarySyncService {

    private static let store = HKHealthStore()

    // MARK: - HR Zone Model (v2)

    /// NOTE: MVP hardcode for Mark. Move into UserProfile/Settings later.
    private static let markBirthDateComponents = DateComponents(year: 1977, month: 6, day: 7)

    /// Apple-like zoneing works best with HR Reserve (HRR / Karvonen).
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

    /// Pull metrics for the most likely workout around `session.completedAt` (or session.date).
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

            let anchor = session.completedAt ?? session.date
            let startWindow = Calendar.current.date(byAdding: .hour, value: -6, to: anchor) ?? anchor.addingTimeInterval(-6*3600)
            let endWindow   = Calendar.current.date(byAdding: .hour, value:  6, to: anchor) ?? anchor.addingTimeInterval( 6*3600)

            // Find candidate workouts
            let workout = try await fetchBestStrengthWorkout(from: startWindow, to: endWindow, anchor: anchor)

            guard let workout else {
                print("ℹ️ No matching strength workout found in window.")
                return
            }

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

            // ✅ Zones + sparkline series + post-workout HR (v2 zones)
            await syncHeartRateUIFields(into: session, workoutStart: workout.startDate, workoutEnd: workout.endDate, maxHR: maxHR)

            try context.save()
            print("✅ HK workout summary synced to Session")
        } catch {
            print("⚠️ HK sync failed: \(error)")
        }
    }

    // MARK: - Helpers

    private static func fetchBestStrengthWorkout(from start: Date, to end: Date, anchor: Date) async throws -> HKWorkout? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 25,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { return continuation.resume(throwing: error) }

                let workouts = (samples as? [HKWorkout]) ?? []

                // Prefer Traditional Strength Training if present; else take closest workout by time.
                let strength = workouts.filter { $0.workoutActivityType == .traditionalStrengthTraining }
                let candidates = strength.isEmpty ? workouts : strength

                let best = candidates.min { a, b in
                    abs(a.startDate.timeIntervalSince(anchor)) < abs(b.startDate.timeIntervalSince(anchor))
                }

                continuation.resume(returning: best)
            }

            store.execute(query)
        }
    }

    private static func heartRateStats(from start: Date, to end: Date) async throws -> (avg: Double, max: Double) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return (0, 0) }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

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
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error { return continuation.resume(throwing: error) }
                let kcal = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                continuation.resume(returning: kcal)
            }
            store.execute(query)
        }
    }

    // MARK: - NEW: HR series + zones + post-workout HR

    /// Writes UI-friendly HR fields onto Session.
    /// Safe behavior: if we can’t get samples, we just leave series empty + zones at 0.
    @MainActor
    private static func syncHeartRateUIFields(into session: Session, workoutStart: Date, workoutEnd: Date, maxHR: Double) async {
        do {
            let samples = try await fetchHeartRateSamples(from: workoutStart, to: workoutEnd)
            guard samples.count >= 2 else {
                // leave empty; UI can hide sparkline/zones
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

            // Sparkline series (downsample to keep SwiftData fast)
            let (series, step) = downsampleHRSeries(samples: samples, start: workoutStart, end: workoutEnd, maxPoints: 140)
            session.hkHeartRateSeriesBPM = series
            session.hkHeartRateSeriesStepSeconds = step

            // ✅ v2 Zones: HRR (Karvonen) using 30-day resting HR average.
            // If we fail to fetch RHR, we fall back to the legacy %max model.
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
                // Legacy fallback: percent of observed max HR for this workout
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

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
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
    /// Returns nil if the data is unavailable or the query yields no samples.
    private static func restingHeartRateAverageBPM(endingAt end: Date, lookbackDays: Int) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else { return nil }
        let start = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: end) ?? end.addingTimeInterval(-Double(lookbackDays) * 86400)

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

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
        let years = Calendar.current.dateComponents([.year], from: birth, to: date).year
        return years
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
        // keep step reasonable; round to 5s increments
        let step = max(5, (rawStep / 5.0).rounded() * 5.0)

        var series: [Double] = []
        series.reserveCapacity(min(maxPoints, 200))

        var targetTime = start
        var i = 0

        while targetTime <= end {
            // advance i until sample time >= target
            while i < samples.count && samples[i].startDate < targetTime {
                i += 1
            }

            // choose nearest previous sample if we overshot
            let sampleIndex: Int
            if i == 0 {
                sampleIndex = 0
            } else if i >= samples.count {
                sampleIndex = samples.count - 1
            } else {
                // between i-1 and i, pick whichever is closer
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
    /// We use Apple-like cutoffs:
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

        func boundary(_ pct: Double) -> Double {
            rhr + pct * hrr
        }

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
