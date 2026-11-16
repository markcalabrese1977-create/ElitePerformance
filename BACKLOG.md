# Backlog

One line per item; dates are 2026. Open items first; shipped items are under "Done (Oct 2026)" with their commits (original wording kept).

## Rules

- New persisted field: add it to the backup DTO, exporter and importer, and set it to a non-default value in the BA2 builder (`PopulatedStoreBuilder`). BA1 fails with `Entity.field` otherwise. A field that must not be backed up goes in `BackupSchemaMap.exclusions` with a one-line reason.
- New UserDefaults / App Group key: register it in `PersistedKeyRegistry` (Domain/Sync) with a disposition; BA3 fails on any key the registry does not cover. Prefer a model field.
- New persisted model: add it to `AppSchema.models`; BA1 and the app container both read that one list.

## Open

- (Done) Dead code removed: `SessionRecapView`, `ExerciseRecapRow` (Features/Session/SessionRecapView.swift keeps `LoadOverridePromptRow` and the SessionItem helpers the live screens use) and the Home `ExerciseHistoryView`. The live recap sheet (`SessionRecapSheet` in SessionView.swift) now takes its per-exercise top e1RM from `AnalyticsEngine.ItemStats` (working sets only, warm-ups no longer count). Open: a PR chip on the live recap (from `AnalyticsEngine.recordExerciseIds`) if wanted.
- PR candidates to verify (analytics): `PersonalRecords.suspects` lists a record more than 1.25x the lifter's next best session for the lift (typos, wrong-unit loads). Nothing shows it yet: surface it (a "verify this record" row on the lift's history, with a fix-or-confirm action) when the screens move to the new definitions. On the Nov 12 backup it flags 4: Smith Machine Hip Thrust 351x10 (x1.27, a maintenance-block set), DB Skull Crushers 10x10 (x2.00), DB Skull Crusher [Rehab] (x1.50), Decline Cable Crunch 50x12 (x1.33).
- Analytics next: switch the screens (History summary, exercise history sheet, Home history, Analytics tab, meso summary) to the single definitions in Domain/Analytics (records include maintenance; seeds, fatigue baselines and meso comparisons exclude it); FatigueMonitor performance signals are watch-only until tuned on more than one lifter's history (see its header).
- OBSOLETE (Nov 14): "Install current HEAD after the Fri Oct 30 Push A backup checks out"; the commits it names are many rounds old. Installs are done by hand on request.
- HealthKitAuthorizationCoordinator: add `nonisolated deinit {}` defensively (same shape
  as SessionScreenViewModel; tests pass today). Low priority.
- Top set follow-ups (feat/top-set, shipped): (a) planEdited is one flag, so a manual load edit freezes carry-forward for both roles; split per role if it bites; (b) Change prescription only offers a top count of 1 (the model allows up to 3); (c) MesoPerformanceAnalyzer, PR and recap code were not reviewed for top rows (they count every row; verify the first/last-load comparisons); (d) Add Set on an item without a top set still appends a plain row; adding a top set is done from Change prescription.
- Coach-message honesty (mostly done): the stage-gate wording is now "N of M planned sets logged." (d491a8c) and landing / blocked-write wording shipped (0cd2455). Remaining: the unresolved-target fallback for a non-exempt reduce still says "next session"; a completed session with a skipped set reads "N of M planned sets logged." with no word about the skip.
- Deload in place (fallback, works today; Insert deload week has since shipped, see Done): log the week light with load-override reason Deliberate Deload. Follow-ups: (a) verify a deload-flagged source never seeds an EMPTY same-letter target (new-lift first exposure) with light loads; (b) the "Last A/B/C" caption and the meso summary verdicts must skip items flagged Deliberate Deload, as they already skip deload-wave items.
- Earned volume (v5.2): Pull A hammer curl 4th set if earned on Oct 18 (>20 reps at 102 or heavier vs Sept 27); parameterized one-shot repair, weeks 5-12; later decline the 4th set, then one open slot chosen at rotation 3. (Status not re-checked in the Oct 26 sweep.)
- Rotation 4 (weeks 10-12): optional RIR 1 on upper compounds and hack squat/hip thrust A/B weeks; decide ~Nov 20.
- Swap/add service (partly done: the Today "Apply to future <weekday>" propagation is retired and the replace service sizes arrays and seeds from completed history, see Done). Remaining, not re-verified: Today "Apply to future <weekday>" is unscoped and zeroes loads (guard or scope it); arrays sized to sets; rep range and wave on adds; (lastKnownLoad no longer reads future plans: d8c0967); custom names from the table.
- Empty-target seeding ignores the incomplete-evidence guard and can bump (DB row:
  60 x 20, 20 of 3 sets -> 65 seeded into an empty target). When evidence is incomplete,
  seed the last load without a bump.
