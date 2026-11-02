#!/usr/bin/env bash
# realpath.sh — realpath_m, a `realpath -m` that also runs on macOS.
# Sourcing defines functions only.
# shellcheck shell=bash

# realpath_m PATH — print PATH the way GNU `realpath -m` does: absolute, with
# every symlink resolved and `.` and `..` folded, even when the end of the path
# does not exist yet. GNU realpath does the work when it has -m. Otherwise (BSD
# realpath on macOS, BusyBox) the path is walked one component at a time from
# the physical working directory, and each symlink met on the way is replaced
# by its target, so `..` after a symlink leaves from the target, as in GNU.
realpath_m() {
  local p="$1" r out="" part link hops=0
  # Only a success counts: BusyBox reads -m as a file name, prints what it
  # can resolve and exits 1.
  if r="$(realpath -m -- "$p" 2>/dev/null)"; then
    printf '%s\n' "$r"
    return 0
  fi
  [[ "$p" == /* ]] || p="$(pwd -P)/$p"
  p="${p}/"
  while [[ -n "$p" ]]; do
    part="${p%%/*}"
    p="${p#*/}"
    case "$part" in
      ''|.) continue ;;
      ..) out="${out%/*}"; continue ;;
    esac
    # At most 40 symlinks, as on Linux, so a loop ends.
    if [[ -L "${out}/${part}" && $hops -lt 40 ]] && link="$(readlink "${out}/${part}")"; then
      hops=$((hops + 1))
      [[ "$link" == /* ]] && out=""
      p="${link}/${p}"
      continue
    fi
    out="${out}/${part}"
  done
  printf '%s\n' "${out:-/}"
}
