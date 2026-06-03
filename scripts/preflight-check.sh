#!/usr/bin/env bash
# Checks that all required tools are available before the swarm starts.
# Fails fast with a clear message listing everything that's missing.
#
# Usage: preflight-check.sh [--lang <language>] [--test-cmd <cmd>] [--kanban-server]

set -euo pipefail

LANG_HINT=""
TEST_CMD=""
KANBAN_SERVER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang|-l)        LANG_HINT="$2"; shift 2 ;;
    --test-cmd|-tc)   TEST_CMD="$2";  shift 2 ;;
    --kanban-server|-cbs) KANBAN_SERVER=true; shift ;;
    *) shift ;;
  esac
done

MISSING=()

check() {
  local cmd="$1" reason="$2"
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("  $cmd — $reason")
  fi
}

# ── Always required ──────────────────────────────────────────────────────────
check "tmux"    "session management for agent windows"
check "git"     "worktree creation and branch management"
check "python3" "workforce adapter selection"
check "claude"  "AI agent CLI"

# ── Kanban board ─────────────────────────────────────────────────────────────
if [[ "$KANBAN_SERVER" == true ]]; then
  check "node" "kanban board server (kanban-board.js)"
fi

# ── Language toolchain ───────────────────────────────────────────────────────
case "$(echo "${LANG_HINT:-}" | tr '[:upper:]' '[:lower:]')" in
  clojure|clj)
    check "lein" "Clojure project management (leiningen)"
    ;;
  typescript|javascript|js|ts|node)
    check "node" "Node.js runtime"
    check "npm"  "Node.js package manager"
    ;;
  ruby|rb)
    check "ruby"   "Ruby runtime"
    check "bundle" "Ruby dependency manager (bundler)"
    ;;
  python|py)
    check "python3" "Python runtime"
    ;;
  rust)
    check "cargo" "Rust build tool and package manager"
    ;;
  go|golang)
    check "go" "Go toolchain"
    ;;
  elixir)
    check "mix"   "Elixir build tool"
    check "elixir" "Elixir runtime"
    ;;
  java)
    check "java" "Java runtime"
    ;;
  kotlin)
    check "kotlin" "Kotlin compiler"
    ;;
esac

# ── Test command tool ────────────────────────────────────────────────────────
if [[ -n "$TEST_CMD" ]]; then
  # Extract the base executable (first word, handle "bundle exec rspec" → bundle)
  TEST_BIN=$(echo "$TEST_CMD" | awk '{print $1}')
  check "$TEST_BIN" "test runner (from --test-cmd)"
fi

# ── Report ───────────────────────────────────────────────────────────────────
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Preflight check failed — missing tools:" >&2
  for m in "${MISSING[@]}"; do
    echo "$m" >&2
  done
  exit 1
fi

echo "Preflight check passed."
