#!/bin/zsh
# Mac half of tooling/ios/sim-smoke.sh: runs app/integration_test/ios_smoke_test.dart on a
# dedicated simulator and leaves screenshots + report.json + run.log in ~/Workspace/dsh-go/logs/sim-smoke/.
#
#   SMOKE_DEFINES=<0600 json> zsh sim-smoke-mac.zsh [--keep] [--ipad] [--tour] [--dark]
#     SMOKE_DEFINES: optional --dart-define-from-file (SMOKE_DIRECT_URL / SMOKE_DIRECT_TOKEN), in a
#                    temp dir of its own: read only by flutter, the token is scrubbed from run.log,
#                    and the dir is deleted when this script exits (however it exits).
#     --keep:        keep the simulator device (default: shut down and delete it, which also
#                    drops the app's data and keychain).
#     --ipad:        iPad Pro 13-inch (M5) instead of iPhone 18 Pro; results in logs/sim-smoke-ipad/.
#     --tour:        the UX tour (integration_test/ios_ux_tour_test.dart) instead of the smoke test:
#                    screenshots for review in logs/ux-tour/{iphone-light,iphone-dark,ipad}/ (iPad in
#                    landscape), tour.json describing them.
#     --dark:        the simulator in dark appearance (the app follows the system).
# Ends with SMOKE_RC=<flutter test exit code>.
set -uo pipefail
source ${0:A:h}/env.sh
KEEP=0; IPAD=0; TOUR=0; DARK=0
for a in "$@"; do
  case $a in
    --keep) KEEP=1 ;;
    --ipad) IPAD=1 ;;
    --tour) TOUR=1 ;;
    --dark) DARK=1 ;;
    *) echo "unknown arg $a"; exit 2 ;;
  esac
done
if [[ -n ${SMOKE_DEFINES:-} ]]; then
  [[ ${SMOKE_DEFINES:h} == /tmp/dsh-go-smoke.* ]] || { echo "SMOKE_DEFINES must be in /tmp/dsh-go-smoke.*"; exit 2; }
  trap 'rm -rf -- "${SMOKE_DEFINES:h}"' EXIT
  trap 'exit 130' INT TERM HUP
fi
if (( IPAD )); then
  OUT=$DG_LOGS/sim-smoke-ipad
  DEV_NAME=dsh-go-smoke-ipad
  DEV_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
else
  OUT=$DG_LOGS/sim-smoke
  DEV_NAME=dsh-go-smoke
  DEV_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro
fi
TEST=integration_test/ios_smoke_test.dart
EXTRA=()
if (( TOUR )); then
  TEST=integration_test/ios_ux_tour_test.dart
  VARIANT=$( (( IPAD )) && echo ipad || { (( DARK )) && echo iphone-dark || echo iphone-light; } )
  OUT=$DG_LOGS/ux-tour/$VARIANT
  EXTRA=(--dart-define=TOUR_VARIANT=$VARIANT)
  (( IPAD )) && EXTRA+=(--dart-define=TOUR_LANDSCAPE=true)
fi
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(r[-1]["identifier"])')

rm -rf $OUT; mkdir -p $OUT
UDID=$(xcrun simctl list devices -j | python3 -c "import json,sys; d=[x['udid'] for v in json.load(sys.stdin)['devices'].values() for x in v if x['name']=='$DEV_NAME' and x['isAvailable']]; print(d[0] if d else '')")
[[ -n $UDID ]] || UDID=$(xcrun simctl create $DEV_NAME $DEV_TYPE $RUNTIME)
echo "device $DEV_NAME $UDID ($RUNTIME)"
xcrun simctl boot $UDID 2>/dev/null
xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl uninstall $UDID $DG_BUNDLE_ID 2>/dev/null
xcrun simctl keychain $UDID reset
xcrun simctl ui $UDID appearance $( (( DARK )) && echo dark || echo light )

# The token never reaches run.log: every line passes through this filter.
TOK=""
if [[ -n ${SMOKE_DEFINES:-} ]]; then
  TOK=$(plutil -extract SMOKE_DIRECT_TOKEN raw -o - "$SMOKE_DEFINES" 2>/dev/null)
