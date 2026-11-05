#!/usr/bin/env bash
# iOS simulator smoke test, from whole: sync, then app/integration_test/ios_smoke_test.dart on a
# dedicated simulator on the Mac (tooling/ios/sim-smoke-mac.zsh).
#
#   tooling/ios/sim-smoke.sh                 # with a real direct host (see below)
#   tooling/ios/sim-smoke.sh --offline       # no real host: first run skipped via SharedPreferences
#   tooling/ios/sim-smoke.sh --keep          # keep the simulator device afterwards
#   tooling/ios/sim-smoke.sh --ipad          # iPad Pro 13-inch instead of iPhone (logs/sim-smoke-ipad/)
#   tooling/ios/sim-smoke.sh --no-sync
#
# Real host: SMOKE_URL (tooling/ios/local.env, or the environment) with the launch token from the last
# "dsh web: …token=" line of ~/.dsh/run/stdout.log. The token goes to the Mac only as a 0600 file
# in a 0700 temp dir, handed to flutter via --dart-define-from-file, and deleted on exit. It is
# never printed.
#
# Results on the Mac: ~/Workspace/dsh-go/logs/sim-smoke[-ipad]/ (NNN-<step>.png, report.json, run.log).
# Exit code = the test's.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC_HOST="${MAC_HOST:-macstudio}"
LIVE=1; SYNC=1; MAC_ARGS=()
for a in "$@"; do
  case "$a" in
    --offline) LIVE=0 ;;
    --keep|--ipad) MAC_ARGS+=("$a") ;;
    --no-sync) SYNC=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

(( SYNC )) && "$ROOT/tooling/ios/sync-to-mac.sh"

REMOTE_DIR=""
# The Mac half deletes the defines dir itself when it ends; this is for a failure before it starts.
cleanup() { [[ -n $REMOTE_DIR && ${STARTED:-0} == 0 ]] && ssh "$MAC_HOST" "rm -rf '$REMOTE_DIR'" || true; }
trap cleanup EXIT

ENV_PREFIX=""
if (( LIVE )); then
  if [[ -z ${SMOKE_URL:-} && -f "$ROOT/tooling/ios/local.env" ]]; then
    SMOKE_URL=$(sed -n 's/^SMOKE_URL=//p' "$ROOT/tooling/ios/local.env" | tail -1)
  fi
  [[ -n ${SMOKE_URL:-} ]] || { echo "SMOKE_URL is not set: add it to tooling/ios/local.env (or use --offline)" >&2; exit 2; }
  [[ $SMOKE_URL =~ ^https?://[A-Za-z0-9.:/_-]+$ ]] || { echo "SMOKE_URL is not a plain http(s) URL" >&2; exit 2; }
  TOKEN=$(grep -o 'dsh web: [^ ]*token=[^ &"]*' "$HOME/.dsh/run/stdout.log" | tail -1 | sed 's/.*token=//')
  [[ -n $TOKEN ]] || { echo "no 'dsh web: …token=' line in ~/.dsh/run/stdout.log" >&2; exit 1; }
  [[ $TOKEN =~ ^[A-Za-z0-9._~-]+$ ]] || { echo "unexpected token characters" >&2; exit 1; }
  REMOTE_DIR=$(ssh "$MAC_HOST" 'umask 077; mktemp -d /tmp/dsh-go-smoke.XXXXXX')
  printf '{"SMOKE_DIRECT_URL":"%s","SMOKE_DIRECT_TOKEN":"%s"}\n' "$SMOKE_URL" "$TOKEN" |
    ssh "$MAC_HOST" "umask 077; cat > '$REMOTE_DIR/defines.json'; chmod 600 '$REMOTE_DIR/defines.json'"
  unset TOKEN
  ENV_PREFIX="SMOKE_DEFINES='$REMOTE_DIR/defines.json'"
fi

# Detached on the Mac, so a dropped ssh connection doesn't kill the run; followed by polling.
LOG='~/Workspace/dsh-go/logs/sim-smoke.out'
# The Mac's sshd sometimes resets a connection under load: retry the launch (it starts nothing
# unless the whole command ran), and drop the previous run's log first so it is never read as this one's.
for try in 1 2 3 4 5; do
  ssh -o ConnectTimeout=20 "$MAC_HOST" "rm -f $LOG; $ENV_PREFIX nohup zsh ~/Workspace/dsh-go/src/tooling/ios/sim-smoke-mac.zsh ${MAC_ARGS[*]:-} </dev/null >$LOG 2>&1 &" && break
  (( try == 5 )) && { echo "could not start the run on $MAC_HOST" >&2; exit 1; }
  sleep 10
done
STARTED=1
echo "running on $MAC_HOST, log $LOG"
SEEN=0
while :; do
  sleep 15
  OUTPUT=$(ssh -o ConnectTimeout=20 "$MAC_HOST" "tail -n +$((SEEN + 1)) $LOG" 2>/dev/null) || continue
  if [[ -n $OUTPUT ]]; then
    printf '%s\n' "$OUTPUT" | grep -E 'SMOKE_|^--- |^device |files in|no report' || true
    SEEN=$((SEEN + $(printf '%s\n' "$OUTPUT" | wc -l)))
  fi
  RC=$(printf '%s\n' "$OUTPUT" | sed -n 's/^SMOKE_RC=//p' | tail -1)
  [[ -n $RC ]] && exit "$RC"
done
