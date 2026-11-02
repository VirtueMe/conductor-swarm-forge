#!/usr/bin/env bash
# Which script handles a conductor skill.
#
# A handler is a script when one exists, else the skill goes to the model. For the skill
# conductor/on-x the script is <handlers dir>/on-x.sh. This is the one place that says so, for
# conductor-loop.sh (which runs it) and handler-replay.sh (which checks it): a gate that found
# a handler differently from the loop would be checking a script the loop never runs.
#
# Sourced (not executed). It defines one function:
#
#   handler_script <handlers dir> <skill name>   print the path of the script for the skill
#                                                (it need not exist; the caller tests it)

handler_script() { # <handlers dir> <skill name>
  printf '%s/%s.sh\n' "$1" "$(basename "$2")"
}
