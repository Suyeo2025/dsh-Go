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
#     --perf:        the idle-cost probe (integration_test/ios_perf_probe_test.dart) instead: frames,
#                    requests and repaint sources per screen in logs/perf-probe/perf.json, plus the
#                    Runner / WebContent CPU% sampled by `top` during each 10 s window (cpu-<scene>.txt).
#     --islands:     every plugin seat of the host at page size (integration_test/ios_islands_test.dart):
#                    islands.json + screenshots in logs/sim-islands/. Also a warm dshgo:// link the app
#                    opens itself (simctl openurl always stops at iOS's 「在"DSH Go"中打开？」 prompt).
#     --links:       no flutter test: a debug simulator build installed on its own, first run skipped,
#                    a share dropped into the App Group inbox as the share extension leaves it (it must
#                    land in a new conversation on launch), then `simctl openurl` dshgo:// links warm
#                    and cold (shot at iOS's open prompt: nothing here can press 打开); screenshots +
#                    links.txt in logs/sim-links/. Needs no host (SMOKE_DEFINES unused).
# Ends with SMOKE_RC=<flutter test exit code>.
set -uo pipefail
source ${0:A:h}/env.sh
KEEP=0; IPAD=0; TOUR=0; DARK=0; PERF=0; ISLANDS=0; LINKS=0
for a in "$@"; do
  case $a in
    --keep) KEEP=1 ;;
    --ipad) IPAD=1 ;;
    --tour) TOUR=1 ;;
    --dark) DARK=1 ;;
    --perf) PERF=1 ;;
    --islands) ISLANDS=1 ;;
    --links) LINKS=1 ;;
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
if (( PERF )); then
  TEST=integration_test/ios_perf_probe_test.dart
  OUT=$DG_LOGS/perf-probe$( (( IPAD )) && echo -ipad )
fi
if (( ISLANDS )); then
  TEST=integration_test/ios_islands_test.dart
  OUT=$DG_LOGS/sim-islands$( (( IPAD )) && echo -ipad )
fi
(( LINKS )) && OUT=$DG_LOGS/sim-links$( (( IPAD )) && echo -ipad )
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

if (( LINKS )); then
  # dsh/links and dsh/share without flutter test (which would own the app's launch): a debug
  # simulator build (ad-hoc signed, so its entitlements — the App Group — apply), installed and
  # started by the simulator itself. iOS asks 「在"DSH Go"中打开？」 for a link simctl opens while
  # the app isn't in front; nothing here can press 打开, so the cold link is shot at that prompt.
  shoot() { sleep $2; xcrun simctl io $UDID screenshot --type=png $OUT/$1.png >/dev/null 2>&1 && echo "LINKS_SHOT $1.png"; }
  echo "--- build $(date '+%F %T')"
  flutter build ios --simulator --debug > $OUT/build.log 2>&1 || { echo "LINKS build failed (build.log)"; echo SMOKE_RC=1; exit 1; }
  APP=build/ios/iphonesimulator/Runner.app
  xcrun simctl install $UDID $APP || { echo "LINKS install failed"; echo SMOKE_RC=1; exit 1; }
  echo "plugins: $(ls $APP/PlugIns 2>&1)" >> $OUT/links.txt
  # First run skipped as ios_smoke_test.dart --offline does (SharedPreferences = the app's defaults).
  DATA=$(xcrun simctl get_app_container $UDID $DG_BUNDLE_ID data)
  mkdir -p "$DATA/Library/Preferences"
  python3 - "$DATA/Library/Preferences/$DG_BUNDLE_ID.plist" <<'PY'
