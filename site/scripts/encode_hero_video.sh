#!/usr/bin/env bash
# Regenerates the homepage hero loops and posters from the two 30-second promos.
# Usage: site/scripts/encode_hero_video.sh WIDESCREEN.mp4 VERTICAL.mp4 [OUTPUT_DIR]
# Needs ffmpeg with libx264 and libsvtav1.
set -euo pipefail

wide_source="$1"
tall_source="$2"
output="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../assets/video" && pwd)}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$output"

# Drop the store-badge end card during the pause before the closing line. Speech
# starts 0.2 seconds in, so the picture dissolves to a still of the first frame
# and the sound fades out, instead of either overlapping the opening.
make_loop() {
  ffmpeg -nostdin -v error -y -i "$2" -filter_complex "
    [0:v]fps=30,format=yuv420p,split[va][vb];
    [va]trim=0:25.7,setpts=PTS-STARTPTS[v1];
    [vb]trim=end_frame=1,setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=0.5[v2];
    [v1][v2]xfade=transition=fade:duration=0.5:offset=25.2,format=yuv420p[v];
    [0:a]atrim=0:25.7,asetpts=PTS-STARTPTS,afade=t=out:st=25.0:d=0.7[a]" \
    -map "[v]" -map "[a]" -t 25.7 -c:v libx264 -preset fast -crf 8 -c:a pcm_s16le "$work/$1.mov"
  ffmpeg -nostdin -v error -y -ss 6.9 -i "$2" -frames:v 1 "$output/hero-$1-poster.png"
}

# encode NAME WIDTH HEIGHT AUDIO AV1_CRF [H264_CRF H264_MAXRATE]
encode() {
  local common=(-nostdin -v error -y -i "$work/$1.mov" -vf "scale=$2:$3:flags=lanczos,setsar=1"
    -g 60 -pix_fmt yuv420p -c:a aac -b:a "$4" -ac 2 -movflags +faststart)
  if [[ -n "${6:-}" ]]; then
    ffmpeg "${common[@]}" -c:v libx264 -profile:v high -refs 4 -preset slower -crf "$6" \
      -maxrate "$7" -bufsize "$7" "$output/hero-$1-$2.h264.mp4"
  fi
  SVT_LOG=1 ffmpeg "${common[@]}" -c:v libsvtav1 -preset 4 -crf "$5" \
    "$output/hero-$1-$2.av1.mp4"
}

make_loop wide "$wide_source"
make_loop tall "$tall_source"
encode wide 854 480 48k 50 30 700k
encode wide 1280 720 72k 49 29 1400k
# H.264 would be 2.8 MB at this size, so 1080p is AV1 only.
encode wide 1920 1080 72k 49
encode tall 360 640 48k 50 30 500k
encode tall 540 960 72k 49 29 900k
encode tall 720 1280 72k 49 29 1400k
