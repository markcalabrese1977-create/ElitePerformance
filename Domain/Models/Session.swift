import Foundation
import SwiftData

// MARK: - Session Status

enum SessionStatus: String, Codable, CaseIterable {
    case planned
    case inProgress
    case completed
}

// MARK: - Session Readiness

enum SessionReadiness: String, Codable {
    case fresh        // better than normal — aggressive increase threshold
    case normal       // baseline — standard evaluation
    case fatigued     // tired but trainable — hold load, no increases
    case compromised  // joint/injury issue — reduce load, shift reps up
}

// MARK: - Session

@Model
final class Session {
    // Sync-safe identity (optional for migration safety)
    var id: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    // Core
    var date: Date
    var status: SessionStatus
    var completedAt: Date?

    /// 0 = not set yet, 1–5 = readiness rating for this session.
    var readinessStars: Int
    
    /// Structured readiness for coaching engine use. Default normal.
    var readinessRaw: String = "normal"

    var readiness: SessionReadiness {
        get { SessionReadiness(rawValue: readinessRaw) ?? .normal }
        set { readinessRaw = newValue.rawValue }
    }

    /// Optional text recap / notes for this session (end-of-workout recap writes here).
    var sessionNotes: String?

    /// Stored property kept for migration compatibility.
    var weekInMeso: Int?

    var meso: MesoBlock?

    /// Stable order within a mesocycle: 1...N
    /// Optional for migration safety with existing stores.
    var programIndex: Int?

    var dayLabel: String?

    /// True on the sessions of a deload week the user inserted into the block (as opposed to one
    /// the program generated). Optional for lightweight migration; nil and false both mean "not inserted".
    var insertedDeload: Bool?

    /// The day this session is scheduled for. Set at creation (= `date`), moved only by the services that move
    /// planned sessions (Rest today, insert / remove deload week), and NEVER by completion: finishing a session
    /// overwrites `date` with the completion time, so this is what tells a late or missed session from an on-time
    /// one. nil on sessions from before the field existed (only planned ones are backfilled), meaning "unknown".
    /// Optional Date: SwiftData lightweight migration, no schema version bump.
    var plannedDate: Date?

    /// True when `plannedDate` was recorded by Session creation (and has only been moved by the services above), so
    /// it is the real schedule. nil when the date was derived later (`PlannedDateBackfill`) or never existed:
    /// analytics must not read "planned, not done" off a derived date as a missed session. Additive optional Bool.
    var plannedDateExact: Bool?

    /// Alias used throughout the app.
    var weekIndex: Int {
        get { weekInMeso ?? 1 }
        set { weekInMeso = newValue }
    }

    /// Exercises for this session.
    @Relationship(deleteRule: .cascade) var items: [SessionItem] = []

    // MARK: - HealthKit / Apple Workout Summary

    /// Linked HealthKit workout UUID (string form). Used as our “already synced” flag.
    var hkWorkoutUUID: String?

    var hkWorkoutStart: Date?
    var hkWorkoutEnd: Date?

    /// Workout duration in seconds.
    var hkDuration: Double

    /// Calories (kcal)
    var hkActiveCalories: Double
    var hkTotalCalories: Double

    /// Heart Rate (bpm)
    var hkAvgHeartRate: Double
    var hkMaxHeartRate: Double

    // MARK: - HealthKit HR UI series

    /// Zone durations in seconds
    var hkZone1Seconds: Double
    var hkZone2Seconds: Double
    var hkZone3Seconds: Double
    var hkZone4Seconds: Double
    var hkZone5Seconds: Double

    /// Downsampled HR series for sparkline (bpm)
    var hkHeartRateSeriesBPM: [Double]
    var hkHeartRateSeriesStepSeconds: Double

