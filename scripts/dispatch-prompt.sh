#!/usr/bin/env bash
# What an adapter_dispatch hands to a model for one conductor event, and how it
# reads the answer back.
#
# Sourced (not executed). The three adapters share this so the contract lives in one
# place. It defines:
#
#   dispatch_prompt <skill_content> <event>
#     <event> is an artifact path, or the word "startup" for the reconcile the loop runs
#     first, which has no artifact and no task. Prints the prompt: the static briefing ($CONDUCTOR_DIR/prompts/conductor.prompt)
#     first so prompt caching can hit it, then the rules for a dispatched run, then the
#     skill, then the event. Returns 1 if the briefing is missing.
#
#   dispatch_final_exit <final_message>
#     Returns 1 if the last non-empty line of the model's final message starts with
#     HANDLER-FAILED:, otherwise 0. An adapter calls it on the final message and exits
#     with the result, so a model that stops on a failing script is a failed dispatch.
#
# The HANDLER-FAILED line is a convention the model has to follow. An exit code cannot
# tell the loop that a model carried on after a guard script failed (the spike found
# this: a failing task-locks.sh was read as "locks free"). It is a mitigation, not a
# guarantee. Phase 2 moves the guards into code that fails closed.

DISPATCH_FAILED_MARKER="HANDLER-FAILED:"

dispatch_prompt() {
  local skill_content="${1:?Usage: dispatch_prompt <skill_content> <event>}"
  local event="${2:?Usage: dispatch_prompt <skill_content> <event>}"
  local briefing="${CONDUCTOR_DIR:?CONDUCTOR_DIR is not set}/prompts/conductor.prompt"
  [[ -f "$briefing" ]] || { echo "dispatch_prompt: no briefing at $briefing" >&2; return 1; }

  cat "$briefing"
  printf '\n\n---\n\n## This is one dispatched event\n\n'
  printf 'You are handling a single event, not running the conductor. Ignore the Startup and\n'
  printf 'Watch loop sections of the briefing above. Do only what the skill below says.\n\n'
  if [[ "$event" == "startup" ]]; then
    printf 'The scripts are on PATH and CONDUCTOR_DIR is set in your shell environment.\n\n'
  else
    printf 'The scripts are on PATH. CONDUCTOR_DIR, TASK_ID, TASK_FILE and ARTIFACT are set in\n'
    printf 'your shell environment.\n\n'
  fi
  printf 'If any script exits non-zero, or a check the skill tells you to make cannot be\n'
  printf 'completed, stop at once and change nothing further. Make your final line:\n'
  printf '%s <one-line reason>\n' "$DISPATCH_FAILED_MARKER"
  printf 'Otherwise finish with one line saying what you did.\n\n'
  printf '## Skill to run\n\n%s\n\n' "$skill_content"
  if [[ "$event" == "startup" ]]; then
    printf '## The event\n\nStartup reconcile. There is no artifact and no task.\n'
  else
    printf '## The event\n\nArtifact: %s\nTask: %s\n' "$event" "${TASK_ID:-unknown}"
  fi
}

dispatch_final_exit() {
  local last
  last="$(printf '%s\n' "$1" | awk 'NF{l=$0} END{print l}')"
  [[ "$last" == "$DISPATCH_FAILED_MARKER"* ]] && return 1
  return 0
}
