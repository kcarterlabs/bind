#!/usr/bin/env bash
# One stop: validate, commit, push, watch CI build and push the image to
# ECR, dry-run, deploy. Stops at the first thing that fails, before anything
# after it happens.
#
#   scripts/release.sh [-m "commit message"] [-y]
#   make release MSG="dns: add foo" [YES=1]
#
#   -m  commit message for uncommitted changes (asked for if needed)
#   -y  don't ask: commit what's there and deploy after a clean `make check`
#
# Safe to re-run: with nothing to commit or push it picks up at CI (an
# already-finished run returns at once) and carries on to check and deploy.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

MSG="${MSG:-}"
YES="${YES:-}"
while getopts "m:y" opt; do
  case $opt in
    m) MSG=$OPTARG ;;
    y) YES=1 ;;
    *) echo "usage: $0 [-m message] [-y]" >&2; exit 2 ;;
  esac
done

WORKFLOW=docker-build.yml
REPO=kcarterlabs/bind
REGION=us-west-2

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mStopped: %s\033[0m\n' "$*" >&2; exit 1; }
confirm() {  # question; true if yes
  [ -n "$YES" ] && return 0
  local a; read -rp "$1 [y/N] " a; [[ $a =~ ^[Yy] ]]
}

# ------------------------------------------------------------ preconditions
step "Preconditions"
for tool in git gh aws ansible-playbook docker dig; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
branch=$(git branch --show-current)
[ "$branch" = main ] || die "on branch '$branch'. CI only builds and pushes to ECR from main."
git fetch --quiet origin main
behind=$(git rev-list --count HEAD..origin/main)
[ "$behind" = 0 ] || die "origin/main has $behind commit(s) this checkout doesn't. git pull --rebase, then re-run."
echo "main, up to date with origin"

# ----------------------------------------------------------------- validate
step "Validate (what CI will run)"
make --no-print-directory validate

# ----------------------------------------------------------- commit + push
if [ -n "$(git status --porcelain)" ]; then
  step "Commit"
  git status --short
  echo
  git --no-pager diff --stat
  confirm "Commit all of the above?" || die "nothing committed"
  if [ -z "$MSG" ]; then
    [ -n "$YES" ] && die "-y needs -m (or MSG=) for the commit message"
    read -rp "Commit message: " MSG
    [ -n "$MSG" ] || die "empty commit message"
  fi
  git add -A
  git commit --quiet -m "$MSG"
  echo "committed $(git rev-parse --short HEAD): $MSG"
fi

sha=$(git rev-parse HEAD)
if [ "$(git rev-list --count origin/main..HEAD)" != 0 ]; then
  step "Push"
  git push --quiet origin main
  echo "pushed $(git rev-parse --short HEAD) to origin/main"
else
  echo "$(git rev-parse --short HEAD) is already on origin/main"
fi

# ---------------------------------------------------------------------- CI
step "CI: validate, build, push to ECR"
run=""
for _ in $(seq 40); do  # GitHub takes a few seconds to register the run
  run=$(gh run list -R "$REPO" --workflow "$WORKFLOW" --commit "$sha" -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
  [ -n "$run" ] && break
  sleep 3
done
[ -n "$run" ] || die "no CI run appeared for $(git rev-parse --short HEAD) in 2 minutes (gh run list -R $REPO)"
echo "run $run: https://github.com/$REPO/actions/runs/$run"
gh run watch "$run" -R "$REPO" --exit-status --interval 5 >/dev/null \
  || die "CI failed: gh run view $run -R $REPO --log-failed"
echo "CI passed"

tag=$(scripts/image-tag.sh)
aws ecr describe-images --region "$REGION" --repository-name "$REPO" --image-ids "imageTag=$tag" >/dev/null 2>&1 \
  || die "CI passed but $tag isn't in ECR (make ecr-images)"
echo "$REPO:$tag is in ECR"

# -------------------------------------------------------- check + deploy
step "Dry run against every DNS server (make check)"
make --no-print-directory check

confirm "Deploy this to every DNS server, one at a time?" || die "not deployed. Run \`make deploy\` when ready."

step "Deploy (make deploy)"
make --no-print-directory deploy

step "Done"
echo "$(git log -1 --format='%h %s') is live on every DNS server, every record verified on each."
