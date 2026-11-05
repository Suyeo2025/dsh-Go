#!/bin/zsh
# Mac half of tooling/ios/sim-islands.sh: sim-smoke-mac.zsh with --islands (same defines handling,
# simulator lifecycle and token scrubbing). Usage: SMOKE_DEFINES=<0600 json> zsh sim-islands-mac.zsh [--ipad] [--keep]
exec zsh ${0:A:h}/sim-smoke-mac.zsh --islands "$@"