- Pushdown follows the lifter's last load (parked; user raises by hand).
- Import hardening (partly done). Done: pre-restore safety copy and typed-REPLACE staleness guard (b862c7c, 0a6aa84), failure recovery (1af1b46), interrupted-import marker (a5aa6ba), custom-exercise mirror (96ba644), history order, build identity in the export and on the restore sheet (f3f0019). Open: a true atomic import (see the wipe-save-then-insert item below); tolerant dedup (`Dictionary(uniqueKeysWithValues:)` at CustomExerciseDedupMigration.swift:15, SessionItemEditService.swift:1519, SessionItemEditService+NextMeso.swift:272, :504 not re-verified for duplicate keys).
- Test infrastructure: J4 flake (still the one flaky entry in Tests/known_failures.txt; A7 and D12 left it in ee97f03); B10/F6/M7 no longer abort the host (48e6bcb); synchronized test folder (no hand-edited pbxproj); keep Tests/known_failures.txt set-based. Never run two gates concurrently (shared simulator / memory pressure kills the test host without a crash report); before a full-suite or fixture run, check `ps -axo pid,command | grep xcodebuild` and `xcrun simctl list devices booted`, and wait if one is running. New test files in Tests/DomainTests need a hand-added pbxproj entry (that folder is an explicit group, not synchronized), with Xcode quit.
- OBSOLETE (Nov 14): device-build tooling note (run xcodebuild as a tracked/background task). Process note, not a code item.
- Universality guard (C5): never extend the allowlist except for unregistered one-shot repairs; add new patterns when new user-specific data appears. The guard itself shipped (0eef263); this is the standing rule.
- Optional: give the two hand-added week-1 lifts their wave letters; slotOverrides per-day key; isCleanSession vs deliberateDeload; onChange deprecations.
- Hack squat re-entry after Dr. Alexander clears (sled + 135 at W1 stance pain-free -> fresh anchors per letter); cable hip adduction returns only after hips clear.
- E1RM RIR model (low priority): HistorySeedLoad credits RIR additively on input (reps+RIR); load(for:reps:targetRIR:) applies 2.5%/RIR on output. Within ~1% at RIR<=2, ~2% at RIR 4 / low reps. Unify into one E1RMCalculator RIR function used by both; run a C3b-style before/after seed comparison.
- Replace: optional prescription override (e.g. RIR) applied by the service without setting planEdited (planEdited blocks carry-forward writes into the item).
- DONE (e6c28a0 every rounding site through UnitAwareRounding; Domain/Logic/LoadUnit.swift; KgRoundingMatrixTests, UnitSwitchTests): kg support.
- Settings (low priority): 'Use Health date of birth' row next to the Birthdate field, calling requestAuthorizationIfNeeded(), so users grant it in context instead of after a workout. Helper text: Health's date of birth is used when available, otherwise the Birthdate above (iOS can't report whether access was granted). Footer stays as is.
- HR zones: when age is available, HRR uses 220 - age as max HR even if observed max exists. Prefer observed max (with a sanity floor); 220 - age only as fallback.
- Set band (low priority): stepper/prescription widen setMin/setMax but never narrow, so a +1/-1 round
  trip leaves a wider label ("2-4 sets" with 3 working). Narrow back toward the original
  template band (store it, or recompute from the wave prescription), never below it.
