#!/usr/bin/env bash
# Claim a work-artifact file name that no earlier artifact has taken.
#
# Artifacts are named <type>-<YYYYMMDD-HHMMSS>.md, so two artifacts of one type
# for one task in the same second would share a name and the second would
# overwrite the first. Readers depend on the name format and on names within a
# type sorting in arrival order (worker-spawn.sh takes the last merge-*.md and
# review-*.md as the latest; artifact-ledger.sh orders by the text after the
# type). A suffix such as -2 would sort before the unsuffixed name, so the format
# stays as it is and a collision waits for the next second instead.
#
# Sourced (not executed). It defines one function:
#
#   artifact_claim <dir> <type>
#     Creates an empty <dir>/<type>-<timestamp>.md that did not exist, atomically
#     (noclobber opens with O_EXCL), and sets ARTIFACT and TIMESTAMP in the
#     caller's shell. If the name is taken it sleeps a second and stamps again,
#     so TIMESTAMP is always the time the artifact was claimed. Any failure other
#     than "already exists" (a missing or unwritable directory) returns 1.
#     The caller writes the content to $ARTIFACT afterwards, so build the content
#     first and claim last: until it is written the artifact is an empty file.
#
#     It gives up after ARTIFACT_CLAIM_TRIES attempts (default 10) and returns 1.
#     A clock that stepped backwards leaves artifacts with future timestamps, and
#     waiting for it to catch up would hang the caller without saying why.

artifact_claim() {
  local dir="$1" type="$2" tries="${ARTIFACT_CLAIM_TRIES:-10}" attempt=0
  while (( attempt < tries )); do
    attempt=$(( attempt + 1 ))
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    ARTIFACT="$dir/${type}-${TIMESTAMP}.md"
    if ( set -o noclobber; : > "$ARTIFACT" ) 2>/dev/null; then
      return 0
    fi
    [[ -e "$ARTIFACT" ]] || { echo "artifact_claim: cannot create $ARTIFACT" >&2; return 1; }
    sleep 1
  done
  echo "artifact_claim: no free name for '$type' in $dir after $tries attempts; is the clock behind?" >&2
  return 1
}
