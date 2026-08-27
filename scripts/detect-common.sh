#!/usr/bin/env bash
# Prints whichever common project-folder names exist under $HOME, one per
# line, for the panel's "Detect" button — a quick way to seed search folders
# without having to know/type the exact path.
set -uo pipefail

candidates=(
  RubymineProjects
  Code
  code
  Projects
  projects
  dev
  Dev
  src
  Work
  work
  Sites
  Developer
)

for name in "${candidates[@]}"; do
  dir="$HOME/$name"
  [[ -d "$dir" ]] && echo "$dir"
done
