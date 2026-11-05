# Shared settings for the iOS scripts. Sourced (zsh) on the Mac build host.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
# Pinned Flutter (matches the Android toolchain); never the homebrew one.
export FLUTTER_ROOT=$HOME/sdk/flutter-3.47.7
export PATH=$FLUTTER_ROOT/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export DG_WS=$HOME/Workspace/dsh-go          # Mac workspace
export DG_SRC=$DG_WS/src                      # rsync target of tooling/ios/sync-to-mac.sh
export DG_APP=$DG_SRC/app
export DG_LOGS=$DG_WS/logs
export DG_BUILD=$DG_WS/build                  # archives / exports (outside the synced tree)
export DG_BUNDLE_ID=com.colex.dshgo
export DG_PROFILE_NAME="dg com.colex.dshgo"
export DG_TEAM=4JV8BHB2KW

# Account-specific values: tooling/ios/local.env (not in git; template local.env.example).
DG_LOCAL_ENV=${${(%):-%x}:A:h}/local.env
if [[ ! -f $DG_LOCAL_ENV ]]; then
  echo "missing $DG_LOCAL_ENV (copy local.env.example and fill it in)" >&2
  return 1 2>/dev/null || exit 1
fi
set -a; source $DG_LOCAL_ENV; set +a
for v in ASC_KEY_ID ASC_ISSUER DG_CERT_ID DG_DEV_CERT_ID DG_KC DG_KC_PASS_FILE DG_TF_TESTERS; do
  if [[ -z ${(P)v:-} ]]; then
    echo "$v is not set in $DG_LOCAL_ENV" >&2
    return 1 2>/dev/null || exit 1
  fi
done
mkdir -p $DG_LOGS $DG_BUILD
