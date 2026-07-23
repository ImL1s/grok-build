#!/usr/bin/env bash
# Sync pristine main from upstream, then merge into a sync branch off providers.
# See FORK.md for the branch model and weekly workflow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DATE="$(date +%Y%m%d)"
SYNC_BRANCH="sync/upstream-${DATE}"
PRODUCT_BRANCH="providers"

die() {
  echo "error: $*" >&2
  exit 1
}

require_remote() {
  local name="$1"
  git remote get-url "$name" >/dev/null 2>&1 || die "missing remote '${name}' (expected upstream=xai-org, origin=ImL1s)"
}

echo "==> Checking working tree (tracked files must be clean; untracked OK)"
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "tracked working tree is dirty; commit or stash changes before syncing"
fi

require_remote upstream
require_remote origin

echo "==> Fetching upstream and origin"
git fetch upstream
git fetch origin

echo "==> Fast-forwarding local main from upstream/main"
git checkout main
if ! git merge --ff-only upstream/main; then
  die "could not fast-forward main from upstream/main (main has diverged; do not force-push)"
fi

echo "==> Pushing origin main (ff-only expected; never force)"
git push origin main

if git show-ref --verify --quiet "refs/heads/${PRODUCT_BRANCH}"; then
  :
elif git show-ref --verify --quiet "refs/remotes/origin/${PRODUCT_BRANCH}"; then
  echo "==> Creating local ${PRODUCT_BRANCH} from origin/${PRODUCT_BRANCH}"
  git branch "${PRODUCT_BRANCH}" "origin/${PRODUCT_BRANCH}"
else
  echo "==> ${PRODUCT_BRANCH} missing; creating from current HEAD ($(git rev-parse --short HEAD))"
  git branch "${PRODUCT_BRANCH}" HEAD
fi

echo "==> Creating ${SYNC_BRANCH} from ${PRODUCT_BRANCH}"
if git show-ref --verify --quiet "refs/heads/${SYNC_BRANCH}"; then
  die "branch ${SYNC_BRANCH} already exists; delete it or wait until tomorrow / rename"
fi
git checkout -B "${SYNC_BRANCH}" "${PRODUCT_BRANCH}"

echo "==> Merging main into ${SYNC_BRANCH}"
set +e
git merge --no-edit main
merge_status=$?
set -e

if [[ "${merge_status}" -ne 0 ]]; then
  echo >&2
  echo "error: merge conflicts while merging main into ${SYNC_BRANCH}" >&2
  echo "Resolve conflicts (prefer keeping providers auth/config intent on the watchlist)," >&2
  echo "then: git add -A && git commit" >&2
  echo "Watchlist: see FORK.md" >&2
  echo "After resolving, push and open a PR into ${PRODUCT_BRANCH}." >&2
  exit 1
fi

echo
echo "==> Sync branch ready: ${SYNC_BRANCH}"
echo "    main tip:      $(git rev-parse --short main)"
echo "    providers tip: $(git rev-parse --short "${PRODUCT_BRANCH}")"
echo "    sync tip:      $(git rev-parse --short HEAD)"
echo
echo "Next steps:"
echo "  1. Review hotspot diffs: git log --oneline ${PRODUCT_BRANCH}..main -- \\"
echo "       'crates/codegen/xai-grok-sampler/**' \\"
echo "       'crates/codegen/xai-grok-shell/src/agent/**' \\"
echo "       'crates/codegen/xai-grok-pager/**'"
echo "  2. Run auth/config smoke tests (sampler none_scheme_ / shell auth_method)."
echo "  3. Push and open a PR into ${PRODUCT_BRANCH}:"
echo
echo "       git push -u origin ${SYNC_BRANCH}"
echo

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  cat <<EOF
  Or create the PR now:

       gh pr create --base ${PRODUCT_BRANCH} --head ${SYNC_BRANCH} \\
         --title "chore: sync upstream ${DATE}" \\
         --body "\$(cat <<'PRBODY'
## Upstream sync
- Mirror: \`main\` ff-only from upstream
- Strategy: merge into \`${PRODUCT_BRANCH}\`

## Hotspot review
- [ ] sampler AuthScheme / client
- [ ] shell config / credentials / auth_method
- [ ] pager /model + picker

## Verify
- [ ] multi-provider auth
- [ ] local auth_scheme=none
PRBODY
)"

EOF
else
  echo "  (gh unavailable or not authenticated; push then open a PR into ${PRODUCT_BRANCH} in the browser.)"
  echo
fi

echo "Done. Do not force-push main."
