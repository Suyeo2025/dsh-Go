#!/bin/zsh
# Unsigned iOS compile check, on the Mac. Usage (from whole):
#   tooling/ios/sync-to-mac.sh && ssh macstudio 'zsh ~/Workspace/dsh-go/src/tooling/ios/build-nocodesign.sh [debug|release]'
# Log: ~/Workspace/dsh-go/logs/build-<mode>.log (also streamed to stdout).
set -uo pipefail
source ${0:A:h}/env.sh
MODE=${1:-release}
LOG=$DG_LOGS/build-$MODE.log
cd $DG_APP || exit 1
{
  echo "--- $(date) flutter $(flutter --version 2>/dev/null | head -1)"
  flutter pub get --enforce-lockfile && \
  BN=$(date +%Y%m%d%H%M); VNAME=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
  flutter build ios --$MODE --no-codesign --build-number "$BN" --dart-define=DSH_APP_VERSION=$VNAME+$BN
  echo "BUILD_RC=$?"
  echo "--- done $(date)"
} 2>&1 | tee $LOG
