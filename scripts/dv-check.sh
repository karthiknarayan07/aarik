#!/usr/bin/env bash
# Counts video frames and how many carry a Dolby Vision RPU (per-frame metadata).
# Prints: frames=<N> nb_frames=<frame count the stream declares, or N/A> rpu_frames=<M> config=<profile/level/compat>
# Exit 0 only if N > 0, every frame has an RPU, N matches nb_frames (when declared) and ffprobe reported no
# errors. Dev-only: needs ffprobe (brew install ffmpeg).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: dv-check.sh <video file>" >&2
  exit 1
fi
file=$1
if [[ ! -f $file ]]; then
  echo "dv-check: file not found: $file" >&2
  exit 1
fi
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "dv-check: ffprobe not found. Install it with: brew install ffmpeg" >&2
  exit 1
fi

probe_failed=0
errfile=$(mktemp "${TMPDIR:-/tmp}/dv-check.XXXXXX")
trap 'rm -f "$errfile"' EXIT

# Stream ffprobe straight into awk (nothing is held in a shell variable). pipefail makes an ffprobe
# failure fail the script; any stderr output (decode errors) is treated as a failure below.
frame_counts=$(ffprobe -v error -select_streams v:0 -show_frames \
  -show_entries frame=side_data_list -of compact "$file" 2>"$errfile" |
  awk '/^frame\|/ { n++; if (index($0, "Dolby Vision RPU")) r++ } END { print n + 0, r + 0 }') ||
  probe_failed=1

stream_info=$(ffprobe -v error -select_streams v:0 -show_streams \
  -show_entries stream=nb_frames:stream_side_data_list -of compact "$file" 2>>"$errfile" |
  awk -F'|' '
    /^stream\|/ {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^nb_frames=/) nb = substr($i, 11)
        if ($i ~ /dovi_configuration_record:dv_profile=/) p = substr($i, index($i, "=") + 1)
        if ($i ~ /dovi_configuration_record:dv_level=/) l = substr($i, index($i, "=") + 1)
        if ($i ~ /dovi_configuration_record:dv_bl_signal_compatibility_id=/) c = substr($i, index($i, "=") + 1)
      }
    }
    END {
      cfg = (p == "" ? "none" : p "/" l "/" c)
      print (nb == "" ? "N/A" : nb), cfg
    }') || probe_failed=1

if [[ $probe_failed -ne 0 ]]; then
  echo "dv-check: ffprobe failed on $file:" >&2
  cat "$errfile" >&2
  exit 1
fi
read -r frames rpu_frames <<<"$frame_counts"
read -r nb_frames config <<<"$stream_info"
echo "frames=$frames nb_frames=$nb_frames rpu_frames=$rpu_frames config=$config"

if [[ -s $errfile ]]; then
  echo "dv-check: ffprobe reported errors; the file may be truncated or corrupt:" >&2
  cat "$errfile" >&2
  exit 1
fi
if [[ $nb_frames =~ ^[0-9]+$ && $frames -ne $nb_frames ]]; then
  echo "dv-check: counted $frames frames but the stream declares $nb_frames." >&2
  exit 1
fi
if [[ $frames -gt 0 && $frames -eq $rpu_frames ]]; then exit 0; fi
exit 1
