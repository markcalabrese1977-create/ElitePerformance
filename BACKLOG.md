# Backlog

One line per item; dates are 2026. Open items first; shipped items are under "Done (Oct 2026)" with their commits (original wording kept).

## Rules

- New persisted field: add it to the backup DTO, exporter and importer, and set it to a non-default value in the BA2 builder (`PopulatedStoreBuilder`). BA1 fails with `Entity.field` otherwise. A field that must not be backed up goes in `BackupSchemaMap.exclusions` with a one-line reason.
- New UserDefaults / App Group key: register it in `PersistedKeyRegistry` (Domain/Sync) with a disposition; BA3 fails on any key the registry does not cover. Prefer a model field.
- New persisted model: add it to `AppSchema.models`; BA1 and the app container both read that one list.

## Open

- Install: install current HEAD after the Fri Oct 30 Push A backup checks out; commits after 46039ee are deinit (a5b3b74), baseline (48e6bcb), test-only (c3ca2d0) and docs. 46039ee carries top set + back-off, the prescribed set count and its backfill, and the next-meso clone. Verify the launch log lists the 10 StartupBackfills (the new one last) and that the Push A next-meso preview shows 3 back-offs on B/C weeks.
- HealthKitAuthorizationCoordinator: add `nonisolated deinit {}` defensively (same shape
  as SessionScreenViewModel; tests pass today). Low priority.
- Top set follow-ups (feat/top-set, shipped): (a) planEdited is one flag, so a manual load edit freezes carry-forward for both roles; split per role if it bites; (b) Change prescription only offers a top count of 1 (the model allows up to 3); (c) MesoPerformanceAnalyzer, PR and recap code were not reviewed for top rows (they count every row; verify the first/last-load comparisons); (d) Add Set on an item without a top set still appends a plain row; adding a top set is done from Change prescription.
- Coach-message honesty (mostly done): the stage-gate wording is now "N of M planned sets logged." (d491a8c) and landing / blocked-write wording shipped (0cd2455). Remaining: the unresolved-target fallback for a non-exempt reduce still says "next session"; a completed session with a skipped set reads "N of M planned sets logged." with no word about the skip.
- Deload in place (fallback, works today; Insert deload week has since shipped, see Done): log the week light with load-override reason Deliberate Deload. Follow-ups: (a) verify a deload-flagged source never seeds an EMPTY same-letter target (new-lift first exposure) with light loads; (b) the "Last A/B/C" caption and the meso summary verdicts must skip items flagged Deliberate Deload, as they already skip deload-wave items.
- Earned volume (v5.2): Pull A hammer curl 4th set if earned on Oct 18 (>20 reps at 102 or heavier vs Sept 27); parameterized one-shot repair, weeks 5-12; later decline the 4th set, then one open slot chosen at rotation 3. (Status not re-checked in the Oct 26 sweep.)
- Rotation 4 (weeks 10-12): optional RIR 1 on upper compounds and hack squat/hip thrust A/B weeks; decide ~Nov 20.
- Swap/add service (partly done: the Today "Apply to future <weekday>" propagation is retired and the replace service sizes arrays and seeds from completed history, see Done). Remaining, not re-verified: Today "Apply to future <weekday>" is unscoped and zeroes loads (guard or scope it); arrays sized to sets; rep range and wave on adds; lastKnownLoad must not read future plans; custom names from the table.
- Pushdown follows the lifter's last load (parked; user raises by hand).
- Import hardening: atomic import with pre-restore safety copy, tolerant decoding, version check, history order, HealthDashboard rebuild after import, build identity in export, custom-exercise mirror (clear when empty, isBodyweight), tolerant dedup (Dictionary(uniqueKeysWithValues:) trap), idempotent CustomExerciseStoreMigration.
- Test infrastructure: J4 flake; B10/F6/M7 no longer abort the host (48e6bcb); synchronized test folder (no hand-edited pbxproj); keep Tests/known_failures.txt set-based. Never run two gates concurrently (shared simulator / memory pressure kills the test host without a crash report); before a full-suite or fixture run, check `ps -axo pid,command | grep xcodebuild` and `xcrun simctl list devices booted`, and wait if one is running. New test files in Tests/DomainTests need a hand-added pbxproj entry (that folder is an explicit group, not synchronized), with Xcode quit.
- Device builds: run xcodebuild as a tracked/background task; foreground runs can be
  killed by the tool timeout (two BUILD INTERRUPTED on Oct 25 before a clean third run).
- Universality guard (C5): never extend the allowlist except for unregistered one-shot repairs; add new patterns when new user-specific data appears. The guard itself shipped (0eef263); this is the standing rule.
- Optional: give the two hand-added week-1 lifts their wave letters; slotOverrides per-day key; isCleanSession vs deliberateDeload; onChange deprecations.
- Hack squat re-entry after Dr. Alexander clears (sled + 135 at W1 stance pain-free -> fresh anchors per letter); cable hip adduction returns only after hips clear.
- E1RM RIR model (low priority): HistorySeedLoad credits RIR additively on input (reps+RIR); load(for:reps:targetRIR:) applies 2.5%/RIR on output. Within ~1% at RIR<=2, ~2% at RIR 4 / low reps. Unify into one E1RMCalculator RIR function used by both; run a C3b-style before/after seed comparison.
- Replace: optional prescription override (e.g. RIR) applied by the service without setting planEdited (planEdited blocks carry-forward writes into the item).
- kg support: User.units is unused; loads/increments/display/backups.
- Settings (low priority): 'Use Health date of birth' row next to the Birthdate field, calling requestAuthorizationIfNeeded(), so users grant it in context instead of after a workout. Helper text: Health's date of birth is used when available, otherwise the Birthdate above (iOS can't report whether access was granted). Footer stays as is.
- HR zones: when age is available, HRR uses 220 - age as max HR even if observed max exists. Prefer observed max (with a sanity floor); 220 - age only as fallback.
- Set band (low priority): stepper/prescription widen setMin/setMax but never narrow, so a +1/-1 round
  trip leaves a wider label ("2-4 sets" with 3 working). Narrow back toward the original
  template band (store it, or recompute from the wave prescription), never below it.
- Rest today (low priority): when the refusal is a collision with the next week's first session, say
  "No open day this week. Skip a session instead."
- Program selection ignores equipment/injury flags (6-day dumbbell-only user gets machines/cables). Part of Phase 3.1 onboarding; pre-launch.
- Notes UX (pre-launch): two note types look alike. Label them in the UI: "Exercise
  note — applies everywhere" (ExerciseNoteSheet) vs "Session cue — this session"
  (executionNoteLine, editable via Change for remaining sessions). From the exercise
  card, offer a link to edit the session cue for remaining sessions.
- Custom "Concentration Curl" duplicates the built-in concentration_curl (found by the
  O1 collision check). Decide: merge the custom into the built-in (move history,
  canonical id) via the existing dedup path, or rename. Low priority.

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
