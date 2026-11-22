#!/bin/bash
# Upgrade test: the last RELEASED build -> this checkout, on a throwaway simulator, without deleting the app.
#
#   scripts/upgrade_test.sh [--released <commit>] [--seed fixture:<backup.json> | --seed onboarding] [--expect <deltas>] [--keep]
#
#   --expect "customExercises:-1,items:+3"   the count deltas this upgrade is EXPECTED to make (after minus before). Counts: sessions,
#       completed, history, customExercises (alias custom), blocks, items. PASS = every listed delta occurs exactly and every
#       unlisted count is unchanged. Default: no deltas (counts identical).
#
# 1. checks out <commit> (default: the live App Store build, 1.2.2 (5) = tag v1.2.2-b5 = c981c47, see BACKLOG.md "Release check") in a worktree,
#    patches only what a current Xcode needs to build it and makes it take the DEVICE store path (not the simulator one);
# 2. seeds the app's real default store with that build's own code (a fixture imported through its importer, or the
#    onboarding path plus two completed sessions) and launches it once, as a device would;
# 3. installs THIS checkout over it (no uninstall) and launches it, capturing the launch log;
# 4. PASS = same store URL opened, counts identical, every backfill logged, no blocking screen text, no crash report;
#    it also prints pre-backfill markers found in the build-change backup file.
# Never touches a physical device. The simulator, worktree and derived data are deleted at the end unless --keep.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3
REPO="$PWD"
RELEASED="c981c47"; SEED="onboarding"; KEEP=0; EXPECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --released) RELEASED="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --expect) EXPECT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
WORK="${TMPDIR:-/tmp}/ep_upgrade_$$"; mkdir -p "$WORK"
BUNDLE="com.markcalabrese.ElitePerformance"
log() { echo "[upgrade] $*"; }
cleanup() {
  [ "$KEEP" = 1 ] && { log "kept: $WORK  device ${DEV:-none}"; return; }
  [ -n "${DEV:-}" ] && { xcrun simctl shutdown "$DEV" >/dev/null 2>&1; xcrun simctl delete "$DEV" >/dev/null 2>&1; }
  git -C "$REPO" worktree remove --force "$WORK/rel" >/dev/null 2>&1; git -C "$REPO" worktree prune
  rm -rf "$WORK"
}
trap cleanup EXIT

DEV="$(xcrun simctl create "EP-upgrade-$$" "iPhone 17 Pro" 2>/dev/null | tail -1)"
[ -n "$DEV" ] || { log "could not create a simulator"; exit 3; }
xcrun simctl boot "$DEV" || exit 3
DEST="platform=iOS Simulator,id=$DEV"

log "released build: $RELEASED  seed: $SEED  device: $DEV"
git worktree add -q --detach "$WORK/rel" "$RELEASED" || exit 3
REL="$WORK/rel"
# patches (build environment only; no behaviour change except taking the device store path)
f="$REL/Features/Settings/MesoRolloverGuardSheet.swift"
[ -f "$f" ] && ! grep -q "import SwiftData" "$f" && sed -i '' '1s/^import SwiftUI$/import SwiftUI\nimport SwiftData/' "$f"
sed -i '' 's/#if targetEnvironment(simulator)/#if false \/\/ upgrade test: take the device store path/' "$REL/App/ElitePerformanceApp.swift"
T="$REL/Tests/DomainTests/CoachingEngineTests.swift"
sed -i '' '1s/^import XCTest$/import XCTest\nimport SwiftData/' "$T"
cat "$REPO/scripts/upgrade_seed_test.swift.txt" >> "$T"

