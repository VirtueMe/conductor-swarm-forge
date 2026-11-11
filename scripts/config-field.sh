#!/usr/bin/env bash
# The one reader of a key in the project's config.md.
#
# Sourced (not executed), by handler-steps.sh and attribution-mode.sh. It sets no traps and no
# options, so an adapter can source it too. It defines:
#
#   config_field <name>   print the value of a key in $CONDUCTOR_DIR/config.md, the whole line after
#                         "name:" without its surrounding spaces. An empty value, a key the file
#                         lacks and no config file all print nothing and return 0: that is "not
#                         configured", a real answer. Only a name that is not a plain key (letters,
#                         digits, - and _) is a failure.

config_field() { # <name>
  if [[ ! "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "config_field: '${1:-}' is not a plain config key" >&2
    return 1
  fi
  [[ -f "$CONDUCTOR_DIR/config.md" ]] || return 0
  # The first "name:" line; no match is not an error. The config has no fixed shape (the loop's
  # own readers take it with or without frontmatter fences), so this reads lines, not frontmatter.
  sed -n "s/^$1:[[:space:]]*//p" "$CONDUCTOR_DIR/config.md" | sed -n '1s/[[:space:]]*$//p'
}
