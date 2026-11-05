#!/usr/bin/env bash
# Merge the upstream Android project (ccch1mneyyy/dsh-Go main) into the iOS branch.
#
#   tooling/ios/sync-upstream.sh            fetch + merge upstream/main into the current branch
#   tooling/ios/sync-upstream.sh --check    only report how far behind upstream we are
#
# Merges (never rebases) so the pushed `ios` branch history is never rewritten. Stops on
# conflicts and leaves them for a human; after a clean merge it re-checks the generated
# inputs the iOS port touches (l10n, plugin skill) and runs `flutter analyze`.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
flutter=${FLUTTER:-$HOME/sdk/flutter-3.47.7/bin/flutter}
upstream_url=https://github.com/ccch1mneyyy/dsh-Go.git

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$upstream_url"
git fetch --quiet upstream main

behind=$(git rev-list --count HEAD..upstream/main)
echo "behind upstream/main by $behind commit(s)"
[[ ${1:-} == --check ]] && exit 0
((behind == 0)) && exit 0

if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
  echo "working tree has uncommitted changes; commit or stash them first" >&2
  exit 1
fi

if ! git merge --no-edit upstream/main; then
  echo "merge conflicts — resolve them, then: git commit" >&2
  git diff --name-only --diff-filter=U >&2
  exit 1
fi

python3 app/tool/l10n_merge.py --check
node sdk/plugin-kit/scripts/sync-skill.mjs --check
# App Store rejects bundled files that start with `#!` (ITMS-90035).
for f in $(git ls-files app/assets); do
  [[ $(head -c2 "$f" 2>/dev/null) == '#!' ]] && { echo "shebang asset: $f" >&2; exit 1; }
done
(cd app && "$flutter" pub get --enforce-lockfile >/dev/null && "$flutter" analyze)
echo "merged upstream/main; review, run tests, then push"
