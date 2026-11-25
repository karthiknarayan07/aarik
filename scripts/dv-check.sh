#!/usr/bin/env bash
# Counts video frames and how many carry a Dolby Vision RPU (per-frame metadata).
# Prints: frames=<N> rpu_frames=<M> config=<profile/level/compat>
# Exit 0 only if N > 0 and every frame has an RPU. Dev-only: needs ffprobe (brew install ffmpeg).
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
if ! command -v python3 >/dev/null 2>&1; then
  echo "dv-check: python3 not found (install the Xcode command line tools)." >&2
  exit 1
fi

frames_json=$(ffprobe -v error -select_streams v:0 -show_frames \
  -show_entries frame=side_data_list -of json "$file")
stream_json=$(ffprobe -v error -select_streams v:0 -show_streams \
  -show_entries stream=side_data_list -of json "$file")

summary=$(
  FRAMES=$frames_json STREAM=$stream_json python3 -I -c '
import json, os
frames = json.loads(os.environ["FRAMES"]).get("frames", [])
rpu = sum(
    1 for f in frames
    if any("Dolby Vision RPU" in sd.get("side_data_type", "") for sd in f.get("side_data_list", []))
)
config = "none"
for s in json.loads(os.environ["STREAM"]).get("streams", []):
    for sd in s.get("side_data_list", []):
        if "DOVI configuration record" in sd.get("side_data_type", ""):
            config = "{}/{}/{}".format(
                sd.get("dv_profile", "?"), sd.get("dv_level", "?"),
                sd.get("dv_bl_signal_compatibility_id", "?"))
print("{} {} {}".format(len(frames), rpu, config))
'
)
read -r frames rpu_frames config <<<"$summary"
echo "frames=$frames rpu_frames=$rpu_frames config=$config"
if [[ $frames -gt 0 && $frames -eq $rpu_frames ]]; then exit 0; fi
exit 1
