#!/usr/bin/env bash

resolve_path() {
  local target="$1"

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    echo "Error: path does not exist: $target" >&2
    return 1
  fi

  while [ -L "$target" ]; do
    local link_target
    link_target="$(readlink "$target")"
    if [[ "$link_target" = /* ]]; then
      target="$link_target"
    else
      target="$(dirname "$target")/$link_target"
    fi
  done

  local target_dir
  target_dir="$(cd "$(dirname "$target")" && pwd -P)"
  printf '%s/%s\n' "$target_dir" "$(basename "$target")"
}