import XCTest
import SwiftData
@testable import ElitePerformance

/// How the persisted schema maps onto the backup file, for BA1 (completeness) and BA2 (fully populated round trip).
///
/// When you add a persisted field: add it to the backup DTO, exporter and importer, and set it to a non-default value in
/// `PopulatedStoreBuilder`. BA1 fails with `Entity.field` until it is in the DTO (or listed in `exclusions` with a reason).
enum BackupSchemaMap {

    /// "Entity.field" (or "Entity.*") -> why it is deliberately not in the backup. Stale entries fail BA1.
    static let exclusions: [String: String] = [
        "PRIndex.*": "derived from completed sessions, rebuilt on import (PRRebuildService)",
        "ProgramState.*": "unused: no readers (removal is tracked separately)",
        "MesoBlock.sessions": "inverse side of Session.meso, restored from Session.mesoBlockId",
    ]

    /// "Entity.field" -> the DTO key, where it differs from the field name.
    static let renames: [String: String] = [
        "Session.status": "statusRaw",
        "Session.meso": "mesoBlockId",
        "MesoBlock.status": "statusRaw",
        "UserProfile.exemptExerciseIdsStored": "exemptExerciseIds",
        "UserProfile.maxLoadByExerciseStored": "maxLoadByExercise",
    ]

    /// Non-zero model defaults, "Entity.dtoKey" -> default. Zero, false, "", [] and nil are always defaults.
    static let nonZeroDefaults: [String: Any] = [
        "Session.statusRaw": "planned",
        "Session.readinessRaw": "normal",
        "Session.weekInMeso": 1,
        "MesoBlock.statusRaw": "draft",
        "User.unitsRaw": "lb",
        "User.coachVoiceRaw": "casual",
        "User.progressionEnabled": true,
        "UserProfile.experienceRaw": "intermediate",
        "UserProfile.primaryGoalRaw": "hypertrophy",
        "UserProfile.daysPerWeek": 4,
        "UserProfile.sessionLengthMinutes": 60,
        "UserProfile.equipmentProfileRaw": "commercial",
        "UserProfile.minLoadIncrement": 2.5,
    ]

    static func isExcluded(_ entity: String, _ field: String) -> Bool {
        exclusions["\(entity).\(field)"] != nil || exclusions["\(entity).*"] != nil
    }

    static func dtoKey(_ entity: String, _ field: String) -> String {
        renames["\(entity).\(field)"] ?? field
    }

    /// The JSON objects that carry `entity` in an export, or nil when the export has no place for the entity.
    static func objects(_ entity: String, in root: [String: Any]) -> [[String: Any]]? {
        func array(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
        func single(_ value: Any?) -> [[String: Any]] { (value as? [String: Any]).map { [$0] } ?? [] }
        switch entity {
        case "AppState": return single(root["appState"])
        case "UserProfile": return single(root["userProfile"])
        case "User": return single(root["user"])
        case "MesoBlock": return array(root["mesoBlocks"])
        case "Session": return array(root["sessions"])
        case "SessionItem": return array(root["sessions"]).flatMap { array($0["items"]) }
        case "SetLog": return array(root["sessions"]).flatMap { array($0["items"]).flatMap { array($0["logs"]) } }
        case "SessionHistory": return array(root["sessionHistory"])
        case "SessionHistoryExercise": return array(root["sessionHistory"]).flatMap { array($0["exercises"]) }
        case "ExerciseNote": return array(root["exerciseNotes"])
        case "CustomExercise": return array(root["customExercises"])
        default: return nil
        }
    }

    /// Every schema field (attributes then relationships) of every model, as ("Entity", "field").
    static func schemaFields() -> [(entity: String, field: String)] {
        AppSchema.makeSchema().entities.sorted { $0.name < $1.name }.flatMap { entity in
            (entity.attributes.map(\.name) + entity.relationships.map(\.name)).sorted().map { (entity.name, $0) }
        }
    }

    static func isDefault(_ value: Any?, entity: String, key: String) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        if let known = nonZeroDefaults["\(entity).\(key)"] {
            if let n = value as? NSNumber, let k = known as? NSNumber { return n.doubleValue == k.doubleValue }
            if let s = value as? String, let k = known as? String { return s == k }
        }
        if let n = value as? NSNumber { return n.doubleValue == 0 }
        if let s = value as? String { return s.isEmpty }
        if let a = value as? [Any] { return a.isEmpty }
        return false
    }
}

