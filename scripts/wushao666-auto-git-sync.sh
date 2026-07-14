#!/usr/bin/env bash

set -u
set -o pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT_MESSAGE="chore: auto sync changes"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
LOCK_DIR="${TMPDIR:-/tmp}/wushao666-github-io-auto-git-sync.lock"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing command: $1"
    log "Install fswatch with: brew install fswatch"
    exit 1
  fi
}

with_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Previous sync is still running; skip this event."
    return 0
  fi

  "$@"
  local status=$?

  rmdir "$LOCK_DIR" 2>/dev/null || true
  return "$status"
}

sync_changes() {
  cd "$REPO_ROOT" || exit 1

  if [ -z "$(git status --porcelain)" ]; then
    log "No changes detected by git; skip."
    return 0
  fi

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    log "Cannot push because the repository is in detached HEAD state."
    return 1
  fi

  log "Changes detected; staging files."
  git add -A

  if [ -z "$(git status --porcelain)" ]; then
    log "No committable changes after staging; skip."
    return 0
  fi

  log "Creating commit: $COMMIT_MESSAGE"
  if ! git commit -m "$COMMIT_MESSAGE"; then
    log "Commit failed; no reset/rebase/force-push will be performed."
    return 1
  fi

  log "Pushing current branch: $branch"
  if ! git push origin "$branch"; then
    log "Push failed; local commit is preserved."
    return 1
  fi

  log "Auto sync completed."
}

main() {
  require_command fswatch

  cd "$REPO_ROOT" || exit 1
  log "Watching repository: $REPO_ROOT"
  log "Debounce: ${DEBOUNCE_SECONDS}s"

  fswatch \
    --one-per-batch \
    --recursive \
    --exclude '(^|/)\.git(/|$)' \
    --exclude '(^|/)\.DS_Store$' \
    "$REPO_ROOT" | while read -r _event; do
      log "File change event received; waiting for debounce window."
      sleep "$DEBOUNCE_SECONDS"
      with_lock sync_changes
    done
}

main "$@"
