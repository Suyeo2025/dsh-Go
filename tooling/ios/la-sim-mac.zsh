#!/bin/zsh
# 「鲸游」Live Activity on a throwaway iPhone 18 Pro simulator (Dynamic Island), on the Mac:
#
#   1. RunnerTests/WhaleWakeTests (ContentState wire format, copy, the Allow / Deny gate, bridge
#      credentials) and its rendered boards (XCTAttachment PNGs of every state: compact, minimal,
#      expanded, lock screen dark / light, the expanded-whale before / after comparison), exported to
#      logs/live-activity/boards/;
#   2. real Activities: a simulator build started with `-DSHGOLADemo <sample>` (Swift only,
#      LiveActivityChannel; no Dart, no host): ActivityKit must accept every sample and keep it
#      active (Documents/la-demo.log -> logs/live-activity/demo.log). No island screenshots: a
#      simulator booted without Simulator.app (this Mac has none) suppresses the Dynamic Island
#      completely (SpringBoard: `suppressionForSuppressSystemApertureCompletely`), and simctl can
#      neither long-press nor lock. The rendered boards are the visual check.
#
#   ssh macstudio 'zsh ~/Workspace/dsh-go/src/tooling/ios/la-sim-mac.zsh [--keep] [--no-tests] [--lang en]'
# Ends with LA_RC=<0 when the tests passed and every demo Activity started>.
set -uo pipefail
source ${0:A:h}/env.sh
KEEP=0; TESTS=1; LANG_ARG=zh
while (( $# )); do
  case $1 in
    --keep) KEEP=1 ;;
    --no-tests) TESTS=0 ;;
    --lang) LANG_ARG=$2; shift ;;
    *) echo "unknown arg $1"; exit 2 ;;
  esac
  shift
done
OUT=$DG_LOGS/live-activity
DEV_NAME=dsh-go-la
DEV_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(r[-1]["identifier"])')
rm -rf $OUT; mkdir -p $OUT/boards
UDID=$(xcrun simctl list devices -j | python3 -c "import json,sys; d=[x['udid'] for v in json.load(sys.stdin)['devices'].values() for x in v if x['name']=='$DEV_NAME' and x['isAvailable']]; print(d[0] if d else '')")
[[ -n $UDID ]] || UDID=$(xcrun simctl create $DEV_NAME $DEV_TYPE $RUNTIME)
echo "device $DEV_NAME $UDID ($RUNTIME)"
xcrun simctl boot $UDID 2>/dev/null
xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl uninstall $UDID $DG_BUNDLE_ID 2>/dev/null
RC=0

cd $DG_APP
flutter pub get --enforce-lockfile > /dev/null || { echo "pub get failed"; echo LA_RC=2; exit 2; }
echo "--- build $(date '+%F %T')"
flutter build ios --simulator --debug > $OUT/build.log 2>&1 || { echo "build failed (build.log)"; echo LA_RC=1; exit 1; }
APP=build/ios/iphonesimulator/Runner.app
echo "plugins: $(ls $APP/PlugIns | tr '\n' ' ')"

if (( TESTS )); then
  echo "--- WhaleWakeTests $(date '+%F %T')"
  R=$DG_BUILD/la-tests.xcresult
  rm -rf $R
  (cd ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -only-testing:RunnerTests/WhaleWakeTests -parallel-testing-enabled NO \
    -clonedSourcePackagesDirPath $DG_APP/build/ios/SourcePackages -resultBundlePath $R) > $OUT/tests.log 2>&1
  TRC=$?
  grep -E "Test [Cc]ase .* (passed|failed)|error:|TEST (SUCCEEDED|FAILED)" $OUT/tests.log | sed -E "s/ on '.*'//" | sort -u
  (( TRC == 0 )) || RC=1
  if [[ -d $R ]]; then
    xcrun xcresulttool export attachments --path $R --output-path $OUT/boards > /dev/null 2>&1
    # Name the exported files by their attachment names.
    python3 - $OUT/boards <<'PY'
import json, os, re, sys
d = sys.argv[1]
m = os.path.join(d, 'manifest.json')
if os.path.exists(m):
    for test in json.load(open(m)):
        for a in test.get('attachments', []):
            src = os.path.join(d, a['exportedFileName'])
            hit = re.match(r'(la-[A-Za-z0-9-]+?)(?:_\d+_[0-9A-F-]+)?(?:\.png)?$', a.get('suggestedHumanReadableName') or '')
            if hit and os.path.exists(src):
                os.replace(src, os.path.join(d, hit.group(1) + '.png'))
PY
    rm -f $OUT/boards/manifest.json
    # v2 boards (plan/design/live-activity-v2-contract.md) on their own: logs/live-activity/v2/.
    mkdir -p $OUT/v2
    for f in $OUT/boards/la-v2-*.png(N); do mv $f $OUT/v2/${${f:t}#la-v2-}; done
    echo "boards: $(ls $OUT/boards | tr '\n' ' ')"
  fi
fi

echo "--- demo Activities $(date '+%F %T')"
xcrun simctl boot $UDID 2>/dev/null
xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl install $UDID $APP || { echo "install failed"; echo LA_RC=1; exit 1; }
# First run skipped (the demo needs no Dart, but the onboarding would sit on top of the app shot).
DATA=$(xcrun simctl get_app_container $UDID $DG_BUNDLE_ID data)
mkdir -p "$DATA/Library/Preferences"
python3 - "$DATA/Library/Preferences/$DG_BUNDLE_ID.plist" <<'PY'
import plistlib, sys
plistlib.dump({'flutter.onboarding_welcome_seen': True, 'flutter.onboarding_local_declined': True}, open(sys.argv[1], 'wb'))
PY
: > $OUT/demo.log
SAMPLES=(running running-todo approval approval-high approval-expired question done failed multi stale
  v2-running-buoys v2-running-stop-armed v2-running-many v2-question-options v2-question-stop v2-approval-stop
  v2-done-summary v2-failed-summary)
for sample in $SAMPLES; do
  xcrun simctl terminate $UDID $DG_BUNDLE_ID 2>/dev/null
  xcrun simctl launch --terminate-running-process $UDID $DG_BUNDLE_ID -DSHGOLADemo $sample -DSHGOLADemoLang $LANG_ARG > /dev/null || RC=1
  sleep 5
done
# The demo logs whether ActivityKit took each request (Documents/la-demo.log in the app's container).
cp "$(xcrun simctl get_app_container $UDID $DG_BUNDLE_ID data)/Documents/la-demo.log" $OUT/demo.log 2>/dev/null
cat $OUT/demo.log
grep -q 'DSHGO_LA_DEMO failed' $OUT/demo.log && RC=1
[[ $(grep -c 'DSHGO_LA_DEMO started' $OUT/demo.log) -ge ${#SAMPLES} ]] || { echo "not every demo Activity started"; RC=1; }

echo "--- cleanup $(date '+%F %T')"
xcrun simctl uninstall $UDID $DG_BUNDLE_ID 2>/dev/null
if (( ! KEEP )); then
  xcrun simctl shutdown $UDID 2>/dev/null
  xcrun simctl delete $UDID
fi
rm -rf build/ios/Debug-iphonesimulator build/ios/iphonesimulator
flutter build ios --config-only --release > /dev/null 2>&1
ls $OUT $OUT/boards | wc -l | xargs echo "files in $OUT:"
echo "LA_RC=$RC"
exit $RC
