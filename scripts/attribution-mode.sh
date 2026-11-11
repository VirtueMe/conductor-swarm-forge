#!/usr/bin/env bash
# The values of config.md's `attribution:` (docs/commit-attribution.md), written once.
#
# Sourced (not executed), by swarm-start.sh, attribution-trailer.sh and the claude-code adapter. A
# new mode is added to ATTRIBUTION_MODES here, and each caller's own handling of it (a `case` on the
# mode) is what is left to write. It defines:
#
#   ATTRIBUTION_MODES          the valid values, space-separated
#   ATTRIBUTION_DEFAULT        the one used when config.md has no value; it is one of them
#   attribution_valid <value>  returns 0 if <value> is one of them
#   attribution_mode <dir>     print the mode in <dir>/config.md: the default when the key is absent
#                              or empty. It does not check the value; a caller decides what a bad
#                              one means (a merge refuses it, a launch warns and goes on)

# shellcheck source=scripts/config-field.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config-field.sh"

ATTRIBUTION_MODES="trailer none"
ATTRIBUTION_DEFAULT=trailer

attribution_valid() { # <value>
  local m
  for m in $ATTRIBUTION_MODES; do [[ "${1:-}" == "$m" ]] && return 0; done
  return 1
}

attribution_mode() { # <dir>
  local mode
  mode="$(CONDUCTOR_DIR="${1:-}" config_field attribution)"
  echo "${mode:-$ATTRIBUTION_DEFAULT}"
}
