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
#          --share / --no-share: with or without the share extension (default: with it only when both
#          App Store profiles carry the App Group group.com.colex.dshgo, which needs the developer
#          portal; see README "Share extension signing"). Without it, this archive alone leaves the
#          extension out (the project is edited for the archive and restored) and signs the app
#          without the App Group entitlement; the target and its code stay as they are.
#          --activity / --no-activity: with or without the 「鲸游」Live Activity extension
#          (WhaleWakeActivity, com.colex.dshgo.activity; default: with it when profile.mjs reports
#          its App Store profile ACTIVE). Left out the same way: this archive only.
# Steps: keychain -> profile.mjs -> flutter --config-only -> xcodebuild archive (manual signing via
# Signing.xcconfig + --keychain) -> export -> altool upload -> testflight.mjs (wait for processing,
# compliance, internal group, read back).
set -uo pipefail
HERE=${0:A:h}
source $HERE/env.sh

UPLOAD=1; VALIDATE=0; SHARE=auto; ACTIVITY=auto; BN=$(date +%Y%m%d%H%M); BNAME=""
while (( $# )); do
  case $1 in
    --no-upload) UPLOAD=0 ;;
    --validate) UPLOAD=0; VALIDATE=1 ;;
    --build-number) BN=$2; shift ;;
    --build-name) BNAME=$2; shift ;;
    --share) SHARE=on ;;
    --no-share) SHARE=off ;;
    --activity) ACTIVITY=on ;;
    --no-activity) ACTIVITY=off ;;
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
step "start build=$BN upload=$UPLOAD validate=$VALIDATE share=$SHARE activity=$ACTIVITY"

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
PROFILE_OUT=$(cd $HERE && node profile.mjs --store) || { print -r -- "$PROFILE_OUT"; die "profile"; }
print -r -- "$PROFILE_OUT"
# The share extension hands shares over through the App Group; both App Store profiles must carry it.
GROUP=group.com.colex.dshgo
grouped() { print -r -- "$PROFILE_OUT" | grep -q "^APP_GROUPS $1 .*$GROUP"; }
if grouped "dg $DG_BUNDLE_ID" && grouped "dg $DG_BUNDLE_ID.share"; then HAVE_GROUP=1; else HAVE_GROUP=0; fi
if [[ $SHARE == auto ]]; then SHARE=$( (( HAVE_GROUP )) && echo on || echo off ); fi
[[ $SHARE == on ]] && (( ! HAVE_GROUP )) && die "--share: the App Store profiles don't carry $GROUP (README: Share extension signing)"
echo "share extension: $SHARE (profiles carry $GROUP: $HAVE_GROUP)"

# The Live Activity extension needs only its own App Store profile (no capability).
ACTIVITY_PROFILE="dg $DG_BUNDLE_ID.activity"
if print -r -- "$PROFILE_OUT" | grep -q "^profile \"$ACTIVITY_PROFILE\" .* ACTIVE "; then HAVE_ACTIVITY=1; else HAVE_ACTIVITY=0; fi
if [[ $ACTIVITY == auto ]]; then ACTIVITY=$( (( HAVE_ACTIVITY )) && echo on || echo off ); fi
[[ $ACTIVITY == on ]] && (( ! HAVE_ACTIVITY )) && die "--activity: no ACTIVE '$ACTIVITY_PROFILE' profile"
echo "activity extension: $ACTIVITY (profile: $HAVE_ACTIVITY)"

