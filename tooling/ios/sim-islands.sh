#!/usr/bin/env bash
# iOS islands check, from whole: app/integration_test/ios_islands_test.dart on a throwaway
# simulator against the real direct host (SMOKE_URL + the launch token, exactly as sim-smoke.sh).
#
#   tooling/ios/sim-islands.sh [--ipad] [--keep] [--no-sync]
#
# Results on the Mac: ~/Workspace/dsh-go/logs/sim-islands[-ipad]/ (NNN-<seat>.png, islands.json,
# run.log). The Mac half is sim-islands-mac.zsh (sim-smoke-mac.zsh --islands).
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sim-smoke.sh" --islands "$@"
