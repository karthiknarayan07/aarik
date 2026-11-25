#!/usr/bin/env bash
# Compares the per-frame Dolby Vision metadata (RPU) of a source clip and its downscaled output, to tell a
# preserved RPU from a regenerated (re-analysed) one. Frames are aligned by index (presentation order); the two
# files must have the same number of frames.
#
# Prints:
#   frames=<N> ffprobe=<version>
#   L1/L2/L5 (extension blocks), when ffprobe prints them:
#     max |dL1| min/avg/max in PQ codes, L2 present in source/output, output frames with non-zero L5 offsets
#   always, from the fields ffprobe does print:
#     max |d source_min_pq| and |d source_max_pq|, frames whose reshaping curves (pivots, polynomial and MMR
#     coefficients) are identical, frames whose other RPU fields are identical, scene-refresh frames in each
#   verdict=PASS | FAIL | INCONCLUSIVE
#
# Exit status:
#   0  PASS: every frame's L1 within L1_TOLERANCE, L2 presence matches, output L5 offsets all zero
#   1  FAIL: a check above failed, frame counts differ, a frame has no Dolby Vision metadata, or ffprobe failed
#      or reported errors
#   3  INCONCLUSIVE: this ffprobe does not print the L1/L2/L5 extension blocks (ffprobe 8.1 stops after
#      source_diagonal), so only the fields listed under "always" were compared
#
# Dev-only: needs ffprobe (brew install ffmpeg).
set -euo pipefail

# Largest allowed per-frame L1 difference, in 12-bit PQ codes (0..4095): 41 is 1% of the range.
L1_TOLERANCE=41