- Rest today (low priority): when the refusal is a collision with the next week's first session, say
  "No open day this week. Skip a session instead."
- Custom "Landmine Press" (shoulders, compound; 6 logged items in the Oct 30 backup) duplicates the new built-in
  landmine_press. The one-shot dedup migration already ran on existing installs, so the two coexist. Decide: merge the
  custom into the built-in (move history, canonical id) or rename. ExerciseTraitsCoverageTests tracks it as a known
  collision. Low priority.
- 2-Day Full Body template is ~99 min untrimmed; trim its content (pre-launch).
- Program selection ignores equipment/injury flags (6-day dumbbell-only user gets machines/cables). Part of Phase 3.1 onboarding; pre-launch.
- Notes UX (pre-launch): two note types look alike. Label them in the UI: "Exercise
  note — applies everywhere" (ExerciseNoteSheet) vs "Session cue — this session"
  (executionNoteLine, editable via Change for remaining sessions). From the exercise
  card, offer a link to edit the session cue for remaining sessions.
- Custom "Concentration Curl" duplicates the built-in concentration_curl (found by the
  O1 collision check). Decide: merge the custom into the built-in (move history,
  canonical id) via the existing dedup path, or rename. Low priority.
- In-app guide: when the Claude guide doc changes, re-export and replace Resources/Guide.

## Release check (standing): upgrade test

Before every upload, run `scripts/upgrade_test.sh` from the candidate commit. It checks out the LAST UPLOADED build in a worktree, seeds the
app's real default store with that build's own code on a throwaway simulator, launches it as a device would, installs the candidate OVER it
(no uninstall) and launches again. PASS needs: the same store URL opened, identical counts, every registered backfill logged, no blocking
screen, no crash report, and exactly one automatic backup for the launch. It also prints pre-backfill markers found in that backup
(history entries all at order 0, planned sessions without plannedDate, padded RIR 0s), which proves the upgrade backup is the data as it
was BEFORE the backfills.

