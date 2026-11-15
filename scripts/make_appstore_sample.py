#!/usr/bin/env python3
"""Invented sample backup for App Store screenshots. No personal data: every name, load and note is generated here.

    python3 scripts/make_appstore_sample.py OUT.json [--today YYYY-MM-DD]

Writes a full-backup JSON (version 1) that the app's own importer reads (Settings > Backup & Restore > Move data > Import):

  * an archived 4-week intro block (12 full-body sessions: bench press and back squat, so those two lifts earn a PR chip later),
  * an ACTIVE 12-week Push / Pull / Legs block, 6 days a week, 8 weeks (48 sessions) completed, today = week 9 day 1 (planned),
    the other 23 sessions planned with projected loads,
  * loads that climb on every lift (double progression: reps climb to the top of the range, then +step),
  * RIR on every completed set, a coach note on every completed exercise written in the engine's own phrasing
    (the strings are generated here to MIRROR CoachingEngine output; they are not produced by the engine),
  * no custom exercises (every built-in lift is mapped to its muscles), no HealthKit data.
"""
import json, sys, uuid, datetime as dt, random

NS = uuid.UUID("5a1e0000-0000-4000-8000-000000000001")
def uid(*parts): return str(uuid.uuid5(NS, "/".join(str(p) for p in parts))).upper()
def iso(d): return d.strftime("%Y-%m-%dT%H:%M:%SZ")

# id, name, kind (main/sec/iso), sets, repMin, repMax, week-1 load (lb), step (lb)
PUSH_A = [("bench_press","Bench Press","main",3,6,8,155,5), ("incline_dumbbell_press","Incline Dumbbell Press","sec",3,8,10,55,5),
          ("seated_cable_fly","Seated Cable Fly","iso",3,10,12,30,2.5), ("dumbbell_lateral_raise","Dumbbell Lateral Raise","iso",4,12,15,15,2.5),
          ("cable_tricep_rope_pushdown","Cable Tricep Rope Pushdown","iso",3,10,12,45,5), ("overhead_rope_tricep_extension","Overhead Rope Tricep Extension","iso",3,10,12,35,5)]
PULL_A = [("wide_grip_pulldown","Wide Grip Pulldown","main",4,8,10,120,5), ("barbell_row","Barbell Row","main",3,6,8,115,5),
          ("seated_cable_row","Seated Cable Row","sec",3,8,10,110,5), ("cable_face_pull","Cable Face Pull","iso",3,12,15,40,2.5),
          ("barbell_curl","Barbell Curl","iso",3,8,10,55,5), ("hammer_curl","Hammer Curl","iso",3,10,12,25,2.5)]
LEGS_A = [("barbell_back_squat","Barbell Back Squat","main",3,6,8,185,10), ("romanian_deadlift","Romanian Deadlift","main",3,6,8,155,10),
          ("leg_press","Leg Press","sec",3,10,12,270,10), ("lying_leg_curl","Lying Leg Curl","iso",3,10,12,70,5),
          ("seated_calf_raise","Seated Calf Raise","iso",4,12,15,90,5), ("cable_rope_crunch","Cable Rope Crunch","iso",3,12,15,70,5)]
PUSH_B = [("barbell_overhead_press","Barbell Overhead Press","main",3,6,8,95,5), ("machine_chest_press","Machine Chest Press","sec",3,8,10,130,10),
          ("pec_deck","Pec Deck","iso",3,10,12,100,5), ("single_arm_cable_lateral_raise","Single-Arm Cable Lateral Raise","iso",4,12,15,10,2.5),
          ("ez_bar_skull_crusher","EZ Bar Skull Crusher","iso",3,8,10,55,5), ("dumbbell_overhead_tricep_extension","Dumbbell Overhead Tricep Extension","iso",3,10,12,40,5)]
PULL_B = [("chest_supported_incline_dumbbell_row","Chest-Supported Incline DB Row","main",3,8,10,55,5), ("pulldown_normal_grip","Pulldown (Normal Grip)","sec",4,8,10,115,5),
          ("dumbbell_row_single_arm","Dumbbell Row (Single Arm)","sec",3,8,10,65,5), ("incline_rear_delt_fly","Incline Rear Delt Fly","iso",3,12,15,15,2.5),
          ("incline_dumbbell_curl","Incline Dumbbell Curl","iso",3,10,12,20,2.5), ("cable_rope_hammer_curl","Cable Rope Hammer Curl","iso",3,10,12,45,5)]
