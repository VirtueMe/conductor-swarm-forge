#!/usr/bin/env bash
# YAML-frontmatter readers for the swarm's task and artifact files.
#
# Sourced (not executed). Same field and list syntax as task-replay.sh, with one
# difference: fm_body drops only the two frontmatter fences, so a markdown rule
# (---) inside the body survives.
#
#   fm_field <file> <field>   print a scalar field
#   fm_list  <file> <field>   print a list field, one item per line
#   fm_body  <file>           print everything after the frontmatter

fm_field() {
  awk 'BEGIN{f=0} /^---$/{f++; next} f==1 && /^'"$2"': /{sub(/^'"$2"': /,""); print; exit}' "$1"
}

fm_list() {
  awk 'BEGIN{f=0; found=0} /^---$/{f++; next} f==1 && /^'"$2"':/{found=1; next} found && /^  - /{sub(/^  - /,""); print; next} found && !/^  /{exit}' "$1"
}

fm_body() {
  awk 'BEGIN{f=0} f<2 && /^---$/{f++; next} f>=2{print}' "$1"
}