    /// Post-workout HR mini chart (bpm)
    var hkPostWorkoutHeartRateBPM: [Double]
    var hkPostWorkoutHeartRateStepSeconds: Double

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),

        date: Date,
        status: SessionStatus = .planned,
        readinessStars: Int = 0,
        sessionNotes: String? = nil,
        weekIndex: Int = 1,
        dayLabel: String? = nil,
        items: [SessionItem] = [],
        completedAt: Date? = nil,
        programIndex: Int? = nil,

        hkWorkoutUUID: String? = nil,
        hkWorkoutStart: Date? = nil,
        hkWorkoutEnd: Date? = nil,
        hkDuration: Double = 0,
        hkActiveCalories: Double = 0,
        hkTotalCalories: Double = 0,
        hkAvgHeartRate: Double = 0,
        hkMaxHeartRate: Double = 0,

        hkZone1Seconds: Double = 0,
        hkZone2Seconds: Double = 0,
        hkZone3Seconds: Double = 0,
        hkZone4Seconds: Double = 0,
        hkZone5Seconds: Double = 0,

        hkHeartRateSeriesBPM: [Double] = [],
        hkHeartRateSeriesStepSeconds: Double = 0,

        hkPostWorkoutHeartRateBPM: [Double] = [],
        hkPostWorkoutHeartRateStepSeconds: Double = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        self.date = date
        self.plannedDate = date
        self.plannedDateExact = true
        self.status = status
        self.completedAt = completedAt

        self.readinessStars = readinessStars
        self.sessionNotes = sessionNotes
        self.weekInMeso = weekIndex
        self.dayLabel = dayLabel
        self.items = items
        self.programIndex = programIndex

        self.hkWorkoutUUID = hkWorkoutUUID
        self.hkWorkoutStart = hkWorkoutStart
        self.hkWorkoutEnd = hkWorkoutEnd

        self.hkDuration = hkDuration
        self.hkActiveCalories = hkActiveCalories
        self.hkTotalCalories = hkTotalCalories

        self.hkAvgHeartRate = hkAvgHeartRate
        self.hkMaxHeartRate = hkMaxHeartRate

        self.hkZone1Seconds = hkZone1Seconds
        self.hkZone2Seconds = hkZone2Seconds
        self.hkZone3Seconds = hkZone3Seconds
        self.hkZone4Seconds = hkZone4Seconds
        self.hkZone5Seconds = hkZone5Seconds

        self.hkHeartRateSeriesBPM = hkHeartRateSeriesBPM
        self.hkHeartRateSeriesStepSeconds = hkHeartRateSeriesStepSeconds

        self.hkPostWorkoutHeartRateBPM = hkPostWorkoutHeartRateBPM
        self.hkPostWorkoutHeartRateStepSeconds = hkPostWorkoutHeartRateStepSeconds
    }
}

// MARK: - Session Item (per-exercise)

@Model
final class SessionItem {
    // Sync-safe identity (optional for migration safety)
    var id: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    /// Display order within the session (1-based).
    var order: Int

    /// ID of the exercise in `ExerciseCatalog` / `CatalogExercise`.
    var exerciseId: String

    /// Durable display-name snapshot for history / recap portability.
    var exerciseNameSnapshot: String?

    // Planned targets (flattened execution defaults)
    var targetReps: Int
    var targetSets: Int
    var targetRIR: Int
    var suggestedLoad: Double

    // Resolved DUP prescription metadata (optional for migration safety)
    var waveRaw: String?
    var priorityRaw: String?

    var setMin: Int?
    var setMax: Int?

    var repMin: Int?
    var repMax: Int?

    var targetRIRMin: Int?
    var targetRIRMax: Int?

    var intensifierRaw: String?
    var intensifierNotes: String?
    var prescriptionNotes: String?

    /// Optional per-set logs (for future richer analytics).
    @Relationship(deleteRule: .cascade) var logs: [SetLog] = []

    // Planned pattern per set (v1)
    var plannedRepsBySet: [Int] = []
    var plannedLoadsBySet: [Double] = []
    var plannedRIRsBySet: [Int] = []

    /// True once the user has manually edited this session's plan (per-set load/
    /// reps/RIR or the default steppers) in the Program tab. Auto writes
    /// (materializer, anchor, carry-forward, coaching bump) leave it false.
    /// Carry-forward's bump write-back overwrites only unedited (false) future
    /// plans, so a user's manual edit is never clobbered. Defaults false, so
    /// existing auto-seeded sessions are eligible for the first post-fix bump.
    /// Additive Bool-with-default → SwiftData lightweight migration, no schema
    /// version bump needed (same pattern as MesoBlock.isMaintenance).
    var planEdited: Bool = false

    // Simple inline logging (what you’re using now)
    var actualReps: [Int] = []
    var actualLoads: [Double] = []
    var actualRIRs: [Int] = []
    var usedRestPauseFlags: [Bool] = []
    var restPausePatternsBySet: [String] = []
    var dropSetPatternsBySet: [String] = []
    var setFeedbackBySet: [String] = []
    var pumpRatingsBySet: [Int] = []

    var isCompleted: Bool
    var isPR: Bool

    var coachNote: String?
    var loadOverrideReasonRaw: String? = nil

    var loadOverrideReason: LoadOverrideReason? {
        get {
            guard let raw = loadOverrideReasonRaw else { return nil }
            return LoadOverrideReason(rawValue: raw)
        }
        set { loadOverrideReasonRaw = newValue?.rawValue }
    }
    var nextSuggestedLoad: Double?