LEGS_B = [("hack_squat","Hack Squat","main",3,6,8,180,10), ("machine_hip_thrust","Machine Hip Thrust","sec",3,8,10,180,10),
          ("leg_extension","Leg Extension","iso",3,10,12,100,5), ("seated_leg_curl","Seated Leg Curl","iso",3,10,12,90,5),
          ("leg_press_calf_raise","Leg Press Calf Raise","iso",4,12,15,160,10), ("decline_cable_crunch","Decline Cable Crunch","iso",3,12,15,80,5)]
DAYS = [("Push A", PUSH_A), ("Pull A", PULL_A), ("Legs A", LEGS_A), ("Push B", PUSH_B), ("Pull B", PULL_B), ("Legs B", LEGS_B)]

# intro block: lifts also in the PPL block that start LIGHTER here (the PPL block beats them: a PR chip), plus two lifts that only exist here
INTRO = [("Full Body A", [("bench_press","Bench Press","main",3,6,8,135,5), ("barbell_back_squat","Barbell Back Squat","main",3,6,8,165,10), ("machine_row","Machine Row","sec",3,8,10,100,5)]),
         ("Full Body B", [("bench_press","Bench Press","main",3,6,8,140,5), ("barbell_back_squat","Barbell Back Squat","main",3,6,8,170,10), ("dumbbell_shoulder_press","Dumbbell Shoulder Press","sec",3,8,10,40,5)]),
         ("Full Body C", [("bench_press","Bench Press","main",3,6,8,145,5), ("barbell_back_squat","Barbell Back Squat","main",3,6,8,175,10), ("machine_row","Machine Row","sec",3,8,10,105,5)])]