import plistlib, sys
plistlib.dump({'flutter.onboarding_welcome_seen': True, 'flutter.onboarding_local_declined': True}, open(sys.argv[1], 'wb'))
PY
  RC=0
  # A share as the extension leaves it, put in the inbox before the app starts: it has to come
  # through on the app's first activation (ShareChannel drains once Dart is ready).
  GROUP=$(xcrun simctl get_app_container $UDID $DG_BUNDLE_ID groups 2>>$OUT/links.txt | awk '$1=="group.com.colex.dshgo" {print $2}')
  echo "group container: ${GROUP:+found}" >> $OUT/links.txt
  if [[ -n $GROUP ]]; then
    SLOT=$GROUP/share-inbox/sim-links-$(date +%s)
    mkdir -p $SLOT
    cp $(ls $DG_APP/ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png | head -1) $SLOT/photo.png
    SIZE=$(stat -f %z $SLOT/photo.png)
    print -r -- "{\"text\":\"sim-links share check\",\"files\":[{\"name\":\"photo.png\",\"mime\":\"image/png\",\"size\":$SIZE,\"path\":\"photo.png\"}],\"skipped\":[]}" > $SLOT/manifest.json
  else
    echo "LINKS no App Group container"
    RC=1
  fi
  echo "--- launch + share inbox $(date '+%F %T')"
  xcrun simctl launch $UDID $DG_BUNDLE_ID > /dev/null || RC=1
  shoot 01-launch-share-draft 35
  [[ -n $GROUP ]] && echo "inbox after launch: $(ls $GROUP/share-inbox | wc -l | tr -d ' ') folder(s) left" >> $OUT/links.txt
  echo "--- warm link $(date '+%F %T')"
  xcrun simctl openurl $UDID 'dshgo://open/settings' || RC=1
  shoot 02-warm-open-settings 6
  xcrun simctl openurl $UDID 'dshgo://open/appearance' || RC=1
  shoot 03-warm-open-appearance 6
  xcrun simctl openurl $UDID 'dshgo://open/no-such-page' || RC=1
  shoot 04-warm-unknown-page 2
  echo "--- cold link $(date '+%F %T')"
  xcrun simctl terminate $UDID $DG_BUNDLE_ID 2>/dev/null
  sleep 2
  xcrun simctl openurl $UDID 'dshgo://open/settings' || RC=1
  shoot 05-cold-open-settings 30
  cat $OUT/links.txt
  xcrun simctl uninstall $UDID $DG_BUNDLE_ID 2>/dev/null
  if (( ! KEEP )); then
    xcrun simctl shutdown $UDID 2>/dev/null
    xcrun simctl delete $UDID
  fi
  rm -rf build/ios/Debug-iphonesimulator build/ios/iphonesimulator
  ls $OUT | wc -l | xargs echo "files in $OUT:"
  echo "SMOKE_RC=$RC"
  exit $RC
fi
echo "--- flutter test $(date '+%F %T')"
# The simulator app can't write here; it writes into its Documents and names the folder
# (SMOKE_OUT_DIR=…). flutter test uninstalls the app when it ends, so copy while it runs.
: > $OUT/run.log
(
  typeset -A captured sampled
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
    # Perf probe: CPU of the app (and the simulator's WebKit content processes) over each
    # measured window the test announces (PERF_CPU <scene> <seconds>), one sample a second.
    for line in ${(f)"$(grep -o 'PERF_CPU [A-Za-z0-9_.-]* [0-9]*' $OUT/run.log)"}; do
      scene=${${line#PERF_CPU }% *}; secs=${line##* }
      [[ -z $scene || -n ${sampled[$scene]:-} ]] && continue
      sampled[$scene]=1
      sim=$(pgrep -f "launchd_sim.*$UDID" | head -1)
      pids=($(pgrep -f "$UDID.*/Runner.app/Runner"))
      [[ -n $sim ]] && pids+=($(ps -A -o pid=,ppid=,comm= | awk -v p=$sim '$2==p && $3 ~ /WebKit|WebContent|Networking|GPU/ {print $1}'))
      args=(); for p in $pids; do args+=(-pid $p); done
      (( ${#args} )) && top -l $(( secs + 1 )) -s 1 -stats pid,cpu,command ${args[@]} > $OUT/cpu-$scene.txt 2>&1 &
    done
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
[[ -f $OUT/report.json || -f $OUT/tour.json || -f $OUT/perf.json || -f $OUT/islands.json ]] || { echo "no report.json / tour.json"; (( RC == 0 )) && RC=1; }

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