    // MARK: Top set (optional; nil on every item that has no top set)
    //
    // Back-off rows are 0..<targetSets; top rows sit at the tail (targetSets..<targetSets +
    // topCount). The role comes from the ROW (setRolesBySet[idx] == "top"), never from the order
    // sets were logged. All four fields are nil on an item without a top set, which then behaves
    // exactly as before (no migration). Additive optionals: lightweight migration.

    /// Index-aligned with the per-set arrays: "top" or "" (back-off). nil = no top set.
    var setRolesBySet: [String]?
    var topRepMin: Int?
    var topRepMax: Int?
    var topRIR: Int?

    /// The number of back-off sets the PROGRAM prescribes for this session. `targetSets` is what this
    /// session is set up to run and is changed by the in-session Add Set; `prescribedSets` is changed
    /// only by a prescription edit (materialization, Change prescription, the Program tab, volume
    /// regulation, insert deload, next-meso clone). nil on data from before the key existed: readers use
    /// `effectivePrescribedSets`, which then falls back to `targetSets` (today's behavior).
    var prescribedSets: Int?

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),

        order: Int,
        exerciseId: String,
        exerciseNameSnapshot: String? = nil,
        targetReps: Int,
        targetSets: Int,
        targetRIR: Int,
        suggestedLoad: Double,

        waveRaw: String? = nil,
        priorityRaw: String? = nil,
        setMin: Int? = nil,
        setMax: Int? = nil,
        repMin: Int? = nil,
        repMax: Int? = nil,
        targetRIRMin: Int? = nil,
        targetRIRMax: Int? = nil,
        intensifierRaw: String? = nil,
        intensifierNotes: String? = nil,
        prescriptionNotes: String? = nil,

        plannedRepsBySet: [Int] = [],
        plannedLoadsBySet: [Double] = [],
        plannedRIRsBySet: [Int] = [],
        logs: [SetLog] = [],
        actualReps: [Int] = [],
        actualLoads: [Double] = [],
        actualRIRs: [Int] = [],
        usedRestPauseFlags: [Bool] = [],
        restPausePatternsBySet: [String] = [],
        dropSetPatternsBySet: [String] = [],
        setFeedbackBySet: [String] = [],
        pumpRatingsBySet: [Int] = [],
        isCompleted: Bool = false,
        isPR: Bool = false,
        coachNote: String? = nil,
        nextSuggestedLoad: Double? = nil,
        loadOverrideReasonRaw: String? = nil,
        prescribedSets: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        // A new item is born prescribed: what it is created with is what the program prescribes.
        self.prescribedSets = prescribedSets ?? targetSets
        self.order = order
        self.exerciseId = exerciseId
        self.exerciseNameSnapshot = exerciseNameSnapshot

        self.targetReps = targetReps
        self.targetSets = targetSets
        self.targetRIR = targetRIR
        self.suggestedLoad = suggestedLoad

        self.waveRaw = waveRaw
        self.priorityRaw = priorityRaw
        self.setMin = setMin
        self.setMax = setMax
        self.repMin = repMin
        self.repMax = repMax
        self.targetRIRMin = targetRIRMin
        self.targetRIRMax = targetRIRMax
        self.intensifierRaw = intensifierRaw
        self.intensifierNotes = intensifierNotes
        self.prescriptionNotes = prescriptionNotes

        self.plannedRepsBySet = plannedRepsBySet
        self.plannedLoadsBySet = plannedLoadsBySet
        self.plannedRIRsBySet = plannedRIRsBySet
        self.logs = logs

        self.actualReps = actualReps
        self.actualLoads = actualLoads
        self.actualRIRs = actualRIRs
        self.usedRestPauseFlags = usedRestPauseFlags
        self.restPausePatternsBySet = restPausePatternsBySet
        self.dropSetPatternsBySet = dropSetPatternsBySet
        self.setFeedbackBySet = setFeedbackBySet
        self.pumpRatingsBySet = pumpRatingsBySet

        self.isCompleted = isCompleted
        self.isPR = isPR

        self.coachNote = coachNote
        self.nextSuggestedLoad = nextSuggestedLoad
        self.loadOverrideReasonRaw = loadOverrideReasonRaw
    }
}

// MARK: - Top-set roles

extension SessionItem {
    static let topRole = "top"

    /// Row indices whose role is "top", ascending.
    var topRowIndices: [Int] {
        (setRolesBySet ?? []).enumerated().compactMap { $0.element == Self.topRole ? $0.offset : nil }
    }

    /// Number of top rows (0 when the item has no top set).
    var topCount: Int { topRowIndices.count }

    var hasTopSet: Bool { topCount > 0 }