XCCONFIG=$HERE/Signing.xcconfig
EXPORT_OPTIONS=$HERE/ExportOptions.plist
LEAVE_OUT=()
[[ $SHARE == off ]] && LEAVE_OUT+=(ShareExtension)
[[ $ACTIVITY == off ]] && LEAVE_OUT+=(WhaleWakeActivity)
if (( ${#LEAVE_OUT} )); then
  # This archive only: those extensions neither built nor embedded (the project file is edited and
  # restored on exit; targets and code stay).
  PBX=$DG_APP/ios/Runner.xcodeproj/project.pbxproj
  cp $PBX $DG_BUILD/project.pbxproj.ext-$BN
  trap 'cp $DG_BUILD/project.pbxproj.ext-$BN $PBX && rm -f $DG_BUILD/project.pbxproj.ext-$BN' EXIT
  python3 - $PBX $LEAVE_OUT <<'PY' || die "extension project edit"
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
for name in sys.argv[2:]:
    embed = re.search(r'\t+(\w+) /\* ' + name + r'\.appex in Embed Foundation Extensions \*/,\n', s)
    target = re.search(r'(\w+) /\* ' + name + r' \*/ = \{\n\t+isa = PBXNativeTarget;', s)
    assert embed and target, name + ' not found in the project'
    s = s.replace(embed.group(0), '', 1)
    # The Runner dependency whose proxy points at the extension target.
    for dep in re.finditer(r'(\w+) /\* PBXTargetDependency \*/ = \{[^}]*?target = ' + target.group(1), s):
        s = re.sub(r'\t+' + dep.group(1) + r' /\* PBXTargetDependency \*/,\n', '', s, count=1)
open(p, 'w', encoding='utf-8').write(s)
PY
  for x in $LEAVE_OUT; do
    grep -q "$x.appex in Embed Foundation Extensions \*/," $PBX && die "$x still embedded"
  done
  EXPORT_OPTIONS=$DG_BUILD/ExportOptions-ext.plist
  cp $HERE/ExportOptions.plist $EXPORT_OPTIONS
  drop_export() {
    python3 -c "import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,'rb')); d['provisioningProfiles'].pop(sys.argv[2],None); plistlib.dump(d,open(p,'wb'))" $EXPORT_OPTIONS $1
  }
  [[ $ACTIVITY == off ]] && drop_export $DG_BUNDLE_ID.activity
fi
if [[ $SHARE == off ]]; then
  # The app without the App Group entitlement (nothing to share it with).
  NOSHARE_ENT=$DG_BUILD/Runner-noshare.entitlements
  cp $DG_APP/ios/Runner/Runner-Release.entitlements $NOSHARE_ENT
  # (plutil -remove would read the dots of the key as a key path.)
  python3 -c "import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,'rb')); d.pop('com.apple.security.application-groups'); plistlib.dump(d,open(p,'wb'))" $NOSHARE_ENT \
    || die "no-share entitlements"
  XCCONFIG=$DG_BUILD/Signing-noshare.xcconfig
  {
    echo "#include \"$HERE/Signing.xcconfig\""
    echo "DG_ENT_Runner = $NOSHARE_ENT"
    echo 'CODE_SIGN_ENTITLEMENTS = $(DG_ENT_$(TARGET_NAME))'
  } > $XCCONFIG
  drop_export $DG_BUNDLE_ID.share
fi

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
  -xcconfig $XCCONFIG OTHER_CODE_SIGN_FLAGS="--keychain $DG_KC" \
  archive || die "archive"
plutil -p "$A/Products/Applications/Runner.app/Info.plist" | grep -E 'CFBundle(Identifier|ShortVersionString|Version)"'
codesign -dvv "$A/Products/Applications/Runner.app" 2>&1 | grep -E '^(Authority|TeamIdentifier)=' | head -2
echo "plugins: $(ls $A/Products/Applications/Runner.app/PlugIns 2>/dev/null | tr '\n' ' ')"
codesign -d --entitlements - --xml "$A/Products/Applications/Runner.app" 2>/dev/null | plutil -p - | grep -E 'aps-environment|application-groups|time-sensitive' -A1
for x in $A/Products/Applications/Runner.app/PlugIns/*.appex(N); do
  echo "${x:t}: $(plutil -extract CFBundleIdentifier raw -o - $x/Info.plist) $(codesign -dvv $x 2>&1 | grep -m1 '^Authority=')"
  codesign -d --entitlements - --xml "$x" 2>/dev/null | plutil -p - | grep -E 'application-groups' -A1
done

step "export -> $E"
xcodebuild -exportArchive -archivePath "$A" -exportOptionsPlist $EXPORT_OPTIONS -exportPath "$E" || die "export"
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