log "building the released build"
(cd "$REL" && xcodebuild build-for-testing -project ElitePerformance.xcodeproj -scheme ElitePerformance -destination "$DEST" -derivedDataPath "$WORK/dd_rel" > "$WORK/rel_build.log" 2>&1) || { log "released build failed: $WORK/rel_build.log"; KEEP=1; exit 3; }
MODE="onboarding"; FIXTURE=""
case "$SEED" in fixture:*) MODE="fixture"; FIXTURE="${SEED#fixture:}" ;; esac
log "seeding ($MODE) through the released build"
(cd "$REL" && TEST_RUNNER_EP_UPGRADE_MODE="$MODE" TEST_RUNNER_EP_UPGRADE_FIXTURE="$FIXTURE" TEST_RUNNER_EP_UPGRADE_REPORT="$WORK/seed.txt" \
  xcodebuild test-without-building -project ElitePerformance.xcodeproj -scheme ElitePerformance -destination "$DEST" -derivedDataPath "$WORK/dd_rel" \
  -parallel-testing-enabled NO -disable-concurrent-destination-testing -only-testing:ElitePerformanceTests/ZZUpgradeSeedTests > "$WORK/seed.log" 2>&1) || { log "seeding failed: $WORK/seed.log"; KEEP=1; exit 3; }
cat "$WORK/seed.txt"
BASE="$(grep '^counts' "$WORK/seed.txt")"
STORE="$(grep '^store url' "$WORK/seed.txt" | sed 's/^store url: //')"

(cd "$REL" && xcodebuild build -project ElitePerformance.xcodeproj -scheme ElitePerformance -destination "$DEST" -derivedDataPath "$WORK/dd_rel" > "$WORK/rel_app.log" 2>&1) || { log "released app build failed"; KEEP=1; exit 3; }
OLDAPP="$(find "$WORK/dd_rel/Build/Products" -name ElitePerformance.app -maxdepth 3 | head -1)"
xcrun simctl install "$DEV" "$OLDAPP"
xcrun simctl launch --terminate-running-process "$DEV" "$BUNDLE" >/dev/null; sleep 12; xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1

log "building the candidate ($(git rev-parse --short HEAD))"
xcodebuild build -project ElitePerformance.xcodeproj -scheme ElitePerformance -configuration Debug -destination "$DEST" -derivedDataPath "$WORK/dd_head" > "$WORK/head_build.log" 2>&1 || { log "candidate build failed"; KEEP=1; exit 3; }
NEWAPP="$(find "$WORK/dd_head/Build/Products" -name ElitePerformance.app -maxdepth 3 | head -1)"
xcrun simctl install "$DEV" "$NEWAPP" || exit 3     # over the old app: no uninstall
log "launching the candidate over the released build"
touch "$WORK/launch.mark"
( xcrun simctl launch --console-pty --terminate-running-process "$DEV" "$BUNDLE" > "$WORK/head_launch.log" 2>&1 & )
sleep 30; xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1; sleep 2
echo "---- launch log ----"; cut -c1-240 "$WORK/head_launch.log"; echo "--------------------"