    /// The prescribed back-off set count (see `prescribedSets`); `targetSets` for data without the key.
    var effectivePrescribedSets: Int { prescribedSets ?? targetSets }

    /// A prescription edit: both the session's set count and the prescribed count move.
    func setPrescribedSets(_ n: Int) {
        targetSets = n
        prescribedSets = n
    }

    func isTopRow(_ index: Int) -> Bool {
        guard let roles = setRolesBySet, roles.indices.contains(index) else { return false }
        return roles[index] == Self.topRole
    }

    /// Planned values of the back-off rows only (every row that is not a top row). For an item with
    /// no top set this is the whole array.
    func backOffValues<T>(_ array: [T]) -> [T] {
        array.enumerated().filter { !isTopRow($0.offset) }.map(\.element)
    }

    /// Planned values of the top rows only, in row order (missing rows read as `fallback`).
    func topValues<T>(_ array: [T], fallback: T) -> [T] {
        topRowIndices.map { $0 < array.count ? array[$0] : fallback }
    }

    /// Rebuilds the planned arrays of an UNLOGGED item for `count` back-off rows: the back-off segment
    /// is truncated or extended by repeating its last value, the top tail (loads, reps, RIRs) and the
    /// role array are kept in step. `backOffLoad`, when given, fills every back-off load slot.
    /// With no top set it only sets targetSets-many loads, as carry-forward always did.
    func resizeBackOffs(to count: Int, backOffLoad: Double? = nil) {
        let n = max(0, count)
        func fit<T>(_ values: [T], fallback: T) -> [T] {
            if values.count >= n { return Array(values.prefix(n)) }
            let pad = values.last ?? fallback
            return values + Array(repeating: pad, count: n - values.count)
        }
        let topLoads = topValues(plannedLoadsBySet, fallback: 0.0)
        let topReps = topValues(plannedRepsBySet, fallback: topRepMin ?? targetReps)
        let topRIRs = topValues(plannedRIRsBySet, fallback: topRIR ?? targetRIR)
        let backReps = fit(backOffValues(plannedRepsBySet), fallback: targetReps)
        let backRIRs = fit(backOffValues(plannedRIRsBySet), fallback: targetRIR)
        let backLoads = backOffLoad.map { Array(repeating: $0, count: n) } ?? fit(backOffValues(plannedLoadsBySet), fallback: 0.0)
        let tops = topLoads.count
        setPrescribedSets(n)
        plannedLoadsBySet = backLoads + topLoads
        if tops > 0 {
            plannedRepsBySet = backReps + topReps
            plannedRIRsBySet = backRIRs + topRIRs
            setRolesBySet = Self.roles(backOffs: n, tops: tops)
        }
    }

    /// Role array for `targetSets` back-off rows followed by `topCount` top rows.
    static func roles(backOffs: Int, tops: Int) -> [String] {
        Array(repeating: "", count: max(0, backOffs)) + Array(repeating: topRole, count: max(0, tops))
    }
}

// MARK: - SetLog

@Model
final class SetLog {
    // Sync-safe identity (optional for migration safety)
    var id: UUID?
    var createdAt: Date?
    var updatedAt: Date?

    var setNumber: Int
    var targetReps: Int
    var targetRIR: Int
    var targetLoad: Double
    var actualReps: Int
    var actualRIR: Int
    var actualLoad: Double

    init(
        id: UUID? = UUID(),
        createdAt: Date? = Date(),
        updatedAt: Date? = Date(),

        setNumber: Int,
        targetReps: Int,
        targetRIR: Int,
        targetLoad: Double,
        actualReps: Int,
        actualRIR: Int,
        actualLoad: Double
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        self.setNumber = setNumber
        self.targetReps = targetReps
        self.targetRIR = targetRIR
        self.targetLoad = targetLoad
        self.actualReps = actualReps
        self.actualRIR = actualRIR
        self.actualLoad = actualLoad
    }
}

// MARK: - SessionStatus display helper

