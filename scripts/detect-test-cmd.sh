#!/usr/bin/env bash
# Detects the test command for a project directory.
# Prints the command to stdout, or nothing if undetectable.
#
# Usage:
#   detect-test-cmd.sh [target-dir] [--lang <language>]
#
# Priority:
#   1. Project file sniffing (most reliable)
#   2. --lang fallback (when no project files found yet)

set -euo pipefail

TARGET_DIR="."
LANG_HINT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang|-l) LANG_HINT="$2"; shift 2 ;;
    *)         TARGET_DIR="$1"; shift ;;
  esac
done

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

has() { [[ -f "$TARGET_DIR/$1" ]]; }
dir() { [[ -d "$TARGET_DIR/$1" ]]; }

# Read a field from package.json without jq
pkg_test_script() {
  local pkg="$TARGET_DIR/package.json"
  [[ -f "$pkg" ]] || return
  python3 -c "
import json, sys
d = json.load(open('$pkg'))
s = d.get('scripts', {}).get('test', '')
if s and s != 'echo \"Error: no test specified\" && exit 1':
    print(s)
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Project file sniffing
# ---------------------------------------------------------------------------

# Clojure
if has "project.clj"; then
  echo "lein test"; exit 0
fi
if has "deps.edn"; then
  # Check for a :test alias
  if grep -q ':test' "$TARGET_DIR/deps.edn" 2>/dev/null; then
    echo "clj -T:test"; exit 0
  fi
  echo "clj -M:test"; exit 0
fi

# Rust
if has "Cargo.toml"; then
  echo "cargo test"; exit 0
fi

# Go
if has "go.mod"; then
  echo "go test ./..."; exit 0
fi

# Elixir
if has "mix.exs"; then
  echo "mix test"; exit 0
fi

# Ruby — check for test framework before falling back
if has "Gemfile"; then
  if dir "spec"; then
    echo "bundle exec rspec"; exit 0
  fi
  if dir "test"; then
    echo "bundle exec rake test"; exit 0
  fi
  echo "bundle exec rake test"; exit 0
fi

# Python — check for pytest config or test dir
if has "pyproject.toml" || has "pytest.ini" || has "setup.cfg"; then
  echo "pytest"; exit 0
fi
if dir "tests" || dir "test"; then
  if has "pyproject.toml" || has "setup.py" || has "requirements.txt"; then
    echo "pytest"; exit 0
  fi
fi

# Java — Maven before Gradle
if has "pom.xml"; then
  echo "mvn test"; exit 0
fi
if has "build.gradle.kts"; then
  echo "./gradlew test"; exit 0
fi
if has "build.gradle"; then
  echo "./gradlew test"; exit 0
fi

# JavaScript / TypeScript — read scripts.test from package.json
if has "package.json"; then
  CMD=$(pkg_test_script)
  if [[ -n "$CMD" ]]; then
    echo "$CMD"; exit 0
  fi
  # Fallback: detect runner from devDependencies
  if grep -q '"jest"' "$TARGET_DIR/package.json" 2>/dev/null; then
    echo "npx jest"; exit 0
  fi
  if grep -q '"vitest"' "$TARGET_DIR/package.json" 2>/dev/null; then
    echo "npx vitest run"; exit 0
  fi
  if grep -q '"mocha"' "$TARGET_DIR/package.json" 2>/dev/null; then
    echo "npx mocha"; exit 0
  fi
  echo "npm test"; exit 0
fi

# Makefile with a test target
if has "Makefile" && grep -q '^test:' "$TARGET_DIR/Makefile" 2>/dev/null; then
  echo "make test"; exit 0
fi

# ---------------------------------------------------------------------------
# Language fallback (no project files found)
# ---------------------------------------------------------------------------

case "$(echo "$LANG_HINT" | tr '[:upper:]' '[:lower:]')" in
  clojure|clj)              echo "lein test" ;;
  rust)                     echo "cargo test" ;;
  go|golang)                echo "go test ./..." ;;
  elixir)                   echo "mix test" ;;
  ruby|rb)                  echo "bundle exec rspec" ;;
  python|py)                echo "pytest" ;;
  javascript|js|typescript|ts|node) echo "npm test" ;;
  java)                     echo "mvn test" ;;
  kotlin)                   echo "./gradlew test" ;;
  *)                        ;; # nothing detected
esac