/// Sets EVERY non-excluded field of every model to a non-default value (BA2 checks that against the Schema, so a field
/// added later and missed here fails instead of silently skipping its round trip).
enum PopulatedStoreBuilder {

    private static func day(_ n: Int) -> Date { BackupTestSupport.date(1_700_000_000 + TimeInterval(n) * 86_400) }

    static func build(in ctx: ModelContext) throws {
        let user = User(units: .kg, progressionEnabled: false)
        user.createdAt = day(-30)
        user.coachVoiceRaw = "probe_voice"
        ctx.insert(user)

        ctx.insert(AppState(
            id: UUID(), createdAt: day(-20), updatedAt: day(-19),
            activeMesoStartDate: day(1), scheduledNextMesoStartDate: day(70), mesoPromptSnoozeUntil: day(71),
            mesoAnchorDate: day(2), mesoAnchorDayNumber: 3, warmupHidden: true
        ))

        let profile = UserProfile(
            id: UUID(), createdAt: day(-25), experience: .advanced, primaryGoal: .strength, daysPerWeek: 5,
            sessionLengthMinutes: 45, equipmentProfile: .homeGym, injuryFlags: [.knees, .wrists, .hips],
            minLoadIncrement: 5.0, bodyWeight: 82.5
        )
        profile.exemptExerciseIds = ["bench_press"]
        profile.maxLoadByExercise = ["back_squat": 405.0, "cable_tricep_rope_pushdown": 130.0]
        profile.birthDateOverride = day(-9_000)
        profile.loadUnit = .kg
        profile.savedIncrementLb = 5.0
        profile.savedIncrementKg = 1.25
        profile.roundOfferPending = true
        // Set the raw columns directly: the preset setter would also rewrite equipmentProfileRaw.
        profile.equipmentPresetRaw = EquipmentPreset.machinesOnly.rawValue
        profile.equipmentChecklistRaws = [GearTag.cable.rawValue, GearTag.dumbbell.rawValue]
        ctx.insert(profile)

        let archived = MesoBlock(id: UUID(), createdAt: day(-10), updatedAt: day(-9), name: "Probe Block One",
                                 startDate: day(-60), status: .archived, notes: "probe meso notes", totalWeeks: 8)
        let active = MesoBlock(id: UUID(), createdAt: day(-8), updatedAt: day(-7), name: "Probe Block Two",
                               startDate: day(1), status: .active, notes: "second block", totalWeeks: 10)
        let maintenance = MesoBlock(id: UUID(), createdAt: day(-6), updatedAt: day(-5), name: "Maintenance Block",
                                    startDate: day(-3), status: .archived, notes: nil, totalWeeks: 2, isMaintenance: true)
        [archived, active, maintenance].forEach(ctx.insert)

        let completed = session(ctx, date: day(-50), status: .completed, week: 3, label: "Probe Push", meso: archived, items: [
            fullItem(ctx, order: 1, exerciseId: "bench_press", name: "Probe Press"),
            fullItem(ctx, order: 2, exerciseId: "barbell_row", name: "Probe Row"),
        ])
        completed.readinessRaw = "fatigued"
        completed.insertedDeload = true
        completed.completedAt = day(-50)

        _ = session(ctx, date: day(2), status: .planned, week: 4, label: "Probe Pull", meso: active, items: [
            fullItem(ctx, order: 1, exerciseId: "pull_up", name: "Probe Pull-Up"),
        ])
        _ = session(ctx, date: day(-3), status: .inProgress, week: 1, label: "Probe Maintenance", meso: maintenance, items: [
            fullItem(ctx, order: 1, exerciseId: "leg_press", name: "Probe Leg Press"),
        ])

        let history = SessionHistory(
            date: day(-50), weekIndex: 3, title: "Probe Push", subtitle: "Week 3", totalExercises: 2, totalSets: 6,
            totalVolume: 4200.5, sessionId: completed.id, dayLabelSnapshot: "Probe Push", mechanicalLoad: 1234.5,
            mesoBlockId: archived.id, mesoBlockNameSnapshot: archived.name,
            exercises: [
                SessionHistoryExercise(name: "Probe Press", primaryMuscle: "chest", sets: 3, reps: 24, volume: 2400.5),
                SessionHistoryExercise(name: "Probe Row", primaryMuscle: "back", sets: 3, reps: 24, volume: 1800),
            ]
        )
        history.exercises.forEach(ctx.insert)
        ctx.insert(history)

        ctx.insert(ExerciseNote(id: UUID(), createdAt: day(-4), updatedAt: day(-3), exerciseId: "bench_press", note: "probe note"))
        ctx.insert(CustomExercise(id: "probe_custom_one", name: "Probe Custom Lift", primaryMuscleRaw: "back",
                                  isCompound: true, createdAt: day(-15), isBodyweight: true))
        try ctx.save()
    }