fi
scrub() { SMOKE_TOK="$TOK" perl -pe 'BEGIN { $| = 1; $t = $ENV{SMOKE_TOK} } s/\Q$t\E/<token>/g if length $t; $_ = substr($_, 0, 4000) . "…\n" if length > 4000'; }

cd $DG_APP
flutter pub get --enforce-lockfile > /dev/null || { echo "pub get failed"; echo SMOKE_RC=2; exit 2; }
echo "--- flutter test $(date '+%F %T')"
# The simulator app can't write here; it writes into its Documents and names the folder
# (SMOKE_OUT_DIR=…). flutter test uninstalls the app when it ends, so copy while it runs.
: > $OUT/run.log
(
  typeset -A captured
  while [[ ! -f $OUT/.done ]]; do
    dir=$(sed -n 's/.*SMOKE_OUT_DIR=//p' $OUT/run.log | tail -1)
    # UX tour: a full device screenshot when the test asks (TOUR_CAPTURE <file>), into the
    # app's folder where the test waits for it.
    if [[ -n $dir && -d $dir ]]; then
      for f in $(sed -n 's/.*TOUR_CAPTURE \([A-Za-z0-9_.-]*\.png\).*/\1/p' $OUT/run.log); do
        [[ -n ${captured[$f]:-} ]] && continue
        captured[$f]=1
        xcrun simctl io $UDID screenshot --type=png "$dir/$f.tmp" >/dev/null 2>&1 && mv "$dir/$f.tmp" "$dir/$f"
      done
    fi
    [[ -n $dir && -d $dir ]] && rsync -a --exclude=.probe --exclude="*.tmp" "$dir/" $OUT/
    # The test says when the downloaded font is on disk: list it and its backup flag
    # (NSURLIsExcludedFromBackupKey is the com.apple.metadata:com_apple_backup_excludeItem xattr).
    if [[ ! -f $OUT/fonts-check.txt && -n $dir ]] && grep -q SMOKE_FONTS_READY $OUT/run.log; then
      fonts="${dir:h:h}/Library/Application Support/fonts"
      {
        echo "# $fonts"
        ls -la "$fonts" "$fonts"/*/ 2>&1
        du -sh "$fonts" 2>&1
        echo "# xattr on fonts/"
        xattr -l "$fonts" 2>&1
        print -r -- "excludedFromBackup=$(xattr "$fonts" 2>/dev/null | grep -c com_apple_backup_excludeItem)"
      } > $OUT/fonts-check.txt
    fi
    sleep 0.3
  done
) &
COPIER=$!
flutter test $TEST -d $UDID "${EXTRA[@]}" \
  --dart-define=SMOKE_OUT=$OUT --dart-define=DSH_APP_VERSION=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)+0 \
  ${SMOKE_DEFINES:+--dart-define-from-file=$SMOKE_DEFINES} 2>&1 | scrub | tee $OUT/run.log
RC=${pipestatus[1]}
touch $OUT/.done; wait $COPIER; rm -f $OUT/.done $OUT/.probe
[[ -f $OUT/report.json || -f $OUT/tour.json ]] || { echo "no report.json / tour.json"; (( RC == 0 )) && RC=1; }

echo "--- cleanup $(date '+%F %T')"
xcrun simctl uninstall $UDID $DG_BUNDLE_ID 2>/dev/null
xcrun simctl keychain $UDID reset
if (( ! KEEP )); then
  xcrun simctl shutdown $UDID 2>/dev/null
  xcrun simctl delete $UDID
fi
# Build products compiled with the defines (kernel, App.framework, Generated.xcconfig's
# DART_DEFINES) hold the token: remove them and regenerate a define-free config.
rm -rf build/ios/Debug-iphonesimulator build/ios/iphonesimulator .dart_tool/flutter_build
flutter build ios --config-only --release > /dev/null 2>&1
for f in ios/Flutter/Generated.xcconfig ios/Flutter/flutter_export_environment.sh; do
  sed -n 's/.*DART_DEFINES=\(.*\)/\1/p' $f | tr -d '"' | tr ',' '\n' | while read -r d; do print -r -- $d | base64 -D 2>/dev/null; echo; done \
    | grep -q '^SMOKE_' && echo "WARN: $f still has SMOKE_ defines"
done
ls $OUT | wc -l | xargs echo "files in $OUT:"
echo "SMOKE_RC=$RC"
exit $RC