# counts from the store itself
mkdir -p "$WORK/sq"; cp "$STORE"* "$WORK/sq/" 2>/dev/null
Q() { sqlite3 "$WORK/sq/$(basename "$STORE")" "$1"; }
NOW="counts sessions=$(Q 'select count(*) from ZSESSION') completed=$(Q "select count(*) from ZSESSION where ZSTATUS='completed'") history=$(Q 'select count(*) from ZSESSIONHISTORY') custom=$(Q 'select count(*) from ZCUSTOMEXERCISE') blocks=$(Q 'select count(*) from ZMESOBLOCK') items=$(Q 'select count(*) from ZSESSIONITEM')"
FAIL=0
check() { if [ "$2" = "0" ]; then echo "PASS  $1"; else echo "FAIL  $1"; FAIL=1; fi; }
echo "before: $BASE"; echo "after:  $NOW"
python3 - "$BASE" "$NOW" "$EXPECT" <<'PY'
import re,sys
def parse(t): return {k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',t)}
before,after=parse(sys.argv[1]),parse(sys.argv[2])
alias={'customExercises':'custom','customexercises':'custom','custom':'custom'}
expect={}
for part in [p for p in sys.argv[3].split(',') if p.strip()]:
    k,d=part.rsplit(':',1); expect[alias.get(k.strip(),k.strip())]=int(d)
bad=[]
for k in sorted(set(before)|set(after)|set(expect)):
    delta=after.get(k,0)-before.get(k,0); want=expect.get(k,0)
    mark='' if delta==want else '   <-- expected %+d'%want
    if delta!=0 or k in expect: print(f"  delta {k}: {delta:+d}{' (expected)' if k in expect and delta==want else ''}{mark}")
    if delta!=want: bad.append(k)
sys.exit(1 if bad else 0)
PY
check "count deltas $( [ -n "$EXPECT" ] && echo "= expected ($EXPECT)" || echo "= none" )" $?
OPENED="$(grep -o 'at file://[^ ]*' "$WORK/head_launch.log" | head -1 | tr -d '\r' | sed 's#^at file://##; s/%20/ /g')"; [ "$OPENED" = "$STORE" ]; check "same store URL opened" $?
EXPECTED=$(grep -c "^        (String(describing:" "$REPO/App/ElitePerformanceApp.swift")
GOT=$(grep -c "Backfill [A-Za-z]*:" "$WORK/head_launch.log")
[ "$EXPECTED" = "$GOT" ]; check "all $EXPECTED backfills logged ($GOT)" $?
! grep -qE "BLOCKING|Could not open the store|MissingData|Restore interrupted" "$WORK/head_launch.log"; check "no blocking screen" $?
! find "$HOME/Library/Logs/DiagnosticReports" -name 'ElitePerformance*' -newer "$WORK/launch.mark" 2>/dev/null | grep -q .; check "no crash report" $?

echo "---- automatic backups written by the candidate's launch (oldest first) ----"
# Only the files written AFTER the candidate was launched count: a released build that writes its own launch backup (1.2.2 (4) and later)
# leaves one of its own from the seeding launch, which is not the candidate's.
BKS="$(find "$HOME/Library/Developer/CoreSimulator/Devices/$DEV/data" -name 'ElitePerformance_AutoBackup_*.json' -newer "$WORK/launch.mark" 2>/dev/null | sort)"
if [ -n "$BKS" ]; then
  echo "$BKS" | while IFS= read -r f; do python3 - "$f" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
hist=d.get("sessionHistory",[])
multi=[h for h in hist if len(h.get("exercises",[]))>1]
unordered=[h for h in multi if len({e.get("order",0) for e in h["exercises"]})==1]
planned=[s for s in d.get("sessions",[]) if s.get("statusRaw")=="planned"]
nodate=[s for s in planned if not s.get("plannedDate")]
pad=neg=0
for s in planned:
    for i in s.get("items",[]):
        reps=i.get("actualReps",[])
        for k,r in enumerate(i.get("actualRIRs",[])):
            if (reps[k] if k<len(reps) else 0)==0:
                pad+= r==0; neg+= r==-1
print(sys.argv[1].split("/")[-1])
print(f"  multi-exercise history entries: {len(multi)}, with every order 0 (pre-backfill): {len(unordered)}")
print(f"  planned sessions: {len(planned)}, without plannedDate (pre-backfill): {len(nodate)}")
print(f"  unlogged planned sets with RIR 0 (padding, pre-backfill): {pad}; with RIR -1 (unset, post-backfill): {neg}")
PY
  done
  N=$(echo "$BKS" | wc -l | tr -d ' ')
  [ "$N" = "1" ]; check "one backup for the launch ($N file)" $?
else
  echo "no automatic backup file found"; FAIL=1
fi
[ $FAIL = 0 ] && { echo "UPGRADE TEST: PASS"; exit 0; } || { echo "UPGRADE TEST: FAIL"; KEEP=1; exit 1; }