    private static func session(_ ctx: ModelContext, date: Date, status: SessionStatus, week: Int, label: String,
                                meso: MesoBlock, items: [SessionItem]) -> Session {
        let s = Session(
            id: UUID(), createdAt: date, updatedAt: date, date: date, status: status, readinessStars: 4,
            sessionNotes: "probe session notes", weekIndex: week, dayLabel: label, items: [], completedAt: nil,
            programIndex: 7, hkWorkoutUUID: "probe-hk-workout", hkWorkoutStart: date, hkWorkoutEnd: date.addingTimeInterval(3_600),
            hkDuration: 3_600, hkActiveCalories: 400, hkTotalCalories: 520, hkAvgHeartRate: 130, hkMaxHeartRate: 170,
            hkZone1Seconds: 60, hkZone2Seconds: 120, hkZone3Seconds: 180, hkZone4Seconds: 240, hkZone5Seconds: 300,
            hkHeartRateSeriesBPM: [110, 120, 130], hkHeartRateSeriesStepSeconds: 30,
            hkPostWorkoutHeartRateBPM: [140, 120, 100], hkPostWorkoutHeartRateStepSeconds: 15
        )
        // BA2: a non-default value (Session.init sets plannedDate = date, so move it a day).
        s.plannedDate = date.addingTimeInterval(-86_400)
        s.plannedDateExact = true
        s.meso = meso
        meso.sessions.append(s)
        ctx.insert(s)
        for item in items {
            ctx.insert(item)
            s.items.append(item)
        }
        return s
    }

    private static func fullItem(_ ctx: ModelContext, order: Int, exerciseId: String, name: String) -> SessionItem {
        let logs = (1...3).map { n -> SetLog in
            let log = SetLog(id: UUID(), createdAt: day(-n), updatedAt: day(-n + 1), setNumber: n, targetReps: 8,
                             targetRIR: 2, targetLoad: 100 + Double(n), actualReps: 7 + n, actualRIR: n, actualLoad: 99.5 + Double(n))
            ctx.insert(log)
            return log
        }
        let item = SessionItem(
            id: UUID(), createdAt: day(-12), updatedAt: day(-11), order: order, exerciseId: exerciseId,
            exerciseNameSnapshot: name, targetReps: 8, targetSets: 3, targetRIR: 2, suggestedLoad: 102.5,
            waveRaw: "b", priorityRaw: "anchor", setMin: 3, setMax: 4, repMin: 6, repMax: 10, targetRIRMin: 1, targetRIRMax: 2,
            intensifierRaw: "dropSetLast", intensifierNotes: "probe intensifier", prescriptionNotes: "probe prescription",
            plannedRepsBySet: [8, 8, 5], plannedLoadsBySet: [100, 100, 110], plannedRIRsBySet: [2, 2, 1],
            logs: logs, actualReps: [8, 7, 5], actualLoads: [100, 100, 110], actualRIRs: [2, 1, 0],
            usedRestPauseFlags: [false, true, false], restPausePatternsBySet: ["", "4+3", ""],
            dropSetPatternsBySet: ["", "", "-20%"], setFeedbackBySet: ["ok", "hard", "failed"], pumpRatingsBySet: [3, 4, 5],
            isCompleted: true, isPR: true, coachNote: "probe coach note", nextSuggestedLoad: 105,
            loadOverrideReasonRaw: "jointTenderness", prescribedSets: 4
        )
        item.planEdited = true
        item.setRolesBySet = ["", "", "top"]
        item.topRepMin = 3
        item.topRepMax = 5
        item.topRIR = 1
        return item
    }
}
