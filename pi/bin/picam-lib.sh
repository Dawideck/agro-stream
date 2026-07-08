#!/usr/bin/env bash
# Shared helpers — sourced by capture-gate.sh and upload.sh.
# Do NOT execute directly; this file only defines functions.

# Convert HH:MM to total minutes since midnight.
# 10# prefix forces decimal interpretation (avoids octal for 08, 09).
_to_min() {
  local h="${1%%:*}" m="${1##*:}"
  printf '%d' $(( 10#$h * 60 + 10#$m ))
}

# _in_window HH:MM → exits 0 if the time falls inside the capture window.
# Reads WINDOW_START and WINDOW_END from the environment.
_in_window() {
  local t="${1:-00:00}" s e n
  s=$(_to_min "${WINDOW_START:-07:00}")
  e=$(_to_min "${WINDOW_END:-18:00}")
  n=$(_to_min "$t")
  if [ "$s" -le "$e" ]; then
    # Normal window e.g. 07:00–18:00
    [ "$n" -ge "$s" ] && [ "$n" -le "$e" ]
  else
    # Wrap-around window e.g. 21:00–20:00 (crosses midnight)
    [ "$n" -ge "$s" ] || [ "$n" -le "$e" ]
  fi
}
