#!/bin/bash
# Ships a new version:   tools/release.sh 1.0.2
#   1. checks you're on a clean, up-to-date main and CHANGELOG.md has a "## [1.0.2]" section, then runs
#      tools/regress.sh (and asks you to confirm its contact sheet looks right) and tools/update-test.sh --quick
#   2. writes VERSION, commits "Release 1.0.2", tags v1.0.2 and pushes both
#   3. GitHub Actions (.github/workflows/release.yml) builds, signs and publishes the release; every installed copy
#      picks it up on its next check (launch, or every 6 h) and installs it while the screen is locked.
set -euo pipefail
cd "$(dirname "$0")/.."
v="${1:-}"; [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: tools/release.sh X.Y.Z"; exit 1; }
cur=$(tr -d ' \n' < VERSION)
[ "$(printf '%s\n%s\n' "$cur" "$v" | sort -V | tail -1)" = "$v" ] && [ "$v" != "$cur" ] || { echo "✗ $v isn't newer than $cur"; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "✗ not on main"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "✗ uncommitted changes"; exit 1; }
git fetch -q origin main && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "✗ main isn't in sync with origin/main"; exit 1; }
grep -q "^## \[$v\]" CHANGELOG.md || { echo "✗ add a '## [$v]' section to CHANGELOG.md first"; exit 1; }
git rev-parse -q --verify "refs/tags/v$v" >/dev/null && { echo "✗ tag v$v already exists"; exit 1; }
./build.sh >/dev/null && bash tools/check-pages.sh >/dev/null && echo "✓ builds"
# the regression suite (every wall, three displays, the Settings window under stress): no tag unless it passes.
# TIDEWALL_SKIP_REGRESS=1 skips it, for a release that changes nothing the suite runs (say, only the workflow)
if [ "${TIDEWALL_SKIP_REGRESS:-}" = 1 ]; then echo "⚠ regression suite skipped (TIDEWALL_SKIP_REGRESS=1)"
else tools/regress.sh || { echo "✗ the regression suite failed: no release"; exit 1; }
  tools/update-test.sh --quick || { echo "✗ the update test failed: no release (this version might not update the next)"; exit 1; }
  read -r -p "Looked at the contact sheet above, and it's all right? [y/N] " ok || ok=""   # (no terminal: no)
  [ "$ok" = y ] || [ "$ok" = Y ] || { echo; echo "✗ not released (answer y once you've looked at the sheet)"; exit 1; }
fi
echo "$v" > VERSION
git add VERSION && git commit -q -m "Release $v" && git tag -a "v$v" -m "Tidewall $v"
git push -q origin main "v$v"
echo "✓ v$v pushed. GitHub Actions is building and publishing it:"
echo "  https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/](.*)\.git#\1#')/actions"
