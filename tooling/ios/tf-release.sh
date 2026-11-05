#!/bin/zsh
# Signed App Store build -> TestFlight (internal testing only), on the Mac.
#
#   tooling/ios/sync-to-mac.sh       # on whole first: push the tree
#   ssh macstudio 'nohup zsh ~/Workspace/dsh-go/src/tooling/ios/tf-release.sh > /dev/null 2>&1 &'
#   ssh macstudio 'tail -f ~/Workspace/dsh-go/logs/tf-latest.log'
#
# Options: --no-upload (archive + export only)   --validate (archive + export + altool --validate-app)
#          --build-name X.Y.Z (default: pubspec version)
#          --build-number N (default: yyyyMMddHHmm, local time)
# Steps: keychain -> profile.mjs -> flutter --config-only -> xcodebuild archive (manual signing via
# Signing.xcconfig + --keychain) -> export -> altool upload -> testflight.mjs (wait for processing,
# compliance, internal group, read back).
set -uo pipefail
HERE=${0:A:h}
source $HERE/env.sh

UPLOAD=1; VALIDATE=0; BN=$(date +%Y%m%d%H%M); BNAME=""
while (( $# )); do
  case $1 in
    --no-upload) UPLOAD=0 ;;
    --validate) UPLOAD=0; VALIDATE=1 ;;
    --build-number) BN=$2; shift ;;
    --build-name) BNAME=$2; shift ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
  shift
done

A=$DG_BUILD/DSHGo-$BN.xcarchive
E=$DG_BUILD/export-$BN
LOG=$DG_LOGS/tf-$BN.log
ln -sf $LOG $DG_LOGS/tf-latest.log
step() { echo "--- $* $(date '+%F %T')"; }
die() { echo "FAILED: $*"; echo "TF_RC=1"; exit 1; }

{
step "start build=$BN upload=$UPLOAD validate=$VALIDATE"

step preflight
# App Store validation (ITMS-90035) treats any bundled file starting with "#!" as unsigned script
# code. Catch it before a 3-minute archive and a rejected upload.
bad=()
for f in $DG_APP/assets/**/*(.N); do [[ $(head -c2 "$f") == '#!' ]] && bad+=("${f#$DG_SRC/}"); done
(( ${#bad} == 0 )) || die "assets starting with #! (App Store rejects them as unsigned code): $bad"

step keychain
# The Apple Distribution key lives in a dedicated keychain (login keychain makes codesign block on
# a SecurityAgent prompt). Keep it in the user search list and unlocked for this run.
if ! security list-keychains -d user | grep -q "${DG_KC:t}"; then
  security list-keychains -d user -s ${(f)"$(security list-keychains -d user | tr -d '" ')"} "$DG_KC"
fi
security unlock-keychain -p "$(cat "$DG_KC_PASS_FILE")" "$DG_KC" || die "unlock keychain"
security set-keychain-settings "$DG_KC"
security find-identity -v -p codesigning "$DG_KC" | grep -q "Apple Distribution: .*($DG_TEAM)" || die "no Apple Distribution identity in $DG_KC"

step profile
(cd $HERE && node profile.mjs --store) || die "profile"

step "flutter config-only"
cd $DG_APP || die "no $DG_APP"
flutter pub get --enforce-lockfile || die "pub get"
# 关于 › 版本 reads DSH_APP_VERSION (lib/state/app_info.dart), as tooling/build-apk.sh passes it.
VNAME=${BNAME:-$(sed -n 's/^version: *\([^+]*\).*/\1/p' $DG_APP/pubspec.yaml)}
flutter build ios --config-only --release --build-number "$BN" ${BNAME:+--build-name "$BNAME"} \
  --dart-define=DSH_APP_VERSION=$VNAME+$BN || die "flutter config-only"

step "archive -> $A"
rm -rf "$A" "$E"
cd $DG_APP/ios
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$A" \
  -clonedSourcePackagesDirPath $DG_APP/build/ios/SourcePackages \
  -xcconfig $HERE/Signing.xcconfig OTHER_CODE_SIGN_FLAGS="--keychain $DG_KC" \
  archive || die "archive"
plutil -p "$A/Products/Applications/Runner.app/Info.plist" | grep -E 'CFBundle(Identifier|ShortVersionString|Version)"'
codesign -dvv "$A/Products/Applications/Runner.app" 2>&1 | grep -E '^(Authority|TeamIdentifier)=' | head -2

step "export -> $E"
xcodebuild -exportArchive -archivePath "$A" -exportOptionsPlist $HERE/ExportOptions.plist -exportPath "$E" || die "export"
IPA=$(ls $E/*.ipa | head -1)
[[ -f $IPA ]] || die "no ipa"
ls -la $E

if (( VALIDATE )); then
  step "validate $IPA"
  xcrun altool --validate-app -f "$IPA" -t ios --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER || die "validate"
fi
if (( UPLOAD )); then
  step "upload $IPA"
  xcrun altool --upload-app -f "$IPA" -t ios --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER || die "upload"
  step "testflight"
  (cd $HERE && node testflight.mjs "$BN") || die "testflight"
fi
step done
echo "TF_RC=0"
} > $LOG 2>&1