- `scripts/upgrade_test.sh --seed onboarding` : one template program (as onboarding applies it), shifted so its first two sessions are the only ones in the past and both are completed (nothing missed), no customs, no import.
- `scripts/upgrade_test.sh --seed fixture:<backup.json>` : a real backup imported through the released build's importer.
- `--released <commit>` : the build to upgrade from. The default is `3faaf49`, the uploaded build: 1.2.2 (4), archived from `3faaf49` (tag `v1.2.2-b4`; the
  device's About row shows `3faaf49`). It was first mis-pointed at `c9b4792`, the commit before the docs-only screenshot commit; the two differ only by `docs/screenshots/guide/`.
  The previous default was `26006d5` (1.2.1 (4), last uploaded as of Jul 7 2026; the 1.2.2 (1) upload of Oct 17 failed with a 403 and was never distributed).
  After the next upload, set the default in the script to that build's commit (tag it when you archive).
- The script never touches a physical device; it deletes its simulator and worktree unless `--keep` is given.
- Runs: 1.2.1 (4) -> ec64bd5 with the Nov 14 15:12 fixture (294 sessions) and with onboarding (40 sessions, 2 completed): both PASS.

## Done (Oct 2026)

- DONE (feat/top-set 70c0f8a, cdb1c76, d7e1706, 8cc18a5, 6f697aa; A1-A4 d491a8c, cdbb1a3, aa0ca81, 440aa87; B7 88a753c; B8 46039ee): Top set + back-off (priority, before TestFlight): set roles (top/back-off) with own
  load, rep range, RIR; carry-forward per role. Repro (Oct 24, bench B): logging the
  added 315 x 5 top set first -> "Set 1 came in short of the rep target" (judged
  against back-off 6-8 @ 290); after one back-off -> "2 sets in. Finish the session."
  with 2 back-offs left; added row shows "goal 8 @ 0 RIR" (0 = default sentinel shown
  literally). Messages must judge each set by its role and actual index, and "finish"
  only when all planned sets are logged.
- DONE (88143fd, 70467b8, 3271a7f, 99916cd; choose week + remove inserted deload fc5aa10, 9b01b9d; real-backup test 04e8316; deload loads solve at the top of the rep range 6253404): Insert deload week (target: ready before rotation 3, Fri Nov 6; needed because a v5.3 tripwire deload must happen within days of the trigger). A USER-INITIATED action with a dry-run preview and a confirm step, never a startup migration. Start at the next Friday (week boundary). Shift every PLANNED session on or after that date by +7 days; completed sessions never move. Insert 6 deload sessions (one per day label) with that day's current roster, waveRaw "deload", ~half the sets, RIR 3-4, loads ~60% of each lift's most recent completed same-day load. Renumber weekInMeso and programIndex; totalWeeks +1 (update a week count in the block name if present). Verify before save: no completed session moved; every same-letter chain target is unchanged (week numbers shift, targets don't); nothing targets a deload item and deload items write nothing; no date collisions, no Thursdays; backup round-trip clean. Snapshot-and-restore rollback, same pattern as the 12-week conversion.
- DONE (1b430aa plan, ceb9c3e apply + verify + restore, bac435e UI, db65f56 peak seed, f8c0144 + 9f6935a seed rounding, 77f2f14 test, 440aa87 refusal copy; prescribed set count 88a753c + backfill 46039ee so an in-session Add Set is not cloned): Start next meso from this one: clone roster, wave prescriptions, notes and length onto new dates; anchored loads, exempt lifts seed from the last lifted load (not peak e1RM). Needed by Dec 1; current meso ends Dec 16.
- DONE (replace service adbb4ed, UI 9cda73a which retires swap propagation, 6672584 wave-block guard; completed-only history seed 44e7e60, 136b078, ccfc7b5; no-seed text 75d71a1): replace exercise in remaining sessions.
- DONE (service 3f926e6, UI 4a91267, label and freezing fixes a8d16a3): change prescription for remaining sessions (sets, reps, RIR), steppers no longer freeze carry-forward.
- DONE (74597a4): change the session note for remaining sessions.
- DONE (9ebe367): Rest today goes through SessionItemEditService.
- DONE (fe51f10): HealthKit workout sync never waits on authorization; the permission request is made once, at a safe moment, by HealthKitAuthorizationCoordinator.
- DONE (865cce8, fcd8ef1, 1123df3, a5c5f71, 0eef263, f1f1a31): universality cleanup (no user-specific assumptions, one-shot repairs unregistered then removed) and the UniversalityGuardTests scan.
- DONE (91308c8): text audit, neutral app-supplied wording.
- DONE (a5b3b74 nonisolated deinit for SessionScreenViewModel, 48e6bcb baseline: B10/F6/M7 pass and left Tests/known_failures.txt, c3ca2d0 parking workaround removed): deinit fix.
- DONE (46039ee): PrescribedSetsBackfill, the tenth registered StartupBackfill.
- Replaced, kept for history: "Next install after Oct 21: main branch; verify the launch log equals today's minus the three unregistered migrations (StartupBackfills refactor)." (superseded by the Install item above)
- Replaced, kept for history: "Deinit fix (feat/nonisolated-deinit): own install after Oct 21; then remove B10/F6/M7 from Tests/known_failures.txt and delete the parking workaround." (done, see Done)
- Replaced, kept for history: "Coach-message honesty: non-exempt reduce text says \"next session\"; \"N sets in. Finish the session.\" appears on completed sessions with incomplete evidence; blocked-write wording." (see Open)
- Fixture-dependent tests (CarryForwardAudit, DUPMesoLengthConversion fixture, LastSameLetter fixture, InsertDeloadRealBackup...): 4 fail against the Oct 30 backup because they pin old data. Make them backup-agnostic (assert invariants, not specific dates/loads) or retire them; then run them with the latest backup in the gate.
- Store the weekday pattern on UserProfile so Change Program prefills it (today it falls back to the default pattern for the day count).

## Done (Nov 2026)

- DONE (d90c70d AppStoreOpener: one way to open the store, a failure changes nothing; a5aa6ba interrupted-import marker; b862c7c, 0a6aa84 restore confirmation, staleness guard, pre-import snapshots and undo; 1af1b46 failure recovery; ca91e3d, 59f4057 missing-data sentinel and its launch logging): launch has one store-selection path (replaces "Launch has five store-selection paths") and import is snapshot-first with recovery.
- DONE (23e8876 verified automatic backups to iCloud Documents/Backups with local fallback, 5223234 one log line per attempt, f9588b1 reason beforeMesoSeed: a verified backup before next-meso, new-program and maintenance seeding, blocked with Back up now / typed CONTINUE on failure): automatic backups.
- DONE (f3f0019): backups carry build identity (appVersion, build, gitCommit, gitBranch, schemaVersion); the restore sheet shows "Backup from <version> (<build>) · <commit>" and warns on a newer backup format.
- DONE (9d0de36, 28b60f5 planEdited on every lifter edit including the set-count stepper; cf7609b propagation only to the same weekday + dayLabel + wave letter + meso, edited items skipped, always confirmed; 5eab7e6 Auto/Auto+ clear planEdited; 5fb36ab Auto/Auto+ confirm when edited; b4fa1d8 day rename across the whole meso, confirmed, history titles follow; 702da06 apply-plan-to-block scoped and confirmed): plan editing safety. Replaces the open "Today 'Apply to future <weekday>' is unscoped" concern.
- DONE (9c55ce8 compound RIR starts unset, 0-4 chips, unset = -1; b24e99d total-rep progression for compounds; a9719d9 RIRUnsetBackfill; 86f0681 every actualRIRs access through RIREntry; 11009b6, 6572eba custom exercises can be compound, with the suggester tie rule): RIR entry and progression.
- DONE (d7b8a77 missed-source seeding and backfill, b59c2b4 12-week fallback, 8340976 all seeding and anchoring e1RMs reps-only): zero-load targets are seeded from history; plan-prefilled RIRs no longer inflate starting loads.
- DONE (d8c0967): lastKnownLoad reads only completed sessions dated before the current one, matched on the canonical exerciseId.
- DONE (564e941, ac08310, bb7915f): records use the 12-rep rule; PRIndexRuleBackfill is versioned.
- DONE (ee97f03): A7 and D12 removed from Tests/known_failures.txt.

## Open (found Nov 14)

- Reset to coached plan via CoachingEngine (Cut 4): the Program day's Auto and Auto+ buttons were removed (Auto+ took loads from the e1RM projection and bypassed the coach; both wrote the bottom of the rep band). A replacement should rebuild a day's plan through `CoachingEngine` / carry-forward and keep the top-of-band goal.

- Maintenance and deload carry-forward use a flat 60% factor (PlanMemoryEngine.swift:22, applied at :159-163); derive it from RIR when deload RIR targets are reliable.
- Maintenance is still detected by name in places: ProgramDayDetailView.swift:90, :352, :432, :659, SessionView.swift:1829, MaintenanceProgramSeeder.swift:533, :566, DUPWaveModels.swift:29. `MesoBlock.isMaintenance` exists; switch these to it.
- Bodyweight "BW" display: StartNextMesoFlow, InsertDeloadFlow, ExerciseSessionDetailView, HistoryView, ExerciseHistorySheet and the session row handle it; the other screens are not audited.
- Coaching Cut 6 (coaching-style tuning; `consecutiveCleanCount` is deliberately unused, CoachingEngine.swift:491) is not built. There is no Cut 4 or Cut 5 in the code.
- `PreviewOverrides.slotOverrides` is keyed by exerciseId; `slotKeyed` exists beside it. Program start (onboarding, HomeView) is the only user; next-meso does not use it.
- Existing custom exercises whose stored `isCompound` is false by default (never toggled) are not re-inferred; only nil is decided by the backfill.

## Muscle volume: custom exercises are credited by their coarse group only (resolved)
Resolved by the custom fine-muscle mapping (CustomExercise.fineMuscleRaw + shares, mapping editor, "Unmapped exercises" row).
Unmapped customs are now counted in no muscle's total instead of being credited by coarse group.

## Destructive controls: audit (confirmations added) and what is left
Fixed on fix/mapping-and-delete-confirm: Program tab item delete (trash button and swipe) now asks "Remove <name> from <day, date>?"
and offers an 8 second Undo that restores the slot (order, wave letter, prescription, edited loads); all five Settings repair
actions (Reset mesocycle, Repair exercise data, Remove unrecognized exercises, Sync meso start date, Repair maintenance
loads) confirm with what they scan/change; deleting a custom exercise (picker swipe) confirms.
Already confirmed before: Program plan session delete (ProgramPlanView), MesoSummary and SessionView dialogs.
Also confirmed now: clearing an exercise note, "Reset to default" in exercise customization, "Reset all to defaults" for muscle ranges.
Deliberately left one tap: "Remove deload" (InsertDeloadFlow, has its own review screen first) and the onboarding trash buttons (pre-data).
Undo only covers the Program tab item delete; the Settings repairs have no undo (confirmation only).

## Re-adding an exercise to a wave-based session creates a blank, letterless item
After removing and re-adding an exercise on a wave session (A/B/C), the new item has no wave letter or prescription, which
breaks carry-forward. Offer to restore the slot's prescription from the same-letter template / previous exposure when adding
an exercise to a wave-based session (Undo covers the accidental-delete case only).

## MesoPerformanceAnalyzer verdict is first-vs-last session
The Meso Summary verdict (and the % on each By-exercise row) compares a lift's e1RM in the block's FIRST session with its LAST
(+-3%). Replace it with a trend over all of the block's sessions before it gates starting loads (roadmap 4.4): one noisy
opening or closing session currently decides the chip.

## PRIndex has no live reader
PRIndex is stored and rebuilt (import, PRIndexRuleBackfill) but nothing live reads it (PRService.currentPR has no caller). Delete it, or make it the canonical record source.

## full_gate.sh should take a lock
scripts/full_gate.sh should refuse to start while another gate holds a lock (two runs share one output dir and clobber each other).

## PersonalRecords.suspects needs a user "confirmed real" flag
PersonalRecords.suspects needs a user "confirmed real" flag before it's ever displayed (e.g. Smith Machine Hip Thrust 351×10 is genuine).

## Import is wipe-save-then-insert (mitigated: verified pre-import snapshot b862c7c/0a6aa84, in-process recovery 1af1b46, interrupted-import marker a5aa6ba)
Import is wipe-save-then-insert. A true atomic import needs a scratch-store swap; a single-context rollback attempt crashed SwiftData (_FullFutureBackingData<SessionHistoryExercise>).

## DONE (d90c70d, a5aa6ba): Launch has five store-selection paths, each starting the same startup work
App/ElitePerformanceApp.swift init() picks the store through a ladder: simulator default store, simulator recreate-after-open-failure (deletes default.store), pinned store, "no legacy store files" fallback to the default store, and the scan-and-score of legacy store files. Each branch returns early and used to call the startup backfills itself (five call sites; StartupGate now funnels them into one). The ladder is a leftover of older builds that named their stores. Collapse it to one "open the store" function (legacy-store scan kept as a separate, tested step) and run startup work once after it.