extension SessionStatus {
    var displayTitle: String {
        switch self {
        case .planned:     return "Planned"
        case .inProgress:  return "In Progress"
        case .completed:   return "Completed"
        }
    }
}
extension Session {
    /// Day number within the training week (1...N), derived from this session's position
    /// among the sessions of the same meso and `weekInMeso`, in date order. Works for any
    /// block shape (2-, 3-, 4-, 6-day weeks) — no assumption about days per week.
    /// nil when the session has no meso to count within.
    var positionInWeek: Int? {
        guard let meso else { return nil }
        let week = weekIndex
        let sameWeek = meso.sessions
            .filter { $0.weekIndex == week }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                if ($0.programIndex ?? 0) != ($1.programIndex ?? 0) { return ($0.programIndex ?? 0) < ($1.programIndex ?? 0) }
                return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
            }
        guard let idx = sameWeek.firstIndex(where: { $0 === self }) else { return nil }
        return idx + 1
    }

    var dayNumberInWeek: Int {
        positionInWeek ?? 1
    }

    var weekDayLabel: String {
        let week = weekIndex

        let dayText: String = {
            if let position = positionInWeek {
                return "D\(position)"
            }

            let weekdayName = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .none)
            _ = weekdayName // keep compiler quiet if you later change this logic

            let calendar = Calendar.current
            let weekday = calendar.component(.weekday, from: date)

            switch weekday {
            case 1: return "D1" // Sunday
            case 2: return "D2" // Monday
            case 3: return "D3" // Tuesday
            case 4: return "D4" // Wednesday
            case 6: return "D5" // Friday
            case 7: return "D6" // Saturday
            case 5: return "Rest"
            default: return "D?"
            }
        }()
        return "W\(week)\(dayText)"
    }
}
extension Session {
    /// True when this session falls in the deload phase of its meso.
    /// Derived from `mesoPhase` (the single source of truth for phase-band
    /// math) so the two can never contradict each other — previously this
    /// compared weekIndex to totalWeeks directly (exact-last-week-only),
    /// which disagreed with mesoPhase's 90%-of-block percentage band for
    /// every meso where the deload band spans more than one week (e.g.
    /// totalWeeks == 10: mesoPhase already says .deload at week 9, but the
    /// old isDeloadWeek required week 10 exactly). See OPEN Q6 in
    /// Tests/DomainTests/TestOpenQuestions.swift.
    var isDeloadWeek: Bool {
        mesoPhase == .deload
    }
}

extension Session {
    /// Meso phase derived from position within the block.
    /// Uses percentage bands so it works for any meso length.
    ///
    /// Wave-based blocks (DUP A/B/C) are the exception for the DELOAD phase: whether a
    /// week is a deload is a fact of its prescription (its items carry waveRaw
    /// "deload"), not of its position. The 90% band would otherwise flag a full-volume
    /// week as deload — week 9 of a 10-week block, and weeks 11-12 of a 12-week block
    /// with no scheduled deload — and MesoPerformanceAnalyzer would drop them from the
    /// verdicts.
    ///
    /// EXACT RULE (non-maintenance blocks), decided per SESSION from its items' waveRaw
    /// (compared case-insensitively; a nil or empty waveRaw casts no vote):
    ///   1. ANY item with waveRaw "deload"            -> .deload   (any, not all)
    ///   2. else ANY item with a wave letter (a/b/c)  -> position band, but .deload is
    ///                                                   capped to .late
    ///   3. else (no item has wave data)              -> position band, unchanged
    /// So a session mixing deload items with nil-wave items is .deload (the nil-wave items
    /// are ignored, not counted against it), and a session mixing a deload item with letter
    /// items is also .deload. Mixed sessions do not occur in generated blocks (the
    /// materializer stamps every item of a session with the week's wave); they can only come
    /// from hand-added items, which is why the rule is "any" rather than "all": a single
    /// deload-prescribed lift is enough to keep the week out of working-week verdicts.
    /// Maintenance blocks (isMaintenance) always use the position band.
    var mesoPhase: MesoPhase {
        guard let total = meso?.totalWeeks, total > 0 else {
            return .early
        }
        let pct = Double(weekIndex) / Double(total)
        let band: MesoPhase
        switch pct {
        case ..<0.30: band = .early
        case ..<0.70: band = .mid
        case ..<0.90: band = .late
        default:      band = .deload
        }

        guard meso?.isMaintenance != true,
              items.contains(where: { WavePrescriptionGuard.isWaveLetter($0.waveRaw) || $0.waveRaw?.lowercased() == "deload" })
        else {
            return band
        }
        if items.contains(where: { $0.waveRaw?.lowercased() == "deload" }) {
            return .deload
        }
        return band == .deload ? .late : band
    }
}

// MARK: - Which rows of an item to show or export

/// Rows of an item that history views and exports include: every planned row (index < targetSets)
/// plus any later row that has logged work. A row past targetSets with a logged set (an extra or
/// top set) is real history and must not drop out.
enum LoggedRowSelection {
    static func indices(targetSets: Int, rowCount: Int, isLogged: (Int) -> Bool) -> [Int] {
        guard rowCount > 0 else { return [] }
        let planned = max(1, targetSets)
        return (0..<rowCount).filter { $0 < planned || isLogged($0) }
    }
}
