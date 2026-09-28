#!/bin/bash
# Turns a demo/record.sh recording into assets/demo.gif.
#
#   demo/make-gif.sh input.mp4 [crop]
#
# crop is an ffmpeg crop (w:h:x:y) around the menu card; the default fits a
# 1920x1080 display at scale 1.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
in=$1
crop=${2:-740:300:590:390}
out=$here/../assets/demo.gif

# Skip the lead-in before the menu opens and the empty tail after it closes.
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")
length=$(awk -v d="$duration" 'BEGIN { print d - 1.6 - 0.9 }')

ffmpeg -v error -y -ss 1.6 -t "$length" -i "$in" \
  -vf "crop=$crop,fps=15,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 "$out"
echo "$out"