if [[ $# -ne 2 ]]; then
  echo "usage: dv-compare.sh <source> <output>" >&2
  exit 1
fi
for file in "$1" "$2"; do
  if [[ ! -f $file ]]; then
    echo "dv-compare: file not found: $file" >&2
    exit 1
  fi
done
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "dv-compare: ffprobe not found. Install it with: brew install ffmpeg" >&2
  exit 1
fi

workdir=$(mktemp -d "${TMPDIR:-/tmp}/dv-compare.XXXXXX")
trap 'rm -rf "$workdir"' EXIT

# One tab-separated line per frame, in presentation order:
#   index, has_dv, source_min_pq, source_max_pq, scene_refresh_flag, l1_min, l1_avg, l1_max, has_l2, l2,
#   l5_nonzero, mapping, other
# L1/L2/L5 are taken from the field names of libavutil's AVDOVIDmData (min_pq/avg_pq/max_pq, trim_*,
# left/right/top/bottom_offset), which is what an ffprobe that prints extension blocks is expected to use.
extract() {
  awk '
    function flush() {
      if (!inframe) return
      printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%d\t%s\t%s\n", n, dv, smin, smax, refresh,
        l1min, l1avg, l1max, hasl2, l2, l5nz, mapping, other
      n++
    }
    /^\[FRAME\]/ {
      inframe = 1; dv = 0; indv = 0; incomp = 0
      smin = smax = refresh = l1min = l1avg = l1max = "-"
      hasl2 = 0; l2 = ""; l5nz = 0; mapping = ""; other = ""
      next
    }
    /^\[\/FRAME\]/ { flush(); inframe = 0; next }
    /^\[SIDE_DATA\]/ { indv = 0; next }
    /^\[\/SIDE_DATA\]/ { indv = 0; next }
    /^side_data_type=Dolby Vision Metadata$/ { dv = 1; indv = 1; next }
    !indv { next }
    /^\[COMPONENT\]/ { incomp = 1; next }
    /^\[\/COMPONENT\]/ { incomp = 0; mapping = mapping "|"; next }
    /^\[/ { next }
    {
      eq = index($0, "="); if (eq == 0) next
      key = substr($0, 1, eq - 1); value = substr($0, eq + 1)
      if (key == "min_pq") { l1min = value; next }
      if (key == "avg_pq") { l1avg = value; next }
      if (key == "max_pq") { l1max = value; next }
      if (key ~ /^trim_/ || key == "target_max_pq" || key == "ms_weight") {
        hasl2 = 1; l2 = l2 key "=" value ";"; next
      }
      if (key == "left_offset" || key == "right_offset" || key == "top_offset" || key == "bottom_offset") {
        if (value + 0 != 0) l5nz = 1
        next
      }
      if (key == "source_min_pq") { smin = value; next }
      if (key == "source_max_pq") { smax = value; next }
      if (key == "scene_refresh_flag") { refresh = value; next }
      if (incomp) mapping = mapping key "=" value ";"
      else other = other key "=" value ";"
    }
  '
}

probe() {
  local file=$1 out=$2
  # Stream ffprobe straight into awk (nothing is held in a shell variable); pipefail makes an ffprobe failure
  # fail here, and any stderr output (decode errors) is treated as a failure by the caller.
  if ! ffprobe -v error -select_streams v:0 -show_frames "$file" 2>>"$workdir/stderr" | extract >"$out"; then
    echo "dv-compare: ffprobe failed on $file:" >&2
    cat "$workdir/stderr" >&2
    exit 1
  fi
}

: >"$workdir/stderr"
probe "$1" "$workdir/source.tsv"
probe "$2" "$workdir/output.tsv"
if [[ -s $workdir/stderr ]]; then
  echo "dv-compare: ffprobe reported errors; a file may be truncated or corrupt:" >&2
  cat "$workdir/stderr" >&2
  exit 1
fi

source_frames=$(wc -l <"$workdir/source.tsv" | tr -d ' ')
output_frames=$(wc -l <"$workdir/output.tsv" | tr -d ' ')
if [[ $source_frames -ne $output_frames || $source_frames -eq 0 ]]; then
  echo "dv-compare: frame counts differ or are zero: source=$source_frames output=$output_frames" >&2
  exit 1
fi

version=$(ffprobe -version | awk 'NR == 1 { print $3 }')
echo "frames=$source_frames ffprobe=$version"

status=0
awk -F'\t' -v tol="$L1_TOLERANCE" '
  function abs(x) { return x < 0 ? -x : x }
  function num(x) { return x ~ /^-?[0-9]+$/ }
  NR == FNR { src[$1] = $0; next }
  {
    split(src[$1], s, "\t")
    frames++
    if (!s[2] || !$2) { nodv++; next }
    if (num(s[3]) && num($3)) { d = abs(s[3] - $3); if (d > dmin) dmin = d }
    if (num(s[4]) && num($4)) { d = abs(s[4] - $4); if (d > dmax) dmax = d }
    if (s[5] == "1") srefresh++
    if ($5 == "1") orefresh++
    if (s[12] == $12) samemap++
    if (s[13] == $13) sameother++
    if (num(s[6]) || num($6)) exposed = 1
    if (num(s[6]) && num($6)) {
      d = abs(s[6] - $6); if (d > l1[1]) l1[1] = d
      d = abs(s[7] - $7); if (d > l1[2]) l1[2] = d
      d = abs(s[8] - $8); if (d > l1[3]) l1[3] = d
    } else if (num(s[6]) != num($6)) l1missing++
    if (s[9]) sl2 = 1
    if ($9) ol2 = 1
    if ($11) l5nz++
  }
  END {
    fail = 0
    if (nodv) { printf "frames without Dolby Vision metadata: %d\n", nodv; fail = 1 }
    if (exposed) {
      printf "L1 max |d| (PQ codes, tolerance %d): min=%d avg=%d max=%d\n", tol, l1[1], l1[2], l1[3]
      if (l1missing) printf "L1 missing on one side: %d frames\n", l1missing
      printf "L2 present: source=%s output=%s\n", sl2 ? "yes" : "no", ol2 ? "yes" : "no"
      printf "output frames with non-zero L5 offsets: %d\n", l5nz
      if (l1[1] > tol || l1[2] > tol || l1[3] > tol || l1missing || sl2 != ol2 || l5nz) fail = 1
    } else {
      print "L1/L2/L5: not printed by this ffprobe; not evaluated"
    }
    printf "max |d source_min_pq|=%d max |d source_max_pq|=%d\n", dmin, dmax
    printf "identical reshaping curves: %d/%d frames\n", samemap, frames
    printf "identical other RPU fields: %d/%d frames\n", sameother, frames
    printf "scene refresh frames: source=%d output=%d\n", srefresh, orefresh
    if (fail) { print "verdict=FAIL"; exit 1 }
    if (!exposed) { print "verdict=INCONCLUSIVE"; exit 3 }
    print "verdict=PASS"
  }
' "$workdir/source.tsv" "$workdir/output.tsv" || status=$?
exit "$status"
