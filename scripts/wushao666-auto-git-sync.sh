#!/usr/bin/env bash

set -u
set -o pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT_MESSAGE="chore: auto sync changes"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
PUSH_TIMEOUT_SECONDS="${PUSH_TIMEOUT_SECONDS:-120}"
LOCK_DIR="${TMPDIR:-/tmp}/wushao666-github-io-auto-git-sync.lock"
NOTIFICATION_TITLE="wushao666 自动同步"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

notify() {
  local message="$1"

  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$message\" with title \"$NOTIFICATION_TITLE\"" \
      >/dev/null 2>&1 || true
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing command: $1"
    log "Install fswatch with: brew install fswatch"
    notify "启动失败：缺少 $1，请执行 brew install fswatch"
    exit 1
  fi
}

with_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local lock_pid
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      log "Previous sync is still running; skip this event."
      return 0
    fi

    log "Stale sync lock found; removing it."
    rm -rf "$LOCK_DIR"

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      log "Cannot acquire sync lock; skip this event."
      return 1
    fi
  fi

  printf '%s\n' "$$" >"$LOCK_DIR/pid"

  "$@"
  local status=$?

  rm -rf "$LOCK_DIR"
  return "$status"
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  "$@" &
  local command_pid=$!
  local elapsed=0

  while kill -0 "$command_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      kill "$command_pid" 2>/dev/null || true
      wait "$command_pid" 2>/dev/null || true
      return 124
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$command_pid"
}

sync_changes() {
  if ! cd "$REPO_ROOT"; then
    log "Cannot enter repository: $REPO_ROOT"
    notify "同步失败：无法进入仓库目录"
    return 1
  fi

  if [ -z "$(git status --porcelain)" ]; then
    log "No changes detected by git; skip."
    return 0
  fi

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    log "Cannot push because the repository is in detached HEAD state."
    notify "同步失败：当前处于 detached HEAD，无法推送"
    return 1
  fi

  log "Changes detected; staging files."
  if ! git add -A; then
    log "git add failed."
    notify "同步失败：git add 执行失败"
    return 1
  fi

  if [ -z "$(git status --porcelain)" ]; then
    log "No committable changes after staging; skip."
    return 0
  fi

  log "Creating commit: $COMMIT_MESSAGE"
  if ! git commit -m "$COMMIT_MESSAGE"; then
    log "Commit failed; no reset/rebase/force-push will be performed."
    notify "同步失败：commit 失败，未执行破坏性操作"
    return 1
  fi

  log "Pushing current branch: $branch"
  if ! run_with_timeout "$PUSH_TIMEOUT_SECONDS" git push origin "$branch"; then
    log "Push failed; local commit is preserved."
    notify "同步失败：push 失败或超时，本地 commit 已保留"
    return 1
  fi

  log "Auto sync completed."
  notify "同步完成：已提交并推送 $branch"
}

main() {
  require_command fswatch

  if ! cd "$REPO_ROOT"; then
    log "Cannot enter repository: $REPO_ROOT"
    notify "启动失败：无法进入仓库目录"
    exit 1
  fi
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