def load_at(L0, step, repMin, repMax, week):
    """Double progression: reps climb repMin..repMax over the cycle, then the load steps up. Returns (load, topReps)."""
    cycle = max(2, min(3, repMax - repMin + 1))
    n = week // cycle
    pos = week % cycle
    reps = min(repMax, repMin + pos * max(1, (repMax - repMin) // (cycle - 1)))
    return L0 + n * step, reps

def fmt(x): return str(int(x)) if float(x).is_integer() else f"{x:.1f}"

def item(session_id, order, ex, week, completed, rng, force_note=None):
    eid, name, kind, sets, rmin, rmax, L0, step = ex
    load, reps = load_at(L0, step, rmin, rmax, week)
    nxt_load, _ = load_at(L0, step, rmin, rmax, week + 1)
    goal = rmax * sets
    top_hit = reps >= rmax                       # the week the cycle reaches the top of the range
    actual_reps = [reps] * sets
    if completed and not top_hit and sets > 1: actual_reps[-1] = max(rmin, reps - 1)
    if completed and top_hit and kind == "main" and rng.random() < 0.5: actual_reps[-1] = rmax - 1   # "23/24"
    if force_note == "23of24": actual_reps = [rmax] * (sets - 1) + [rmax - 1]
    total = sum(actual_reps)
    rirs = [2] * sets if not completed else [rng.choice([1, 2, 2, 2, 3]) for _ in range(sets)]
    if completed and kind != "main": rirs = [2] * sets
    increase = completed and total >= goal - 1 and top_hit
    # coach note, in the engine's phrasing
    note = None
    if completed:
        if kind in ("main", "sec"):
            note = (f"{total}/{goal} reps — increase earned. Next session: {fmt(nxt_load)}. Pump was good — this lift is responding well." if increase
                    else f"{total}/{goal} — hold, climb reps.")
        else:
            note = (f"Every working set hit the top of your range at the target difficulty — increase earned. Next session: {fmt(nxt_load)}. Pump was good — this lift is responding well." if increase
                    else f"On target and in range — hold {fmt(load)}. Hit the top of your range ({rmax}) on all working sets to earn the increase; climb your reps next session.")
    d = {
        "id": uid("item", session_id, order), "createdAt": "2026-09-19T12:00:00Z", "updatedAt": "2026-09-19T12:00:00Z",
        "exerciseId": eid, "exerciseNameSnapshot": name, "order": order,
        "targetReps": rmax, "targetSets": sets, "targetRIR": 2, "suggestedLoad": load,
        "setMin": sets, "setMax": sets, "repMin": rmin, "repMax": rmax, "targetRIRMin": 2, "targetRIRMax": 2,
        "priorityRaw": "anchor" if kind == "main" else "standard", "intensifierRaw": "none",
        "plannedRepsBySet": [rmax] * sets, "plannedLoadsBySet": [load] * sets, "plannedRIRsBySet": [2] * sets,
        "actualReps": actual_reps if completed else [0] * sets, "actualLoads": [load] * sets if completed else [0] * sets,
        "actualRIRs": rirs if completed else [-1] * sets,
        "usedRestPauseFlags": [False] * sets, "restPausePatternsBySet": [""] * sets, "dropSetPatternsBySet": [""] * sets,
        "setFeedbackBySet": [""] * sets, "pumpRatingsBySet": ([3] * sets if completed else [0] * sets),
        "isCompleted": bool(completed), "isPR": False, "planEdited": False, "logs": [],
    }
    if note: d["coachNote"] = note
    return d, load, actual_reps

def main():
    out = sys.argv[1]
    today = dt.date.today()
    if "--today" in sys.argv: today = dt.date.fromisoformat(sys.argv[sys.argv.index("--today") + 1])
    rng = random.Random(20261115)
    day0 = today - dt.timedelta(days=56)           # 8 full weeks before today; today is week 9 day 1
    meso_id, intro_id = uid("meso", "ppl"), uid("meso", "intro")
    def midnight(d): return dt.datetime(d.year, d.month, d.day, 4 if d < dt.date(2026, 11, 1) else 5, 0, 0)
    def noon(d): return dt.datetime(d.year, d.month, d.day, 17, 30, 0)
    sessions, history = [], []
    pr_marks = {}

    def add_session(sid, d, label, exs, week, prog_idx, meso, completed, force=None):
        items = []
        for i, ex in enumerate(exs, 1):
            it, _, _ = item(sid, i, ex, week, completed, rng, force_note=(force if (force and ex[0] == "bench_press") else None))
            items.append(it)
        s = {"id": sid, "createdAt": iso(midnight(day0) - dt.timedelta(days=1)), "updatedAt": iso(noon(d) if completed else midnight(d)),
             "date": iso(noon(d) if completed else midnight(d)), "plannedDate": iso(midnight(d)),
             "statusRaw": "completed" if completed else "planned", "weekInMeso": week, "dayLabel": label, "mesoBlockId": meso, "programIndex": prog_idx,
             "readinessRaw": "normal", "readinessStars": 0, "items": items,
             "hkActiveCalories": 0, "hkAvgHeartRate": 0, "hkDuration": 0, "hkHeartRateSeriesBPM": [], "hkHeartRateSeriesStepSeconds": 0,
             "hkMaxHeartRate": 0, "hkPostWorkoutHeartRateBPM": [], "hkPostWorkoutHeartRateStepSeconds": 0, "hkTotalCalories": 0,
             "hkZone1Seconds": 0, "hkZone2Seconds": 0, "hkZone3Seconds": 0, "hkZone4Seconds": 0, "hkZone5Seconds": 0}
        if completed: s["completedAt"] = iso(noon(d))
        sessions.append(s)
        if completed:
            exs_h, vol, nsets = [], 0, 0
            for k, (ex, it) in enumerate(zip(exs, items), 1):
                v = sum(r * l for r, l in zip(it["actualReps"], it["actualLoads"])); vol += v; nsets += len(it["actualReps"])
                muscle = {"main": "x"}.get(ex[2], "x")
                exs_h.append({"name": ex[1], "order": k, "primaryMuscle": MUSCLE.get(ex[0], "chest").capitalize(), "reps": sum(it["actualReps"]), "sets": len(it["actualReps"]), "volume": v})
            history.append({"date": iso(noon(d)), "title": d.strftime("%b %-d, %Y"), "subtitle": f"W{week}D{((prog_idx - 1) % 6) + 1}" if meso == meso_id else label,
                            "weekIndex": week, "totalExercises": len(exs), "totalSets": nsets, "totalVolume": vol, "mechanicalLoad": int(vol * 0.6), "exercises": exs_h})

    # intro block: 4 weeks, Mon/Wed/Fri, ending the week before the PPL block starts
    intro_start = day0 - dt.timedelta(days=35)
    n = 0
    for w in range(4):
        for k, off in enumerate((0, 2, 4)):
            n += 1
            d = intro_start + dt.timedelta(days=7 * w + off)
            label, exs = INTRO[k]
            add_session(uid("sess", "intro", n), d, label, exs, w + 1, n, intro_id, True)

    # PPL block
    prog = 0
    for w in range(1, 13):
        for k, (label, exs) in enumerate(DAYS):
            prog += 1
            d = day0 + dt.timedelta(days=7 * (w - 1) + k)
            completed = d < today
            force = "23of24" if (completed and w == 8 and label == "Push A") else None
            add_session(uid("sess", "ppl", prog), d, label, exs, w, prog, meso_id, completed, force=force)

    # PR flags on the newest bench / squat items
    for s in reversed(sessions):
        for it in s["items"]:
            if it["exerciseId"] in ("bench_press", "barbell_back_squat") and s["statusRaw"] == "completed" and it["exerciseId"] not in pr_marks:
                it["isPR"] = True; pr_marks[it["exerciseId"]] = s["id"]

    meso = [
        {"id": intro_id, "name": "4-Week Intro Block", "notes": "", "isMaintenance": False, "statusRaw": "archived", "totalWeeks": 4,
         "startDate": iso(midnight(intro_start)), "createdAt": iso(midnight(intro_start)), "updatedAt": iso(midnight(day0))},
        {"id": meso_id, "name": "12-Week Push / Pull / Legs", "notes": "", "isMaintenance": False, "statusRaw": "active", "totalWeeks": 12,
         "startDate": iso(midnight(day0)), "createdAt": iso(midnight(day0)), "updatedAt": iso(midnight(today))},
    ]
    profile = {"profileId": uid("profile"), "createdAt": iso(midnight(intro_start)), "bodyWeight": 185, "daysPerWeek": 6,
               "equipmentPresetRaw": "fullGym", "equipmentProfileRaw": "commercial", "experienceRaw": "intermediate",
               "primaryGoalRaw": "hypertrophy", "sessionLengthMinutes": 75, "minLoadIncrement": 5,
               "exemptExerciseIds": [], "injuryFlagRaws": [], "maxLoadByExercise": {}}
    app_state = {"id": uid("appstate"), "createdAt": iso(midnight(intro_start)), "updatedAt": iso(midnight(today)),
                 "activeMesoStartDate": iso(midnight(day0)), "mesoAnchorDate": iso(midnight(day0)), "mesoAnchorDayNumber": 1, "warmupHidden": True}
    sessions.sort(key=lambda s: s["date"])
    backup = {"version": 1, "exportedAt": iso(dt.datetime.utcnow()), "appState": app_state, "userProfile": profile, "mesoBlocks": meso,
              "sessions": sessions, "sessionHistory": history, "customExercises": [], "exerciseNotes": []}
    json.dump(backup, open(out, "w"), indent=1)
    done = sum(1 for s in sessions if s["statusRaw"] == "completed")
    print(f"wrote {out}: {len(sessions)} sessions ({done} completed), {len(history)} history rows, today={today}, ppl start={day0}")

MUSCLE = {"bench_press":"chest","incline_dumbbell_press":"chest","seated_cable_fly":"chest","machine_chest_press":"chest","pec_deck":"chest",
          "cable_tricep_rope_pushdown":"triceps","overhead_rope_tricep_extension":"triceps","ez_bar_skull_crusher":"triceps","dumbbell_overhead_tricep_extension":"triceps",
          "dumbbell_lateral_raise":"shoulders","single_arm_cable_lateral_raise":"shoulders","barbell_overhead_press":"shoulders","dumbbell_shoulder_press":"shoulders",
          "cable_face_pull":"shoulders","incline_rear_delt_fly":"shoulders","wide_grip_pulldown":"back","barbell_row":"back","seated_cable_row":"back",
          "chest_supported_incline_dumbbell_row":"back","pulldown_normal_grip":"back","dumbbell_row_single_arm":"back","machine_row":"back",
          "barbell_curl":"biceps","hammer_curl":"biceps","incline_dumbbell_curl":"biceps","cable_rope_hammer_curl":"biceps",
          "barbell_back_squat":"quads","leg_press":"quads","hack_squat":"quads","leg_extension":"quads","romanian_deadlift":"hamstrings",
          "lying_leg_curl":"hamstrings","seated_leg_curl":"hamstrings","machine_hip_thrust":"glutes","seated_calf_raise":"calves",
          "leg_press_calf_raise":"calves","cable_rope_crunch":"core","decline_cable_crunch":"core"}

if __name__ == "__main__":
    main()
