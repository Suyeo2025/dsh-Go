#!/usr/bin/env bash
# Sync this checkout to the Mac build host, or pull app/ios back from it.
#
#   tooling/ios/sync-to-mac.sh            # push src -> mac (app/ios included: whole is the source of truth)
#   tooling/ios/sync-to-mac.sh --pull-ios # pull mac app/ios -> whole (after regenerating/editing it on the Mac)
#   tooling/ios/sync-to-mac.sh --dry-run  # show what would change
#
# Env: MAC_HOST (default macstudio), MAC_DIR (default Workspace/dsh-go/src, relative to the Mac $HOME).
#
# The whole -> Mac link is slow. For an empty Mac tree, seed it from GitHub first so rsync only
# sends deltas (--checksum skips identical files regardless of mtime):
#   ssh macstudio 'cd ~/Workspace/dsh-go && git clone -q --depth 1 https://github.com/Suyeo2025/dsh-Go.git seed \
#     && rsync -a --exclude=.git seed/ src/ && rm -rf seed'
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC_HOST="${MAC_HOST:-macstudio}"
MAC_DIR="${MAC_DIR:-Workspace/dsh-go/src}"

MODE=push
RSYNC_EXTRA=()
for a in "$@"; do
  case "$a" in
    --pull-ios) MODE=pull-ios ;;
    --dry-run|-n) RSYNC_EXTRA+=(--dry-run --itemize-changes) ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# Build output, tool state and host-local files that must never travel either way.
EXCLUDES=(
  --exclude=.git
  --exclude=failures/
  --exclude=.dart_tool/
  --exclude=build/
  --exclude=.gradle/
  --exclude=app/android/.gradle/
  --exclude=app/android/local.properties
  --exclude=Pods/
  --exclude=.symlinks/
  --exclude=Flutter/ephemeral/
  --exclude=Flutter/Generated.xcconfig
  --exclude=Flutter/flutter_export_environment.sh
  --exclude=Flutter/.last_build_id
  --exclude='GeneratedPluginRegistrant.*'
  --exclude=xcuserdata/
  --exclude=DerivedData/
  --exclude=.flutter-plugins-dependencies
  --exclude=.flutter-plugins
  --exclude=node_modules/
  --exclude=runtime/.cache/
  --exclude='runtime/out*/'
  --exclude=runtime/.work/
  --exclude=app/test/promo_capture/
  --exclude=.harness-tmp*/
  --exclude=.claude/
  --exclude=/dist/
  --exclude=.DS_Store
  --exclude='*.apk'
  --exclude='*.aab'
  --exclude='*.ipa'
  --exclude='*.xcarchive'
)

ssh "$MAC_HOST" "mkdir -p \"\$HOME/$MAC_DIR\""

if [[ "$MODE" == push ]]; then
  # --delete keeps the Mac mirror exact; excluded paths (Pods, build, ...) are left alone.
  # Everything git ignores (build outputs, golden-test failures/, logs, ...), per directory.
  # Push only: the Mac's rsync (the sender on --pull-ios) can't parse .gitignore patterns.
  rsync -az --delete --checksum --filter=':- .gitignore' "${RSYNC_EXTRA[@]}" "${EXCLUDES[@]}" "$ROOT/" "$MAC_HOST:$MAC_DIR/"
  # local.env is git-ignored (account values), so the filter above skips it: copy it on its own.
  if [[ -f "$ROOT/tooling/ios/local.env" ]]; then
    rsync -a --chmod=F600 "${RSYNC_EXTRA[@]}" "$ROOT/tooling/ios/local.env" "$MAC_HOST:$MAC_DIR/tooling/ios/local.env"
  else
    echo "note: no tooling/ios/local.env (see local.env.example); the Mac scripts need one" >&2
  fi
  echo "pushed $ROOT -> $MAC_HOST:~/$MAC_DIR"
else
  mkdir -p "$ROOT/app/ios"
  rsync -az --delete "${RSYNC_EXTRA[@]}" "${EXCLUDES[@]}" "$MAC_HOST:$MAC_DIR/app/ios/" "$ROOT/app/ios/"
  echo "pulled $MAC_HOST:~/$MAC_DIR/app/ios -> $ROOT/app/ios"
fi
